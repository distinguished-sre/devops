#!/usr/bin/env bash
# Поломки для урока 1.2 «Текст, потоки и конвейеры». Запуск: bash break.sh 1|2|3|fix
# Работает только с файлами в ~/lab12/break, root не нужен (и не разрешён).
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт работает с твоими файлами в ~/lab12/break." >&2
  exit 1
fi

LAB="$HOME/lab12"
DIR="$LAB/break"

# Урок 1.2 выполнен, если есть каталог ~/lab12 с access.log из задания 1
if [[ ! -f $LAB/access.log ]]; then
  echo "Не найден $LAB/access.log. Сначала выполни задание 1 урока 1.2." >&2
  exit 1
fi

mkdir -p "$DIR"

# Журнал «вчерашнего» дня: 300 строк в формате «Заметок», каждая десятая с ошибкой 500
make_app_log() {
  awk 'BEGIN {
    for (i = 1; i <= 300; i++) {
      st = (i % 10 == 0) ? 500 : 200
      printf "2026-09-29 09:%02d:%02d,%03d INFO method=GET path=/notes status=%d dur_ms=%d\n", \
        int(i / 60), i % 60, (i * 7) % 1000, st, (i * 3) % 40
    }
  }' > "$DIR/app.log"
}

# Скрипт «запуска сервиса»: с '>' затирает журнал, с '>>' дописывает
make_start_script() {
  local redirect=$1
  cat > "$DIR/start-log.sh" <<EOF
#!/usr/bin/env bash
# Имитация запуска сервиса: пишет в журнал строку о старте
cd "\$(dirname "\$0")"
echo "\$(date '+%F %T,000') INFO started host=127.0.0.1 port=8080 version=dev" $redirect app.log
EOF
}

# 60 запросов от пяти клиентов (адреса .5, .7, .9, .3, .11), IP идут вперемешку (не подряд)
make_clients_log() {
  awk 'BEGIN {
    split("10.0.0.5 10.0.0.7 10.0.0.9 10.0.0.3 10.0.0.11", ip, " ")
    for (i = 1; i <= 60; i++)
      printf "%s - - [29/Sep/2026:10:%02d:%02d +0300] \"GET /notes HTTP/1.1\" 200 1204 0.012\n", \
        ip[(i * i + i * 7) % 13 % 5 + 1], int(i / 60), i % 60
  }' > "$DIR/clients.log"
}

# Скрипт «топ клиентов»: параметр pre это '| sort ' (верно) или пустая строка (поломка)
make_top_script() {
  local pre=$1
  cat > "$DIR/top-ip.sh" <<EOF
#!/usr/bin/env bash
# Топ клиентов по числу запросов
cd "\$(dirname "\$0")"
cut -d' ' -f1 clients.log $pre| uniq -c | sort -rn | head -5
EOF
}

# service.log: строки ERROR с концами строк Windows (\r\n), как после правки в чужом редакторе
make_service_log() {
  local eol=$1
  {
    printf '2026-09-29 10:15:01,004 INFO started host=127.0.0.1 port=8080 version=dev%s\n' "$eol"
    printf '2026-09-29 10:15:03,120 ERROR db timeout%s\n' "$eol"
    printf '2026-09-29 10:15:04,220 INFO method=GET path=/notes status=200 dur_ms=3%s\n' "$eol"
    printf '2026-09-29 10:15:09,510 ERROR db timeout%s\n' "$eol"
    printf '2026-09-29 10:15:10,001 INFO method=GET path=/ status=200 dur_ms=1%s\n' "$eol"
  } > "$DIR/service.log"
}

case "${1:-}" in
  1)
    make_app_log
    make_start_script '>'
    bash "$DIR/start-log.sh"
    echo "Сценарий 1 готов. Проверь: cd ~/lab12/break; ls -l app.log; wc -l app.log"
    ;;
  2)
    make_clients_log
    make_top_script ''
    echo "Сценарий 2 готов. Запусти: bash ~/lab12/break/top-ip.sh и сверь с wc -l ~/lab12/break/clients.log"
    ;;
  3)
    make_service_log $'\r'
    echo "Сценарий 3 готов. Найди ошибки: cd ~/lab12/break; grep error service.log"
    ;;
  fix)
    make_app_log
    make_start_script '>>'
    bash "$DIR/start-log.sh"
    make_clients_log
    make_top_script '| sort '
    make_service_log ''
    echo "Всё возвращено: app.log на 301 строку, start-log.sh с >>, top-ip.sh с sort, service.log без символа возврата каретки."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
