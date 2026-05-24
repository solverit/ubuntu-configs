# AGENTS.md

## Mission

Репозиторий скриптов и документации для автоматической настройки **Ubuntu 26.04** после чистой установки: пакеты, репозитории, тюнинг системы, окружение разработки и отдельные сценарии (Podman, llama.cpp ROCm).

Целевая ОС: **Ubuntu 26.04** (Noble-based или актуальный релиз на момент использования). Скрипты рассчитаны на **amd64**, основная рабочая машина — **AMD Ryzen AI MAX+ 395 / Strix Halo** (128 GB unified memory).

## First Read

Перед изменениями прочитай релевантные файлы:

| Задача | Файл |
|--------|------|
| Первичная настройка Ubuntu/Kubuntu | `do_all_nice.sh` (`--kde` для KDE) |
| Обёртка KDE (legacy) | `do_all_nice_kde.sh` → `do_all_nice.sh --kde` |
| llama.cpp + Podman + Quadlet + ROCm | `llamacpp-podman-setup.sh`, затем `llamacpp-podman-guide.md` |
| Быстрый старт для пользователя | `README.md` |

## Структура репозитория

```text
ubuntu-configs/
├── AGENTS.md                  # этот файл — контекст для агента
├── README.md                  # минимальный quick start
├── do_all_nice.sh             # единый bootstrap: GNOME по умолчанию, --kde для Kubuntu
├── do_all_nice_kde.sh         # обёртка: do_all_nice.sh --kde
├── llamacpp-podman-setup.sh   # idempotent user-level setup llama.cpp ROCm
└── llamacpp-podman-guide.md   # подробная документация по llama.cpp схеме
```

Скрипты **не** организованы в подкаталоги — каждый файл самодостаточен. Новые сценарии добавляй отдельными `.sh` + при необходимости `.md`-гайдом рядом.

## Два стиля скриптов

### Legacy bootstrap (`do_all_nice.sh`)

- Запуск: `sudo ./do_all_nice.sh` или `sudo ./do_all_nice.sh --kde`.
- Предполагают права **root** на всё время выполнения.
- Последовательность: `apt update` → PPA/сторонние репы → `dist-upgrade` → пакеты → post-install (oh-my-zsh, rustup, chrome .deb, sysctl).
- **Не идемпотентны**: повторный запуск может дублировать строки в `/etc/sysctl.conf`, повторно качать .deb, ломаться на уже добавленных репозиториях.
- Используют устаревшие приёмы (`apt-key`, `--force-yes` в старом скрипте) — при правках для 26.04 предпочитай современные аналоги (keyrings в `/etc/apt/trusted.gpg.d/`, `.sources` deb822).

### Modern user-level (`llamacpp-podman-setup.sh`)

- Запуск **только от обычного пользователя** (не root).
- `set -euo pipefail`, явные `need_cmd`, `die`, `warn`.
- **Идемпотентность**: `write_if_changed` / `write_executable_if_changed`, не перезаписывает `~/.llamacpp/config/llama.env` если уже есть.
- Side effects в `$HOME`: `~/.llamacpp/`, `~/.config/containers/systemd/*.container`.
- Зависимости (podman, группы render/video) проверяются, но не устанавливаются автоматически — только предупреждения.

**Новые скрипты пиши в стиле modern**, если они не являются одноразовым полным bootstrap.

## Что делают bootstrap-скрипты

Общее для обоих:

- Dev-стек: zsh, oh-my-zsh, git, build-essential, golang, rust (rustup), docker (CE + compose plugin)
- Редакторы/IDE: Sublime Text, VS Code
- Медиа/утилиты: mc, p7zip, vlc, keepassxc
- Chrome (.deb напрямую с Google)
- Docker: пользователь добавляется в группу `docker`
- Sysctl: `fs.inotify.max_user_watches`, `vm.max_map_count`, `vm.swappiness`

Общий bootstrap (`do_all_nice.sh`): LibreOffice PPA, Enpass, Yandex Disk (apt), Docker deb822, OpenVPN, Chrome .deb, oh-my-zsh, rustup, sysctl.

Отличия профилей:

- **GNOME** (default): `network-manager-openvpn-gnome`, gsettings для Gedit encodings.
- **KDE** (`--kde`): `network-manager-openvpn`, без gsettings.
- **Оба профиля**: snap postman + discord.

## llama.cpp ROCm

- Образ по умолчанию: `docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.3`
- User systemd Quadlet → `llama.cpp-rocm.service`
- Конфиг модели: `~/.llamacpp/config/llama.env` (sampling, MTP через `EXTRA_ARGS`)
- Системный конфиг: `~/.llamacpp/config/system.env` (`GPU_VRAM_GB`: 60|90|114|124)
- Порт по умолчанию: `7777`
- **GRUB** обновляется скриптом идемпотентно: `iommu=pt`, `amdgpu.gttsize`, `ttm.pages_limit` (замена, не дописывание)
- Дефолтная модель: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` + MTP flags в `EXTRA_ARGS`
- Удаление: `./llamacpp-podman-setup.sh --uninstall` (сохраняет `~/.llamacpp`)
- Не использовать `systemctl --user enable` для Quadlet-generated unit — только `start`/`restart`

Подробности, troubleshooting, смена модели — в `llamacpp-podman-guide.md`.

## Operating Rules

1. **Минимальный diff** — не рефакторить legacy bootstrap целиком без запроса; точечные правки под 26.04 и конкретную задачу.
2. **Язык комментариев** — смешанный RU/EN как в существующих файлах; новые комментарии на русском, если правишь русскоязычный скрипт.
3. **Shebang**: `#!/bin/bash` (legacy) или `#!/usr/bin/env bash` (modern).
4. **Секреты** — не хардкодить ключи, токены, пароли; не коммитить `.env` с credentials.
5. **Root vs user** — явно документировать в шапке скрипта, от кого запускать.
6. **Идемпотентность** — для setup-скриптов, которые будут перезапускаться, обязательна (как в llamacpp).
7. **Документация** — нетривиальные сценарии сопровождай `.md` рядом со скриптом; `README.md` обновляй только если меняется точка входа для пользователя.
8. **Не создавай коммиты** без явной просьбы пользователя.

## Добавление нового скрипта

1. Имя: `verb-target.sh` или `setup-<feature>.sh` (kebab-case).
2. Шапка: назначение, Ubuntu version, root/user, идемпотентность, зависимости.
3. Если скрипт пишет в `/etc` или ставит пакеты — root bootstrap; если настраивает user services/containers — user-level.
4. Переменные окружения для переопределения путей/имён — через `${VAR:-default}` (как `LLAMACPP_*`).
5. При изменении поведения llama.cpp — синхронизируй `llamacpp-podman-setup.sh` и `llamacpp-podman-guide.md`.

## Validation

Репозиторий без CI. Проверки вручную на Ubuntu 26.04:

```bash
# синтаксис bash
bash -n do_all_nice.sh
bash -n do_all_nice_kde.sh
bash -n llamacpp-podman-setup.sh

# shellcheck (если установлен)
shellcheck llamacpp-podman-setup.sh
```

После bootstrap — перелогин/reboot для групп (`docker`, `render`, `video`) и sysctl.

## Escalate To Human If

- нужно менять GRUB / параметры ядра на прод-машине;
- конфликт пакетов или PPA на 26.04 неочевиден;
- скрипт требует credentials (VPN, Enpass, облака);
- удаление/замена крупного блока legacy bootstrap затронет привычный workflow пользователя.

## Related Docs

- `README.md`
- `llamacpp-podman-guide.md`
