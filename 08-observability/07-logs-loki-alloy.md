---
layout: lesson
title: "Логи: JSON, Loki и Grafana Alloy"
topic: 8
lesson: "8.7"
time: "2 ч"
---

## Зачем это нужно

Метрики говорят, что ошибок стало больше. Логи (logs) говорят, какой запрос упал и почему. Пока логи лежат в `docker logs` на одном хосте, их нельзя искать по всем сервисам сразу, они пропадают вместе с контейнером, а текст вида `GET /notes 200 3ms` не отфильтровать по числу.

На работе это каждый инцидент: алерт сработал, ты открываешь Grafana и должен за минуту дойти от графика до конкретной строки. Для этого логи пишут структурно (JSON), собирают агентом в одно место (Loki) и ищут по небольшому набору лейблов.

Шаг проекта: «Заметки» пишут JSON-логи в stdout (app.py v6, образ 0.6.0), Alloy собирает их в Loki, в Grafana появляется панель логов рядом с графиком ошибок.

## Что нужно знать

- [Урок 1.2: текст, pipe, grep](../01-linux/02-text-pipes.md) - фильтры и `jq` работают так же, как в конвейере
- [Урок 4.3: тома и сети](../04-docker/03-storage-networks.md) - сеть `notes-net` и именованные тома
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - `compose.yml` проекта «Заметки»
- [Урок 4.9: диагностика контейнеров](../04-docker/09-docker-troubleshooting.md) - `docker logs`, `inspect`
- [Урок 8.2: основы Prometheus](02-prometheus-basics.md) - лейблы и кардинальность метрик, здесь то же самое
- [Урок 8.5: алерты и Alertmanager](05-alertmanager.md) - от алерта ты идёшь в логи
- [Урок 8.6: Grafana, дашборды как код](06-grafana-dashboards.md) - provisioning, из него подключим Loki

## Теория

### Структурный лог: одна запись, один JSON

Строка `2026-09-29 10:00:00,123 INFO method=GET path=/notes status=200 dur_ms=3` читается глазами, но чтобы найти запросы дольше секунды, нужны регулярные выражения. Структурный лог (structured log) пишет каждую запись как JSON с фиксированными ключами:

```json
{"ts":"2026-09-29T10:00:00.123+00:00","level":"info","msg":"request","method":"GET","path":"/notes","status":200,"dur_ms":3,"version":"0.6.0"}
```

Правила, которые работают в любой команде:

- одна запись, одна строка, одна JSON-структура; многострочные traceback кладут в поле, а не печатают отдельно;
- ключи не меняются между версиями (`status` всегда число, не строка);
- уровни (levels): `debug`, `info`, `warning`, `error`; на проде включён `info`;
- в stdout, не в файл: контейнерный рантайм сам забирает stdout и ротирует его, а агент читает оттуда ([12-factor](https://12factor.net/logs) называет это «логи как поток событий»);
- никаких паролей, токенов и персональных данных: то, что попало в лог, потом лежит в хранилище неделями.

> **Проверь понимание:** почему `status` должен быть числом, а не строкой `"200"`?

<details>
<summary>Ответ</summary>

Сравнение `status >= 500` в запросе работает только с числом. Со строкой придётся писать регулярку, и первый же `"5xx"` вместо `500` сломает фильтр.

</details>

### Loki: индексируем только лейблы

Grafana Loki хранит логи иначе, чем Elasticsearch. Elasticsearch индексирует каждое слово, поэтому поиск быстрый, а хранение дорогое. Loki индексирует только набор лейблов (labels) у потока (stream), а текст хранит сжатыми кусками (chunks). Запрос сначала выбирает потоки по лейблам, потом просматривает текст внутри них.

Поток (stream) это уникальная комбинация лейблов. `{service="notes", level="info"}` и `{service="notes", level="error"}` это два потока. Отсюда главное правило: лейбл должен иметь мало значений (низкая кардинальность, low cardinality). Пример из метрик (урок 8.2) тот же: `user_id` в лейбле взрывает Prometheus, а здесь он взрывает Loki.

| Что | Лейбл? | Почему |
|---|---|---|
| `service`, `level`, `env` | да | единицы значений |
| `path` из URL (`/notes/12345`) | нет | тысячи значений, тысячи потоков |
| `trace_id`, `user_id`, `remote` | нет | уникальны для каждого запроса |
| `status` | лучше нет | искать через `\| json \| status >= 500` |

Много потоков означает много маленьких chunks, большой индекс, медленные запросы и отказы приёма. То, что не лейбл, остаётся полем JSON и достаётся в запросе через `| json`.

> **Проверь понимание:** сервис пишет 1000 запросов в минуту на 500 разных путей. Сколько потоков получится, если сделать `path` лейблом, а `level` оставить?

<details>
<summary>Ответ</summary>

До 500 путей умножить на число уровней, то есть 1000-1500 потоков вместо 3. Каждый маленький и живёт недолго. Правильно: два лейбла `service` и `level`, путь ищется фильтром по тексту.

</details>

### Alloy: агент между контейнером и Loki

Grafana Alloy (агент сбора телеметрии, ранее Grafana Agent) читает логи, обрабатывает их и отправляет в Loki. Promtail снят с поддержки 2 марта 2026 года, новые стеки строят на Alloy. Конфиг (`config.alloy`) описывает конвейер из компонентов, выход одного подключён ко входу другого:

```text
discovery.docker  ->  discovery.relabel  ->  loki.source.docker  ->  loki.process  ->  loki.write
(найти контейнеры)    (задать лейбл)         (читать логи)           (json, level)     (отправить в Loki)
```

Компонент задаётся так: `тип "имя" { ... }`, ссылка на выход: `тип.имя.поле`. Alloy ходит в Docker через сокет `/var/run/docker.sock` (только чтение) и сам замечает новые контейнеры. Старый `promtail.yml` конвертируется командой `alloy convert --source-format=promtail`.

В Kubernetes та же идея: Alloy запускают как DaemonSet ([урок 5.8](../05-kubernetes/08-jobs-cronjob-daemonset.md)), он читает файлы логов подов на узле, а не Docker socket.

> **Проверь понимание:** контейнер удалили. Где искать его логи, если агента не было?

<details>
<summary>Ответ</summary>

Нигде: `docker logs` работает только пока контейнер существует. Поэтому агент собирает логи заранее, а не после инцидента.

</details>

### LogQL: выбрать потоки, отфильтровать, посчитать

LogQL (язык запросов Loki) очень похож на PromQL. Запрос состоит из селектора потоков и конвейера фильтров:

```text
{service="notes"}                                   # все логи сервиса
{service="notes"} |= "error"                        # строки с подстрокой
{service="notes"} | json | status >= 500            # разобрать JSON, отфильтровать по числу
{service="notes"} | json | dur_ms > 500          # медленные запросы
```

Селектор `{...}` обязателен и должен содержать хотя бы одно точное условие: `{service=~".*"}` Loki отклонит. Метрики из логов строятся функциями `rate()` и `count_over_time()`:

```text
sum by (level) (count_over_time({service="notes"}[1m]))
```

Логи и метрики дополняют друг друга: метрика из приложения (урок 8.2) дешевле и точнее для алертов, а логи нужны, чтобы посмотреть конкретные записи. Метрику «из логов» считают, когда приложение нельзя изменить.

> **Проверь понимание:** зачем `| json` перед `status >= 500`?

<details>
<summary>Ответ</summary>

Без `| json` строка остаётся просто текстом и полей `status` нет. `| json` разбирает JSON и превращает ключи в поля, по которым можно сравнивать.

</details>

## Практика

Стек «Заметок» из урока 4.5 запущен (`docker compose up -d` в `~/notes`), сеть `notes-net` существует, мониторинг из 8.6 работает (`monitoring/compose.yml`). Нужны `curl` и `jq`.

### Если у тебя 8 ГБ

Loki и Alloy вместе занимают около 500 МБ. Чтобы уложиться, останови то, что не нужно в этом уроке, и ограничь новые сервисы:

```bash
cd ~/notes/monitoring
docker compose stop cadvisor blackbox alertmanager
```

К сервисам `loki` и `alloy` в `compose.yml` добавь строки `mem_limit: 512m` и `mem_limit: 256m` соответственно. Хранение в `loki.yml` уже ограничено семью днями.

### Задание 1. JSON-логи в app.py v6

**Цель:** заменить текстовый лог на JSON и убедиться, что каждая запись это валидный JSON с ключами по контракту.

**Предскажи:** сколько строк появится в `docker logs` после одного `curl /notes`, если служебные пути `/healthz`, `/readyz`, `/metrics` в лог не пишутся? Какого типа будет `status`?

<details>
<summary>Ответ</summary>

Одна строка `"msg":"request"`. `status` число (200 без кавычек), `dur_ms` тоже число.

</details>

**Шаги:**

1. В `app.py` замени настройку `logging` на форматтер, который печатает JSON в stdout:

```python
import json
import logging
import sys
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    """Одна запись лога это одна строка JSON. Ключи не меняем между версиями."""

    def format(self, record):
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "msg": record.getMessage(),
        }
        # дополнительные поля приходят через extra={"fields": {...}}
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry, ensure_ascii=False)


handler = logging.StreamHandler(sys.stdout)  # в stdout, не в stderr
handler.setFormatter(JsonFormatter())
log = logging.getLogger("notes")
log.addHandler(handler)
log.setLevel(os.environ.get("LOG_LEVEL", "info").upper())
log.propagate = False
```

2. В обработчике запроса после отправки ответа пиши запись (служебные пути пропусти):

```python
def log_request(self, status, started):
    if self.path in ("/healthz", "/readyz", "/metrics"):
        return  # служебные пути не шумят в логе
    log.info("request", extra={"fields": {
        "method": self.command,
        "path": self.path,
        "status": status,
        "dur_ms": round((time.monotonic() - started) * 1000),
        "version": APP_VERSION,
    }})
```

3. При старте пиши `log.info("started", extra={"fields": {"host": HOST, "port": PORT, "store": STORE, "version": APP_VERSION}})`.
4. Установи `APP_VERSION=0.6.0`, собери образ и перезапусти:

```bash
cd ~/notes
docker build -t notes:0.6.0 .
# в compose.yml у сервиса notes: image: notes:0.6.0
docker compose up -d notes
curl -sk https://notes.lab/notes > /dev/null
docker logs notes 2>&1 | tail -n 2 | jq -c .
```

**Что должно получиться:**

```text
{"ts":"2026-09-29T10:00:00.050+00:00","level":"info","msg":"started","host":"0.0.0.0","port":8080,"store":"postgres","version":"0.6.0"}
{"ts":"2026-09-29T10:00:07.311+00:00","level":"info","msg":"request","method":"GET","path":"/notes","status":200,"dur_ms":4,"version":"0.6.0"}
```

**Объясни себе:**

- почему форматтер пишет в stdout, а не в файл внутри контейнера?
- что произойдёт с `jq`, если в лог попадёт обычный `print("debug")`?

**Типичные ошибки:**

- `jq: error (at <stdin>:1): Invalid numeric literal at line 1, column 8`: в stdout попала не-JSON строка (забытый `print`). Убери `print` или замени на `log.debug(...)`.
- `"status":"200"` в кавычках: передан `str(status)`. Передавай число, иначе `status >= 500` не сработает.
- Лог пустой: `LOG_LEVEL=warning` в окружении скрывает `info`. Проверь `docker exec notes env | grep LOG_LEVEL`.

### Задание 2. Loki и Alloy в Compose

**Цель:** запустить Loki 3.7.8 и Grafana Alloy v1.20.1 рядом с остальным мониторингом и увидеть в Loki лейблы `service` и `level`.

**Предскажи:** сколько лейблов будет у логов сервиса `notes`, если мы назначаем `service` и `level`? Что произойдёт со строкой лога nginx (он пишет не JSON)?

<details>
<summary>Ответ</summary>

Два своих лейбла (плюс служебный `service_name`, его Loki добавляет сам). Строка nginx получит только `service`: разбор JSON и лейбл `level` мы включаем лишь для сервиса `notes`.

</details>

**Шаги:**

1. Создай `monitoring/loki/loki.yml`:

```yaml
# Loki в одном процессе, хранение на диске, без аутентификации (учебный стенд)
auth_enabled: false
server:
  http_listen_port: 3100
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  replication_factor: 1
  ring: { kvstore: { store: inmemory } }
  storage:
    filesystem: { chunks_directory: /loki/chunks, rules_directory: /loki/rules }
schema_config:
  configs:
    - from: "2026-01-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  retention_period: 168h          # хранить 7 дней
  reject_old_samples: true
  reject_old_samples_max_age: 168h
compactor:
  working_directory: /loki/compactor
  retention_enabled: true         # без этого retention_period ничего не удаляет
  delete_request_store: filesystem
```

2. Создай `monitoring/alloy/config.alloy`:

```alloy
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}
// 2. Назначить лейбл service из имени сервиса Compose; других лейблов не добавляем
discovery.relabel "containers" {
  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_service"]
    target_label  = "service"
  }
  // контейнеры не из Compose пропускаем
  rule {
    source_labels = ["service"]
    regex         = ".+"
    action        = "keep"
  }
}
loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.containers.output
  forward_to = [loki.process.notes.receiver]
}
// 4. Для сервиса notes разобрать JSON и вынести level в лейбл
loki.process "notes" {
  forward_to = [loki.write.local.receiver]
  stage.match {
    selector = "{service=\"notes\"}"
    stage.json {
      expressions = { level = "level" }
    }
    stage.labels {
      values = { level = "" }
    }
  }
}
loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

3. Добавь в `monitoring/compose.yml` два сервиса и том (сеть `notes-net` уже подключена как внешняя):

```yaml
  loki:
    image: grafana/loki:3.7.8
    command: ["-config.file=/etc/loki/loki.yml"]
    volumes:
      - ./loki/loki.yml:/etc/loki/loki.yml:ro
      - loki-data:/loki
    ports:
      - "127.0.0.1:3100:3100"
    restart: unless-stopped
  alloy:
    image: grafana/alloy:v1.20.1
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "127.0.0.1:12345:12345"
    depends_on:
      - loki
    restart: unless-stopped
volumes:
  loki-data:
```

Если блок `volumes:` в файле уже есть, добавь `loki-data:` в него, а не создавай второй.

4. Подключи Loki в Grafana: `monitoring/grafana/provisioning/datasources/loki.yml`:

```yaml
apiVersion: 1
datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
```

5. Запусти и проверь:

```bash
cd ~/notes/monitoring
docker compose up -d loki alloy
docker compose restart grafana
sleep 20
curl -s http://localhost:3100/ready
for i in 1 2 3; do curl -sk https://notes.lab/notes > /dev/null; done
curl -sk -o /dev/null https://notes.lab/error
sleep 5
curl -s http://localhost:3100/loki/api/v1/labels | jq -c .
```

Открой в браузере `http://localhost:12345`: это интерфейс Alloy, на вкладке Graph видны компоненты и стрелки между ними, зелёные значит здоровы.

**Что должно получиться:**

```text
ready
{"status":"success","data":["level","service","service_name"]}
```

**Объясни себе:**

- зачем `depends_on: loki` не гарантирует, что Loki готов, и почему Alloy всё равно не потеряет логи?
- зачем сокет смонтирован `:ro`, ведь Alloy только читает?

**Типичные ошибки:**

- `network notes-net declared as external, but could not be found`: основной стек не запущен. Подними `docker compose up -d` в `~/notes`.
- `Bind for 127.0.0.1:3100 failed: port is already allocated`: порт занят другим Loki или контейнером. Найди через `docker ps` и останови.
- `failed parsing config: /etc/loki/loki.yml: yaml: unmarshal errors`: опечатка в ключе или отступе `loki.yml`. Проверь по тексту выше, строка указана в ошибке.
- `/ready` отвечает `Ingester not ready: waiting for 15s after being ready`: Loki ещё стартует, подожди 15-30 секунд.

### Задание 3. LogQL в Grafana Explore

**Цель:** найти пятисотые, посчитать записи по уровням и долю ошибок.

**Предскажи:** запрос `{service="notes"} | json | status >= 500` после трёх `GET /notes` и одного `GET /error`: сколько строк вернёт?

<details>
<summary>Ответ</summary>

Одну: запись `/error` со `status: 500`. Три запроса `/notes` отсеет фильтр по числу.

</details>

**Шаги:**

1. Grafana (`http://localhost:3000`) -> Explore -> источник Loki, режим Code.
2. Выполни по очереди (`{service="notes"}` без фильтров покажет все записи):

```text
{service="notes"} | json | status >= 500
sum by (level) (count_over_time({service="notes"}[5m]))
sum(rate({service="notes"} | json | status >= 500 [1m])) / sum(rate({service="notes"} | json | status > 0 [1m]))
```

Первый запрос вернёт одну запись: `/error` со `status: 500`.

**Что должно получиться:** поток один, у него лейблы `service="notes"` и `level="info"` (ошибки в логе идут уровнем `info`, `error` появляется только у исключений). Панель по уровням покажет одну линию.

**Объясни себе:**

- почему после `| json` в Explore появляется поле `level_extracted`, а не `level`?
- чем `count_over_time` отличается от `rate`?
- почему доля ошибок здесь считается по логам, а алерт из урока 8.5 лучше держать на метрике приложения?

**Типичные ошибки:**

- `queries require at least one regexp or equality matcher that does not have an empty-compatible value`: селектор `{service=~".*"}` или пустой. Укажи точное условие `{service="notes"}`.
- `parse error at line 1, col 20: syntax error: unexpected |`: фильтр стоит внутри `{}`. Вынеси конвейер за скобки.
- `No data`: данных нет за выбранный период или логи ещё не дошли. Расширь диапазон до 15 минут и повтори `curl`.

### Задание 4. Шаг проекта: дашборд, образ 0.6.0, тег v0.6.0

**Цель:** привести «Заметки» к состоянию после урока 8.7: логи в JSON, Loki и Alloy в Compose, дашборд `notes-logs.json` в git.

**Предскажи:** поднимется ли дашборд в Grafana после `git pull` на чистой машине без ручных кликов?

<details>
<summary>Ответ</summary>

Да, если файл лежит в каталоге, который читает provisioning (урок 8.6), и `uid` источника `loki` совпадает с `uid` в `datasources/loki.yml`. Ручных кликов нет: дашборд это код.

</details>

**Шаги:**

1. Создай `monitoring/grafana/dashboards/notes-logs.json`:

```json
{
  "uid": "notes-logs", "title": "Notes: логи", "schemaVersion": 41, "version": 1,
  "refresh": "10s", "time": { "from": "now-30m", "to": "now" },
  "panels": [
    { "id": 1, "type": "timeseries", "title": "Записи по уровням",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "refId": "A", "legendFormat": "__auto",
        "expr": "sum by (level) (count_over_time({service=\"notes\"}[1m]))" } ] },
    { "id": 2, "type": "timeseries", "title": "Доля 5xx по логам",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "loki", "uid": "loki" },
      "fieldConfig": { "defaults": { "unit": "percentunit" }, "overrides": [] },
      "targets": [ { "refId": "A", "legendFormat": "5xx",
        "expr": "sum(rate({service=\"notes\"} | json | status >= 500 [1m])) / sum(rate({service=\"notes\"} | json | status > 0 [1m]))" } ] },
    { "id": 3, "type": "logs", "title": "Ошибки (status >= 500)",
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 8 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "refId": "A", "expr": "{service=\"notes\"} | json | status >= 500" } ] }
  ]
}
```

2. Перезапусти Grafana и открой дашборд: пока ошибок нет, третья панель пуста, а график доли показывает `No data`. Вызови `/error` несколько раз и обнови страницу.

3. Проверь, что тесты проходят, зафиксируй и поставь тег:

```bash
cd ~/notes
docker compose -f monitoring/compose.yml restart grafana
python3 -m unittest
git add app.py monitoring/
git commit -m "8.7: JSON-логи, Loki и Alloy, дашборд notes-logs"
git tag v0.6.0
git tag --list 'v0.6*'
```

**Что должно получиться:**

```text
Ran 12 tests in 0.410s

OK
v0.6.0
```

Число тестов у тебя может отличаться, важно `OK`. Состояние проекта после урока: app.py v6, образ `notes:0.6.0`, Loki на 3100, Alloy на 12345 (UI), том `loki-data`, тег `v0.6.0`.

**Объясни себе:**

- что сломается в дашборде, если переименовать `uid` источника?

**Типичные ошибки:**

- `pull access denied for notes, repository does not exist or may require authentication`: образ `notes:0.6.0` не собран. Выполни `docker build -t notes:0.6.0 .`.
- `Datasource loki was not found` в панели: `uid` в дашборде не совпадает с `uid` в `loki.yml`. Приведи к одному.
- Дашборд не появился: файл лежит вне каталога provisioning. Проверь путь монтирования из урока 8.6.

## Сломай и почини

Запусти случайный сценарий, но не читай сам скрипт:

```bash
cd ~/notes
bash break/8.7/break.sh random
```

Сценарий поломает сбор или хранение логов. Цель: найти причину по симптомам, не читая скрипт.

### Симптом

Один из четырёх: запросы в Grafana падают с ошибкой очереди; Alloy повторяет ошибку приёма и логи не доходят; Loki тормозит и растёт по памяти; в Loki нет свежих логов, хотя `docker logs notes` их показывает.

### Гипотезы

Составь список до правок: сломан приём или чтение? Чей лог читать первым, Alloy или Loki? Изменился ли набор лейблов? Выросла нагрузка на запросы или на приём?

### Проверки

```bash
cd ~/notes/monitoring
docker compose logs --tail 30 alloy
docker compose logs --tail 30 loki
curl -s http://localhost:3100/loki/api/v1/labels | jq -c .
curl -sG http://localhost:3100/loki/api/v1/series --data-urlencode 'match[]={service="notes"}' | jq '.data | length'
```

Число потоков в `series` должно быть единицами. Нездоровые компоненты Alloy видны в его интерфейсе на `:12345`.

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**1. `too many outstanding requests`.** Очередь запросов Loki переполнена: дашборд с многими панелями за большой период. Починка: уменьши диапазон и число панелей, в `loki.yml` подними `query_scheduler.max_outstanding_requests_per_tenant` и ограничь `limits_config.max_query_parallelism`.

**2. `entry out of order` / `entry too far behind`.** Loki отклоняет запись со слишком старым временем относительно принятых в потоке. Причина: два источника в один поток, разные часы, агент отправляет накопленный хвост. Починка: один источник на поток, синхронизация времени, для догоняющих логов подними `reject_old_samples_max_age`. Отклонённые записи не вернуть.

**3. Лейбл `path` из URL.** В `stage.labels` добавлен `path`: каждый путь стал потоком, `series` показывает сотни потоков, растёт память, возможна ошибка `maximum active stream limit exceeded`. Починка: оставь лейблы `service` и `level`, перезапусти Alloy.

**4. Нет прав на docker.sock.** В логе Alloy `dial unix /var/run/docker.sock: connect: permission denied`, `discovery.docker` нездоров в UI. Починка: проверь монтирование, добавь пользователя в группу через `group_add` с gid из `stat -c %g /var/run/docker.sock`. Не давай `privileged: true`.

После разбора верни рабочее состояние:

```bash
bash break/8.7/fix.sh
```

</details>

## Вопросы с собеседований

### 1. [junior] Чем Loki отличается от Elasticsearch и почему он дешевле?

Loki индексирует только лейблы потока, а текст хранит сжатыми кусками. Elasticsearch индексирует каждое слово. Поэтому Loki хранит логи в разы дешевле, но полнотекстовый поиск по всему объёму медленнее: сначала сужаешь лейблами, потом ищешь текст внутри.

**Что хотят услышать:** индекс только по лейблам, chunks, компромисс «дёшево, но поиск через фильтр», Elasticsearch когда нужен сложный поиск (SIEM, аудит).

**Красный флаг:** «Loki это просто Elasticsearch проще».

### 2. [junior] Нужно найти все запросы с ответом 5xx и длительностью больше секунды за последний час, а логи текстовые. Как быть?

Регулярными выражениями это делается плохо и ломается при смене формата. Правильно перевести приложение на JSON-логи с числовыми `status` и `dur_ms`, тогда запрос будет `| json | status >= 500 | dur_ms > 1000`. Пока переход не сделан, можно временно разобрать текст стадией `logfmt` или `regexp` в Alloy.

**Что хотят услышать:** структурные логи, типы полей (число, не строка), парсинг в запросе, не на глаз.

**Красный флаг:** «`grep` и `awk` по серверам».

### 3. [junior] Под с приложением удалили, а инцидент был ночью. Логов нет. Что не так и как исправить?

Логи контейнера живут, пока жив контейнер. Нужен агент, который сразу отправляет их в хранилище (Alloy или другой агент, в Kubernetes DaemonSet). Тогда логи остаются после удаления пода. Приложение пишет в stdout, не в файл внутри контейнера.

**Что хотят услышать:** stdout, агент на каждом узле, центральное хранилище, срок хранения.

**Красный флаг:** «сделаем том и будем писать туда файлы».

### 4. [junior] На узле закончилось место, `du` показывает, что больше всего занимает каталог Docker. Что смотришь и что делаешь?

Смотрю `docker system df` и размер логов контейнеров в `/var/lib/docker/containers/*/*-json.log`. Драйвер `json-file` без ротации растёт бесконечно. Настраиваю `max-size` и `max-file` в `daemon.json` или в `logging:` сервиса и отправляю логи в центральное хранилище, чтобы локальные можно было держать короткими.

**Что хотят услышать:** `json-file`, ротация, `max-size`, `max-file`, чистка образов и томов отдельно.

**Красный флаг:** «удалю `.log` вручную и всё».

### 5. [middle] Разработчик добавил `user_id` в лейблы Loki. Через день запросы тормозят, а память Loki растёт. Что случилось?

Каждый пользователь стал отдельным потоком: сотни тысяч маленьких потоков, огромный индекс, много мелких chunks. Loki тратит память на активные потоки, запросы перебирают их все. Убираю `user_id` из лейблов, оставляю в теле JSON и ищу `| json | user_id="..."`. В лейблах только `service`, `level`, `env`.

**Что хотят услышать:** кардинальность, число потоков, `series` для диагностики, лимит потоков, поле вместо лейбла.

**Красный флаг:** «увеличим память Loki».

### 6. [middle] Сработал алерт по росту 5xx. Как идёшь от алерта до причины по логам?

Открываю дашборд: график ошибок и рядом панель логов за тот же период. Фильтрую `| json | status >= 500`, группирую по `path` и по версии, смотрю, что общего: один путь, одна версия, один узел. Ищу первую ошибку по времени и сверяю с деплоем. Если есть `trace_id`, иду по нему в трейс (урок 8.8).

**Что хотят услышать:** метрика показывает масштаб, лог причину, группировка, сверка со временем релиза, корреляция.

**Красный флаг:** «зайду на сервер и посмотрю `tail`».

### 7. [middle] Alloy пишет `entry too far behind`, и часть логов не доходит. Какие причины?

Loki принимает записи, только если их время не сильно старше последних в потоке. Причины: два источника в один поток, расхождение часов, агент отправляет накопленный хвост после простоя, слишком строгий `reject_old_samples_max_age`. Проверяю время на узлах, уникальность потока, что делают ретраи. Потерянные записи уже не вернуть.

**Что хотят услышать:** окно упорядоченности, часы, один источник на поток, логи Alloy и Loki.

**Красный флаг:** «выключу проверку и не буду разбираться».

### 8. [middle] Стоит ли считать долю ошибок по логам для алерта?

Для алертов надёжнее метрика приложения: она дешевле, считается на стороне сервиса и не зависит от доставки логов. По логам метрику считают, когда код менять нельзя, или для расследования. Если логи отстали, алерт по ним молчит именно в аварию.

**Что хотят услышать:** метрики для алертов, логи для деталей, риск зависимости от доставки, стоимость запроса.

**Красный флаг:** «нет разницы, всё можно посчитать из логов».

### 9. [middle] У тебя Promtail, а он снят с поддержки. Что делаешь?

Ставлю Grafana Alloy рядом, конвертирую конфиг `alloy convert --source-format=promtail`, читаю результат и правлю по смыслу, потом переключаю узлы по одному, сравнивая количество потоков и записей в Loki. Позиции чтения (positions) переносить аккуратно, чтобы не потерять хвост и не задублировать. Старый агент выключаю после проверки.

**Что хотят услышать:** конвертер как черновик, поэтапная замена, проверка дублей и потерь, откат.

**Красный флаг:** «просто заменю образ и перезапущу всё сразу».

### 10. [middle] Ты обнаружил токен доступа в логах приложения. Что делаешь?

Сначала считаю токен скомпрометированным: отзываю и перевыпускаю. Потом убираю причину: не логировать заголовки и тела целиком, маскировать поля в приложении, при необходимости стадией `replace` в Alloy. Удаляю уже попавшие записи через удаление по запросу или жду retention, ограничиваю доступ к логам. Пишу разбор, добавляю проверку в ревью.

**Что хотят услышать:** ротация секрета важнее чистки логов, маскирование у источника, доступ к логам, retention.

**Красный флаг:** «удалю строку и всё, токен можно оставить».

## Проверено на версиях

- Grafana Loki: 3.7.8
- Grafana Alloy: v1.20.1
- Grafana: 13.2.2
- Prometheus: v3.15.0
- Python: 3.13 (образ `python:3.13-slim`)
- Ubuntu: 26.04 LTS и 24.04
- Docker Engine и Compose: версия не закреплена, проверь актуальную версию на странице проекта
- jq: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею вывести логи приложения в JSON в stdout с фиксированными ключами и числовыми полями
- [ ] умею объяснить, почему Loki индексирует только лейблы, и назвать, что можно, а что нельзя делать лейблом
- [ ] умею поднять Loki и Grafana Alloy в Compose и подключить Loki в Grafana через provisioning
- [ ] умею читать конвейер Alloy (`discovery`, `relabel`, `source`, `process`, `write`) и смотреть его в интерфейсе на 12345
- [ ] умею писать LogQL: селектор, `| json`, фильтр по числу, `count_over_time`, `rate`
- [ ] умею от графика ошибок дойти до конкретной строки лога и назвать причину
- [ ] умею диагностировать взрыв потоков, `entry too far behind` и отсутствие прав на docker.sock

**Дальше:** [Урок 8.8: Трейсинг: OpenTelemetry и Tempo](08-tracing.md)
