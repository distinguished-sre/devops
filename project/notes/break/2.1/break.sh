#!/usr/bin/env bash
# Поломки для урока 2.1 «Адреса и маршруты». Запуск: sudo bash break.sh 1|2|3|fix
# Меняет настройки «Заметок», файрвол и маршруты: только для учебной ВМ.
set -euo pipefail

ENV_FILE=/etc/notes/notes.env

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_notes() {
  if [[ ! -f $ENV_FILE ]] || ! systemctl cat notes >/dev/null 2>&1; then
    echo "Не найден сервис notes или $ENV_FILE. Сначала пройди урок 1.8." >&2
    exit 1
  fi
}

need_iptables() {
  if ! command -v iptables >/dev/null 2>&1; then
    apt-get install -y -qq iptables >/dev/null
  fi
}

set_host() {
  sed -i "s/^HOST=.*/HOST=$1/" "$ENV_FILE"
  systemctl restart notes
}

drop_rule() {
  iptables "$1" INPUT -p tcp -m tcp --dport 8080 -j DROP
}

case "${1:-}" in
  1)
    need_root 1; need_notes
    set_host 127.0.0.2
    echo "Сценарий 1 готов. Проверь: curl -sS --max-time 3 http://127.0.0.1:8080/healthz"
    ;;
  2)
    need_root 2; need_notes; need_iptables
    drop_rule -C 2>/dev/null || drop_rule -A
    echo "Сценарий 2 готов. Проверь: curl -sS --max-time 3 http://127.0.0.1:8080/healthz"
    ;;
  3)
    need_root 3
    ip route replace unreachable 1.1.1.1/32
    echo "Сценарий 3 готов. Проверь: ping -c 3 8.8.8.8 и ping -c 3 1.1.1.1"
    ;;
  fix)
    need_root fix
    if [[ -f $ENV_FILE ]] && ! grep -q '^HOST=127.0.0.1$' "$ENV_FILE"; then
      set_host 127.0.0.1
    fi
    if command -v iptables >/dev/null 2>&1; then
      while drop_rule -C 2>/dev/null; do drop_rule -D; done
    fi
    ip route del unreachable 1.1.1.1/32 2>/dev/null || true
    echo "Всё возвращено: HOST=127.0.0.1, правило DROP на 8080 удалено, маршрут до 1.1.1.1 восстановлен."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
