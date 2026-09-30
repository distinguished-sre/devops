#!/usr/bin/env bash
# Поломки для урока 1.8 «systemd и редакторы». Запуск: sudo bash break.sh 1|2|3|fix
# Ломает только сервис notes: unit-файл не трогается, правки идут через drop-in
# /etc/systemd/system/notes.service.d/break.conf и через строку PORT в /etc/notes/notes.env.
# Только для учебной ВМ.
set -euo pipefail

ENV_FILE=/etc/notes/notes.env
DROPIN_DIR=/etc/systemd/system/notes.service.d
DROPIN=$DROPIN_DIR/break.conf

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_notes() {
  if [[ ! -f /etc/systemd/system/notes.service || ! -f $ENV_FILE ]]; then
    echo "Не найден /etc/systemd/system/notes.service или $ENV_FILE. Сначала пройди задания 2 и 3 урока 1.8." >&2
    exit 1
  fi
  if ! systemctl is-active --quiet notes; then
    echo "Сервис notes сейчас не работает. Сначала почини его или выполни: sudo bash $0 fix" >&2
    exit 1
  fi
}

drop_in() {
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN"
}

apply() {
  systemctl daemon-reload
  systemctl reset-failed notes 2>/dev/null || true
  systemctl restart notes --no-block
}

case "${1:-}" in
  1)
    need_root 1; need_notes
    drop_in <<'CONF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/python3 /opt/notes/app.py
CONF
    apply
    echo "Сценарий 1 готов. Подожди 10 секунд и проверь: systemctl is-active notes; curl -sS --max-time 3 http://127.0.0.1:8080/healthz"
    ;;
  2)
    need_root 2; need_notes
    sed -i 's/^PORT=.*/PORT=8080a/' "$ENV_FILE"
    apply
    echo "Сценарий 2 готов. Подожди 10 секунд и проверь: systemctl is-active notes; curl -sS --max-time 3 http://127.0.0.1:8080/healthz"
    ;;
  3)
    need_root 3; need_notes
    drop_in <<'CONF'
[Service]
ReadWritePaths=
CONF
    apply
    sleep 2
    echo "Сценарий 3 готов. Проверь: systemctl is-active notes; curl -sS -X POST -d '{\"text\":\"проверка\"}' http://127.0.0.1:8080/notes"
    ;;
  fix)
    need_root fix
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    if [[ -f $ENV_FILE ]] && ! grep -q '^PORT=8080$' "$ENV_FILE"; then
      sed -i 's/^PORT=.*/PORT=8080/' "$ENV_FILE"
    fi
    if [[ -f /etc/systemd/system/notes.service ]]; then
      systemctl daemon-reload
      systemctl reset-failed notes 2>/dev/null || true
      systemctl restart notes
    fi
    echo "Всё возвращено: drop-in break.conf удалён, PORT=8080, сервис notes перезапущен."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
