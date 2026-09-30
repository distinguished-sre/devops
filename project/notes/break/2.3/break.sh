#!/usr/bin/env bash
# Поломки для урока 2.3 «DNS». Запуск: sudo bash break.sh 1|2|3|fix
# Меняет /etc/resolv.conf, /etc/hosts и /etc/nsswitch.conf: только для учебной ВМ.
# Всё, что меняется, запоминается в /var/lib/break-2.3, а fix возвращает как было.
set -euo pipefail

STATE=/var/lib/break-2.3
MARK='# старый сервер'

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# Сценарии 2 и 3 опираются на запись notes.lab из задания 5 урока.
need_hosts_entry() {
  if ! grep -Eq '^[^#]*[[:space:]]notes\.lab([[:space:]]|$)' /etc/hosts; then
    echo "В /etc/hosts нет записи notes.lab. Сначала пройди задание 5 урока 2.3." >&2
    exit 1
  fi
}

# Возвращает /etc/resolv.conf в исходный вид.
restore_resolv() {
  [[ -f $STATE/resolv.kind ]] || return 0
  local kind
  kind=$(cat "$STATE/resolv.kind")
  rm -f /etc/resolv.conf
  if [[ $kind == link ]]; then
    ln -s "$(cat "$STATE/resolv.target")" /etc/resolv.conf
  else
    cp "$STATE/resolv.copy" /etc/resolv.conf
  fi
  rm -f "$STATE/resolv.kind" "$STATE/resolv.target" "$STATE/resolv.copy"
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl restart systemd-resolved
  fi
}

restore_nsswitch() {
  [[ -f $STATE/nsswitch.hosts ]] || return 0
  local line
  line=$(cat "$STATE/nsswitch.hosts")
  # Возвращаем ровно ту строку hosts:, которая была до поломки.
  awk -v l="$line" '/^hosts:/ { print l; next } { print }' /etc/nsswitch.conf > "$STATE/nsswitch.new"
  cat "$STATE/nsswitch.new" > /etc/nsswitch.conf
  rm -f "$STATE/nsswitch.new" "$STATE/nsswitch.hosts"
}

restore_hosts() {
  grep -q "$MARK" /etc/hosts || return 0
  # Убираем добавленную скриптом строку и возвращаем настоящую, которую он вынул.
  grep -v "$MARK" /etc/hosts > "$STATE/hosts.new"
  if [[ -f $STATE/hosts.orig ]]; then
    cat "$STATE/hosts.orig" >> "$STATE/hosts.new"
  fi
  cat "$STATE/hosts.new" > /etc/hosts
  rm -f "$STATE/hosts.new" "$STATE/hosts.orig"
}

case "${1:-}" in
  1)
    need_root 1
    mkdir -p "$STATE"
    restore_resolv
    if [[ -L /etc/resolv.conf ]]; then
      echo link > "$STATE/resolv.kind"
      readlink /etc/resolv.conf > "$STATE/resolv.target"
    else
      echo file > "$STATE/resolv.kind"
      cp /etc/resolv.conf "$STATE/resolv.copy"
    fi
    rm -f /etc/resolv.conf
    # 192.0.2.53 из диапазона документации: такого DNS-сервера в интернете нет.
    printf 'nameserver 192.0.2.53\n' > /etc/resolv.conf
    echo "Сценарий 1 готов. Проверь: dig +time=2 +tries=1 example.com и ping -c 1 -W 3 8.8.8.8"
    ;;
  2)
    need_root 2; need_hosts_entry
    mkdir -p "$STATE"
    restore_hosts
    # Настоящую запись вынимаем (fix её вернёт), вместо неё ставим «старый» адрес.
    grep -E '^[^#]*[[:space:]]notes\.lab([[:space:]]|$)' /etc/hosts > "$STATE/hosts.orig"
    grep -Ev '^[^#]*[[:space:]]notes\.lab([[:space:]]|$)' /etc/hosts > "$STATE/hosts.new" || true
    printf '127.0.0.2 notes.lab %s\n' "$MARK" >> "$STATE/hosts.new"
    cat "$STATE/hosts.new" > /etc/hosts
    rm -f "$STATE/hosts.new"
    echo "Сценарий 2 готов. Проверь: curl -sS --max-time 3 http://notes.lab:8080/healthz"
    ;;
  3)
    need_root 3
    mkdir -p "$STATE"
    restore_nsswitch
    grep '^hosts:' /etc/nsswitch.conf > "$STATE/nsswitch.hosts"
    awk '/^hosts:/ { print "hosts:          files"; next } { print }' /etc/nsswitch.conf > "$STATE/nsswitch.new"
    cat "$STATE/nsswitch.new" > /etc/nsswitch.conf
    rm -f "$STATE/nsswitch.new"
    echo "Сценарий 3 готов. Проверь: dig +short example.com и curl -sS --max-time 5 http://example.com/"
    ;;
  fix)
    need_root fix
    mkdir -p "$STATE"
    restore_resolv
    restore_hosts
    restore_nsswitch
    echo "Всё возвращено: resolv.conf, запись notes.lab в /etc/hosts и строка hosts: в nsswitch.conf как были."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
