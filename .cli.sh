#!/usr/bin/env bash
#===============================================================================
# GitLab CI Library - CLI Runner
#
# Simulates GitLab CI pipeline execution using Docker containers to match
# the real CI environment, with --local fallback for direct execution.
#
# Usage:
#   ./cli.sh <command> [options]
#
# Commands:
#   build     Build the project (golang container)
#   upload    Build + upload artifacts (golang container)
#   deploy    Deploy service (debian container)
#   verify    Verify deployment (debian container)
#   all       Full pipeline: upload -> deploy -> verify
#
# Options:
#   -e, --env <file>    Environment config file (default: .env)
#   -d, --dry-run       Show docker commands without executing
#   -v, --verbose       Verbose output
#   -l, --local         Run locally without Docker containers
#   -h, --help          Show this help
#
# Examples:
#   ./cli.sh build -e .env.develop             # Docker mode (default)
#   ./cli.sh build -e .env.develop --local     # Local mode
#   ./cli.sh all -e .env.develop               # Full pipeline in Docker
#   ./cli.sh deploy -e .env.testing -d         # Dry-run: show docker command
#===============================================================================

set -eo pipefail

#===============================================================================
# Constants
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_DIR="${SCRIPT_DIR}"

# CI library files (local paths)
CI_LIB_FILE="${SCRIPT_DIR}/.gitlab-ci.lib.sh"
CI_CUSTOM_FILE="${SCRIPT_DIR}/.gitlab-ci.sh"

# Remote CI library — used when local CI_LIB_FILE does not exist.
# Override via .env or environment: CI_LIB_URL, CI_LIB_VERSION
CI_LIB_VERSION="${CI_LIB_VERSION:-custom/zxq}"
CI_LIB_URL="${CI_LIB_URL:-https://raw.githubusercontent.com/selfmaking/gitlab-ci-lib/${CI_LIB_VERSION:?}/.gitlab-ci.lib.sh}"

# Docker images and cache config — defaults applied in setup_container_vars()
# after .env is loaded, so .env values take effect.
IMAGE_BUILD=""
IMAGE_DEPLOY=""
CONTAINER_PROJECT_DIR=""
CACHE_VOLUME_PREFIX=""
CACHE_DIR=""

# Relative path from project root to script directory (for locating lib files in container)
# When cli.sh lives in a subdirectory (e.g. deploy/ci/), the container needs
# to source library files from that subdirectory, not from the project root.
# CONTAINER_CI_DIR is derived in setup_container_vars() after .env is loaded.
_project_root_abs="$(cd "${PROJECT_ROOT_DIR}" && pwd)"
SCRIPT_REL_DIR="${SCRIPT_DIR#"${_project_root_abs}"}"
SCRIPT_REL_DIR="${SCRIPT_REL_DIR#/}"
unset _project_root_abs

#===============================================================================
# CLI state
#===============================================================================

ENV_FILE=""
DRY_RUN="false"
VERBOSE="false"
LOCAL_MODE="false"
COMMAND=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#===============================================================================
# Logging
#===============================================================================

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug()   { [[ "${VERBOSE}" == "true" ]] && echo -e "${YELLOW}[DEBUG]${NC} $*"; return 0; }
log_step() {
  echo ""
  echo -e "${BLUE}================================================================${NC}"
  echo -e "${BLUE}  $*${NC}"
  echo -e "${BLUE}================================================================${NC}"
}

print_help() {
  cat << 'EOF'
Usage:
  ./cli.sh <command> [options]

Commands:
  build     Build the project (runs in golang container)
  upload    Build + upload artifacts (runs in golang container)
  deploy    Deploy service (runs in debian container)
  verify    Verify deployment (runs in debian container)
  all       Full pipeline: upload -> deploy -> verify

Options:
  -e, --env <file>    Environment config file (default: .env)
  -d, --dry-run       Show docker commands without executing
  -v, --verbose       Verbose output
  -l, --local         Run locally without Docker containers
  -h, --help          Show this help

Examples:
  ./cli.sh build -e .env.develop             # Docker mode (default)
  ./cli.sh build -e .env.develop --local     # Local mode
  ./cli.sh all -e .env.develop               # Full pipeline in Docker
  ./cli.sh deploy -e .env.testing -d         # Dry-run: show docker command

Environment config:
  1. Create per-environment configs:
     cp .env.example .env.develop
     cp .env.example .env.testing

  2. Edit the config files with your SSH, service parameters

  3. Make sure .env.* is in .gitignore
EOF
}

#===============================================================================
# Argument parsing
#===============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      build|upload|deploy|verify|all)
        COMMAND="$1"
        shift
        ;;
      -e|--env)
        ENV_FILE="$2"
        shift 2
        ;;
      -d|--dry-run)
        DRY_RUN="true"
        shift
        ;;
      -v|--verbose)
        VERBOSE="true"
        shift
        ;;
      -l|--local)
        LOCAL_MODE="true"
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        print_help
        exit 1
        ;;
    esac
  done

  [[ -z "${ENV_FILE}" ]] && ENV_FILE=".env"

  if [[ -z "${COMMAND}" ]]; then
    log_error "Please specify a command"
    print_help
    exit 1
  fi
}

#===============================================================================
# Environment loading
#===============================================================================

# Resolve .env file to absolute path
resolve_env_path() {
  local _env_path="${SCRIPT_DIR}/${ENV_FILE}"

  if [[ ! -f "${_env_path}" ]]; then
    if [[ -f "${ENV_FILE}" ]]; then
      _env_path="$(cd "$(dirname "${ENV_FILE}")" && pwd)/$(basename "${ENV_FILE}")"
    else
      log_error "Environment config not found: ${ENV_FILE}"
      log_info "Create one with: cp .env.example ${ENV_FILE}"
      exit 1
    fi
  fi

  ENV_FILE_ABS="${_env_path}"
}

# Source the env file into current shell and export all vars
load_env_file() {
  log_info "Loading env: ${ENV_FILE_ABS}"

  # shellcheck source=/dev/null
  source "${ENV_FILE_ABS}"

  log_debug "ENV_NAME=${ENV_NAME:-unset}"
  log_debug "CI_PROJECT_NAME=${CI_PROJECT_NAME:-unset}"
}

# Generate simulated GitLab CI variables from git info
setup_ci_vars() {
  export CI_PROJECT_DIR="${CI_PROJECT_DIR:-${PROJECT_ROOT_DIR}}"
  export CI_PROJECT_NAME="${CI_PROJECT_NAME:-$(basename "${PROJECT_ROOT_DIR}")}"
  export CI_COMMIT_REF_NAME="${CI_COMMIT_REF_NAME:-$(git -C "${PROJECT_ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')}"
  export CI_COMMIT_SHA="${CI_COMMIT_SHA:-$(git -C "${PROJECT_ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo 'unknown')}"
  export CI_COMMIT_SHORT_SHA="${CI_COMMIT_SHORT_SHA:-$(git -C "${PROJECT_ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')}"
  export CI_PIPELINE_ID="${CI_PIPELINE_ID:-local-$(date +%s)}"
  export CI_PIPELINE_IID="${CI_PIPELINE_IID:-1}"
  export CI_JOB_ID="${CI_JOB_ID:-local-job}"
  export CI_JOB_NAME="${CI_JOB_NAME:-${COMMAND}}"
  export CI_JOB_STAGE="${CI_JOB_STAGE:-${COMMAND}}"

  if [[ -z "${CI_COMMIT_TAG}" ]]; then
    CI_COMMIT_TAG="$(git -C "${PROJECT_ROOT_DIR}" describe --tags --exact-match 2>/dev/null || echo '')"
    export CI_COMMIT_TAG
  fi
}

# Apply container defaults after .env is loaded so .env values take effect
setup_container_vars() {
  IMAGE_BUILD="${IMAGE_BUILD:-golang:1.24}"
  IMAGE_DEPLOY="${IMAGE_DEPLOY:-i3est/debian:stable-20251229}"
  CONTAINER_PROJECT_DIR="${CONTAINER_PROJECT_DIR:-/builds/project}"
  CACHE_VOLUME_PREFIX="${CACHE_VOLUME_PREFIX:-go-cache}"
  CACHE_DIR="${CACHE_DIR:-.go}"

  # Derive CONTAINER_CI_DIR from CONTAINER_PROJECT_DIR + relative script path
  [[ -z "${SCRIPT_REL_DIR}" ]] && CONTAINER_CI_DIR="${CONTAINER_PROJECT_DIR}" || CONTAINER_CI_DIR="${CONTAINER_PROJECT_DIR}/${SCRIPT_REL_DIR}"

  log_debug "IMAGE_BUILD=${IMAGE_BUILD}"
  log_debug "IMAGE_DEPLOY=${IMAGE_DEPLOY}"
  log_debug "CACHE_VOLUME_PREFIX=${CACHE_VOLUME_PREFIX}, CACHE_DIR=${CACHE_DIR}"
}

# Load CI core library (local file first, fallback to remote URL)
load_ci_library() {
  if [[ -f "${CI_LIB_FILE}" ]]; then
    log_info "Loading CI library: ${CI_LIB_FILE}"
    # shellcheck source=/dev/null
    source "${CI_LIB_FILE}"
  else
    log_info "Local CI library not found, fetching from remote..."
    log_info "URL: ${CI_LIB_URL}"
    local _tmp_lib
    _tmp_lib="$(mktemp)"
    curl -fsSL "${CI_LIB_URL}" -o "${_tmp_lib}" || {
      log_error "Failed to fetch CI library from: ${CI_LIB_URL}"
      rm -f "${_tmp_lib}"
      exit 1
    }
    # shellcheck source=/dev/null
    source "${_tmp_lib}"
    rm -f "${_tmp_lib}"
  fi
  define_common_init
}

#===============================================================================
# Container scripts
#
# Each function mirrors the before_script + script sections from the
# GitLab CI YAML templates. The common preamble (set -eo pipefail,
# source libraries) is prepended automatically by run_in_container().
#===============================================================================

# build_then_upload — matches .build_then_upload in yml
script_build_upload() {
  # -- before_script --
  define_common_init
  do_func_invoke 'define_custom_init'
  init_first_do

  # -- script --
  define_common_init_ssh
  init_ssh_do
  init_inject_ci_bash_do
  init_final_do
  define_common_build
  do_func_invoke 'define_custom_build'
  build_job_do
  define_common_upload
  init_inject_cd_bash_do
  do_func_invoke 'define_custom_upload'
  upload_job_do
}

# build_only — matches .build_only in yml
script_build_only() {
  # -- before_script --
  define_common_init
  do_func_invoke 'define_custom_init'
  init_first_do

  # -- script --
  define_common_init_ssh
  init_ssh_do
  init_inject_ci_bash_do
  init_final_do
  define_common_build
  do_func_invoke 'define_custom_build'
  build_job_do
}

# deploy_to_env — matches .deploy_to_env in yml
script_deploy() {
  # -- before_script --
  define_common_init
  do_func_invoke 'define_custom_init'
  init_first_do
  define_common_init_ssh
  init_ssh_do

  # -- script --
  define_common_service
  define_common_deploy
  init_inject_ci_bash_do
  init_final_do
  init_inject_cd_bash_do
  do_func_invoke 'define_custom_deploy'
  deploy_job_do
}

# deploy_verify_env — matches .deploy_verify_env in yml
script_verify() {
  # -- before_script --
  define_common_init
  do_func_invoke 'define_custom_init'
  init_first_do
  define_common_init_ssh
  init_ssh_do

  # -- script --
  define_common_service
  define_common_verify
  init_inject_ci_bash_do
  init_final_do
  init_inject_cd_bash_do
  do_func_invoke 'define_custom_verify'
  verify_job_do
}

#===============================================================================
# Docker execution
#===============================================================================

# Build the full container script from a function name.
# Prepends the common preamble (source libraries) and appends the function
# body extracted via declare -f, then invokes it.
build_container_script() {
  local _func_name="${1:?}"
  local _body
  _body="$(declare -f "${_func_name}")"

  local _custom_name
  _custom_name="$(basename "${CI_CUSTOM_FILE}")"
  local _lib_name
  _lib_name="$(basename "${CI_LIB_FILE}")"

  cat << EOF
set -eo pipefail

CI_DIR="${CONTAINER_CI_DIR}"

# -- source libraries --
[[ -f "\${CI_DIR}/${_custom_name}" ]] && { . "\${CI_DIR}/${_custom_name}"; echo "Sourced ${_custom_name}: \${?}"; }
if [[ -f "\${CI_DIR}/${_lib_name}" ]]; then
  . "\${CI_DIR}/${_lib_name}"; echo "Sourced ${_lib_name}: \${?}"
else
  echo "Local lib not found, fetching from: ${CI_LIB_URL}"
  . <(curl -fsSL "${CI_LIB_URL}"); echo "Sourced remote lib: \${?}"
fi
pwd

# -- stage function --
${_body}
${_func_name}
EOF
}

# Execute a stage script inside a Docker container.
# $1: docker image
# $2: stage name (for logging)
# $3: function name whose body will be executed in the container
run_in_container() {
  local _image="${1:?}"
  local _stage="${2:?}"
  local _func_name="${3:?}"

  local _script
  _script="$(build_container_script "${_func_name}")"

  # Create temp env-file
  local _env_file
  _env_file=$(mktemp)

  do_container_generate_env_file "${_env_file}" "${CONTAINER_PROJECT_DIR}" "${ENV_FILE_ABS}"

  # Configure container execution globals
  CONTAINER_ENV_FILE="${_env_file}"
  CONTAINER_SOURCE_DIR="${PROJECT_ROOT_DIR}"
  # CONTAINER_PROJECT_DIR already set as constant

  # Build cache volume (language-specific: .go for Go, .m2 for Maven, etc.)
  CONTAINER_EXTRA_VOLUMES=()
  if [[ "${_image}" == "${IMAGE_BUILD}" && -n "${CACHE_DIR}" ]]; then
    local _project_name="${CI_PROJECT_NAME:-$(basename "${PROJECT_ROOT_DIR}")}"
    do_container_add_volume "${CACHE_VOLUME_PREFIX}-${_project_name}:${CONTAINER_PROJECT_DIR}/${CACHE_DIR}"
  fi

  # Mount symlink targets so they resolve inside the container
  local _mounted_dirs=""
  for _ci_file in "${CI_LIB_FILE}" "${CI_CUSTOM_FILE}"; do
    if [[ -L "${_ci_file}" ]]; then
      local _real_dir
      _real_dir="$(dirname "$(readlink -f "${_ci_file}")")"
      if [[ ":${_mounted_dirs}:" != *":${_real_dir}:"* ]]; then
        _mounted_dirs="${_mounted_dirs:+${_mounted_dirs}:}${_real_dir}"
        do_container_add_volume "${_real_dir}:${_real_dir}:ro"
        log_debug "Symlink mount: ${_real_dir}"
      fi
    fi
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_step "[DRY-RUN] ${_stage}"
    log_info "Image: ${_image}"
    log_info "Command:"
    # Build a preview of what do_container_run would execute
    local _preview="docker run --rm -i --env-file ${_env_file}"
    for _name in "${CONTAINER_MULTILINE_VARS[@]}"; do
      _preview+=" -e ${_name}"
    done
    _preview+=" -v ${CONTAINER_SOURCE_DIR}:${CONTAINER_PROJECT_DIR}"
    for _vol in "${CONTAINER_EXTRA_VOLUMES[@]}"; do
      _preview+=" -v ${_vol}"
    done
    _preview+=" -w ${CONTAINER_PROJECT_DIR} ${_image} bash -eo pipefail -s"
    echo -e "${CYAN}${_preview}${NC} <<'SCRIPT'"
    echo "${_script}"
    echo "SCRIPT"
    echo ""
    if [[ "${VERBOSE}" == "true" ]]; then
      log_info "Environment file contents:"
      cat "${_env_file}"
      echo ""
    fi
    rm -f "${_env_file}"
    return 0
  fi

  log_step "Docker: ${_stage} [${_image}]"

  local _status=0
  do_container_run "${_image}" "${_stage}" "${_script}" || _status=$?
  rm -f "${_env_file}"

  if [[ ${_status} -ne 0 ]]; then
    log_error "Stage '${_stage}' failed with exit code ${_status}"
    exit ${_status}
  fi
}

#===============================================================================
# Local mode execution (--local)
#===============================================================================

local_load_ci_library() {
  log_step "Loading CI library (local)"

  load_ci_library
  local_load_custom_script

  log_success "Library loaded"
}

local_load_custom_script() {
  local _custom_path="${CI_CUSTOM_FILE}"
  if [[ -f "${_custom_path}" ]]; then
    # shellcheck source=/dev/null
    source "${_custom_path}"
    log_success "Custom script loaded"
  fi
}

local_do_init() {
  # before_script
  do_func_invoke 'define_custom_init'
  init_first_do

  # script
  define_common_init_ssh
  init_ssh_do
  init_inject_ci_bash_do
  init_final_do
}

local_do_build() {
  log_step "Build (local)"
  define_common_build
  do_func_invoke 'define_custom_build'
  build_job_do
  log_success "Build done"
}

local_do_upload() {
  log_step "Upload (local)"
  define_common_upload
  init_inject_cd_bash_do
  do_func_invoke 'define_custom_upload'
  upload_job_do
  log_success "Upload done"
}

local_do_deploy() {
  log_step "Deploy (local)"

  define_common_service
  define_common_deploy
  init_inject_ci_bash_do
  init_final_do

  init_inject_cd_bash_do
  do_func_invoke 'define_custom_deploy'

  deploy_job_do

  log_success "Deploy done"
}

local_do_verify() {
  log_step "Verify (local)"
  define_common_service
  define_common_verify
  init_inject_ci_bash_do
  init_final_do
  init_inject_cd_bash_do
  do_func_invoke 'define_custom_verify'
  verify_job_do
  log_success "Verify done"
}

run_local() {
  local _command="${1:?}"

  load_env_file
  setup_ci_vars
  local_load_ci_library

  local_do_init

  case "${_command}" in
    build)
      local_do_build
      ;;
    upload)
      local_do_build
      local_do_upload
      ;;
    deploy)
      local_do_deploy
      ;;
    verify)
      local_do_verify
      ;;
    all)
      local_do_build
      local_do_upload
      local_do_deploy
      local_do_verify
      ;;
  esac
}

#===============================================================================
# Docker mode execution (default)
#===============================================================================

run_docker() {
  local _command="${1:?}"

  load_env_file
  setup_ci_vars
  setup_container_vars
  load_ci_library

  case "${_command}" in
    build)
      run_in_container "${IMAGE_BUILD}" "build" script_build_only
      ;;
    upload)
      run_in_container "${IMAGE_BUILD}" "build+upload" script_build_upload
      ;;
    deploy)
      run_in_container "${IMAGE_DEPLOY}" "deploy" script_deploy
      ;;
    verify)
      run_in_container "${IMAGE_DEPLOY}" "verify" script_verify
      ;;
    all)
      run_in_container "${IMAGE_BUILD}" "build+upload" script_build_upload
      run_in_container "${IMAGE_DEPLOY}" "deploy" script_deploy
      run_in_container "${IMAGE_DEPLOY}" "verify" script_verify
      ;;
  esac
}

#===============================================================================
# Main
#===============================================================================

main() {
  parse_args "$@"
  resolve_env_path

  local _mode="docker"
  [[ "${LOCAL_MODE}" == "true" ]] && _mode="local"

  log_info "Command: ${COMMAND} | Env: ${ENV_FILE} | Mode: ${_mode}"
  [[ "${DRY_RUN}" == "true" ]] && log_info "Dry-run enabled"
  echo ""

  if [[ "${LOCAL_MODE}" == "true" ]]; then
    run_local "${COMMAND}"
  else
    run_docker "${COMMAND}"
  fi

  echo ""
  log_success "Done."
}

main "$@"
