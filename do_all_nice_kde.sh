#!/bin/bash

#Начальное обновление системы
apt-get update
apt-get -y --force-yes dist-upgrade

#Добавляем нужные репы
apt-add-repository --yes ppa:kubuntu-ppa/backports
add-apt-repository --yes ppa:graphics-drivers/ppa
add-apt-repository --yes ppa:git-core/ppa
add-apt-repository --yes ppa:webupd8team/java
add-apt-repository --yes ppa:libreoffice/ppa
apt-add-repository --yes ppa:shutter/ppa

#sublime
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | apt-key add -
echo "deb https://download.sublimetext.com/ apt/stable/" | tee /etc/apt/sources.list.d/sublime-text.list

#docker
sudo apt-get -y --force-yes install curl
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
   
#sbt
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 2EE0EA64E40A89B84B2DF73499E82A75642AC823
echo "deb https://dl.bintray.com/sbt/debian /" | tee -a /etc/apt/sources.list.d/sbt.list


#Проверим ключи репозиториев
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com `apt-get update 2>&1 | grep -o '[0-9A-Z]\{16\}$' | xargs`


#Обновление пакетов
apt-get update
apt-get -y --force-yes dist-upgrade


#Устанавливаем нужные пакеты
PACKAGES="docker-ce mc git maven sbt redshift chromium-browser shutter p7zip vlc sublime-text nvidia-384 nvidia-settings"

sudo apt-get -y --force-yes install $PACKAGES

#env
sudo usermod -aG docker $USER


# sudo apt-get install nvidia-384 nvidia-settings oracle-java7-installer oracle-java8-installer
