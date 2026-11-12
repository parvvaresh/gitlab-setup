#!/usr/bin/env bash
set -euo pipefail

# GitLab Runner installer + registration for Ubuntu 22.04 (jammy)
#
# Works on the GitLab server itself or on a separate machine.
# Settings are read from .env (next to this script) or from the file in $ENV_FILE.
# Anything missing is asked interactively.
#
# Token:
#   - Create a runner in GitLab (Admin > CI/CD > Runners > New instance runner,
#     or Project > Settings > CI/CD > Runners) and put the glrt-... token in RUNNER_TOKEN.
#   - On the GitLab server itself, leave RUNNER_TOKEN empty: an instance runner is
#     created automatically via gitlab-rails.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

die() { echo "ERROR: $*" >&2; exit 1; }
is_yes() { [[ "${1,,}" =~ ^(y|yes|true|1)$ ]]; }

load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    echo ">> Loading settings from ${ENV_FILE}"
    # Variables already exported in the environment win over .env
    local saved
    saved="$(export -p | sed "s/^declare -x /declare -gx /")"
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
    eval "${saved}"
  fi
}

ask() {
  local var="$1" prompt="$2" def="${3:-}" val="${!1:-}"
  if [[ -z "${val}" && -t 0 ]]; then
    read -rp "${prompt}${def:+ [${def}]}: " val
  fi
  printf -v "${var}" '%s' "${val:-${def}}"
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Please run as root: sudo bash $0"
}

prompt_inputs() {
  echo "=== GitLab Runner Installer ==="
  ask GITLAB_URL "GitLab URL (e.g., https://gitlab.example.com or http://31.184.130.229)"
  [[ -n "${GITLAB_URL}" ]] || die "GITLAB_URL is required."
  GITLAB_URL="${GITLAB_URL%/}"

  ask RUNNER_EXECUTOR "Executor (docker/shell)" "docker"
  case "${RUNNER_EXECUTOR}" in docker|shell) ;; *) die "Unsupported RUNNER_EXECUTOR: ${RUNNER_EXECUTOR}";; esac

  RUNNER_NAME="${RUNNER_NAME:-$(hostname)-runner}"
  RUNNER_DOCKER_IMAGE="${RUNNER_DOCKER_IMAGE:-alpine:latest}"
  RUNNER_RUN_UNTAGGED="${RUNNER_RUN_UNTAGGED:-yes}"
  RUNNER_CONCURRENT="${RUNNER_CONCURRENT:-}"

  # Token can be auto-created on the GitLab server, so only ask elsewhere
  if [[ -z "${RUNNER_TOKEN:-}" ]] && ! command -v gitlab-rails >/dev/null 2>&1; then
    ask RUNNER_TOKEN "Runner token (glrt-...)"
    [[ -n "${RUNNER_TOKEN}" ]] || die "RUNNER_TOKEN is required (GitLab is not installed on this machine)."
  fi
}

install_runner_pkg() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v gitlab-runner >/dev/null 2>&1; then
    echo ">> gitlab-runner already installed: $(gitlab-runner --version | head -n1)"
    return
  fi
  echo ">> Installing gitlab-runner ..."
  apt-get update
  apt-get install -y curl ca-certificates
  curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash
  apt-get install -y gitlab-runner
}

install_docker() {
  [[ "${RUNNER_EXECUTOR}" == "docker" ]] || return 0
  if ! command -v docker >/dev/null 2>&1; then
    echo ">> Installing Docker (docker.io) ..."
    apt-get install -y docker.io
  fi
  systemctl enable --now docker
  usermod -aG docker gitlab-runner || true
}

create_token_locally() {
  echo ">> No RUNNER_TOKEN given; creating an instance runner via gitlab-rails (takes ~1 min) ..."
  local out
  out="$(R_NAME="${RUNNER_NAME}" R_TAGS="${RUNNER_TAGS:-}" \
         R_UNTAGGED="$(is_yes "${RUNNER_RUN_UNTAGGED}" && echo true || echo false)" \
    gitlab-rails runner '
      user = User.find_by_username("root") || User.admins.first
      params = {
        runner_type: "instance_type",
        description: ENV["R_NAME"],
        tag_list: ENV["R_TAGS"].to_s.split(",").map(&:strip).reject(&:empty?),
        run_untagged: ENV["R_UNTAGGED"] == "true"
      }
      result = Ci::Runners::CreateRunnerService.new(user: user, params: params).execute
      abort("CreateRunnerService failed: #{result.message}") unless result.success?
      puts "RUNNER_TOKEN=#{result.payload[:runner].token}"
    ' 2>&1)" || { echo "${out}"; die "Could not create runner token. Create one in the GitLab UI and set RUNNER_TOKEN."; }
  RUNNER_TOKEN="$(sed -n 's/^RUNNER_TOKEN=//p' <<<"${out}" | tail -n1)"
  [[ -n "${RUNNER_TOKEN}" ]] || { echo "${out}"; die "Runner token not found in gitlab-rails output."; }
}

register_runner() {
  local cfg=/etc/gitlab-runner/config.toml
  if [[ -f "${cfg}" ]] && grep -q "name = \"${RUNNER_NAME}\"" "${cfg}"; then
    echo ">> Runner '${RUNNER_NAME}' is already registered in ${cfg}; skipping registration."
    return
  fi

  [[ -n "${RUNNER_TOKEN:-}" ]] || create_token_locally

  local args=(
    register --non-interactive
    --url "${GITLAB_URL}"
    --name "${RUNNER_NAME}"
    --executor "${RUNNER_EXECUTOR}"
  )

  if [[ "${RUNNER_TOKEN}" == glrt-* ]]; then
    # Runner authentication token: tags/untagged/locked are configured in GitLab, not here
    args+=(--token "${RUNNER_TOKEN}")
  else
    # Legacy registration token (deprecated in GitLab 16+, disabled by default in 17+)
    args+=(--registration-token "${RUNNER_TOKEN}" --run-untagged="$(is_yes "${RUNNER_RUN_UNTAGGED}" && echo true || echo false)")
    [[ -n "${RUNNER_TAGS:-}" ]] && args+=(--tag-list "${RUNNER_TAGS}")
  fi

  if [[ "${RUNNER_EXECUTOR}" == "docker" ]]; then
    args+=(--docker-image "${RUNNER_DOCKER_IMAGE}" --docker-volumes /cache)
    is_yes "${RUNNER_DOCKER_PRIVILEGED:-no}" && args+=(--docker-privileged)
    if [[ -n "${RUNNER_DOCKER_EXTRA_HOSTS:-}" ]]; then
      local h
      IFS=',' read -ra hosts <<<"${RUNNER_DOCKER_EXTRA_HOSTS}"
      for h in "${hosts[@]}"; do args+=(--docker-extra-hosts "${h// /}"); done
    fi
  fi

  [[ -n "${RUNNER_TLS_CA_FILE:-}" ]] && args+=(--tls-ca-file "${RUNNER_TLS_CA_FILE}")

  echo ">> Registering runner '${RUNNER_NAME}' with ${GITLAB_URL} (executor: ${RUNNER_EXECUTOR}) ..."
  gitlab-runner "${args[@]}"
}

finalize() {
  local cfg=/etc/gitlab-runner/config.toml
  if [[ -n "${RUNNER_CONCURRENT}" && -f "${cfg}" ]]; then
    sed -i "s/^concurrent = .*/concurrent = ${RUNNER_CONCURRENT}/" "${cfg}"
  fi
  systemctl enable gitlab-runner >/dev/null 2>&1 || true
  systemctl restart gitlab-runner
  gitlab-runner verify || true

  echo
  echo "=============================================================="
  echo " GitLab Runner '${RUNNER_NAME}' is installed and registered."
  echo "   GitLab:   ${GITLAB_URL}"
  echo "   Executor: ${RUNNER_EXECUTOR}"
  echo " Check it in GitLab: Admin > CI/CD > Runners"
  echo " Useful: gitlab-runner list | gitlab-runner verify | journalctl -u gitlab-runner -f"
  echo "=============================================================="
}

main() {
  require_root
  load_env
  prompt_inputs
  install_runner_pkg
  install_docker
  register_runner
  finalize
}

main "$@"
