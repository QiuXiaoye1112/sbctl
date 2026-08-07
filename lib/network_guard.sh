# shellcheck shell=bash
# Network helpers, package manager policy, and Certbot environment bootstrap.
# Most canonical implementations live in core.sh (network/pkg) and certops.sh (certbot).
# This late-loaded compatibility module applies APT-specific execution hardening.

_apt_run_bounded() {
  local seconds=$1; shift
  if command_exists timeout; then
    # GNU timeout normally places the child in a separate process group. During
    # apt/dpkg hooks that touch the controlling TTY (for example apt-listchanges),
    # that can stop apt with SIGTTIN/SIGTTOU. Keep APT in the foreground when
    # supported, while retaining the portable BusyBox fallback used on Alpine.
    if timeout --help 2>&1 | grep -F -- '--foreground' >/dev/null; then
      timeout --foreground "$seconds" "$@"
    else
      timeout "$seconds" "$@"
    fi
  else
    "$@"
  fi
}

apt_get_guarded() {
  local total_timeout=${SBCTL_APT_TIMEOUT:-180}
  local apt_options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=15
    -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
  )
  apt_ipv4_available && apt_options+=(-o Acquire::ForceIPv4=true)

  # apt-listchanges has its own frontend and may still try to use the terminal
  # even when debconf is noninteractive. Disable it explicitly for sbctl's
  # unattended dependency bootstrap.
  _apt_run_bounded "$total_timeout" env \
    DEBIAN_FRONTEND=noninteractive \
    APT_LISTCHANGES_FRONTEND=none \
    apt-get "${apt_options[@]}" "$@"
}
