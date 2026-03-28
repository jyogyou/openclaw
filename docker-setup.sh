#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
WEIXIN_PLUGIN_SPEC="@tencent-weixin/openclaw-weixin@latest"
SUDO=""

log() {
  printf '[openclaw-setup] %s\n' "$*"
}

fail() {
  printf '[openclaw-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif [[ -n "${SUDO}" ]]; then
    "${SUDO}" "$@"
  else
    fail "root privileges are required for: $*"
  fi
}

wait_http_ok() {
  local url="$1"
  local timeout="${2:-120}"
  local start
  start="$(date +%s)"
  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

wait_file() {
  local path="$1"
  local timeout="${2:-120}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -f "$path" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  need_cmd curl
  log "docker not found, installing via get.docker.com"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  run_root sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
}

enable_docker() {
  if command -v systemctl >/dev/null 2>&1; then
    log "enabling docker service"
    run_root systemctl enable --now docker
  fi
}

wait_docker_ready() {
  local start
  start="$(date +%s)"
  while true; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= 120 )); then
      fail "docker daemon did not become ready in time"
    fi
    sleep 2
  done
}

install_autostart() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not found, skipping compose autostart installation"
    return 0
  fi
  log "installing systemd autostart"
  run_root bash "${PROJECT_DIR}/install-autostart.sh"
}

deploy_stack() {
  log "building and starting docker compose stack"
  cd "${PROJECT_DIR}"
  docker compose up -d --build
}

ensure_weixin_plugin() {
  local plugin_pkg="${PROJECT_DIR}/openclaw-data/extensions/openclaw-weixin/package.json"
  if wait_file "${plugin_pkg}" 300; then
    log "weixin plugin detected in shared volume"
    return 0
  fi
  log "weixin plugin not detected yet, forcing installation in gateway"
  docker exec openclaw-gateway sh -lc \
    "HOME=/home/node node dist/index.js plugins install '${WEIXIN_PLUGIN_SPEC}'"
  wait_file "${plugin_pkg}" 180 || fail "weixin plugin installation did not complete"
}

verify_stack() {
  log "waiting for openclaw gateway health"
  wait_http_ok "http://127.0.0.1:18789/healthz" 600 || fail "gateway health check failed"
  log "waiting for clawpanel web ui"
  wait_http_ok "http://127.0.0.1:1420" 300 || fail "clawpanel web ui did not become ready"
  ensure_weixin_plugin
  docker builder prune -af >/dev/null 2>&1 || true
}

print_summary() {
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  log "deployment completed"
  echo
  echo "ClawPanel: http://127.0.0.1:1420"
  if [[ -n "${host_ip}" ]]; then
    echo "ClawPanel LAN: http://${host_ip}:1420"
  fi
  echo "OpenClaw Gateway health: http://127.0.0.1:18789/healthz"
  echo "Default ClawPanel password: 123456"
  echo
  echo "Useful commands:"
  echo "  cd ${PROJECT_DIR}"
  echo "  docker compose ps"
  echo "  docker compose logs -f openclaw-gateway"
  echo "  docker compose logs -f clawpanel"
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || fail "this script only supports Linux"
  [[ -f "${COMPOSE_FILE}" ]] || fail "docker-compose.yml not found in ${PROJECT_DIR}"
  if [[ "${EUID}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi

  install_docker_if_missing
  need_cmd docker
  enable_docker
  wait_docker_ready
  deploy_stack
  verify_stack
  install_autostart
  print_summary
}

main "$@"
