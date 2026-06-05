#!/usr/bin/env bash
set -euo pipefail

# llamacpp-podman-setup.sh
#
# Idempotent rootless Podman + user systemd Quadlet setup for llama.cpp ROCm on Ubuntu.
#
# Target hardware: AMD Ryzen AI MAX+ 395 / Strix Halo (128 GB unified memory)
#
# Usage:
#   ./llamacpp-podman-setup.sh                         # interactive prompts, then quiet install
#   ./llamacpp-podman-setup.sh --gpu-mem 124 --yes     # fully non-interactive
#   ./llamacpp-podman-setup.sh --uninstall [--remove-containers] [--purge-cache]
#                               [--remove-image] [--reset-grub] [--purge-all]
#
# Flow: collect all parameters first, then configure silently (no further prompts).

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
LOG_FILE="${LLAMACPP_SETUP_LOG:-${TMPDIR:-/tmp}/llamacpp-setup-$$.log}"

SYSTEMD_SERVICE="${SERVICE_NAME}.service"
GRUB_FILE="/etc/default/grub"

VALID_GPU_MEM=(60 90 114 124)
DEFAULT_GPU_MEM=124
INSTALL_STEPS=8

ACTION="install"
GPU_MEM=""
ASSUME_YES=0
QUIET=0
STEP=0

# Uninstall options (default: service + Quadlet only)
UNINSTALL_REMOVE_CONTAINERS=0
UNINSTALL_PURGE_CACHE=0
UNINSTALL_REMOVE_IMAGE=0
UNINSTALL_RESET_GRUB=0
UNINSTALL_PURGE_ALL=0
UNINSTALL_CLI_OPTS=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Install or update llama.cpp ROCm user service (default).

Options:
  --gpu-mem GB   GPU VRAM allocation: 60, 90, 114, or 124
  --yes, -y      Skip confirmation prompts (required for non-interactive install)

Uninstall (default: stop user-service and remove Quadlet only):
  --uninstall              Remove service integration
  --remove-containers      Also remove Podman container(s) for this setup
  --purge-cache            Also remove ~/.llamacpp/cache
  --remove-image           Also remove the ROCm container image from Podman
  --reset-grub             Also remove script-managed kernel parameters from GRUB
  --purge-all              Remove all script data: ~/.llamacpp, containers, image, GRUB, linger

  -h, --help     Show this help

Interactive mode asks all parameters upfront, then installs silently.
Non-interactive: $0 --gpu-mem 124 --yes

Log file during quiet phase: ${LOG_FILE}
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
      --yes|-y)
        ASSUME_YES=1
        shift
        ;;
      --uninstall|--remove)
        ACTION="uninstall"
        shift
        ;;
      --remove-containers)
        UNINSTALL_REMOVE_CONTAINERS=1
        UNINSTALL_CLI_OPTS=1
        shift
        ;;
      --purge-cache)
        UNINSTALL_PURGE_CACHE=1
        UNINSTALL_CLI_OPTS=1
        shift
        ;;
      --remove-image)
        UNINSTALL_REMOVE_IMAGE=1
        UNINSTALL_CLI_OPTS=1
        shift
        ;;
      --reset-grub)
        UNINSTALL_RESET_GRUB=1
        UNINSTALL_CLI_OPTS=1
        shift
        ;;
      --purge-all)
        UNINSTALL_PURGE_ALL=1
        UNINSTALL_CLI_OPTS=1
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

log() {
  echo "[$(date '+%H:%M:%S')] $*" >>"$LOG_FILE"
}

say() {
  if [[ "${QUIET}" -eq 0 ]]; then
    echo "$@"
  fi
}

warn() {
  echo "WARNING: $*" >&2
  log "WARNING: $*"
}

die() {
  echo "ERROR: $*" >&2
  log "ERROR: $*"
  exit 1
}

progress() {
  STEP=$((STEP + 1))
  log "[${STEP}/${INSTALL_STEPS}] $*"
  if [[ "${QUIET}" -eq 1 ]]; then
    echo "  [${STEP}/${INSTALL_STEPS}] $*"
  else
    echo
    echo "==> $*"
  fi
}

confirm() {
  local prompt="$1"
  local answer

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Non-interactive mode requires --yes (prompt: ${prompt})"
  fi

  read -r -p "${prompt} [Y/n]: " answer
  case "${answer}" in
    ""|y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_no() {
  local prompt="$1"
  local answer

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 1
  fi

  if [[ ! -t 0 ]]; then
    return 1
  fi

  read -r -p "${prompt} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

apply_purge_all_flags() {
  UNINSTALL_REMOVE_CONTAINERS=1
  UNINSTALL_PURGE_CACHE=0
  UNINSTALL_REMOVE_IMAGE=1
  UNINSTALL_RESET_GRUB=1
  UNINSTALL_PURGE_ALL=1
}

has_managed_kernel_params() {
  local params="$1"
  [[ "$params" == *"iommu=pt"* ]] \
    || [[ "$params" == *"amdgpu.gttsize="* ]] \
    || [[ "$params" == *"ttm.pages_limit="* ]]
}

ensure_sudo() {
  need_cmd sudo || die "sudo required for GRUB updates and linger"
  if ! sudo -n true 2>/dev/null; then
    say "Administrator privileges required for GRUB and linger."
    sudo -v
  fi
  ( while true; do sleep 50; sudo -v; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
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
  local default="${DEFAULT_GPU_MEM}"
  local saved choice

  if saved="$(read_saved_gpu_mem 2>/dev/null)"; then
    default="$saved"
    say "Saved GPU allocation: ${saved} GB"
  fi

  say
  say "GPU memory for ROCm (GB):"
  local i=1
  local opt
  for opt in "${VALID_GPU_MEM[@]}"; do
    if [[ "$opt" == "$default" ]]; then
      say "  ${i}) ${opt} (default)"
    else
      say "  ${i}) ${opt}"
    fi
    i=$((i + 1))
  done

  while true; do
    read -r -p "Choice [${default}]: " choice
    choice="${choice:-$default}"

    if is_valid_gpu_mem "$choice"; then
      GPU_MEM="$choice"
      return 0
    fi

    if [[ "$choice" =~ ^[1-4]$ ]]; then
      GPU_MEM="${VALID_GPU_MEM[$((choice - 1))]}"
      return 0
    fi

    say "Invalid choice. Enter 60, 90, 114, 124 or option number 1-4."
  done
}

resolve_gpu_mem_interactive() {
  if [[ -n "$GPU_MEM" ]]; then
    is_valid_gpu_mem "$GPU_MEM" || die "Invalid --gpu-mem: ${GPU_MEM}. Use: ${VALID_GPU_MEM[*]}"
    return 0
  fi

  if [[ -t 0 ]]; then
    prompt_gpu_mem
    return 0
  fi

  if saved="$(read_saved_gpu_mem 2>/dev/null)"; then
    GPU_MEM="$saved"
    return 0
  fi

  GPU_MEM="$DEFAULT_GPU_MEM"
}

model_config_summary() {
  if [[ -f "$ENV_FILE" ]]; then
    echo "keep existing ${ENV_FILE}"
  else
    echo "create default (unsloth/Qwen3.6-35B-A3B-MTP-GGUF)"
  fi
}

print_install_summary() {
  local gttsize pages_limit

  gttsize="$(gpu_mem_gttsize "$GPU_MEM")"
  pages_limit="$(gpu_mem_pages_limit "$GPU_MEM")"

  say
  say "Summary:"
  say "  GPU allocation:    ${GPU_MEM} GB"
  say "  Kernel params:     iommu=pt amdgpu.gttsize=${gttsize} ttm.pages_limit=${pages_limit}"
  say "  Container image:   ${IMAGE_DEFAULT}"
  say "  Model config:      $(model_config_summary)"
  say "  Service:           ${SYSTEMD_SERVICE}"
  say "  Log file:          ${LOG_FILE}"
}

collect_install_parameters() {
  : >"$LOG_FILE"
  log "Starting parameter collection"

  say "=== llama.cpp ROCm setup — configuration ==="
  say

  resolve_gpu_mem_interactive
  print_install_summary
  say

  confirm "Start installation?" || die "Installation cancelled."

  ensure_sudo
  QUIET=1

  say
  say "=== Installing (quiet mode) ==="
  log "Parameters collected: GPU_MEM=${GPU_MEM}"
}

reset_grub_managed_params() {
  local current stripped tmp_grub

  current="$(read_grub_cmdline_default)"
  stripped="$(strip_managed_kernel_params "$current")"

  if ! has_managed_kernel_params "$current"; then
    log "GRUB already has no script-managed kernel parameters"
    return 0
  fi

  log "GRUB reset: ${current} -> ${stripped}"

  tmp_grub="$(mktemp)"
  sudo grep -v '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" >"$tmp_grub"
  printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT=\"${stripped}\"" >>"$tmp_grub"
  sudo cp "$tmp_grub" "$GRUB_FILE"
  rm -f "$tmp_grub"

  if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub >>"$LOG_FILE" 2>&1
  else
    die "update-grub not found"
  fi

  log "GRUB managed kernel parameters removed"
}

remove_setup_containers() {
  if ! command -v podman >/dev/null 2>&1; then
    log "podman not found, skipping container removal"
    return 0
  fi

  podman rm -f "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true

  local ids
  ids="$(podman ps -aq --filter "ancestor=${IMAGE_DEFAULT}" 2>/dev/null || true)"
  if [[ -n "${ids}" ]]; then
    # shellcheck disable=SC2086
    podman rm -f ${ids} >>"$LOG_FILE" 2>&1 || true
    log "Removed containers for image: ${IMAGE_DEFAULT}"
  fi
}

remove_setup_image() {
  if ! command -v podman >/dev/null 2>&1; then
    log "podman not found, skipping image removal"
    return 0
  fi

  podman rmi -f "$IMAGE_DEFAULT" >>"$LOG_FILE" 2>&1 || true
  log "Removed image (if present): ${IMAGE_DEFAULT}"
}

disable_user_linger() {
  if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    sudo loginctl disable-linger "$USER" >>"$LOG_FILE" 2>&1
    log "Linger disabled for user: $USER"
  else
    log "Linger was not enabled"
  fi
}

count_uninstall_steps() {
  local n=2
  [[ "${UNINSTALL_REMOVE_CONTAINERS}" -eq 1 ]] && n=$((n + 1))
  if [[ "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    n=$((n + 1))
  elif [[ "${UNINSTALL_PURGE_CACHE}" -eq 1 ]]; then
    n=$((n + 1))
  fi
  [[ "${UNINSTALL_REMOVE_IMAGE}" -eq 1 ]] && n=$((n + 1))
  [[ "${UNINSTALL_RESET_GRUB}" -eq 1 ]] && n=$((n + 1))
  [[ "${UNINSTALL_PURGE_ALL}" -eq 1 ]] && n=$((n + 1))
  echo "$n"
}

print_uninstall_summary() {
  say
  say "Uninstall plan:"
  say "  [always] Stop user-service:  ${SYSTEMD_SERVICE}"
  say "  [always] Remove Quadlet:     ${QUADLET_FILE}"
  say "  [always] Reload user systemd"

  if [[ "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    say "  [purge-all] Remove ~/.llamacpp (config, cache, scripts)"
    say "  [purge-all] Remove Podman container(s) for this setup"
    say "  [purge-all] Remove container image: ${IMAGE_DEFAULT}"
    say "  [purge-all] Reset GRUB kernel parameters (iommu=pt, amdgpu.gttsize, ttm.pages_limit)"
    say "  [purge-all] Disable user linger"
    return 0
  fi

  [[ "${UNINSTALL_REMOVE_CONTAINERS}" -eq 1 ]] \
    && say "  Remove Podman container(s) for this setup"
  [[ "${UNINSTALL_PURGE_CACHE}" -eq 1 ]] \
    && say "  Remove model cache: ${CACHE_DIR}"
  [[ "${UNINSTALL_REMOVE_IMAGE}" -eq 1 ]] \
    && say "  Remove container image: ${IMAGE_DEFAULT}"
  [[ "${UNINSTALL_RESET_GRUB}" -eq 1 ]] \
    && say "  Reset GRUB kernel parameters"

  say
  say "Preserved (unless selected above):"
  [[ "${UNINSTALL_PURGE_CACHE}" -eq 0 && "${UNINSTALL_PURGE_ALL}" -eq 0 ]] \
    && say "  ${BASE_DIR}/"
  [[ "${UNINSTALL_REMOVE_CONTAINERS}" -eq 0 ]] \
    && say "  Podman container(s) (if any)"
  [[ "${UNINSTALL_REMOVE_IMAGE}" -eq 0 ]] \
    && say "  Container image in Podman"
  [[ "${UNINSTALL_RESET_GRUB}" -eq 0 ]] \
    && say "  GRUB kernel parameters"
}

collect_uninstall_parameters() {
  : >"$LOG_FILE"
  log "Starting uninstall parameter collection"

  if [[ "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    apply_purge_all_flags
  elif [[ "${UNINSTALL_CLI_OPTS}" -eq 0 && -t 0 && "${ASSUME_YES}" -eq 0 ]]; then
    say "=== llama.cpp ROCm — uninstall options ==="
    say
    say "Default removal: user-service + Quadlet file."
    say

    confirm_no "Also remove Podman container(s) for this setup?" \
      && UNINSTALL_REMOVE_CONTAINERS=1

    if confirm_no "Purge ALL script data (~/.llamacpp, containers, image, GRUB, linger)?"; then
      apply_purge_all_flags
    else
      confirm_no "Purge model cache only (${CACHE_DIR})?" \
        && UNINSTALL_PURGE_CACHE=1
      confirm_no "Remove container image (${IMAGE_DEFAULT})?" \
        && UNINSTALL_REMOVE_IMAGE=1
      confirm_no "Reset GRUB kernel parameters added by this script?" \
        && UNINSTALL_RESET_GRUB=1
    fi
  fi

  say "=== llama.cpp ROCm — uninstall ==="
  print_uninstall_summary
  say

  if [[ "${UNINSTALL_RESET_GRUB}" -eq 1 || "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    ensure_sudo
  fi

  confirm "Proceed with uninstall?" || die "Uninstall cancelled."

  QUIET=1
  say
  say "=== Uninstalling (quiet mode) ==="
  log "Uninstall confirmed: containers=${UNINSTALL_REMOVE_CONTAINERS} cache=${UNINSTALL_PURGE_CACHE} image=${UNINSTALL_REMOVE_IMAGE} grub=${UNINSTALL_RESET_GRUB} purge_all=${UNINSTALL_PURGE_ALL}"
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
    log "Unchanged: $SYSTEM_ENV"
  else
    install -m 0644 "$tmp" "$SYSTEM_ENV"
    rm -f "$tmp"
    log "Written: $SYSTEM_ENV (GPU_VRAM_GB=${GPU_MEM})"
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

  current="$(read_grub_cmdline_default)"

  if kernel_params_match "$current" "$gttsize" "$pages_limit"; then
    log "GRUB already configured for ${gb} GB"
    return 0
  fi

  merged="$(merge_kernel_params "$current" "$gttsize" "$pages_limit")"
  log "GRUB: ${current} -> ${merged}"

  tmp_grub="$(mktemp)"
  sudo grep -v '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" >"$tmp_grub"
  printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT=\"${merged}\"" >>"$tmp_grub"
  sudo cp "$tmp_grub" "$GRUB_FILE"
  rm -f "$tmp_grub"

  if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub >>"$LOG_FILE" 2>&1
  else
    die "update-grub not found"
  fi

  log "GRUB updated for ${gb} GB"
}

check_runtime_kernel_params() {
  local gb="$1"
  local gttsize pages_limit cmdline

  gttsize="$(gpu_mem_gttsize "$gb")"
  pages_limit="$(gpu_mem_pages_limit "$gb")"
  cmdline="$(cat /proc/cmdline)"

  if kernel_params_match "$cmdline" "$gttsize" "$pages_limit"; then
    log "Active kernel parameters match ${gb} GB"
    return 0
  fi

  warn "Active kernel parameters do not match ${gb} GB yet — reboot required."
  log "Expected: iommu=pt amdgpu.gttsize=${gttsize} ttm.pages_limit=${pages_limit}"
}

write_if_changed() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"

  cat >"$tmp"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log "Unchanged: $target"
  else
    install -m 0644 "$tmp" "$target"
    rm -f "$tmp"
    log "Written: $target"
  fi
}

write_executable_if_changed() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"

  cat >"$tmp"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    chmod +x "$target"
    log "Unchanged: $target"
  else
    install -m 0755 "$tmp" "$target"
    rm -f "$tmp"
    log "Written: $target"
  fi
}

write_default_llama_env() {
  cat >"$ENV_FILE" <<'EOT'
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
  collect_uninstall_parameters
  INSTALL_STEPS="$(count_uninstall_steps)"
  STEP=0

  progress "Stopping user-service"
  systemctl --user stop "$SYSTEMD_SERVICE" 2>/dev/null || true
  log "Stopped (if running): ${SYSTEMD_SERVICE}"

  progress "Removing Quadlet"
  if [[ -f "$QUADLET_FILE" ]]; then
    rm -f "$QUADLET_FILE"
    log "Removed: $QUADLET_FILE"
  else
    log "Quadlet not found: $QUADLET_FILE"
  fi

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed 2>/dev/null || true
  log "User systemd reloaded"

  if [[ "${UNINSTALL_REMOVE_CONTAINERS}" -eq 1 ]]; then
    progress "Removing Podman container(s)"
    remove_setup_containers
  fi

  if [[ "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    progress "Removing ~/.llamacpp"
    if [[ -d "$BASE_DIR" ]]; then
      rm -rf "$BASE_DIR"
      log "Removed: ${BASE_DIR}"
    fi
  elif [[ "${UNINSTALL_PURGE_CACHE}" -eq 1 ]]; then
    progress "Purging model cache"
    if [[ -d "$CACHE_DIR" ]]; then
      rm -rf "$CACHE_DIR"
      log "Removed: ${CACHE_DIR}"
    fi
  fi

  if [[ "${UNINSTALL_REMOVE_IMAGE}" -eq 1 ]]; then
    progress "Removing container image"
    remove_setup_image
  fi

  if [[ "${UNINSTALL_RESET_GRUB}" -eq 1 ]]; then
    progress "Resetting GRUB kernel parameters"
    reset_grub_managed_params
  fi

  if [[ "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    progress "Disabling user linger"
    disable_user_linger
  fi

  say
  say "=== Uninstall complete ==="
  say "Log: ${LOG_FILE}"
  if [[ "${UNINSTALL_PURGE_ALL}" -eq 0 ]]; then
    say "Reinstall: $0"
  fi
  if [[ "${UNINSTALL_RESET_GRUB}" -eq 1 || "${UNINSTALL_PURGE_ALL}" -eq 1 ]]; then
    say "Reboot to apply GRUB changes."
  fi
}

do_install() {
  collect_install_parameters
  STEP=0

  progress "Checking required tools"
  need_cmd podman || die "Install podman first: sudo apt install -y podman"
  need_cmd systemctl || die "systemctl not found"
  need_cmd loginctl || die "loginctl not found"
  need_cmd curl || warn "curl not found. Health-check examples will require curl."

  progress "Checking ROCm devices and groups"
  if [[ ! -e /dev/kfd ]]; then
    warn "/dev/kfd not found."
  else
    log "$(ls -l /dev/kfd)"
  fi
  if [[ ! -d /dev/dri ]]; then
    warn "/dev/dri not found."
  else
    log "$(ls -l /dev/dri 2>/dev/null || true)"
  fi
  if ! has_group render || ! has_group video; then
    warn "User '$USER' should be in groups render and video. Run: sudo usermod -aG render,video $USER"
  fi

  progress "Writing system config"
  mkdir -p "$CACHE_DIR" "$CONFIG_DIR" "$SCRIPTS_DIR" "$QUADLET_DIR"
  write_system_env

  progress "Updating GRUB kernel parameters"
  update_grub_for_gpu_mem "$GPU_MEM"
  check_runtime_kernel_params "$GPU_MEM"

  progress "Writing model config and scripts"
  if [[ -f "$ENV_FILE" ]]; then
    log "Keeping existing config: $ENV_FILE"
  else
    write_default_llama_env
    log "Created: $ENV_FILE"
  fi

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

  progress "Pulling container image"
  podman pull -q "$IMAGE_DEFAULT" >>"$LOG_FILE" 2>&1

  progress "Testing ROCm in container"
  set +e
  podman run --rm \
    --device /dev/dri \
    --device /dev/kfd \
    --group-add video \
    --group-add render \
    --security-opt seccomp=unconfined \
    "$IMAGE_DEFAULT" \
    llama-cli --list-devices >>"$LOG_FILE" 2>&1
  rocm_test_status=$?
  set -e

  if [[ "$rocm_test_status" -ne 0 ]]; then
    warn "ROCm test failed — see ${LOG_FILE}"
  fi

  progress "Enabling linger and starting service"
  if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    sudo loginctl enable-linger "$USER" >>"$LOG_FILE" 2>&1
    log "Linger enabled for user: $USER"
  else
    log "Linger already enabled"
  fi

  systemctl --user daemon-reload
  systemctl --user start "$SYSTEMD_SERVICE"

  local_gttsize="$(gpu_mem_gttsize "$GPU_MEM")"
  local_pages_limit="$(gpu_mem_pages_limit "$GPU_MEM")"

  say
  say "=== Setup complete ==="
  say
  say "  GPU allocation:  ${GPU_MEM} GB"
  say "  Kernel params:   iommu=pt amdgpu.gttsize=${local_gttsize} ttm.pages_limit=${local_pages_limit}"
  say "  Service:         ${SYSTEMD_SERVICE}"
  say "  Model config:    ${ENV_FILE}"
  say "  Log:             ${LOG_FILE}"
  say
  say "  systemctl --user status ${SYSTEMD_SERVICE}"
  say "  curl http://127.0.0.1:7777/health"
  say
  say "Reboot if kernel parameters were just changed."
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
