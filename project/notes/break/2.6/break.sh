#!/usr/bin/env bash
# Поломки для урока 2.6 «TLS и HTTPS». Запуск: sudo bash break.sh 1|2|3|fix
# Меняет сертификат и конфиг nginx для «Заметок»: только для учебной ВМ.
set -euo pipefail

TLS_DIR=/etc/notes/tls
CRT=$TLS_DIR/notes.crt
KEY=$TLS_DIR/notes.key
NEW_DIR=/etc/notes/tls-new
SITE=/etc/nginx/sites-available/notes
CHECK="curl -sS --cacert $CRT https://notes.lab/healthz"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_https() {
  if ! command -v nginx >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    echo "Не найден nginx или openssl. Сначала пройди урок 2.5 и задания 1-2 этого урока." >&2
    exit 1
  fi
  if [[ ! -f $SITE ]] || ! grep -q 'listen 443' "$SITE" || [[ ! -f $CRT || ! -f $KEY ]]; then
    echo "HTTPS для «Заметок» не настроен: нет $SITE с 'listen 443' или $CRT. Сначала выполни задания 2 и 4 урока 2.6." >&2
    exit 1
  fi
}

# Выпустить самоподписанный сертификат: $1 значение SAN (например DNS:notes.lab), $2 каталог
issue_cert() {
  mkdir -p "$2"
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=notes.lab" -addext "subjectAltName=$1" \
    -keyout "$2/notes.key" -out "$2/notes.crt" 2>/dev/null
  chmod 600 "$2/notes.key"
  chmod 644 "$2/notes.crt"
}

apply_nginx() {
  nginx -t 2>/dev/null
  systemctl reload nginx
  sleep 1
}

cert_is_good() {
  openssl x509 -in "$CRT" -noout -checkend 86400 >/dev/null 2>&1 &&
    openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:notes.lab' &&
    [[ "$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null | sha256sum)" == \
       "$(openssl pkey -in "$KEY" -pubout 2>/dev/null | sha256sum)" ]]
}

case "${1:-}" in
  1)
    need_root 1; need_https
    # Другой самоподписанный сертификат лежит рядом, nginx переключён на него.
    # Клиентский файл доверия $CRT остаётся старым.
    issue_cert DNS:notes.lab "$NEW_DIR"
    sed -i "s#$TLS_DIR/#$NEW_DIR/#" "$SITE"
    apply_nginx
    echo "Сценарий 1 готов. Проверь: $CHECK"
    ;;
  2)
    need_root 2; need_https
    # Сертификат с нулевым сроком: к моменту проверки он уже просрочен.
    openssl req -newkey rsa:2048 -nodes -subj "/CN=notes.lab" \
      -keyout "$KEY" -out /tmp/break-2.6.csr 2>/dev/null
    printf 'subjectAltName=DNS:notes.lab\n' > /tmp/break-2.6.ext
    openssl x509 -req -in /tmp/break-2.6.csr -signkey "$KEY" -days 0 \
      -extfile /tmp/break-2.6.ext -out "$CRT" 2>/dev/null
    rm -f /tmp/break-2.6.csr /tmp/break-2.6.ext
    chmod 600 "$KEY"; chmod 644 "$CRT"
    sleep 2
    apply_nginx
    echo "Сценарий 2 готов. Проверь: $CHECK"
    ;;
  3)
    need_root 3; need_https
    # В SAN другое имя: сертификат валиден, но не для notes.lab.
    issue_cert DNS:www.notes.lab "$TLS_DIR"
    apply_nginx
    echo "Сценарий 3 готов. Проверь: $CHECK"
    ;;
  fix)
    need_root fix
    if [[ ! -f $SITE ]] || ! grep -q 'listen 443' "$SITE"; then
      echo "HTTPS ещё не настроен, чинить нечего."
      exit 0
    fi
    # Вернуть пути в конфиге и убрать чужой сертификат.
    if grep -q "$NEW_DIR/" "$SITE"; then
      sed -i "s#$NEW_DIR/#$TLS_DIR/#" "$SITE"
    fi
    rm -rf "$NEW_DIR"
    # Перевыпустить сертификат, только если он не годится.
    if [[ ! -f $CRT || ! -f $KEY ]] || ! cert_is_good; then
      issue_cert DNS:notes.lab "$TLS_DIR"
    fi
    apply_nginx
    echo "Всё возвращено: nginx читает $CRT, сертификат действует и выпущен на notes.lab."
    $CHECK || true
    echo
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
