#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="openclaw-compose.service"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${PROJECT_DIR}/openclaw-compose.service"
DOCKER_BIN="$(command -v docker || true)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root."
  echo "Usage: sudo bash ${PROJECT_DIR}/install-autostart.sh"
  exit 1
fi

if [[ -z "${DOCKER_BIN}" ]]; then
  echo "docker command not found."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found. This script only supports systemd-based Linux."
  exit 1
fi

if [[ ! -f "${TEMPLATE_PATH}" ]]; then
  echo "service template not found: ${TEMPLATE_PATH}"
  exit 1
fi

sed \
  -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
  -e "s|__DOCKER_BIN__|${DOCKER_BIN}|g" \
  "${TEMPLATE_PATH}" >"/etc/systemd/system/${SERVICE_NAME}"

systemctl enable docker
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
if [[ "${OPENCLAW_SKIP_INITIAL_BUILD:-0}" != "1" ]]; then
  if ! ${DOCKER_BIN} compose -f "${PROJECT_DIR}/docker-compose.yml" up -d --build; then
    echo "warning: initial build/start failed during autostart install; service is still installed."
  fi
fi
systemctl restart "${SERVICE_NAME}"

echo
echo "Installed and started ${SERVICE_NAME}"
echo "Project directory: ${PROJECT_DIR}"
echo "Check status with:"
echo "  systemctl status ${SERVICE_NAME}"
