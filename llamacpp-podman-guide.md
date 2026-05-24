# Ubuntu 26.04: rootless llama.cpp ROCm через Podman, Quadlet и `~/.llamacpp`

## Назначение

Эта схема предназначена для запуска `llama.cpp` с ROCm на Ubuntu 26.04 под текущим пользователем, без хранения кеша и конфигов в `/opt` и без постоянной работы от root.

Используется контейнер:

```text
docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.2
```

Рабочая схема:

```text
Ubuntu 26.04
↓
rootless Podman
↓
user systemd Quadlet
↓
~/.llamacpp/config/llama.env
↓
llama.cpp ROCm server
```

---

# 1. Что создаёт установочный скрипт

Скрипт `setup-llamacpp-rocm-user-idempotent.sh` создаёт структуру:

```text
~/.llamacpp/
├── cache/
│   └── постоянный кеш моделей llama.cpp / Hugging Face
├── config/
│   └── llama.env
└── scripts/
    └── start-llama.sh
```

И Quadlet-файл:

```text
~/.config/containers/systemd/llama.cpp-rocm.container
```

После запуска появляется user-service:

```text
llama.cpp-rocm.service
```

---

# 2. Важная особенность AMD Ryzen AI MAX+ 395 / Strix Halo

Для больших моделей на системе с 128 GB unified memory обязательно нужны параметры ядра:

```text
iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

Без них ROCm может видеть около 64 GB и падать на больших Q8-моделях:

```text
cudaMalloc failed: out of memory
```

Проверить текущие параметры:

```bash
cat /proc/cmdline
```

В выводе должны быть:

```text
iommu=pt
amdgpu.gttsize=126976
ttm.pages_limit=32505856
```

Если их нет, открыть:

```bash
sudo nano /etc/default/grub
```

Пример строки:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856"
```

Применить:

```bash
sudo update-grub
sudo reboot
```

После правильной настройки `llama-cli --list-devices` внутри контейнера должен показывать примерно:

```text
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 126976 MiB)
Device 0: AMD Radeon 8060S Graphics, gfx1151
```

---

# 3. Предварительные условия

Установить Podman:

```bash
sudo apt update
sudo apt install -y podman curl git
```

Пользователь должен быть в группах:

```text
render
video
```

Проверить:

```bash
groups $USER
```

Если групп нет:

```bash
sudo usermod -aG render,video $USER
sudo reboot
```

Проверить устройства:

```bash
ls -l /dev/kfd /dev/dri
```

---

# 4. Установка через готовый скрипт

Сделать скрипт исполняемым:

```bash
chmod +x setup-llamacpp-rocm-user-idempotent.sh
```

Запустить от обычного пользователя, не через `sudo`:

```bash
./setup-llamacpp-rocm-user-idempotent.sh
```

Скрипт:

- проверяет `podman`, `systemctl`, `loginctl`;
- проверяет `/dev/kfd` и `/dev/dri`;
- проверяет группы `render` и `video`;
- проверяет параметры GRUB для Strix Halo;
- создаёт `~/.llamacpp`;
- создаёт дефолтный `llama.env`, если его ещё нет;
- создаёт `start-llama.sh`;
- создаёт user Quadlet;
- скачивает образ `rocm-7.2.2`;
- проверяет ROCm внутри контейнера;
- включает `linger`;
- запускает user-service.

---

# 5. Повторный запуск скрипта

Скрипт рассчитан на повторный запуск.

При повторном запуске он:

- не создаёт дубликаты каталогов;
- не создаёт дубликаты systemd-юнитов;
- не создаёт второй контейнер с тем же именем;
- не перетирает существующий `~/.llamacpp/config/llama.env`;
- перезаписывает helper-скрипт только если его содержимое изменилось;
- перезаписывает Quadlet только если его содержимое изменилось;
- выполняет `systemctl --user daemon-reload`;
- запускает тот же `llama.cpp-rocm.service`.

Важно: если ты уже изменил модель в `llama.env`, повторный запуск setup-скрипта её не сбросит.

---

# 6. Проблема Quadlet: почему не используется `enable --now`

Для Quadlet нельзя делать:

```bash
systemctl --user enable --now llama.cpp-rocm.service
```

Это может дать ошибку:

```text
Failed to enable unit: Unit ... is transient or generated
```

Причина: `llama.cpp-rocm.service` является сгенерированным unit-файлом из:

```text
~/.config/containers/systemd/llama.cpp-rocm.container
```

Правильная команда:

```bash
systemctl --user daemon-reload
systemctl --user start llama.cpp-rocm.service
```

Автозапуск после reboot обеспечивают:

```ini
[Install]
WantedBy=default.target
```

в Quadlet-файле и включённый linger:

```bash
sudo loginctl enable-linger $USER
```

Проверить linger:

```bash
loginctl show-user $USER | grep Linger
```

Ожидаемо:

```text
Linger=yes
```

---

# 7. Дефолтная модель

Скрипт создаёт дефолтный конфиг:

```text
~/.llamacpp/config/llama.env
```

Содержимое по умолчанию:

```bash
HF_REPO="Qwen/Qwen3-Coder-Next-GGUF"
HF_FILE="Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf"

HOST="0.0.0.0"
PORT="7777"

CTX="242144"
NGL="999"

EXTRA_ARGS="-fa 1 --no-mmap --jinja"
```

---

# 8. Управление сервисом

Статус:

```bash
systemctl --user status llama.cpp-rocm.service
```

Логи:

```bash
journalctl --user -u llama.cpp-rocm.service -f
```

Запуск:

```bash
systemctl --user start llama.cpp-rocm.service
```

Остановка:

```bash
systemctl --user stop llama.cpp-rocm.service
```

Перезапуск:

```bash
systemctl --user restart llama.cpp-rocm.service
```

Проверка API:

```bash
curl http://127.0.0.1:7777/health
curl http://127.0.0.1:7777/v1/models
```

---

# 9. Работа с моделями

## 9.1. Изменить модель

Открыть конфиг:

```bash
nano ~/.llamacpp/config/llama.env
```

Изменить:

```bash
HF_REPO="..."
HF_FILE="..."
CTX="..."
NGL="..."
EXTRA_ARGS="..."
```

Перезапустить сервис:

```bash
systemctl --user restart llama.cpp-rocm.service
```

После reboot будет запущена последняя модель, указанная в `llama.env`.

---

## 9.2. Модель без `HF_FILE`

Некоторые репозитории можно запускать через quant-suffix:

```bash
HF_REPO="Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M"
HF_FILE=""
HOST="0.0.0.0"
PORT="7777"
CTX="131072"
NGL="999"
EXTRA_ARGS="-fa 1 --no-mmap --jinja"
```

Если `HF_FILE` пустой, wrapper запускает `llama-server` только с `--hf-repo`.

---

## 9.3. Модель с конкретным GGUF-файлом

Пример:

```bash
HF_REPO="Qwen/Qwen3-Coder-Next-GGUF"
HF_FILE="Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf"
```

Важно: не передавать путь к файлу в `HF_REPO`.

Неправильно:

```bash
HF_REPO="Qwen/Qwen3-Coder-Next-GGUF/Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf"
```

Правильно:

```bash
HF_REPO="Qwen/Qwen3-Coder-Next-GGUF"
HF_FILE="Qwen3-Coder-Next-Q8_0/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf"
```

---

# 10. Загрузка новых моделей

## 10.1. Рекомендуемый способ: foreground warm-up

Иногда user-service при старте не может сам скачать новую большую модель, особенно если сеть ещё не готова, Hugging Face требует токен или нужно увидеть интерактивный вывод.

Надёжный workflow:

Остановить сервис:

```bash
systemctl --user stop llama.cpp-rocm.service
```

Запустить вручную в foreground:

```bash
podman run --rm -it \
  --name llama.cpp-rocm \
  --network host \
  --device /dev/dri \
  --device /dev/kfd \
  --group-add video \
  --group-add render \
  --security-opt seccomp=unconfined \
  -e LLAMA_CACHE=/models-cache \
  -v ~/.llamacpp/cache:/models-cache:rw \
  -v ~/.llamacpp/config:/config:ro \
  -v ~/.llamacpp/scripts/start-llama.sh:/usr/local/bin/start-llama.sh:ro \
  docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.2 \
  /usr/local/bin/start-llama.sh
```

Дождаться скачивания модели.

Остановить `Ctrl+C`.

Запустить сервис:

```bash
systemctl --user start llama.cpp-rocm.service
```

Проверить:

```bash
curl http://127.0.0.1:7777/health
```

---

## 10.2. Проверить кеш

Кеш находится здесь:

```text
~/.llamacpp/cache
```

Размер:

```bash
du -sh ~/.llamacpp/cache
```

Найти GGUF-файлы:

```bash
find ~/.llamacpp/cache -type f | grep -i '.gguf' | head
```

Найти Qwen:

```bash
find ~/.llamacpp/cache -type f | grep -i 'Qwen3-Coder-Next' | head
```

---

## 10.3. Перенести старый кеш из `/opt`

Если модель уже была скачана раньше в `/opt/llama/cache`, можно перенести её:

```bash
sudo cp -a /opt/llama/cache/. /home/mikay/.llamacpp/cache/
sudo chown -R mikay:mikay /home/mikay/.llamacpp
```

После этого:

```bash
systemctl --user restart llama.cpp-rocm.service
```

---

# 11. Права на новый кеш

Если файлы случайно оказались под root, исправить:

```bash
sudo chown -R mikay:mikay /home/mikay/.llamacpp
```

Только кеш:

```bash
sudo chown -R mikay:mikay /home/mikay/.llamacpp/cache
```

---

# 12. Обновление контейнера

В Quadlet стоит:

```ini
Pull=never
```

Это сделано специально, чтобы сервис не проверял и не тянул образ при каждом старте.

Обновлять образ вручную:

```bash
systemctl --user stop llama.cpp-rocm.service
podman pull docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.2
systemctl --user start llama.cpp-rocm.service
```

Проверить:

```bash
systemctl --user status llama.cpp-rocm.service
curl http://127.0.0.1:7777/health
```

---

# 13. Проверка ROCm внутри контейнера

```bash
podman run --rm -it \
  --device /dev/dri \
  --device /dev/kfd \
  --group-add video \
  --group-add render \
  --security-opt seccomp=unconfined \
  docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.2 \
  llama-cli --list-devices
```

Ожидаемый результат после правильного GRUB:

```text
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 126976 MiB)
Device 0: AMD Radeon 8060S Graphics, gfx1151
```

---

# 14. Типовые проблемы

## 14.1. `Failed to enable unit: transient or generated`

Не использовать:

```bash
systemctl --user enable --now llama.cpp-rocm.service
```

Использовать:

```bash
systemctl --user daemon-reload
systemctl --user start llama.cpp-rocm.service
```

---

## 14.2. `cudaMalloc failed: out of memory` около 64 GB

Проверить:

```bash
cat /proc/cmdline
```

Нужны параметры:

```text
iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

---

## 14.3. Сервис не скачивает модель

Использовать foreground warm-up:

```bash
systemctl --user stop llama.cpp-rocm.service
podman run --rm -it ...
systemctl --user start llama.cpp-rocm.service
```

И проверить права:

```bash
sudo chown -R mikay:mikay /home/mikay/.llamacpp
```

---

## 14.4. `invalid HF repo format`

Неправильно:

```bash
HF_REPO="user/model/path/to/file.gguf"
```

Правильно:

```bash
HF_REPO="user/model"
HF_FILE="path/to/file.gguf"
```

---

## 14.5. Конфликт имени контейнера

Если ручной запуск говорит, что контейнер `llama.cpp-rocm` уже существует:

```bash
systemctl --user stop llama.cpp-rocm.service
podman rm -f llama.cpp-rocm
```

Затем повторить ручной запуск.

---

# 15. Финальный workflow

## Установка

```bash
chmod +x setup-llamacpp-rocm-user-idempotent.sh
./setup-llamacpp-rocm-user-idempotent.sh
```

## Проверка

```bash
systemctl --user status llama.cpp-rocm.service
journalctl --user -u llama.cpp-rocm.service -f
curl http://127.0.0.1:7777/health
```

## Смена модели

```bash
nano ~/.llamacpp/config/llama.env
systemctl --user restart llama.cpp-rocm.service
```

## Загрузка новой модели вручную

```bash
systemctl --user stop llama.cpp-rocm.service
podman run --rm -it ... /usr/local/bin/start-llama.sh
systemctl --user start llama.cpp-rocm.service
```

## Обновление образа

```bash
systemctl --user stop llama.cpp-rocm.service
podman pull docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.2
systemctl --user start llama.cpp-rocm.service
```

---

# 16. Что считается успешной установкой

```text
systemctl --user status llama.cpp-rocm.service
```

должен показывать:

```text
Active: active (running)
Loaded: loaded (.../llama.cpp-rocm.container; generated)
```

В логах должно быть:

```text
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 126976 MiB)
Device 0: AMD Radeon 8060S Graphics, gfx1151
```

API:

```bash
curl http://127.0.0.1:7777/health
```

должен отвечать после полной загрузки модели.
