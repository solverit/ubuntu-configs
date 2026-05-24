#!/usr/bin/env bash
# Обратная совместимость: делегирует в единый bootstrap-скрипт.
exec "$(dirname "$0")/do_all_nice.sh" --kde "$@"
