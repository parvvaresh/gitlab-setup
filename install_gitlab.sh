#!/usr/bin/env bash
set -euo pipefail

# GitLab CE installer for Ubuntu 22.04 (jammy)
# Supports: IP-only setup OR domain + HTTPS (Let's Encrypt)
#
# Settings are read from .env (next to this script) or from the file in $ENV_FILE.
# Anything missing is asked interactively.

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

# ask VAR "Prompt" [default] — prompts only if VAR is empty
ask() {
  local var="$1" prompt="$2" def="${3:-}" val="${!1:-}"
  if [[ -z "${val}" && -t 0 ]]; then
    read -rp "${prompt}${def:+ [${def}]}: " val
  fi
  printf -v "${var}" '%s' "${val:-${def}}"
}

confirm() {
  is_yes "${ASSUME_YES:-no}" && return 0
  [[ -t 0 ]] || die "Non-interactive run: set ASSUME_YES=yes to continue."
  local ans
  read -rp "$1 [y/N]: " ans
  is_yes "${ans}"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"
    exit 1
  fi
}

prompt_inputs() {
  echo "=== GitLab CE Installer ==="
  ask SERVER_IP "Enter SERVER PUBLIC IP (e.g., 31.184.130.229)"
  [[ -n "${SERVER_IP}" ]] || die "SERVER_IP is required."

  local default_url
  ask USE_DOMAIN "Do you already have a real domain to use? (y/N)" "no"
  if is_yes "${USE_DOMAIN}"; then
    USE_DOMAIN="yes"
    ask GITLAB_HOSTNAME "Enter domain/hostname (e.g., gitlab.example.com)"
    [[ -n "${GITLAB_HOSTNAME}" ]] || die "GITLAB_HOSTNAME is required when using a domain."

    ask USE_LETSENCRYPT "Enable HTTPS with Let's Encrypt? (Y/n)" "yes"
    if is_yes "${USE_LETSENCRYPT}"; then
      USE_LETSENCRYPT="yes"
      default_url="https://${GITLAB_HOSTNAME}"
      ask LE_EMAIL "Contact email for Let's Encrypt (e.g., you@example.com)"
      [[ -n "${LE_EMAIL}" ]] || die "LE_EMAIL is required for Let's Encrypt."
    else
      USE_LETSENCRYPT="no"
      default_url="http://${GITLAB_HOSTNAME}"
    fi
  else
    # IP-only mode (or local hostname)
    USE_DOMAIN="no"
    USE_LETSENCRYPT="no"
    ask GITLAB_HOSTNAME "Enter a local hostname" "gitlab.local"
    ask ACCESS_VIA "Expose GitLab via 'ip' (http://${SERVER_IP}) or 'hostname' (http://${GITLAB_HOSTNAME})" "ip"
    if [[ "${ACCESS_VIA,,}" == "hostname" ]]; then
      default_url="http://${GITLAB_HOSTNAME}"
    else
      default_url="http://${SERVER_IP}"
    fi
  fi
  EXTERNAL_URL="${EXTERNAL_URL:-${default_url}}"

  echo
  echo "Summary:"
  echo "  SERVER_IP       = ${SERVER_IP}"
  echo "  GITLAB_HOSTNAME = ${GITLAB_HOSTNAME}"
  echo "  EXTERNAL_URL    = ${EXTERNAL_URL}"
  echo "  LETS_ENCRYPT    = ${USE_LETSENCRYPT}"
  [[ "${USE_LETSENCRYPT}" == "yes" ]] && echo "  LE_EMAIL        = ${LE_EMAIL}"
  echo "  CREATE_BACKUP   = ${CREATE_BACKUP:-yes}"
  echo "  INSTALL_RUNNER  = ${INSTALL_RUNNER:-no}"
  echo
  confirm "Proceed with these settings?" || { echo "Aborted."; exit 1; }
}

prep_network() {
  # Optional sanity check: does hostname resolve to the server IP (if using domain)?
  if [[ "${USE_LETSENCRYPT}" == "yes" || "${EXTERNAL_URL}" == http*://${GITLAB_HOSTNAME}* ]]; then
    if command -v getent >/dev/null 2>&1; then
      RESOLVED_IP="$(getent hosts "${GITLAB_HOSTNAME}" | awk '{print $1}' | head -n1 || true)"
      if [[ -n "${RESOLVED_IP}" && "${RESOLVED_IP}" != "${SERVER_IP}" ]]; then
        echo "WARNING: ${GITLAB_HOSTNAME} resolves to ${RESOLVED_IP}, not ${SERVER_IP}."
        echo "Let's Encrypt requires the domain to resolve to this server."
        confirm "Continue anyway?" || exit 1
      fi
    fi
  fi

  # Open basic ports (UFW) if available
  if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
}

setup_hostname_and_hosts() {
  echo ">> Setting system hostname to '${GITLAB_HOSTNAME}' ..."
  hostnamectl set-hostname "${GITLAB_HOSTNAME}"

  # Ensure /etc/hosts maps server IP to hostname (helps local resolution)
  if ! grep -Eq "^\s*${SERVER_IP}\s+.*\b${GITLAB_HOSTNAME}\b" /etc/hosts; then
    echo ">> Adding '${SERVER_IP} ${GITLAB_HOSTNAME} gitlab' to /etc/hosts"
    echo "${SERVER_IP} ${GITLAB_HOSTNAME} gitlab" >> /etc/hosts
  fi
}

apt_prep() {
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  apt install -y curl ca-certificates apt-transport-https gnupg lsb-release
}

add_gitlab_repo() {
  echo ">> Adding GitLab CE repository ..."
  curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
  apt update
}

install_gitlab() {
  echo ">> Installing GitLab CE with EXTERNAL_URL='${EXTERNAL_URL}' ..."
  EXTERNAL_URL="${EXTERNAL_URL}" apt-get install -y gitlab-ce
}

configure_gitlab() {
  # If Let's Encrypt is requested, write into /etc/gitlab/gitlab.rb before reconfigure
  if [[ "${USE_LETSENCRYPT}" == "yes" ]]; then
    echo ">> Enabling Let's Encrypt in /etc/gitlab/gitlab.rb"
    # Ensure external_url is correct and LE is enabled
    if grep -q '^external_url' /etc/gitlab/gitlab.rb; then
      sed -i "s|^external_url .*|external_url \"${EXTERNAL_URL}\"|g" /etc/gitlab/gitlab.rb
    else
      echo "external_url \"${EXTERNAL_URL}\"" >> /etc/gitlab/gitlab.rb
    fi
    # Add/replace LE settings
    if grep -q "^letsencrypt\['enable'\]" /etc/gitlab/gitlab.rb; then
      sed -i "s|^letsencrypt\['enable'\].*|letsencrypt['enable'] = true|g" /etc/gitlab/gitlab.rb
    else
      echo "letsencrypt['enable'] = true" >> /etc/gitlab/gitlab.rb
    fi
    if grep -q "^letsencrypt\['contact_emails'\]" /etc/gitlab/gitlab.rb; then
      sed -i "s|^letsencrypt\['contact_emails'\].*|letsencrypt['contact_emails'] = ['${LE_EMAIL}']|g" /etc/gitlab/gitlab.rb
    else
      echo "letsencrypt['contact_emails'] = ['${LE_EMAIL}']" >> /etc/gitlab/gitlab.rb
    fi
  fi

  echo ">> gitlab-ctl reconfigure (this may take several minutes) ..."
  gitlab-ctl reconfigure

  echo ">> GitLab services:"
  gitlab-ctl status || true

  echo ">> Initial root password (valid for 24h after first reconfigure):"
  if [[ -f /etc/gitlab/initial_root_password ]]; then
    cat /etc/gitlab/initial_root_password
  else
    echo "File /etc/gitlab/initial_root_password not found."
    echo "Reset with: gitlab-rake \"gitlab:password:reset[root]\""
  fi
}

create_backup() {
  is_yes "${CREATE_BACKUP:-yes}" || return 0
  echo ">> Creating initial backup ..."
  gitlab-rake gitlab:backup:create
  echo "Backup location: /var/opt/gitlab/backups/"
}

install_runner() {
  is_yes "${INSTALL_RUNNER:-no}" || return 0
  echo ">> Installing GitLab Runner on this server ..."
  local extra_hosts="${RUNNER_DOCKER_EXTRA_HOSTS:-}"
  # Job containers can't see this server's /etc/hosts; give them the local hostname mapping.
  if [[ -z "${extra_hosts}" && "${USE_DOMAIN}" != "yes" ]]; then
    extra_hosts="${GITLAB_HOSTNAME}:${SERVER_IP}"
  fi
  GITLAB_URL="${GITLAB_URL:-${EXTERNAL_URL}}" \
  RUNNER_DOCKER_EXTRA_HOSTS="${extra_hosts}" \
    bash "${SCRIPT_DIR}/install_gitlab_runner.sh"
}

post_notes() {
  echo
  echo "=============================================================="
  echo " GitLab is installed!"
  echo " Open in browser:"
  echo "   ${EXTERNAL_URL}"
  echo
  echo "If you used a local hostname and want to access from your laptop,"
  echo "add to your local hosts file:"
  echo "   ${SERVER_IP} ${GITLAB_HOSTNAME}"
  echo
  echo "To switch later to a real domain + HTTPS:"
  echo "  1) Point DNS: gitlab.yourdomain.tld -> ${SERVER_IP}"
  echo "  2) Edit /etc/gitlab/gitlab.rb:"
  echo "       external_url \"https://gitlab.yourdomain.tld\""
  echo "       letsencrypt['enable'] = true"
  echo "       letsencrypt['contact_emails'] = ['you@example.com']"
  echo "  3) Run: gitlab-ctl reconfigure"
  echo
  echo "To add a GitLab Runner (here or on another server):"
  echo "  sudo bash install_gitlab_runner.sh"
  echo "=============================================================="
}

main() {
  require_root
  load_env
  prompt_inputs
  prep_network
  setup_hostname_and_hosts
  apt_prep
  add_gitlab_repo
  install_gitlab
  configure_gitlab
  create_backup
  install_runner
  post_notes
}

main "$@"
