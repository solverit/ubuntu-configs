#!/usr/bin/env bash
#
# Первичная настройка Ubuntu 26.04 после чистой установки.
# Запуск: sudo ./do_all_nice.sh [--kde]
#
# --kde  Kubuntu/KDE Plasma: network-manager-openvpn вместо -gnome,
#        без gsettings для Gedit.
#
# Одноразовый bootstrap от root. Повторный запуск не идемпотентен.

set -e

DESKTOP="gnome"

usage() {
  cat <<'EOF'
Usage: sudo ./do_all_nice.sh [--kde]

  (default)  GNOME / Ubuntu Desktop
  --kde      Kubuntu / KDE Plasma
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kde)
      DESKTOP="kde"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0 [--kde]" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-${USER}}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  echo "Cannot detect target user. Run via sudo from a normal user account." >&2
  exit 1
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

echo "Desktop profile: ${DESKTOP}"
echo "Target user: ${TARGET_USER}"

# Начальное обновление системы
apt-get update
apt-get -y dist-upgrade

# Добавляем нужные репы
add-apt-repository --yes ppa:libreoffice/ppa

apt-get update

if [[ "${DESKTOP}" == "gnome" ]]; then
  # Фиксим кодировки Gedit (только GNOME)
  sudo -u "${TARGET_USER}" gsettings set org.gnome.gedit.preferences.encodings candidate-encodings "['UTF-8', 'WINDOWS-1251', 'KOI8-R', 'CURRENT', 'ISO-8859-15', 'UTF-16']"
fi

# Sublime Text
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | apt-key add -
echo "deb https://download.sublimetext.com/ apt/stable/" > /etc/apt/sources.list.d/sublime-text.list

# VS Code
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
rm -f packages.microsoft.gpg

# Enpass
wget -O - https://apt.enpass.io/keys/enpass-linux.key | tee /etc/apt/trusted.gpg.d/enpass.asc > /dev/null
echo "deb https://apt.enpass.io/ stable main" > /etc/apt/sources.list.d/enpass.list

# Docker (deb822)
apt-get -y install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Yandex Disk
echo "deb http://repo.yandex.ru/yandex-disk/deb/ stable main" > /etc/apt/sources.list.d/yandex-disk.list
wget http://repo.yandex.ru/yandex-disk/YANDEX-DISK-KEY.GPG -O- | apt-key add -
apt-get update
apt-get -y install yandex-disk

# Обновление пакетов
apt-get update
apt-get -y dist-upgrade

# Базовый набор пакетов (актуальный)
PACKAGES=(
  zsh mc git maven p7zip vlc
  sublime-text code
  openvpn
  build-essential golang-go keepassxc
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
)

if [[ "${DESKTOP}" == "kde" ]]; then
  PACKAGES+=(network-manager-openvpn)
else
  PACKAGES+=(network-manager-openvpn-gnome)
fi

apt-get -y install "${PACKAGES[@]}"

# oh-my-zsh
if [[ ! -d "${TARGET_HOME}/.oh-my-zsh" ]]; then
  sudo -u "${TARGET_USER}" env HOME="${TARGET_HOME}" RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
chsh -s "$(which zsh)" "${TARGET_USER}"

# Rust
if [[ ! -f "${TARGET_HOME}/.cargo/bin/rustc" ]]; then
  sudo -u "${TARGET_USER}" curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

snap install postman
snap install discord

# Chrome
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
wget -q -O "${TMPDIR}/google-chrome-stable_current_amd64.deb" \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i --force-depends "${TMPDIR}/google-chrome-stable_current_amd64.deb" || apt-get -y -f install

# Группы
usermod -aG docker "${TARGET_USER}"

# Sysctl (не дублировать при повторном запуске)
append_sysctl() {
  local line="$1"
  if ! grep -qF "${line}" /etc/sysctl.conf 2>/dev/null; then
    echo "${line}" >> /etc/sysctl.conf
  fi
}

append_sysctl "fs.inotify.max_user_watches = 524288"
append_sysctl "vm.max_map_count=262144"
append_sysctl "vm.swappiness = 10"
sysctl -p

echo
echo "Done (${DESKTOP}). Reboot or re-login for group docker and default shell zsh."
