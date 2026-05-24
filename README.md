# ubuntu-configs

Скрипты первичной настройки Ubuntu 26.04.

## Bootstrap

```bash
# Ubuntu / GNOME (по умолчанию)
sudo ./do_all_nice.sh

# Kubuntu / KDE Plasma
sudo ./do_all_nice.sh --kde
```

`do_all_nice_kde.sh` — обёртка над `do_all_nice.sh --kde` (для старых инструкций).

После установки: перелогин или reboot (группа `docker`, shell `zsh`).
