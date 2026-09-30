#!/usr/bin/env bash
# Поломки для урока 2.2 «Порты, TCP и SSH». Запуск: bash break.sh 1|2|3|fix
# Ломает только твои файлы в ~/.ssh (права и ~/.ssh/config), root не нужен.
# Запускай на ВМ, а входи проверять с неё же: ssh localhost.
set -euo pipefail

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/id_ed25519"
AUTH="$SSH_DIR/authorized_keys"
CONFIG="$SSH_DIR/config"
BEGIN='# break-2.2 begin'
END='# break-2.2 end'

no_root() {
  if [[ $EUID -eq 0 ]]; then
    echo "Не запускай через sudo: скрипт правит твои файлы в ~/.ssh. Запусти: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_lesson() {
  if [[ ! -f $KEY || ! -f $KEY.pub ]]; then
    echo "Нет ключа $KEY. Сначала пройди задание 3 урока 2.2." >&2
    exit 1
  fi
  local body
  body=$(awk '{print $2}' "$KEY.pub")
  if [[ ! -f $AUTH ]] || ! grep -qF -- "$body" "$AUTH"; then
    echo "Твоего ключа нет в $AUTH. Сначала пройди задание 3 урока 2.2 (ssh-copy-id)." >&2
    exit 1
  fi
}

# Убирает блок поломки из ~/.ssh/config, остальное не трогает.
# Пишем через cat, чтобы файл остался тем же (владелец и права не меняются).
strip_block() {
  [[ -f $CONFIG ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$CONFIG" > "$tmp"
  cat "$tmp" > "$CONFIG"
  rm -f "$tmp"
}

restore() {
  chmod 700 "$SSH_DIR"
  [[ -f $KEY ]] && chmod 600 "$KEY"
  [[ -f $AUTH ]] && chmod 600 "$AUTH"
  strip_block
  return 0
}

case "${1:-}" in
  1)
    no_root 1; need_lesson; restore
    chmod 777 "$SSH_DIR"
    echo "Сценарий 1 готов. Проверь: ssh localhost true"
    ;;
  2)
    no_root 2; need_lesson; restore
    chmod 644 "$KEY"
    echo "Сценарий 2 готов. Проверь: ssh localhost true"
    ;;
  3)
    no_root 3; need_lesson; restore
    tmp=$(mktemp)
    {
      printf '%s\nHost notes-vm localhost\n    Port 2222\n%s\n' "$BEGIN" "$END"
      [[ -f $CONFIG ]] && cat "$CONFIG"
    } > "$tmp"
    touch "$CONFIG"
    cat "$tmp" > "$CONFIG"
    chmod 600 "$CONFIG"
    rm -f "$tmp"
    echo "Сценарий 3 готов. Проверь: ssh localhost true"
    ;;
  fix)
    no_root fix
    if [[ -d $SSH_DIR ]]; then
      restore
    fi
    echo "Всё возвращено: ~/.ssh 700, ключ и authorized_keys 600, лишних строк в ~/.ssh/config нет."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
