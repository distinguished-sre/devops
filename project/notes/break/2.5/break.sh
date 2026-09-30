#!/usr/bin/env bash
# Поломки для урока 2.5 «nginx как reverse proxy». Запуск: sudo bash break.sh 1|2|3|4|fix
# Меняет конфиг nginx для notes.lab и настройки «Заметок»: только для учебной ВМ.
set -euo pipefail

SITE=/etc/nginx/sites-available/notes
LINK=/etc/nginx/sites-enabled/notes
ENV_FILE=/etc/notes/notes.env
BACKUP=/var/backups/break-2.5-notes.conf
HANG_UNIT=notes-break-hang

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_lesson() {
  if [[ ! -f $ENV_FILE ]] || ! systemctl cat notes >/dev/null 2>&1; then
    echo "Не найден сервис notes или $ENV_FILE. Сначала пройди урок 1.8." >&2
    exit 1
  fi
  if ! command -v nginx >/dev/null 2>&1 || [[ ! -f $SITE ]] || [[ ! -e $LINK ]]; then
    echo "Не найден nginx с сайтом $SITE. Сначала выполни задания 1 и 2 урока 2.5." >&2
    exit 1
  fi
}

# Ломать можно только рабочее состояние: иначе непонятно, что сломал скрипт.
need_healthy() {
  if ! nginx -t >/dev/null 2>&1; then
    echo "nginx -t уже не проходит. Сначала верни рабочее состояние: sudo bash $0 fix" >&2
    exit 1
  fi
  if [[ -f $BACKUP ]]; then
    echo "Предыдущая поломка ещё не снята. Сначала: sudo bash $0 fix" >&2
    exit 1
  fi
}

save_backup() {
  cp -p "$SITE" "$BACKUP"
}

apply_nginx() {
  # Если nginx -t не прошёл, reload не выполняем: сайт остаётся на старом конфиге.
  if nginx -t 2>&1; then
    systemctl reload nginx
    sleep 1   # reload асинхронный: даём новым worker подняться
  else
    echo "nginx -t не прошёл, reload пропущен" >&2
  fi
}

# Конфиг из урока, на случай если резервной копии нет.
canonical_conf() {
  cat <<'CONF'
# Прокси перед «Заметками»: nginx :80 -> приложение 127.0.0.1:8080
server {
    listen 80;
    server_name notes.lab;

    access_log /var/log/nginx/notes-access.log;
    error_log  /var/log/nginx/notes-error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;

        # Приложение за прокси не видит клиента, поэтому передаём явно
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 3s;
        proxy_read_timeout    30s;
    }
}
CONF
}

case "${1:-}" in
  1)
    need_root 1; need_lesson; need_healthy
    save_backup
    # Опечатка в имени директивы, как при быстрой правке на проде.
    sed -i 's/^\( *\)proxy_read_timeout /\1proxy_read_timeuot /' "$SITE"
    echo "Сценарий 1 готов. Коллега правил таймаут и применил конфиг:"
    apply_nginx || true
    echo "Проверь: sudo nginx -t и curl -si http://notes.lab/"
    ;;
  2)
    need_root 2; need_lesson; need_healthy
    save_backup
    # Приложение живо, но слушает другой порт, чем ждёт nginx.
    sed -i 's/^PORT=.*/PORT=8090/' "$ENV_FILE"
    systemctl restart notes
    sleep 1
    echo "Сценарий 2 готов. Проверь: curl -si http://notes.lab/"
    ;;
  3)
    need_root 3; need_lesson; need_healthy
    save_backup
    # Процесс принимает соединения на 8081 и никогда не отвечает.
    systemd-run --quiet --unit="$HANG_UNIT" --collect python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8081))
s.listen(16)
held = []
while True:
    held.append(s.accept())
'
    sed -i 's#proxy_pass http://127.0.0.1:8080;#proxy_pass http://127.0.0.1:8081;#' "$SITE"
    apply_nginx
    echo "Сценарий 3 готов. Проверь (ждать придётся около 30 секунд): time curl -si http://notes.lab/"
    ;;
  4)
    need_root 4; need_lesson; need_healthy
    save_backup
    sed -i '/^    location \/ {/i\
    # Временные правила для проверок (добавлены сценарием)\
    location /healthz { default_type text/plain; return 200 "ok\\n"; }\
    location ~ ^/health { default_type text/plain; return 503 "maintenance\\n"; }\
' "$SITE"
    apply_nginx
    echo "Сценарий 4 готов. Проверь: curl -si http://notes.lab/healthz и curl -s http://127.0.0.1:8080/healthz"
    ;;
  fix)
    need_root fix
    if systemctl is-active --quiet "$HANG_UNIT" 2>/dev/null; then
      systemctl stop "$HANG_UNIT"
    fi
    if [[ -f $ENV_FILE ]] && ! grep -q '^PORT=8080$' "$ENV_FILE"; then
      sed -i 's/^PORT=.*/PORT=8080/' "$ENV_FILE"
      systemctl restart notes
      sleep 1
    fi
    if [[ -f $BACKUP ]]; then
      cp -p "$BACKUP" "$SITE"
      rm -f "$BACKUP"
    elif [[ -d $(dirname "$SITE") ]] && command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
      canonical_conf > "$SITE"
    fi
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
      systemctl reload nginx
      sleep 1
    fi
    echo "Всё возвращено: конфиг nginx как в уроке, PORT=8080, зависший процесс на 8081 остановлен."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|4|fix" >&2
    exit 2
    ;;
esac
