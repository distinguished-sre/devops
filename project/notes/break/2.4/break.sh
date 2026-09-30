#!/usr/bin/env bash
# Поломки для урока 2.4 «HTTP». Запуск: sudo bash break.sh 1|2|3|fix
# Портит код приложения /opt/notes/app.py (версия v3) и перезапускает сервис notes.
# Исходный файл сохраняется рядом: /opt/notes/app.py.good. Только для учебной ВМ.
set -euo pipefail

APP=/opt/notes/app.py
GOOD=/opt/notes/app.py.good
URL=http://127.0.0.1:8080

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_v3() {
  if ! systemctl cat notes >/dev/null 2>&1 || [[ ! -f $APP ]]; then
    echo "Не найден сервис notes или $APP. Сначала пройди урок 1.8." >&2
    exit 1
  fi
  if ! grep -q 'protocol_version = "HTTP/1.1"' "$APP"; then
    echo "В $APP нет версии v3 (protocol_version = \"HTTP/1.1\"). Сначала выполни задание «Шаг проекта» урока 2.4." >&2
    exit 1
  fi
}

# Берём чистый код за основу: если поломка уже стоит, сначала возвращаем оригинал.
prepare() {
  if [[ -f $GOOD ]]; then
    install -o root -g root -m 755 "$GOOD" "$APP"
  else
    install -o root -g root -m 644 "$APP" "$GOOD"
  fi
}

# patch 'что заменить' 'на что': точная замена строки, с проверкой, что она нашлась.
patch() {
  OLD=$1 NEW=$2 APP=$APP python3 - <<'PY'
import os, sys
path = os.environ["APP"]
text = open(path, encoding="utf-8").read()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in text:
    sys.exit("Не нашёл в коде нужную строку. Твой app.py отличается от эталона v3: "
             "скачай эталон (урок 2.4, задание 3) и повтори.")
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

restart_and_wait() {
  # частые перезапуски подряд systemd считает сбоем: сбрасываем счётчик
  systemctl reset-failed notes 2>/dev/null || true
  systemctl restart notes
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 1 "$URL/healthz"; then
      return 0
    fi
    sleep 0.5
  done
  echo "Сервис notes не поднялся после правки: sudo systemctl status notes" >&2
  exit 1
}

case "${1:-}" in
  1)
    need_root 1; need_v3; prepare
    patch 'return self._json(404, {"error": "not found"})' \
          'return self._json(405, {"error": "not found"})'
    patch 'return self._json(405, {"error": "method not allowed"}, {"Allow": allowed})' \
          'return self._json(500, {"error": "method not allowed"})'
    restart_and_wait
    echo "Сценарий 1 готов. Проверь: curl -i $URL/nope и curl -i -X DELETE $URL/notes"
    ;;
  2)
    need_root 2; need_v3; prepare
    # заметка с русским текстом: без неё поломка не видна (в ASCII символ равен байту)
    if ! grep -q 'проверка длины' /var/lib/notes/notes.txt 2>/dev/null; then
      curl -s -o /dev/null -X POST -d '{"text":"проверка длины ответа"}' "$URL/notes" || true
    fi
    patch 'self.send_header("Content-Length", str(len(data)))' \
          'self.send_header("Content-Length", str(len(body)))'
    restart_and_wait
    echo "Сценарий 2 готов. Проверь: curl -s $URL/notes | python3 -m json.tool"
    ;;
  3)
    need_root 3; need_v3; prepare
    patch '        self.end_headers()
        if self.command != "HEAD":' \
          '        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":'
    restart_and_wait
    echo "Сценарий 3 готов. Проверь: curl -sv $URL/healthz $URL/"
    ;;
  fix)
    need_root fix
    if [[ -f $GOOD ]]; then
      install -o root -g root -m 755 "$GOOD" "$APP"
      rm -f "$GOOD"
      restart_and_wait
      echo "Всё возвращено: $APP восстановлен из сохранённой копии, сервис notes перезапущен."
    else
      echo "Сохранённой копии нет: поломка не ставилась (или уже исправлена). Ничего не меняю."
    fi
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
