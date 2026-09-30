#!/usr/bin/env bash
# Поломки для урока 4.6 «Compose: nginx и TLS». Запуск из ~/notes: bash break.sh 1|2|3|fix
# Меняет deploy/nginx/compose.conf и compose.yml в твоём проекте и пересоздаёт контейнер proxy.
# Запускать без sudo: файлы проекта принадлежат тебе, а в группе docker sudo не нужен.
# shellcheck disable=SC2016  # $upstream в одинарных кавычках: это текст для sed, не переменная bash
set -euo pipefail

CONF=deploy/nginx/compose.conf
# Копия рабочего конфига, снятая перед первой поломкой: fix вернёт её обратно.
SAVED=deploy/nginx/.break-4.6.conf
COMPOSE=compose.yml
HOLDER=break-4.6-holder

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

need_project() {
  if [[ ! -f $COMPOSE || ! -f $CONF ]]; then
    echo "Не найдены $COMPOSE и $CONF. Перейди в ~/notes и пройди задания 2 и 3 урока 4.6." >&2
    exit 1
  fi
  if ! grep -q '^  proxy:' "$COMPOSE"; then
    echo "В $COMPOSE нет сервиса proxy. Сначала выполни задание 3 урока 4.6." >&2
    exit 1
  fi
  if ! docker compose ps -q notes 2>/dev/null | grep -q .; then
    echo "Стек не запущен. Подними его: docker compose up -d" >&2
    exit 1
  fi
}

# Рабочий конфиг из задания 2: если своего файла в копии нет, fix запишет этот.
write_good_conf() {
  cat > "$CONF" <<'CONF'
# Внутренний DNS Docker; ответы кэшируются на 10 секунд
resolver 127.0.0.11 valid=10s;

server {
    listen 80;
    server_name notes.lab;
    # весь HTTP уходит на HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name notes.lab;

    ssl_certificate     /etc/nginx/tls/notes.crt;
    ssl_certificate_key /etc/nginx/tls/notes.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        # переменная заставляет nginx разрешать имя на каждый запрос
        set $upstream http://notes:8080;
        proxy_pass $upstream;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }
}
CONF
}

# Конфиг в рабочем виде: есть переменная в proxy_pass.
conf_is_good() {
  grep -q 'set \$upstream http://notes:8080;' "$CONF"
}

# Копия рабочего конфига снимается один раз и только с рабочего файла.
save_good_conf() {
  if [[ ! -f $SAVED ]] && conf_is_good; then
    cp "$CONF" "$SAVED"
  fi
}

# Пересоздать только proxy: без --force-recreate Compose не заметит правку конфига,
# смонтированного файлом. --no-deps не трогает notes и db.
recreate_proxy() {
  docker compose up -d --force-recreate --no-deps proxy >/dev/null 2>&1 || true
}

# Код ответа https://notes.lab/healthz через опубликованный порт 443 ("000" - нет ответа).
health_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 -k \
    --resolve notes.lab:443:127.0.0.1 https://notes.lab/healthz 2>/dev/null || true
}

# Ждём до 20 секунд, пока сайт не начнёт отвечать 200.
wait_site() {
  for _ in $(seq 1 20); do
    [[ $(health_code) == 200 ]] && return 0
    sleep 1
  done
  return 1
}

# Ждём до 30 секунд, пока notes станет healthy.
wait_notes() {
  local id
  id=$(docker compose ps -q notes)
  for _ in $(seq 1 30); do
    if [[ $(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null) == healthy ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

remove_holders() {
  docker ps -aq --filter "name=$HOLDER" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

notes_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(docker compose ps -q notes)"
}

case "${1:-}" in
  1)
    need_project
    if grep -q 'proxy_pass http://notes-app:8080;' "$CONF"; then
      echo "Сценарий 1 уже запущен."
      exit 0
    fi
    save_good_conf
    # Статический proxy_pass с именем, которого нет в сети: nginx не стартует.
    sed -e '/set \$upstream/d' -e 's|proxy_pass \$upstream;|proxy_pass http://notes-app:8080;|' "$CONF" > "$CONF.tmp"
    cat "$CONF.tmp" > "$CONF"
    rm -f "$CONF.tmp"
    recreate_proxy
    echo "Сценарий 1 готов. Проверь: docker compose ps -a и docker compose logs --tail=5 proxy"
    ;;
  2)
    need_project
    if ! conf_is_good && ! grep -q 'proxy_pass http://notes:8080;' "$CONF"; then
      echo "Сценарий 2 работает с рабочим конфигом. Сначала: bash $0 fix" >&2
      exit 1
    fi
    if ! grep -q 'proxy_pass http://notes:8080;' "$CONF"; then
      save_good_conf
      # Статический proxy_pass с правильным именем: nginx стартует и запоминает IP notes.
      sed -e '/set \$upstream/d' -e 's|proxy_pass \$upstream;|proxy_pass http://notes:8080;|' "$CONF" > "$CONF.tmp"
      cat "$CONF.tmp" > "$CONF"
      rm -f "$CONF.tmp"
      recreate_proxy
      wait_site || true
    elif [[ $(health_code) != 200 ]]; then
      echo "Сценарий 2 уже запущен."
      exit 0
    fi
    net=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(docker compose ps -q notes)")
    old=$(notes_ip)
    # Пересоздаём notes так, чтобы адрес сменился: временные контейнеры занимают свободные IP,
    # пока notes не получит адрес, отличный от прежнего (обычно хватает одного).
    for i in 1 2 3 4 5 6; do
      docker compose stop notes >/dev/null 2>&1
      docker run -d --rm --name "$HOLDER-$i" --network "$net" alpine:3.22 sleep 300 >/dev/null
      docker compose up -d notes >/dev/null 2>&1
      [[ $(notes_ip) != "$old" ]] && break
    done
    # Контейнер break-4.6-holder-N остаётся жить: он держит старый адрес, и nginx получает
    # мгновенный отказ (502) вместо долгого ожидания. Его удалит fix.
    wait_notes || true
    echo "Сценарий 2 готов. Проверь: curl -sk --resolve notes.lab:443:127.0.0.1 https://notes.lab/healthz"
    ;;
  3)
    need_project
    if grep -q '/etc/nginx/ssl:ro' "$COMPOSE"; then
      echo "Сценарий 3 уже запущен."
      exit 0
    fi
    if ! grep -q '/etc/nginx/tls:ro' "$COMPOSE"; then
      echo "В $COMPOSE не найден том ./deploy/tls:/etc/nginx/tls:ro. Сценарий 3 не применить." >&2
      exit 1
    fi
    # Сертификаты монтируются в другой каталог контейнера: по пути из конфига их нет.
    sed -i.break-4.6 's|/etc/nginx/tls:ro|/etc/nginx/ssl:ro|' "$COMPOSE"
    rm -f "$COMPOSE.break-4.6"
    recreate_proxy
    echo "Сценарий 3 готов. Проверь: docker compose ps -a и docker compose logs --tail=5 proxy"
    ;;
  fix)
    need_project
    changed=0
    if ! conf_is_good; then
      if [[ -f $SAVED ]]; then
        cat "$SAVED" > "$CONF"
      else
        write_good_conf
      fi
      changed=1
    fi
    rm -f "$SAVED"
    if grep -q '/etc/nginx/ssl:ro' "$COMPOSE"; then
      sed -i.break-4.6 's|/etc/nginx/ssl:ro|/etc/nginx/tls:ro|' "$COMPOSE"
      rm -f "$COMPOSE.break-4.6"
      changed=1
    fi
    remove_holders
    if [[ ! -f deploy/tls/notes.crt ]]; then
      echo "Нет deploy/tls/notes.crt: запусти ./scripts/gen-tls.sh" >&2
    fi
    # Пересоздаём proxy, если правили файлы или он не работает; иначе повторный fix ничего не трогает.
    if [[ $changed -eq 1 ]] || ! wait_site; then
      docker compose up -d >/dev/null 2>&1 || true
      recreate_proxy
    fi
    wait_notes || true
    if wait_site; then
      echo "Всё возвращено: конфиг nginx и тома proxy как в уроке, https://notes.lab/healthz отвечает 200."
    else
      echo "Файлы возвращены, но сайт не отвечает: смотри docker compose logs --tail=20 proxy" >&2
      exit 1
    fi
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix (из каталога ~/notes)" >&2
    exit 2
    ;;
esac
