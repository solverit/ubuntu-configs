#!/bin/bash

#Начальное обновление системы
apt-get update
apt-get -y --force-yes dist-upgrade

#Добавляем нужные репы
#add-apt-repository --yes ppa:graphics-drivers/ppa
#add-apt-repository --yes ppa:git-core/ppa
add-apt-repository --yes ppa:libreoffice/ppa

#Обновление пакетов
apt-get update

#Фиксим кодировки
gsettings set org.gnome.gedit.preferences.encodings candidate-encodings "['UTF-8', 'WINDOWS-1251', 'KOI8-R', 'CURRENT', 'ISO-8859-15', 'UTF-16']"

# sublime
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | sudo apt-key add -
echo "deb https://download.sublimetext.com/ apt/stable/" | sudo tee /etc/apt/sources.list.d/sublime-text.list

# VS Code
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
rm -f packages.microsoft.gpg

# enpass
wget -O - https://apt.enpass.io/keys/enpass-linux.key | sudo tee /etc/apt/trusted.gpg.d/enpass.asc
echo "deb https://apt.enpass.io/  stable main" | sudo tee /etc/apt/sources.list.d/enpass.list
#add-apt-repository --yes "deb https://apt.enpass.io/ stable main"

# docker
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# yandex-disk
echo "deb http://repo.yandex.ru/yandex-disk/deb/ stable main" | sudo tee -a /etc/apt/sources.list.d/yandex-disk.list > /dev/null && wget http://repo.yandex.ru/yandex-disk/YANDEX-DISK-KEY.GPG -O- | sudo apt-key add - && sudo apt-get update && sudo apt-get install -y yandex-disk

# Обновление пакетов
apt-get update
apt-get -y dist-upgrade

# Устанавливаем нужные пакеты
PACKAGES="zsh mc git maven p7zip vlc sublime-text code openvpn network-manager-openvpn-gnome build-essential keepassxc docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

sudo apt-get -y install $PACKAGES
# oh my zsh
curl -L https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh | sh
sudo chsh -s $(which zsh)

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s -- -y

# chrome
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i --force-depends google-chrome-stable_current_amd64.deb

#env
sudo usermod -aG docker $USER
# sudo usermod -aG vboxusers $USER

# speed
echo "fs.inotify.max_user_watches = 524288" >> /etc/sysctl.conf
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
echo "vm.swappiness = 10" >> /etc/sysctl.conf
sysctl -p

# usb power off
# sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&usbcore.autosuspend=-1 /' /etc/default/grub
