#!/bin/bash

# Начальное обновление системы
apt-get update
apt-get -y dist-upgrade

# Добавляем нужные репы
apt-add-repository --yes ppa:kubuntu-ppa/backports
add-apt-repository --yes ppa:graphics-drivers/ppa
add-apt-repository --yes ppa:git-core/ppa
add-apt-repository --yes ppa:libreoffice/ppa

apt-get -y install curl wget apt-transport-https

# sublime
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | sudo apt-key add -
echo "deb https://download.sublimetext.com/ apt/stable/" | sudo tee /etc/apt/sources.list.d/sublime-text.list
# add-apt-repository --yes "deb https://download.sublimetext.com/ apt/stable/"

# VS Code
wget -q https://packages.microsoft.com/keys/microsoft.asc -O- | sudo apt-key add -
echo "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" | sudo tee /etc/apt/sources.list.d/vscode.list
# add-apt-repository --yes "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main"

# Skype
curl https://repo.skype.com/data/SKYPE-GPG-KEY | sudo apt-key add - 
echo "deb [arch=amd64] https://repo.skype.com/deb stable main" | sudo tee /etc/apt/sources.list.d/skypeforlinux.list
# add-apt-repository --yes "deb [arch=amd64] https://repo.skype.com/deb stable main"

# docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository --yes "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
# add-apt-repository \
#    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
#    $(lsb_release -cs) \
#    stable"

# enpass
wget -q https://apt.enpass.io/keys/enpass-linux.key -O- | sudo apt-key add -
echo "deb https://apt.enpass.io/ stable main" | sudo tee /etc/apt/sources.list.d/enpass.list
#add-apt-repository --yes "deb https://apt.enpass.io/ stable main"

# wget http://repo.yandex.ru/yandex-disk/YANDEX-DISK-KEY.GPG -O- | sudo apt-key add -   
# echo "deb http://repo.yandex.ru/yandex-disk/deb/ stable main" | sudo tee /etc/apt/sources.list.d/yandex-disk.list
# add-apt-repository "deb http://repo.yandex.ru/yandex-disk/deb/ stable main"
wget http://repo.yandex.ru/yandex-disk/yandex-disk_latest_amd64.deb
dpkg -i --force-depends yandex-disk_latest_amd64.deb

# sbt
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 2EE0EA64E40A89B84B2DF73499E82A75642AC823
echo "deb https://dl.bintray.com/sbt/debian /" | sudo tee /etc/apt/sources.list.d/sbt.list
# add-apt-repository --yes "deb https://dl.bintray.com/sbt/debian /"

# virtualbox
# wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | apt-key add -
# wget -q https://www.virtualbox.org/download/oracle_vbox.asc -O- | apt-key add -
# echo "deb http://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" | sudo tee -a /etc/apt/sources.list.d/vbox.list

# openvpn
# wget -qO - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
# echo "deb http://build.openvpn.net/debian/openvpn/release/2.4 xenial main" | sudo tee /etc/apt/sources.list.d/openvpn-aptrepo.list

# Проверим ключи репозиториев
#apt-key adv --recv-keys --keyserver keyserver.ubuntu.com `apt-get update 2>&1 | grep -o '[0-9A-Z]\{16\}$' | xargs`


# Обновление пакетов
apt-get update
apt-get -y dist-upgrade


# Устанавливаем нужные пакеты
PACKAGES="zsh docker-ce mc git maven sbt chromium-browser p7zip vlc sublime-text code openvpn synaptic build-essential mono-complete keepassx skypeforlinux"

sudo apt-get -y install $PACKAGES

# oh my zsh
curl -L https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh | sh
sudo chsh -s $(which zsh)

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s -- -y

# Tools
snap install postman
snap install discord

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


# sudo ubuntu-drivers autoinstall
