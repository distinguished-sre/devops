#!/usr/bin/env bash
# Поломки для урока 8.2 «Prometheus: сбор метрик и /metrics в «Заметках»».
# Запуск (без sudo, от пользователя, работающего с Docker): bash break.sh 1|2|3|fix
# Каталог проекта: NOTES_DIR (по умолчанию ~/notes). Скрипт правит только
# monitoring/prometheus/prometheus.yml (строки с пометкой break-8.2) и создаёт
# один контейнер break82-shadow с меткой break=8.2; fix убирает только это.
set -euo pipefail

NOTES_DIR=${NOTES_DIR:-$HOME/notes}
CONF="$NOTES_DIR/monitoring/prometheus/prometheus.yml"
COMPOSE="$NOTES_DIR/monitoring/compose.yml"
LABEL=break=8.2
SHADOW=break82-shadow
# Образ «Заметок» из этого урока: в нём есть python3 для сценария 3.
NOTES_IMAGE=notes:0.5.0
# Пометки в конфиге: -a значит «вернуть исходный текст», -x значит «удалить строку».
MARK_A='# break-8.2-a'
MARK_X='# break-8.2-x'

need_ready() {
  if [[ $EUID -eq 0 ]]; then
    echo "Не запускай через sudo: скрипт работает с твоим Docker. Запусти: bash $0 ${1:-}" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь, что демон запущен и ты в группе docker (урок 4.1)." >&2
    exit 1
  fi
  if [[ ! -f $CONF || ! -f $COMPOSE ]]; then
    echo "Не найден стек мониторинга: $CONF. Выполни задание 2 урока 8.2 (каталог monitoring/) или задай NOTES_DIR." >&2
    exit 1
  fi
  if ! grep -q 'job_name: notes' "$CONF"; then
    echo "В $CONF нет задачи notes. Верни конфиг из задания 2 урока 8.2." >&2
    exit 1
  fi
}

# Уже применена какая-то поломка?
applied() {
  grep -q 'break-8.2' "$CONF" || docker container inspect "$SHADOW" >/dev/null 2>&1
}

# Перезапуск Prometheus и ожидание, пока он начнёт отвечать (до 20 секунд).
restart_prom() {
  docker compose -f "$COMPOSE" restart prometheus >/dev/null
  for _ in $(seq 1 20); do
    if curl -fs localhost:9090/-/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
}

already() {
  echo "Сценарий уже применён. Сначала верни всё командой: bash $0 fix"
  exit 0
}

case "${1:-}" in
  1)
    need_ready 1
    applied && already
    # Порт цели меняем на 8081: имя резолвится, но порт никто не слушает.
    sed -i "s|targets: \[\"notes:8080\"\]|targets: [\"notes:8081\"]  $MARK_A|" "$CONF"
    restart_prom
    echo "Сценарий 1 готов. Открой http://localhost:9090/targets или запроси API целей и найди причину."
    ;;
  2)
    need_ready 2
    applied && already
    # Лишний ключ сразу после имени задачи: путь метрик станет неверным.
    sed -i -E "s|^( *)- job_name: notes\$|&\n\1  metrics_path: /metric  $MARK_X|" "$CONF"
    restart_prom
    echo "Сценарий 2 готов. Цель notes красная, а приложение живо: найди причину."
    ;;
  3)
    need_ready 3
    applied && already
    if ! docker image inspect "$NOTES_IMAGE" >/dev/null 2>&1; then
      echo "Нет образа $NOTES_IMAGE. Собери его в задании 3 урока 8.2: docker build -t $NOTES_IMAGE ." >&2
      exit 1
    fi
    # Источник с 20000 рядами notes_http_requests_total: путь /notes/<номер> в метке path.
    code='
import http.server as h
BODY = ("# TYPE notes_http_requests_total counter\n" + "".join(
    "notes_http_requests_total{method=\"GET\",path=\"/notes/%d\",status=\"200\"} 1\n" % i
    for i in range(20000))).encode()
class H(h.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *a):
        pass
h.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
'
    docker run -d --name "$SHADOW" --label "$LABEL" --network notes-net \
      -e CODE="$code" --entrypoint sh "$NOTES_IMAGE" -c 'python3 -c "$CODE"' >/dev/null
    # отступ берём из самого файла: так работает и при сдвиге всего YAML
    ind=$(sed -nE 's|^( *)- job_name: notes$|\1|p' "$CONF" | head -n 1)
    {
      echo ""
      echo "$ind- job_name: notes-shadow  $MARK_X"
      echo "$ind  static_configs:  $MARK_X"
      echo "$ind    - targets: [\"$SHADOW:8000\"]  $MARK_X"
    } >>"$CONF"
    restart_prom
    echo "Сценарий 3 готов. Все цели up, но что-то с числом рядов: понаблюдай пару минут и найди источник."
    ;;
  fix)
    need_ready fix
    changed=0
    if grep -q 'break-8.2' "$CONF"; then
      # -a: вернуть порт; -x: удалить добавленные строки; пустая строка перед задачей тоже наша.
      sed -i "s|notes:8081\"\]  $MARK_A|notes:8080\"]|" "$CONF"
      sed -i "/$MARK_X/d" "$CONF"
      # убрать хвостовые пустые строки, которые остались от сценария 3
      sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CONF"
      changed=1
    fi
    if docker container inspect "$SHADOW" >/dev/null 2>&1; then
      docker container rm -f "$SHADOW" >/dev/null
    fi
    if [[ $changed -eq 1 ]]; then
      restart_prom
    fi
    echo "Готово: конфиг и контейнер сценариев возвращены. Проверь: все три цели up на http://localhost:9090/targets."
    echo "Ряды сценария 3 уйдут из Prometheus по retention; чтобы очистить сразу: docker compose -f monitoring/compose.yml down -v"
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
