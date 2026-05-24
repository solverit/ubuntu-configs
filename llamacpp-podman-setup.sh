#!/usr/bin/env bash
set -euo pipefail

# setup-llamacpp-rocm-user.sh
#
# Idempotent rootless Podman + user systemd Quadlet setup for llama.cpp ROCm on Ubuntu.
#
# Default model config is created only if it does not exist:
#   Qwen/Qwen3-Coder-Next-GGUF
#   Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf
#
# Target hardware:
#   AMD Ryzen AI MAX+ 395 / Strix Halo
#
# IMPORTANT:
#   For large models on Strix Halo 128 GB, GRUB should contain:
#     iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856
#
# This script does NOT edit GRUB automatically.

IMAGE_DEFAULT="${LLAMACPP_ROCM_IMAGE:-docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.2}"
SERVICE_NAME="${LLAMACPP_SERVICE_NAME:-llama.cpp-rocm}"

BASE_DIR="${LLAMACPP_BASE_DIR:-${HOME}/.llamacpp}"
CACHE_DIR="${BASE_DIR}/cache"
CONFIG_DIR="${BASE_DIR}/config"
SCRIPTS_DIR="${BASE_DIR}/scripts"

QUADLET_DIR="${HOME}/.config/containers/systemd"

ENV_FILE="${CONFIG_DIR}/llama.env"
START_SCRIPT="${SCRIPTS_DIR}/start-llama.sh"
QUADLET_FILE="${QUADLET_DIR}/${SERVICE_NAME}.container"

SYSTEMD_SERVICE="${SERVICE_NAME}.service"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    return 1
  fi
}

has_group() {
  id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

contains_cmdline_param() {
  local param="$1"
  grep -qw "$param" /proc/cmdline
}

section() {
  echo
  echo "==> $*"
}

warn() {
  echo "WARNING: $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

write_if_changed() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"

  cat > "$tmp"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    echo "Unchanged: $target"
  else
    install -m 0644 "$tmp" "$target"
    rm -f "$tmp"
    echo "Written: $target"
  fi
}

write_executable_if_changed() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"

  cat > "$tmp"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    chmod +x "$target"
    echo "Unchanged: $target"
  else
    install -m 0755 "$tmp" "$target"
    rm -f "$tmp"
    echo "Written: $target"
  fi
}

if [[ "${EUID}" -eq 0 ]]; then
  die "Do not run this script as root. Run it as your normal user."
fi

section "Checking required tools"

need_cmd podman || die "Install podman first: sudo apt install -y podman"
need_cmd systemctl || die "systemctl not found"
need_cmd loginctl || die "loginctl not found"
need_cmd curl || warn "curl not found. Health-check examples will require curl."

section "Checking ROCm device nodes"

if [[ ! -e /dev/kfd ]]; then
  warn "/dev/kfd not found. ROCm will not work until the AMD kernel driver exposes /dev/kfd."
else
  ls -l /dev/kfd
fi

if [[ ! -d /dev/dri ]]; then
  warn "/dev/dri not found. GPU device nodes are missing."
else
  ls -l /dev/dri || true
fi

section "Checking user groups"

if ! has_group render; then
  warn "User '$USER' is not in group 'render'."
  warn "Run: sudo usermod -aG render,video $USER"
  warn "Then reboot or fully log out and log in again."
fi

if ! has_group video; then
  warn "User '$USER' is not in group 'video'."
  warn "Run: sudo usermod -aG render,video $USER"
  warn "Then reboot or fully log out and log in again."
fi

section "Checking Strix Halo GRUB/kernel parameters"

missing_kernel_params=0

if ! contains_cmdline_param "iommu=pt"; then
  warn "Missing kernel parameter: iommu=pt"
  missing_kernel_params=1
fi

if ! contains_cmdline_param "amdgpu.gttsize=126976"; then
  warn "Missing kernel parameter: amdgpu.gttsize=126976"
  missing_kernel_params=1
fi

if ! contains_cmdline_param "ttm.pages_limit=32505856"; then
  warn "Missing kernel parameter: ttm.pages_limit=32505856"
  missing_kernel_params=1
fi

if [[ "$missing_kernel_params" -eq 1 ]]; then
  cat >&2 <<'EOT'

For AMD Ryzen AI MAX+ 395 / Strix Halo with 128 GB unified memory,
large models may fail around 64 GB allocation unless GRUB has:

  iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856

Manual fix:

  sudo nano /etc/default/grub

Example:

  GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856"

Then:

  sudo update-grub
  sudo reboot

This script will continue, but large Q8_0 models may fail until this is fixed.

EOT
fi

section "Creating user directory structure"

mkdir -p "$CACHE_DIR" "$CONFIG_DIR" "$SCRIPTS_DIR" "$QUADLET_DIR"

section "Creating default model config if missing"

if [[ -f "$ENV_FILE" ]]; then
  echo "Keeping existing config: $ENV_FILE"
else
  cat > "$ENV_FILE" <<'EOT'
# ~/.llamacpp/config/llama.env
#
# Current llama.cpp model configuration.
#
# Edit this file and restart:
#
#   systemctl --user restart llama.cpp-rocm.service
#
# Default model:
#   Qwen/Qwen3-Coder-Next-GGUF
#   Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf

HF_REPO="Qwen/Qwen3-Coder-Next-GGUF"
HF_FILE="Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf"

HOST="0.0.0.0"
PORT="7777"

CTX="242144"
NGL="999"

EXTRA_ARGS="-fa 1 --no-mmap --jinja"
EOT
  echo "Created: $ENV_FILE"
fi

section "Writing container start script"

write_executable_if_changed "$START_SCRIPT" <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/config/llama.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${HOST:=0.0.0.0}"
: "${PORT:=7777}"
: "${CTX:=8192}"
: "${NGL:=999}"
: "${EXTRA_ARGS:=}"

echo "Starting llama-server"
echo "HF_REPO=${HF_REPO:-}"
echo "HF_FILE=${HF_FILE:-}"
echo "HOST=${HOST}"
echo "PORT=${PORT}"
echo "CTX=${CTX}"
echo "NGL=${NGL}"
echo "EXTRA_ARGS=${EXTRA_ARGS}"
echo "LLAMA_CACHE=${LLAMA_CACHE:-}"

if [[ -z "${HF_REPO:-}" ]]; then
  echo "ERROR: HF_REPO is not set in ${CONFIG_FILE}" >&2
  exit 1
fi

if [[ -n "${HF_FILE:-}" ]]; then
  exec llama-server \
    --hf-repo "${HF_REPO}" \
    --hf-file "${HF_FILE}" \
    --host "${HOST}" \
    --port "${PORT}" \
    -c "${CTX}" \
    -ngl "${NGL}" \
    ${EXTRA_ARGS}
else
  exec llama-server \
    --hf-repo "${HF_REPO}" \
    --host "${HOST}" \
    --port "${PORT}" \
    -c "${CTX}" \
    -ngl "${NGL}" \
    ${EXTRA_ARGS}
fi
EOT

section "Writing user Quadlet"

write_if_changed "$QUADLET_FILE" <<EOT
[Unit]
Description=Universal llama.cpp ROCm server
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=${SERVICE_NAME}
Image=${IMAGE_DEFAULT}
Pull=never

Network=host
AddDevice=/dev/dri
AddDevice=/dev/kfd

Environment=LLAMA_CACHE=/models-cache

Volume=%h/.llamacpp/cache:/models-cache:rw
Volume=%h/.llamacpp/config:/config:ro
Volume=%h/.llamacpp/scripts/start-llama.sh:/usr/local/bin/start-llama.sh:ro

SeccompProfile=unconfined
PodmanArgs=--group-add=video
PodmanArgs=--group-add=render

Exec=/usr/local/bin/start-llama.sh

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=1800

[Install]
WantedBy=default.target
EOT

section "Pulling or updating container image"

podman pull "$IMAGE_DEFAULT"

section "Testing ROCm visibility inside the container"

set +e
podman run --rm -it \
  --device /dev/dri \
  --device /dev/kfd \
  --group-add video \
  --group-add render \
  --security-opt seccomp=unconfined \
  "$IMAGE_DEFAULT" \
  llama-cli --list-devices
rocm_test_status=$?
set -e

if [[ "$rocm_test_status" -ne 0 ]]; then
  warn "ROCm test failed. The service files were created, but llama.cpp may not start."
  warn "Check groups, /dev/kfd, /dev/dri, and GRUB parameters."
fi

section "Enabling linger for user service autostart after reboot"

if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
  echo "Linger already enabled for user: $USER"
else
  sudo loginctl enable-linger "$USER"
  echo "Linger enabled for user: $USER"
fi

section "Reloading user systemd"

systemctl --user daemon-reload

section "Starting user Quadlet service"

# Quadlet generated services are transient/generated units.
# Do NOT use:
#   systemctl --user enable --now llama.cpp-rocm.service
# It fails with:
#   Failed to enable unit: Unit ... is transient or generated
#
# The [Install] section in the .container file is consumed by the Quadlet generator.
# For current session, just start the generated service.
systemctl --user start "$SYSTEMD_SERVICE"

section "Setup completed"

cat <<EOT

Created or verified:

  Base directory:     ${BASE_DIR}
  Cache directory:    ${CACHE_DIR}
  Config file:        ${ENV_FILE}
  Start script:       ${START_SCRIPT}
  Quadlet file:       ${QUADLET_FILE}

Service:

  ${SYSTEMD_SERVICE}

Current status:

  systemctl --user status ${SYSTEMD_SERVICE}

Logs:

  journalctl --user -u ${SYSTEMD_SERVICE} -f

Health checks:

  curl http://127.0.0.1:7777/health
  curl http://127.0.0.1:7777/v1/models

Change model:

  nano ${ENV_FILE}
  systemctl --user restart ${SYSTEMD_SERVICE}

Manual model warm-up / foreground run:

  systemctl --user stop ${SYSTEMD_SERVICE}

  podman run --rm -it \\
    --name ${SERVICE_NAME} \\
    --network host \\
    --device /dev/dri \\
    --device /dev/kfd \\
    --group-add video \\
    --group-add render \\
    --security-opt seccomp=unconfined \\
    -e LLAMA_CACHE=/models-cache \\
    -v ${CACHE_DIR}:/models-cache:rw \\
    -v ${CONFIG_DIR}:/config:ro \\
    -v ${START_SCRIPT}:/usr/local/bin/start-llama.sh:ro \\
    ${IMAGE_DEFAULT} \\
    /usr/local/bin/start-llama.sh

  systemctl --user start ${SYSTEMD_SERVICE}

Update container image:

  systemctl --user stop ${SYSTEMD_SERVICE}
  podman pull ${IMAGE_DEFAULT}
  systemctl --user start ${SYSTEMD_SERVICE}

Note:

  The script is idempotent. Re-running it keeps your existing llama.env,
  rewrites helper files only if content changed, and starts the same service
  without duplicating containers or systemd units.

EOT
