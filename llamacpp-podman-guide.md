# Ubuntu 26.04: rootless llama.cpp ROCm через Podman, Quadlet и `~/.llamacpp`

## Назначение

Схема для запуска `llama.cpp` с ROCm на Ubuntu 26.04 под текущим пользователем, без хранения кеша и конфигов в `/opt` и без постоянной работы от root.

Контейнер:

```text
docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.4
```

Схема:

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

Скрипт установки: `llamacpp-podman-setup.sh`

---

# 1. Что создаёт установочный скрипт

```text
~/.llamacpp/
├── cache/
│   └── постоянный кеш моделей llama.cpp / Hugging Face
├── config/
│   ├── llama.env      # модель, sampling, EXTRA_ARGS
│   └── system.env     # GPU_VRAM_GB (60|90|114|124)
└── scripts/
    └── start-llama.sh
```

Quadlet:

```text
~/.config/containers/systemd/llama.cpp-rocm.container
```

User-service:

```text
llama.cpp-rocm.service
```

---

# 2. AMD Ryzen AI MAX+ 395 / Strix Halo: память GPU

На Strix Halo с 128 GB unified memory ROCm по умолчанию видит ~64 GB. Для больших моделей нужны параметры ядра:

```text
iommu=pt amdgpu.gttsize=<MiB> ttm.pages_limit=<pages>
```

Скрипт **сам** добавляет их в `/etc/default/grub`, **не затирая** остальные параметры (`quiet splash` и т.д.). При повторном запуске с другим `--gpu-mem` старые значения `amdgpu.gttsize` и `ttm.pages_limit` **заменяются**, а не дублируются.

## Выбор объёма GPU (GB)

| `--gpu-mem` | `amdgpu.gttsize` (MiB) | `ttm.pages_limit` | Total VRAM в llama-cli |
|-------------|------------------------|-------------------|------------------------|
| 60          | 61440                  | 15728640          | ~61440 MiB             |
| 90          | 92160                  | 23592960          | ~92160 MiB             |
| 114         | 116736                 | 29884416          | ~116736 MiB            |
| 124         | 126976                 | 32505856          | ~126976 MiB            |

Формулы:

```text
amdgpu.gttsize    = GB × 1024
ttm.pages_limit   = GB × 262144
```

Выбор сохраняется в `~/.llamacpp/config/system.env`:

```bash
GPU_VRAM_GB=124
```

Проверить активные параметры:

```bash
cat /proc/cmdline
```

После смены `--gpu-mem` — **reboot**:

```bash
sudo reboot
```

Ожидаемый вывод `llama-cli --list-devices` (для 124 GB):

```text
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 126976 MiB)
Device 0: AMD Radeon 8060S Graphics, gfx1151
```

---

# 3. Предварительные условия

```bash
sudo apt update
sudo apt install -y podman curl git
```

Группы пользователя:

```text
render
video
```

```bash
groups $USER
# при необходимости:
sudo usermod -aG render,video $USER
sudo reboot
```

Устройства:

```bash
ls -l /dev/kfd /dev/dri
```

---

# 4. Установка

```bash
chmod +x llamacpp-podman-setup.sh
./llamacpp-podman-setup.sh
```

Скрипт работает в **два этапа**:

1. **Конфигурация** — спрашивает все параметры (GPU memory, подтверждение), показывает summary.
2. **Тихая установка** — без дополнительных вопросов; прогресс `[1/8]…[8/8]`, детали в log-файле.

Полностью без вопросов (CI / скрипты):

```bash
./llamacpp-podman-setup.sh --gpu-mem 124 --yes
```

Log тихой фазы: `/tmp/llamacpp-setup-<pid>.log` (или `LLAMACPP_SETUP_LOG`).

Скрипт:

- проверяет `podman`, `systemctl`, `loginctl`, `sudo`;
- проверяет `/dev/kfd`, `/dev/dri`, группы `render`/`video`;
- записывает `system.env` с выбором GPU;
- **идемпотентно** обновляет GRUB (`iommu=pt`, `amdgpu.gttsize`, `ttm.pages_limit`);
- создаёт `~/.llamacpp` (если нет);
- создаёт дефолтный `llama.env`, **если его ещё нет**;
- создаёт/обновляет `start-llama.sh` и Quadlet;
- скачивает образ `rocm-7.2.3`;
- проверяет ROCm внутри контейнера;
- включает `linger`;
- запускает `llama.cpp-rocm.service`.

---

# 5. Удаление

```bash
./llamacpp-podman-setup.sh --uninstall
```

Сначала — опрос опций (или флаги CLI), затем тихое выполнение.

## По умолчанию (всегда)

- останавливает `llama.cpp-rocm.service`
- удаляет `~/.config/containers/systemd/llama.cpp-rocm.container`
- перезагружает user systemd

**Не трогает:** `~/.llamacpp`, Podman-контейнеры, образ, GRUB, linger.

## Дополнительные опции

| Флаг | Действие |
|------|----------|
| `--remove-containers` | Удалить Podman-контейнер(ы) этого setup (`llama.cpp-rocm` и на базе образа ROCm) |
| `--purge-cache` | Удалить только `~/.llamacpp/cache` |
| `--remove-image` | Удалить образ `rocm-7.2.3` из Podman |
| `--reset-grub` | Убрать из GRUB параметры, добавленные скриптом (`iommu=pt`, `amdgpu.gttsize`, `ttm.pages_limit`) |
| `--purge-all` | **Всё данные setup:** весь `~/.llamacpp`, контейнеры, образ, GRUB, `loginctl disable-linger` |

Примеры:

```bash
# только service + Quadlet
./llamacpp-podman-setup.sh --uninstall --yes

# + контейнеры
./llamacpp-podman-setup.sh --uninstall --remove-containers --yes

# полная зачистка данных (Podman как приложение остаётся)
./llamacpp-podman-setup.sh --uninstall --purge-all --yes
```

Podman (`apt install podman`) **не удаляется** — только контейнеры и образ этого setup.

После `--reset-grub` или `--purge-all` нужен reboot.

Переустановка после минимального uninstall:

```bash
./llamacpp-podman-setup.sh --gpu-mem 124
```

---

# 6. Повторный запуск (идемпотентность)

При повторном `./llamacpp-podman-setup.sh`:

- не перетирает существующий `llama.env`;
- обновляет `start-llama.sh` и Quadlet только при изменении содержимого;
- **заменяет** (не дублирует) параметры ядра в GRUB при смене `--gpu-mem`;
- обновляет `system.env`;
- выполняет `systemctl --user daemon-reload`;
- запускает тот же сервис.

Сменить объём GPU:

```bash
./llamacpp-podman-setup.sh --gpu-mem 90
sudo reboot
```

---

# 7. Quadlet: почему не `enable --now`

```bash
systemctl --user enable --now llama.cpp-rocm.service   # НЕ использовать
```

Ошибка:

```text
Failed to enable unit: Unit ... is transient or generated
```

Правильно:

```bash
systemctl --user daemon-reload
systemctl --user start llama.cpp-rocm.service
```

Автозапуск: `[Install] WantedBy=default.target` в Quadlet + `sudo loginctl enable-linger $USER`.

---

# 8. Дефолтная модель и sampling

`~/.llamacpp/config/llama.env` при первой установке:

```bash
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

# MTP draft speculation
EXTRA_ARGS="-fa 1 --no-mmap --jinja --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.75"
```

## Sampling-параметры

Передаются в `llama-server` через `start-llama.sh`:

| `llama.env`           | Флаг llama-server      |
|-----------------------|------------------------|
| `TEMPERATURE`         | `--temp`               |
| `TOP_P`               | `--top-p`              |
| `TOP_K`               | `--top-k`              |
| `MIN_P`               | `--min-p`              |
| `PRESENCE_PENALTY`    | `--presence-penalty`   |
| `REPETITION_PENALTY`  | `--repeat-penalty`     |

После правки:

```bash
systemctl --user restart llama.cpp-rocm.service
```

## MTP-модели

Для MTP-моделей (как дефолтная Qwen3.6) в `EXTRA_ARGS` нужны:

```text
--spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.75
```

Для обычных (не-MTP) моделей эти три флага убрать из `EXTRA_ARGS`.

---

# 9. Управление сервисом

```bash
systemctl --user status llama.cpp-rocm.service
journalctl --user -u llama.cpp-rocm.service -f
systemctl --user start llama.cpp-rocm.service
systemctl --user stop llama.cpp-rocm.service
systemctl --user restart llama.cpp-rocm.service

curl http://127.0.0.1:7777/health
curl http://127.0.0.1:7777/v1/models
```

---

# 10. Работа с моделями

## 10.1. Сменить модель

```bash
nano ~/.llamacpp/config/llama.env
systemctl --user restart llama.cpp-rocm.service
```

## 10.2. Без `HF_FILE`

```bash
HF_REPO="user/model-repo:Q4_K_M"
HF_FILE=""
```

## 10.3. С конкретным GGUF

```bash
HF_REPO="unsloth/Qwen3.6-35B-A3B-MTP-GGUF"
HF_FILE="Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf"
```

Неправильно — путь в `HF_REPO`:

```bash
HF_REPO="user/model/path/file.gguf"   # invalid
```

---

# 11. Загрузка новых моделей

## Foreground warm-up

```bash
systemctl --user stop llama.cpp-rocm.service

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
  docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.4 \
  /usr/local/bin/start-llama.sh
```

Дождаться скачивания → `Ctrl+C` → `systemctl --user start llama.cpp-rocm.service`.

## Кеш

```bash
du -sh ~/.llamacpp/cache
find ~/.llamacpp/cache -type f -name '*.gguf' | head
```

---

# 12. Обновление контейнера

В Quadlet: `Pull=never` — образ не тянется при каждом старте.

```bash
systemctl --user stop llama.cpp-rocm.service
podman pull docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.4
./llamacpp-podman-setup.sh --gpu-mem 124   # обновит Quadlet при смене тега в скрипте
```

Или повторный запуск setup-скрипта после обновления `LLAMACPP_ROCM_IMAGE`.

---

# 13. Проверка ROCm

```bash
podman run --rm -it \
  --device /dev/dri \
  --device /dev/kfd \
  --group-add video \
  --group-add render \
  --security-opt seccomp=unconfined \
  docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.2.3 \
  llama-cli --list-devices
```

---

# 14. Типовые проблемы

## `Failed to enable unit: transient or generated`

Использовать `daemon-reload` + `start`, не `enable --now`.

## `cudaMalloc failed: out of memory` около 64 GB

```bash
cat /proc/cmdline
./llamacpp-podman-setup.sh --gpu-mem 124
sudo reboot
```

## Сервис не скачивает модель

Foreground warm-up (раздел 11) + права:

```bash
sudo chown -R $USER:$USER ~/.llamacpp
```

## `invalid HF repo format`

Разделять `HF_REPO` и `HF_FILE` (раздел 10.3).

## Конфликт имени контейнера

```bash
systemctl --user stop llama.cpp-rocm.service
podman rm -f llama.cpp-rocm
```

---

# 15. Финальный workflow

## Установка

```bash
chmod +x llamacpp-podman-setup.sh
./llamacpp-podman-setup.sh --gpu-mem 124
sudo reboot
```

## Проверка

```bash
systemctl --user status llama.cpp-rocm.service
curl http://127.0.0.1:7777/health
```

## Смена модели / sampling

```bash
nano ~/.llamacpp/config/llama.env
systemctl --user restart llama.cpp-rocm.service
```

## Смена GPU memory

```bash
./llamacpp-podman-setup.sh --gpu-mem 90
sudo reboot
```

## Удаление

```bash
./llamacpp-podman-setup.sh --uninstall              # service + Quadlet
./llamacpp-podman-setup.sh --uninstall --purge-all --yes   # все данные setup
```

## Обновление образа

```bash
./llamacpp-podman-setup.sh --gpu-mem 124
```

---

# 16. Успешная установка

```bash
systemctl --user status llama.cpp-rocm.service
# Active: active (running)

curl http://127.0.0.1:7777/health
# OK после загрузки модели
```

В логах (124 GB):

```text
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 126976 MiB)
```
