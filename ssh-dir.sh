#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="${1:-$HOME/.ssh}"

if [[ ! -d "$SSH_DIR" ]]; then
    echo "Ошибка: каталог не найден: $SSH_DIR" >&2
    exit 1
fi

echo "Использую каталог: $SSH_DIR"

# Каталог .ssh
chmod 700 "$SSH_DIR"

# Все подкаталоги внутри .ssh — закрытые
find "$SSH_DIR" -type d -exec chmod 700 {} \;

# Публичные ключи
find "$SSH_DIR" -type f -name "*.pub" -exec chmod 644 {} \;

# Основные служебные файлы
for file in config authorized_keys; do
    if [[ -f "$SSH_DIR/$file" ]]; then
        chmod 600 "$SSH_DIR/$file"
    fi
done

# known_hosts не секретный, но 644 — стандартно нормально
for file in known_hosts known_hosts.old; do
    if [[ -f "$SSH_DIR/$file" ]]; then
        chmod 644 "$SSH_DIR/$file"
    fi
done

# Все остальные обычные файлы считаем приватными ключами/секретными файлами
# Исключаем .pub, known_hosts и known_hosts.old
find "$SSH_DIR" -type f \
    ! -name "*.pub" \
    ! -name "known_hosts" \
    ! -name "known_hosts.old" \
    -exec chmod 600 {} \;

# Владелец — текущий пользователь
chown -R "$USER:$USER" "$SSH_DIR"

echo "Права для $SSH_DIR приведены в порядок."
