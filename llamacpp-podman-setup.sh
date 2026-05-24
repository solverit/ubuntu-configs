#!/usr/bin/env bash
set -euo pipefail

# llamacpp-podman-setup.sh
#
# Idempotent rootless Podman + user systemd Quadlet setup for llama.cpp ROCm on Ubuntu.
#
# Target hardware: AMD Ryzen AI MAX+ 395 / Strix Halo (128 GB unified memory)
#
# Usage:
#   ./llamacpp-podman-setup.sh [--gpu-mem 60|90|114|124]
#   ./llamacpp-podman-setup.sh --uninstall
#
# Installs or updates the user service. Keeps ~/.llamacpp/config/llama.env on reinstall.
# Uninstall removes the service and Quadlet but preserves ~/.llamacpp (config + cache).

IMAGE_DEFAULT="${LLAMACPP_ROCM_IMAGE:-docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.3}"
SERVICE_NAME="${LLAMACPP_SERVICE_NAME:-llama.cpp-rocm}"

BASE_DIR="${LLAMACPP_BASE_DIR:-${HOME}/.llamacpp}"
CACHE_DIR="${BASE_DIR}/cache"
CONFIG_DIR="${BASE_DIR}/config"
SCRIPTS_DIR="${BASE_DIR}/scripts"

QUADLET_DIR="${HOME}/.config/containers/systemd"

ENV_FILE="${CONFIG_DIR}/llama.env"
SYSTEM_ENV="${CONFIG_DIR}/system.env"
START_SCRIPT="${SCRIPTS_DIR}/start-llama.sh"
QUADLET_FILE="${QUADLET_DIR}/${SERVICE_NAME}.container"

SYSTEMD_SERVICE="${SERVICE_NAME}.service"
GRUB_FILE="/etc/default/grub"

VALID_GPU_MEM=(60 90 114 124)
DEFAULT_GPU_MEM=124

ACTION="install"
GPU_MEM=""

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Install or update llama.cpp ROCm user service (default).

Options:
  --gpu-mem GB   GPU VRAM allocation: 60, 90, 114, or 124 (default: saved or ${DEFAULT_GPU_MEM})
  --uninstall    Stop service, remove Quadlet; keep ~/.llamacpp
  -h, --help     Show this help

Examples:
  $0
  $0 --gpu-mem 90
  $0 --uninstall
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gpu-mem)
        [[ $# -ge 2 ]] || die "--gpu-mem requires a value (60, 90, 114, 124)"
        GPU_MEM="$2"
        shift 2
        ;;
      --uninstall|--remove)
        ACTION="uninstall"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    return 1
  fi
}

has_group() {
  id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
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

is_valid_gpu_mem() {
  local value="$1"
  local v
  for v in "${VALID_GPU_MEM[@]}"; do
    [[ "$value" == "$v" ]] && return 0
  done
  return 1
}

gpu_mem_gttsize() {
  echo $(( "$1" * 1024 ))
}

gpu_mem_pages_limit() {
  echo $(( "$1" * 262144 ))
}

read_saved_gpu_mem() {
  if [[ -f "$SYSTEM_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$SYSTEM_ENV"
    if [[ -n "${GPU_VRAM_GB:-}" ]]; then
      echo "${GPU_VRAM_GB}"
      return 0
    fi
  fi
  return 1
}

prompt_gpu_mem() {
  local choice
  echo "Select GPU memory allocation for ROCm (GB):"
  select choice in "${VALID_GPU_MEM[@]}"; do
    if [[ -n "$choice" ]]; then
      GPU_MEM="$choice"
      return 0
    fi
    echo "Invalid choice, try again."
  done
}

resolve_gpu_mem() {
  if [[ -n "$GPU_MEM" ]]; then
    is_valid_gpu_mem "$GPU_MEM" || die "Invalid --gpu-mem: ${GPU_MEM}. Use: ${VALID_GPU_MEM[*]}"
    return 0
  fi

  if saved="$(read_saved_gpu_mem 2>/dev/null)"; then
    GPU_MEM="$saved"
    echo "Using saved GPU memory allocation: ${GPU_MEM} GB"
    return 0
  fi

  if [[ -t 0 ]]; then
    prompt_gpu_mem
    return 0
  fi

  GPU_MEM="$DEFAULT_GPU_MEM"
  echo "Using default GPU memory allocation: ${GPU_MEM} GB"
}

write_system_env() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOT
# ~/.llamacpp/config/system.env
# Managed by llamacpp-podman-setup.sh — GPU VRAM allocation for kernel parameters.

GPU_VRAM_GB=${GPU_MEM}
EOT
  if [[ -f "$SYSTEM_ENV" ]] && cmp -s "$tmp" "$SYSTEM_ENV"; then
    rm -f "$tmp"
    echo "Unchanged: $SYSTEM_ENV"
  else
    install -m 0644 "$tmp" "$SYSTEM_ENV"
    rm -f "$tmp"
    echo "Written: $SYSTEM_ENV (GPU_VRAM_GB=${GPU_MEM})"
  fi
}

normalize_cmdline() {
  echo "$1" | xargs
}

strip_managed_kernel_params() {
  local params="$1"
  params="$(echo "$params" | sed -E \
    -e 's/(^|[[:space:]])iommu=pt($|[[:space:]])/ /g' \
    -e 's/(^|[[:space:]])amdgpu\.gttsize=[^[:space:]]+//g' \
    -e 's/(^|[[:space:]])ttm\.pages_limit=[^[:space:]]+//g')"
  normalize_cmdline "$params"
}

merge_kernel_params() {
  local existing="$1"
  local gttsize="$2"
  local pages_limit="$3"
  local merged

  merged="$(strip_managed_kernel_params "$existing")"
  merged="${merged} iommu=pt amdgpu.gttsize=${gttsize} ttm.pages_limit=${pages_limit}"
  normalize_cmdline "$merged"
}

read_grub_cmdline_default() {
  [[ -f "$GRUB_FILE" ]] || die "GRUB config not found: ${GRUB_FILE}"
  local line
  line="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | tail -n1)"
  [[ -n "$line" ]] || die "GRUB_CMDLINE_LINUX_DEFAULT not found in ${GRUB_FILE}"
  line="${line#GRUB_CMDLINE_LINUX_DEFAULT=}"
  line="${line#\"}"
  line="${line%\"}"
  echo "$line"
}

kernel_params_match() {
  local params="$1"
  local gttsize="$2"
  local pages_limit="$3"
  [[ "$params" == *"iommu=pt"* ]] \
    && [[ "$params" == *"amdgpu.gttsize=${gttsize}"* ]] \
    && [[ "$params" == *"ttm.pages_limit=${pages_limit}"* ]]
}

update_grub_for_gpu_mem() {
  local gb="$1"
  local gttsize pages_limit current merged tmp_grub

  gttsize="$(gpu_mem_gttsize "$gb")"
  pages_limit="$(gpu_mem_pages_limit "$gb")"

  section "Updating GRUB kernel parameters for ${gb} GB GPU allocation"

  need_cmd sudo || die "sudo required to edit ${GRUB_FILE}"

  current="$(read_grub_cmdline_default)"

  if kernel_params_match "$current" "$gttsize" "$pages_limit"; then
    echo "GRUB already configured: iommu=pt amdgpu.gttsize=${gttsize} ttm.pages_limit=${pages_limit}"
    return 0
  fi

  merged="$(merge_kernel_params "$current" "$gttsize" "$pages_limit")"
  echo "Current: ${current}"
  echo "Updated: ${merged}"

  tmp_grub="$(mktemp)"
  sudo grep -v '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" > "$tmp_grub"
  printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT=\"${merged}\"" >> "$tmp_grub"
  sudo cp "$tmp_grub" "$GRUB_FILE"
  rm -f "$tmp_grub"

  if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub
  else
    die "update-grub not found"
  fi

  echo "GRUB updated. Reboot required for new kernel parameters to take effect."
}

check_runtime_kernel_params() {
  local gb="$1"
  local gttsize pages_limit cmdline

  gttsize="$(gpu_mem_gttsize "$gb")"
  pages_limit="$(gpu_mem_pages_limit "$gb")"
  cmdline="$(cat /proc/cmdline)"

  if kernel_params_match "$cmdline" "$gttsize" "$pages_limit"; then
    echo "Active kernel parameters match ${gb} GB allocation."
    return 0
  fi

  warn "Active kernel parameters do not match ${gb} GB allocation yet."
  warn "Expected: iommu=pt amdgpu.gttsize=${gttsize} ttm.pages_limit=${pages_limit}"
  warn "Reboot after GRUB update if you have not already."
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

write_default_llama_env() {
  cat > "$ENV_FILE" <<'EOT'
# ~/.llamacpp/config/llama.env
#
# Edit this file and restart:
#   systemctl --user restart llama.cpp-rocm.service
#
# Default model (MTP):
#   unsloth/Qwen3.6-35B-A3B-MTP-GGUF
#   Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf

HF_REPO="unsloth/Qwen3.6-35B-A3B-MTP-GGUF"
HF_FILE="Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf"

HOST="0.0.0.0"
PORT="7777"

CTX="242144"
NGL="999"

TEMPERATURE="0.6"
TOP_P="0.95"
TOP_K="20"
MIN_P="0.0"
PRESENCE_PENALTY="0.0"
REPETITION_PENALTY="1.0"

# MTP draft speculation (for MTP models; safe to remove for non-MTP models)
EXTRA_ARGS="-fa 1 --no-mmap --jinja --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.75"
EOT
}

do_uninstall() {
  section "Uninstalling llama.cpp ROCm user service"

  systemctl --user stop "$SYSTEMD_SERVICE" 2>/dev/null || true
  podman rm -f "$SERVICE_NAME" 2>/dev/null || true

  if [[ -f "$QUADLET_FILE" ]]; then
    rm -f "$QUADLET_FILE"
    echo "Removed: $QUADLET_FILE"
  else
    echo "Quadlet not found: $QUADLET_FILE"
  fi

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed 2>/dev/null || true

  cat <<EOT

Uninstall complete.

Removed:
  User service:  ${SYSTEMD_SERVICE}
  Quadlet:       ${QUADLET_FILE}

Preserved:
  ${BASE_DIR}/   (config, cache, scripts)

Reinstall:
  $0 [--gpu-mem 60|90|114|124]

EOT
}

do_install() {
  resolve_gpu_mem

  section "Checking required tools"

  need_cmd podman || die "Install podman first: sudo apt install -y podman"
  need_cmd systemctl || die "systemctl not found"
  need_cmd loginctl || die "loginctl not found"
  need_cmd curl || warn "curl not found. Health-check examples will require curl."
  need_cmd sudo || die "sudo required for GRUB updates"

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

  mkdir -p "$CACHE_DIR" "$CONFIG_DIR" "$SCRIPTS_DIR" "$QUADLET_DIR"

  write_system_env
  update_grub_for_gpu_mem "$GPU_MEM"
  check_runtime_kernel_params "$GPU_MEM"

  section "Creating default model config if missing"

  if [[ -f "$ENV_FILE" ]]; then
    echo "Keeping existing config: $ENV_FILE"
  else
    write_default_llama_env
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
: "${TEMPERATURE:=0.6}"
: "${TOP_P:=0.95}"
: "${TOP_K:=20}"
: "${MIN_P:=0.0}"
: "${PRESENCE_PENALTY:=0.0}"
: "${REPETITION_PENALTY:=1.0}"
: "${EXTRA_ARGS:=}"

SAMPLING_ARGS=(
  --temp "${TEMPERATURE}"
  --top-p "${TOP_P}"
  --top-k "${TOP_K}"
  --min-p "${MIN_P}"
  --presence-penalty "${PRESENCE_PENALTY}"
  --repeat-penalty "${REPETITION_PENALTY}"
)

echo "Starting llama-server"
echo "HF_REPO=${HF_REPO:-}"
echo "HF_FILE=${HF_FILE:-}"
echo "HOST=${HOST}"
echo "PORT=${PORT}"
echo "CTX=${CTX}"
echo "NGL=${NGL}"
echo "SAMPLING: temp=${TEMPERATURE} top_p=${TOP_P} top_k=${TOP_K} min_p=${MIN_P} presence=${PRESENCE_PENALTY} repeat=${REPETITION_PENALTY}"
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
    "${SAMPLING_ARGS[@]}" \
    ${EXTRA_ARGS}
else
  exec llama-server \
    --hf-repo "${HF_REPO}" \
    --host "${HOST}" \
    --port "${PORT}" \
    -c "${CTX}" \
    -ngl "${NGL}" \
    "${SAMPLING_ARGS[@]}" \
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
    warn "Check groups, /dev/kfd, /dev/dri, and kernel parameters (reboot if GRUB was just updated)."
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

  systemctl --user start "$SYSTEMD_SERVICE"

  section "Setup completed"

  local_gttsize="$(gpu_mem_gttsize "$GPU_MEM")"
  local_pages_limit="$(gpu_mem_pages_limit "$GPU_MEM")"

  cat <<EOT

Created or verified:

  Base directory:     ${BASE_DIR}
  Cache directory:    ${CACHE_DIR}
  Model config:       ${ENV_FILE}
  System config:      ${SYSTEM_ENV}
  Start script:       ${START_SCRIPT}
  Quadlet file:       ${QUADLET_FILE}

GPU allocation:       ${GPU_MEM} GB
Kernel parameters:    iommu=pt amdgpu.gttsize=${local_gttsize} ttm.pages_limit=${local_pages_limit}

Service:

  ${SYSTEMD_SERVICE}

Current status:

  systemctl --user status ${SYSTEMD_SERVICE}

Logs:

  journalctl --user -u ${SYSTEMD_SERVICE} -f

Health checks:

  curl http://127.0.0.1:7777/health
  curl http://127.0.0.1:7777/v1/models

Change model or sampling:

  nano ${ENV_FILE}
  systemctl --user restart ${SYSTEMD_SERVICE}

Change GPU memory allocation:

  $0 --gpu-mem 60|90|114|124
  sudo reboot

Uninstall (keeps ~/.llamacpp):

  $0 --uninstall

Note:

  Re-running this script is idempotent. Existing llama.env is preserved.
  GRUB parameters are merged (replaced, not duplicated) on each run.
  Reboot after changing --gpu-mem for kernel parameters to take effect.

EOT
}

if [[ "${EUID}" -eq 0 ]]; then
  die "Do not run this script as root. Run it as your normal user."
fi

parse_args "$@"

case "$ACTION" in
  install)
    do_install
    ;;
  uninstall)
    do_uninstall
    ;;
  *)
    die "Unknown action: $ACTION"
    ;;
esac
