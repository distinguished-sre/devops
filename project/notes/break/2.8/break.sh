#!/usr/bin/env bash
# Поломки для урока 2.8 «Путь запроса и диагностика». Запуск: sudo bash break.sh 1|2|3|4|5|random|fix
# Меняет /etc/hosts, файрвол, сертификат и конфиги nginx и «Заметок»: только для учебной ВМ.
set -euo pipefail

ENV_FILE=/etc/notes/notes.env
TLS_DIR=/etc/notes/tls
SITE=/etc/nginx/sites-available/notes
MARK='# break-2.8'

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# Скрипт ломает стенд из уроков 1.8 и 2.3-2.7: без него ломать нечего
need_stand() {
  local missing=""
  systemctl cat notes >/dev/null 2>&1 && [[ -f $ENV_FILE ]] || missing+=" сервис notes и $ENV_FILE (урок 1.8);"
  grep -qE '^[^#]*[[:space:]]notes\.lab([[:space:]]|$)' /etc/hosts || missing+=" запись notes.lab в /etc/hosts (урок 2.3);"
  [[ -f $SITE ]] && command -v nginx >/dev/null 2>&1 || missing+=" nginx и $SITE (урок 2.5);"
  [[ -f $TLS_DIR/notes.crt && -f $TLS_DIR/notes.key ]] || missing+=" сертификат в $TLS_DIR (урок 2.6);"
  if [[ -n $missing ]]; then
    echo "Стенд не готов, не хватает:$missing" >&2
    echo "Пройди указанные уроки и запусти скрипт снова." >&2
    exit 1
  fi
}

need_iptables() {
  if ! command -v iptables >/dev/null 2>&1; then
    apt-get install -y -qq iptables >/dev/null
  fi
}

# Выпускает сертификат notes.lab так же, как в уроке 2.6. Первый аргумент: срок в днях
issue_cert() {
  openssl req -x509 -newkey rsa:2048 -nodes -days "$1" \
    -subj "/CN=notes.lab" \
    -addext "subjectAltName=DNS:notes.lab" \
    -keyout "$TLS_DIR/notes.key" \
    -out "$TLS_DIR/notes.crt" 2>/dev/null
  chmod 600 "$TLS_DIR/notes.key"
  chmod 644 "$TLS_DIR/notes.crt"
}

drop_rule() {
  iptables "$1" INPUT -p tcp -m tcp --dport 443 -j DROP
}

# /etc/hosts правим без замены файла (в контейнерах его нельзя подменить через sed -i)
edit_hosts() {
  local tmp
  tmp=$(mktemp)
  sed -E "$1" /etc/hosts > "$tmp"
  cat "$tmp" > /etc/hosts
  rm -f "$tmp"
}

break_1() {  # DNS: опечатка в имени
  if grep -q "$MARK" /etc/hosts; then return; fi
  edit_hosts "s/^([^#]*[[:space:]])notes\\.lab([[:space:]]|\$)/\\1notes.lb $MARK\\2/"
}

break_2() {  # TCP: пакеты на 443 молча выбрасываются
  need_iptables
  drop_rule -C 2>/dev/null || drop_rule -I
}

break_3() {  # TLS: сертификат с истёкшим сроком (openssl ca позволяет задать даты)
  local tmp
  tmp=$(mktemp -d)
  : > "$tmp/index.txt"
  echo 01 > "$tmp/serial"
  cat > "$tmp/ca.cnf" <<CNF
[ca]
default_ca = CA
[CA]
database = $tmp/index.txt
new_certs_dir = $tmp
serial = $tmp/serial
default_md = sha256
unique_subject = no
policy = pol
[pol]
commonName = supplied
CNF
  printf 'subjectAltName=DNS:notes.lab\n' > "$tmp/san.cnf"
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=notes.lab" \
    -keyout "$TLS_DIR/notes.key" -out "$tmp/notes.csr" 2>/dev/null
  openssl ca -batch -notext -selfsign -config "$tmp/ca.cnf" \
    -keyfile "$TLS_DIR/notes.key" -in "$tmp/notes.csr" -out "$TLS_DIR/notes.crt" \
    -startdate "$(date -u -d '-400 days' +%Y%m%d%H%M%SZ)" \
    -enddate "$(date -u -d '-35 days' +%Y%m%d%H%M%SZ)" \
    -extfile "$tmp/san.cnf" >/dev/null 2>&1
  chmod 600 "$TLS_DIR/notes.key"
  chmod 644 "$TLS_DIR/notes.crt"
  rm -rf "$tmp"
  systemctl reload nginx
  sleep 1
}

break_4() {  # nginx: прокси смотрит на порт, где приложения нет
  sed -i 's#proxy_pass http://127.0.0.1:8080;#proxy_pass http://127.0.0.1:8081;#' "$SITE"
  nginx -t 2>/dev/null
  systemctl reload nginx
  sleep 1
}

break_5() {  # приложение: HOST с адресом, которого нет на машине, процесс не стартует
  sed -i 's/^HOST=.*/HOST=192.0.2.10/' "$ENV_FILE"
  systemctl restart notes || true
}

fix_all() {
  # DNS: убираем метку и возвращаем имя
  if grep -q "$MARK" /etc/hosts; then
    edit_hosts "s/notes\\.lb $MARK/notes.lab/"
  fi
  # TCP: убираем наше правило (цикл на случай, если оно добавлено дважды)
  if command -v iptables >/dev/null 2>&1; then
    while drop_rule -C 2>/dev/null; do drop_rule -D; done
  fi
  # TLS: перевыпускаем сертификат, только если срок вышел
  if [[ -f $TLS_DIR/notes.crt ]] && ! openssl x509 -in "$TLS_DIR/notes.crt" -noout -checkend 0 >/dev/null 2>&1; then
    issue_cert 365
  fi
  # nginx: возвращаем порт приложения
  if [[ -f $SITE ]]; then
    sed -i 's#proxy_pass http://127.0.0.1:8081;#proxy_pass http://127.0.0.1:8080;#' "$SITE"
    if nginx -t 2>/dev/null; then systemctl reload nginx; fi
  fi
  # приложение: возвращаем HOST
  if [[ -f $ENV_FILE ]] && ! grep -q '^HOST=127.0.0.1$' "$ENV_FILE"; then
    sed -i 's/^HOST=.*/HOST=127.0.0.1/' "$ENV_FILE"
  fi
  if systemctl cat notes >/dev/null 2>&1; then
    systemctl reset-failed notes 2>/dev/null || true
    systemctl restart notes
    sleep 1
  fi
}

msg="Поломка включена. Ты не знаешь, какая. Проверь: curl -v https://notes.lab/"

case "${1:-}" in
  1|2|3|4|5)
    need_root "$1"; need_stand
    "break_$1"
    echo "Сценарий $1 готов. $msg"
    ;;
  random)
    need_root random; need_stand
    n=$(( RANDOM % 5 + 1 ))
    "break_$n"
    echo "Одна из пяти поломок включена, какая именно, ты не знаешь. $msg"
    ;;
  fix)
    need_root fix
    fix_all
    echo "Всё возвращено: имя notes.lab в /etc/hosts, правило DROP на 443 удалено, сертификат в сроке, proxy_pass на 8080, HOST=127.0.0.1."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|4|5|random|fix" >&2
    exit 2
    ;;
esac
