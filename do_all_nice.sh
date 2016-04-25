#!/bin/bash

#Начальное обновление системы
apt-get update
apt-get -y --force-yes dist-upgrade

#Добавляем нужные репы
add-apt-repository --yes ppa:graphics-drivers/ppa
add-apt-repository --yes ppa:git-core/ppa
add-apt-repository --yes ppa:webupd8team/java
add-apt-repository --yes ppa:libreoffice/ppa
add-apt-repository --yes ppa:peterlevi/ppa
apt-add-repository --yes ppa:shutter/ppa

#Проверим ключи репозиториев
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com `apt-get update 2>&1 | grep -o '[0-9A-Z]\{16\}$' | xargs`

#Обновление пакетов
apt-get update

#Фиксим кодировки
gsettings set org.gnome.gedit.preferences.encodings auto-detected "['UTF-8', 'WINDOWS-1251', 'CURRENT', 'ISO-8859-15', 'UTF-16']"

#Устанавливаем нужные пакеты
PACKAGES="gdebi indicator-multiload 
git maven oracle-java7-installer oracle-java8-installer 
gtk-redshift gnome-system-tools unity-tweak-tool
chromium-browser pepperflashplugin-nonfree 
variety shutter p7zip vlc "

sudo apt-get -y --force-yes install $PACKAGES

#Свежий Flash
update-pepperflashplugin-nonfree --install


# sudo apt-get install nvidia-364 nvidia-settings
