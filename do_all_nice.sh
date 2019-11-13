#!/bin/bash

#Начальное обновление системы
apt-get update
apt-get -y --force-yes dist-upgrade

#Добавляем нужные репы
add-apt-repository --yes ppa:graphics-drivers/ppa
add-apt-repository --yes ppa:git-core/ppa
add-apt-repository --yes ppa:libreoffice/ppa

#sbt
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 2EE0EA64E40A89B84B2DF73499E82A75642AC823
echo "deb https://dl.bintray.com/sbt/debian /" | tee -a /etc/apt/sources.list.d/sbt.list

#Проверим ключи репозиториев
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com `apt-get update 2>&1 | grep -o '[0-9A-Z]\{16\}$' | xargs`

#Обновление пакетов
apt-get update

#Фиксим кодировки
gsettings set org.gnome.gedit.preferences.encodings candidate-encodings "['UTF-8', 'WINDOWS-1251', 'KOI8-R', 'CURRENT', 'ISO-8859-15', 'UTF-16']"

#Устанавливаем нужные пакеты
PACKAGES="mc gdebi libreoffice libreoffice-l10n-ru libreoffice-help-ru
git maven sbt chromium-browser p7zip vlc dconf-editor gnome-tweak-tool openvpn"

sudo apt-get -y --force-yes install $PACKAGES

#env
sudo usermod -aG docker $USER
sudo usermod -aG vboxusers $USER

# sudo apt-get install nvidia-driver-435
