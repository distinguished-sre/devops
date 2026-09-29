---
layout: lesson
title: "Grafana: дашборды как код"
topic: 8
lesson: "8.6"
time: "2 ч"
---

## Зачем это нужно

Prometheus хранит числа, а человек в 3 часа ночи хочет увидеть картинку и понять: что горит. Дашборд, собранный мышкой в браузере, живёт только в томе Grafana: пересоздали контейнер или том, и он пропал. Дашборд-свалка на 40 панелей не помогает: глаз не находит проблему.

На работе от тебя ждут дашборд сервиса по методу RED (Rate, Errors, Duration), дашборд узла по методу USE (Utilization, Saturation, Errors) и хранение обоих в git, чтобы стек поднимался с нуля одной командой.

Шаг проекта: в `monitoring/compose.yml` появляется Grafana 13.2.2 на порту 3000, а в `monitoring/grafana/` лежат provisioning (datasource Prometheus, провайдер дашбордов) и дашборды `notes-red.json` и `notes-use.json`.

## Что нужно знать

- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - сервисы, тома и сеть `notes-net` в Compose.
- [Урок 8.1: наблюдаемость и SLO](01-observability-slo.md) - SLI и SLO: что вообще стоит показывать.
- [Урок 8.2: Prometheus и /metrics](02-prometheus-basics.md) - стек `monitoring/compose.yml`, метрики `notes_http_*`.
- [Урок 8.3: PromQL](03-promql.md) - `rate`, `sum by`, `histogram_quantile`, recording rules.
- [Урок 8.5: Alertmanager](05-alertmanager.md) - алерты и runbook: дашборд открывают по ссылке из них.

## Теория

### Что такое Grafana и откуда она берёт данные

Grafana (визуализатор) сама ничего не хранит про метрики. Она ходит в источники данных (datasource): Prometheus, а в следующих уроках Loki и Tempo. Панель (panel) это один запрос к источнику плюс способ показа: линия (time series), одно число (stat), стрелка (gauge), таблица, тепловая карта (heatmap). Дашборд (dashboard) это набор панелей на одной странице, а внутри Grafana он хранится как один JSON-документ. Папки (folders) группируют дашборды и служат границей прав.

Запрос панели это тот же PromQL из урока 8.3. Поэтому хорошая практика: сложную логику держать в recording rules Prometheus (`notes:http_errors:ratio5m`), а панель делать простой. Тогда панель, алерт и разбор инцидента показывают одно и то же число.

Отдельно про алертинг: в Grafana есть свой alerting, но в курсе алерты живут в Prometheus и Alertmanager (урок 8.5). Причина простая: правила в git, тесты `promtool`, один способ доставки. Grafana для нас окно для глаз, а не источник алертов.

> **Проверь понимание:** почему панель лучше строить на recording rule, а не на длинном выражении?

<details>
<summary>Ответ</summary>

Число совпадает с алертом (одно определение «доли ошибок»), запрос считается один раз в Prometheus, а не при каждом обновлении дашборда каждым зрителем, и выражение правится в одном месте.

</details>

### RED и USE: что должно быть на первом экране

Метод RED для сервиса, которому приходят запросы: Rate (сколько запросов в секунду), Errors (какая доля ошибок), Duration (задержка, p50/p95/p99). Метод USE для ресурса (CPU, диск, сеть): Utilization (занятость), Saturation (очередь, нехватка), Errors (сбои). RED отвечает «плохо ли пользователю», USE отвечает «почему: не хватает ли ресурса».

Правило первого экрана: сверху то, что горит. В «Заметках» это доля ошибок и p95 против цели из `docs/slo.md`, ниже RPS и разбивка по `path`, ещё ниже детали. Одна панель отвечает на один вопрос, и у неё говорящий заголовок с единицами: «Ошибки 5xx, % запросов», а не «Panel 7». Антипаттерны: 30-40 панелей без порядка, графики без порогов, суммы там, где нужна разбивка, отсутствие ссылки на runbook.

> **Проверь понимание:** сервис отвечает медленно, а CPU узла 20%. Какой дашборд ты откроешь первым и почему?

<details>
<summary>Ответ</summary>

RED сервиса: он показывает, растёт ли p95 и на каких `path`. USE узла пока не объясняет проблему, а низкий CPU лишь говорит, что причина скорее в ожидании (БД, сеть), и это уже вопрос к трассировке и логам.

</details>

### Переменные и `$__rate_interval`

Переменная (variable) дашборда это выпадающий список вверху, значения которого подставляются в запросы: `$path`, `$instance`. Значения берутся запросом `label_values(notes_http_requests_total, path)`. Так один дашборд заменяет десять копий. Включай для переменной «All» (`includeAll`) и multi-value, тогда в запросе нужен селектор `path=~"$path"` с регулярным выражением, а не `=`.

Окно в `rate()` задаёт специальная переменная `$__rate_interval`. Grafana вычисляет её как максимум из четырёх интервалов скрапа и выбранного шага графика, поэтому окно всегда содержит не меньше двух точек (иначе см. ошибку из урока 8.3: rate на окне короче двух scrape даёт пустоту). Жёсткое `[5m]` на дашборде за 7 дней сгладит графики и спрячет пики, а `[15s]` при скрапе раз в 15 секунд даст дыры.

> **Проверь понимание:** зачем в запросе `$__rate_interval`, а не `[1m]`?

<details>
<summary>Ответ</summary>

Окно подстраивается под масштаб графика и `scrape_interval`, поэтому не бывает «No data» из-за окна короче двух скрапов и не сглаживает график при большом масштабе.

</details>

### Provisioning: дашборды и источники как код

Provisioning (подготовка конфигурации при старте) это файлы, которые Grafana читает сама: `provisioning/datasources/*.yml` создаёт источники, `provisioning/dashboards/*.yml` объявляет провайдер (папку с JSON-файлами дашбордов). Что создано файлом, то при перезапуске пересоздаётся из файла. Итог: `docker compose down -v && up -d` даёт тот же Grafana, без ручных кликов.

Рабочий цикл такой: рисуешь дашборд в UI (быстро), выгружаешь JSON (Share, Export, Export for sharing externally выключено), кладёшь в `monitoring/grafana/dashboards/`, коммитишь. Правки в UI у файлового дашборда не сохраняются в файл, Grafana это запрещает, если `allowUiUpdates: false`: редактируешь копию и снова экспортируешь. У datasource обязательно задай постоянный `uid`, на него ссылаются панели в JSON. Если uid сгенерирован случайно, дашборд после пересоздания получает «datasource not found».

> **Проверь понимание:** ты поправил панель в UI провижененного дашборда, через неделю поправка исчезла. Почему?

<details>
<summary>Ответ</summary>

Источник правды файл в git: при перезапуске или обновлении файла Grafana перечитала JSON и затёрла ручную правку. Правку нужно экспортировать в файл и закоммитить.

</details>

## Практика

Стек «Заметок» из основного `compose.yml` (урок 4.5) уже запущен, каталог `monitoring/` из уроков 8.2-8.5 на месте. Команды выполняются из `~/notes`.

### Задание 1. Grafana в Compose и datasource через provisioning

**Цель:** поднять Grafana 13.2.2 рядом с Prometheus и получить рабочий datasource без единого клика.

**Предскажи:** сколько datasource увидит Grafana после старта, если в `provisioning/datasources/` лежит один файл с одним источником? И что будет с ним после `docker compose restart grafana`?

<details>
<summary>Ответ</summary>

Один источник, помеченный как provisioned (в UI его нельзя удалить). После перезапуска он остаётся: файл читается при каждом старте.

</details>

**Шаги**

1. Создай каталоги и файл datasource:

```bash
mkdir -p monitoring/grafana/provisioning/datasources \
         monitoring/grafana/provisioning/dashboards \
         monitoring/grafana/dashboards
```

```yaml
# monitoring/grafana/provisioning/datasources/prometheus.yml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus          # постоянный uid: на него ссылаются панели в JSON
    type: prometheus
    access: proxy            # запросы идут через сервер Grafana, не из браузера
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: 15s      # равен scrape_interval, от него считается $__rate_interval
```

2. Добавь провайдер дашбордов:

```yaml
# monitoring/grafana/provisioning/dashboards/dashboards.yml
apiVersion: 1
providers:
  - name: notes
    folder: Notes            # папка в интерфейсе Grafana
    type: file
    allowUiUpdates: false    # правки только через git
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
```

3. Добавь сервис в `monitoring/compose.yml` (секция `services:`) и том (секция `volumes:`):

```yaml
  grafana:
    image: grafana/grafana:13.2.2
    ports:
      - "127.0.0.1:3000:3000"   # только с этой машины
    environment:
      GF_SECURITY_ADMIN_PASSWORD: CHANGE_ME   # замени: openssl rand -base64 24
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    depends_on:
      - prometheus
    restart: unless-stopped

# в конец файла, в существующую секцию volumes: добавь строку
#   grafana-data:
```

4. Запусти и проверь через API (пароль тот, что задал):

```bash
docker compose -f monitoring/compose.yml up -d grafana
curl -s -u admin:CHANGE_ME http://127.0.0.1:3000/api/datasources | jq '.[] | {name, uid, url}'
```

**Что должно получиться**

```text
{
  "name": "Prometheus",
  "uid": "prometheus",
  "url": "http://prometheus:9090"
}
```

**Объясни себе**

- Почему в `url` стоит `prometheus:9090`, а не `localhost:9090`?
- Зачем `access: proxy` и что было бы с `direct`?

**Типичные ошибки**

- `Origin not allowed` или пустой ответ из-за `direct`: браузер сам ходит по `url`, а внутри сети Compose имя `prometheus` браузеру неизвестно: ставь `access: proxy`.
- `{"message":"invalid username or password"}`: пароль в `curl` не совпадает с `GF_SECURITY_ADMIN_PASSWORD`. Учти: пароль применяется при первом создании тома `grafana-data`, позже его меняют командой `docker compose exec grafana grafana cli admin reset-admin-password <новый>`.
- `Error: ... permission denied` на `/var/lib/grafana`: том создан другим пользователем, пересоздай том `docker compose down` и `docker volume rm` для него (данные учебные).

### Задание 2. Дашборд Notes RED как JSON

**Цель:** получить дашборд по RED, лежащий в git и подхватываемый Grafana сам.

**Предскажи:** какие панели обязаны быть в верхнем ряду, если человек смотрит только на него? Сколько всего панелей ты оставишь?

<details>
<summary>Ответ</summary>

Сверху доля ошибок и p95 (и число запросов как контекст). Всего 5-6 панелей: каждая отвечает на свой вопрос, остальное уходит в Explore.

</details>

**Шаги**

1. Сохрани дашборд целиком. Запросы используют метрики контракта `notes_http_requests_total{method,path,status}` и `notes_http_request_duration_seconds` из урока 8.2.

{% raw %}
```json
{
  "uid": "notes-red",
  "title": "Notes RED",
  "tags": ["notes", "red"],
  "schemaVersion": 41,
  "version": 1,
  "time": {"from": "now-1h", "to": "now"},
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "path",
        "label": "path",
        "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "query": {"query": "label_values(notes_http_requests_total, path)", "refId": "path"},
        "includeAll": true,
        "multi": true,
        "current": {"text": "All", "value": "$__all"}
      }
    ]
  },
  "links": [
    {"title": "Runbook: NotesHighErrorRate", "type": "link", "url": "https://github.com/distinguished-sre/devops/blob/devops/project/notes/docs/runbooks/NotesHighErrorRate.md", "targetBlank": true}
  ],
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Ошибки 5xx, % запросов",
      "gridPos": {"x": 0, "y": 0, "w": 6, "h": 5},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "100 * sum(rate(notes_http_requests_total{status=~\"5..\", path=~\"$path\"}[$__rate_interval])) / sum(rate(notes_http_requests_total{path=~\"$path\"}[$__rate_interval]))"}],
      "fieldConfig": {"defaults": {"unit": "percent", "decimals": 2,
        "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 0.5}, {"color": "red", "value": 1}]}}, "overrides": []}
    },
    {
      "id": 2, "type": "stat", "title": "p95 задержки, сек",
      "gridPos": {"x": 6, "y": 0, "w": 6, "h": 5},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le) (rate(notes_http_request_duration_seconds_bucket{path=~\"$path\"}[$__rate_interval])))"}],
      "fieldConfig": {"defaults": {"unit": "s", "decimals": 3,
        "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 0.3}, {"color": "red", "value": 0.5}]}}, "overrides": []}
    },
    {
      "id": 3, "type": "timeseries", "title": "Запросы в секунду по path",
      "gridPos": {"x": 12, "y": 0, "w": 12, "h": 5},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "legendFormat": "{{path}}", "expr": "sum by (path) (rate(notes_http_requests_total{path=~\"$path\"}[$__rate_interval]))"}],
      "fieldConfig": {"defaults": {"unit": "reqps"}, "overrides": []}
    },
    {
      "id": 4, "type": "timeseries", "title": "Задержка p50 / p95 / p99, сек",
      "gridPos": {"x": 0, "y": 5, "w": 12, "h": 8},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [
        {"refId": "A", "legendFormat": "p50", "expr": "histogram_quantile(0.50, sum by (le) (rate(notes_http_request_duration_seconds_bucket{path=~\"$path\"}[$__rate_interval])))"},
        {"refId": "B", "legendFormat": "p95", "expr": "histogram_quantile(0.95, sum by (le) (rate(notes_http_request_duration_seconds_bucket{path=~\"$path\"}[$__rate_interval])))"},
        {"refId": "C", "legendFormat": "p99", "expr": "histogram_quantile(0.99, sum by (le) (rate(notes_http_request_duration_seconds_bucket{path=~\"$path\"}[$__rate_interval])))"}
      ],
      "fieldConfig": {"defaults": {"unit": "s"}, "overrides": []}
    },
    {
      "id": 5, "type": "heatmap", "title": "Распределение задержек (heatmap)",
      "gridPos": {"x": 12, "y": 5, "w": 12, "h": 8},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "format": "heatmap", "legendFormat": "{{le}}", "expr": "sum by (le) (increase(notes_http_request_duration_seconds_bucket{path=~\"$path\"}[$__rate_interval]))"}],
      "options": {"calculate": false, "yAxis": {"unit": "s"}},
      "fieldConfig": {"defaults": {}, "overrides": []}
    }
  ]
}
```
{% endraw %}

Файл сохрани как `monitoring/grafana/dashboards/notes-red.json`. Подписи в легенде (`legendFormat`) это шаблоны Grafana с двойными фигурными скобками.

2. Дай Grafana 30 секунд (`updateIntervalSeconds`) и создай трафик:

```bash
for i in $(seq 1 200); do curl -s -o /dev/null http://127.0.0.1:8080/notes; done
curl -s -u admin:CHANGE_ME 'http://127.0.0.1:3000/api/search?query=Notes' | jq '.[] | {title, uid, folderTitle}'
```

3. Открой http://127.0.0.1:3000/d/notes-red в браузере.

**Что должно получиться**

```text
{
  "title": "Notes RED",
  "uid": "notes-red",
  "folderTitle": "Notes"
}
```

**Объясни себе**

- Почему heatmap строится из `increase(..._bucket)` по `le`, а не из `histogram_quantile`?
- Что покажет панель ошибок, если за окно не было ни одного запроса, и как это отличить от «ошибок нет»?

**Типичные ошибки**

- `Templating [path] Error updating options: ... datasource prometheus was not found`: в JSON указан uid, которого нет в provisioning: поправь uid в файле datasource и перезапусти Grafana.
- `A dashboard with the same uid already exists` при импорте вручную: uid дашборда уже занят файловым: удали дубль в UI или смени uid.
- Панель показывает `No data`, хотя метрика есть: проверь, что в выбранном диапазоне были запросы, а переменная `path` не пустая (см. раздел «Сломай и почини»).

### Задание 3. Дашборд Node USE

**Цель:** собрать дашборд ресурсов узла по методу USE на метриках `node_exporter` из урока 8.2.

**Предскажи:** какая метрика покажет saturation процессора: загрузка `idle` или `node_load1`?

<details>
<summary>Ответ</summary>

Saturation это очередь: `node_load1` делённая на число ядер. Утилизация (занятость) это `1 - idle`. Load выше числа ядер значит, что процессы ждут CPU.

</details>

**Шаги**

1. Создай `monitoring/grafana/dashboards/notes-use.json`. Чтобы не писать длинный JSON, сгенерируй его из списка запросов маленьким скриптом (запусти один раз, файл закоммить):

{% raw %}
```bash
jq -n '
def p($id;$x;$y;$title;$unit;$expr): {
  id:$id, type:"timeseries", title:$title,
  gridPos:{x:$x,y:$y,w:12,h:7},
  datasource:{type:"prometheus",uid:"prometheus"},
  targets:[{refId:"A", expr:$expr, legendFormat:"{{instance}}"}],
  fieldConfig:{defaults:{unit:$unit},overrides:[]}};
{
  uid:"notes-use", title:"Node USE", tags:["node","use"],
  schemaVersion:41, version:1, refresh:"30s",
  time:{from:"now-1h",to:"now"},
  panels:[
    p(1;0;0;"CPU: занятость, %";"percent";"100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[$__rate_interval])))"),
    p(2;12;0;"CPU: насыщение (load1 на ядро)";"short";"node_load1 / count by (instance) (node_cpu_seconds_total{mode=\"idle\"})"),
    p(3;0;7;"Память: занято, %";"percent";"100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"),
    p(4;12;7;"Диск /: занято, %";"percent";"100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\",fstype!=\"tmpfs\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!=\"tmpfs\"})"),
    p(5;0;14;"Сеть: приём и передача, байт/с";"Bps";"rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[$__rate_interval])"),
    p(6;12;14;"Сеть: ошибки и потери, пакетов/с";"pps";"rate(node_network_receive_errs_total[$__rate_interval]) + rate(node_network_receive_drop_total[$__rate_interval])")
  ]
}' > monitoring/grafana/dashboards/notes-use.json
```
{% endraw %}

Подпись в легенде каждой панели подставляет имя узла (`instance`).

2. Подожди 30 секунд и посмотри список:

```bash
curl -s -u admin:CHANGE_ME 'http://127.0.0.1:3000/api/search?tag=use' | jq -r '.[].title'
```

**Что должно получиться**

```text
Node USE
```

**Объясни себе**

- Почему для диска берём `avail`, а не `free`?
- Чем в сети «ошибки и потери» это E, а «байт/с» это U?

**Типичные ошибки**

- `jq: error: syntax error, unexpected INVALID_CHARACTER`: в шаблоне остался неэкранированный символ (`"` внутри строки): каждую кавычку внутри выражения пиши как `\"`.
- Панели пустые с `No data`: node_exporter не скрапится, проверь `up{job="node"}` в Prometheus (урок 8.2).

### Задание 4. Пересоздание с нуля и ссылка на runbook

**Цель:** доказать, что дашборды это код: стереть том Grafana и получить тот же результат.

**Предскажи:** что останется после `down -v`: datasource, дашборды, ручные правки паролей?

<details>
<summary>Ответ</summary>

Datasource и дашборды вернутся из файлов. Пароль администратора будет снова из переменной окружения. Пропадёт только то, что жило в томе: история изменений в UI, сессии, созданные вручную пользователи.

</details>

**Шаги**

1. Добавь панель-ссылку на runbook: она уже есть в `notes-red.json` (`links`, ссылка над дашбордом). Проверь, что она читается из файла:

```bash
jq -r '.links[].title' monitoring/grafana/dashboards/notes-red.json
```

2. Стирание Grafana и подъём заново (том Prometheus не трогаем: удаляем только Grafana):

```bash
docker compose -f monitoring/compose.yml rm -sf grafana
docker volume ls -q | grep grafana-data | xargs docker volume rm
docker compose -f monitoring/compose.yml up -d grafana
sleep 20
curl -s -u admin:CHANGE_ME 'http://127.0.0.1:3000/api/search' | jq -r '.[].title' | sort
```

**Что должно получиться**

```text
Node USE
Notes
Notes RED
```

Строка `Notes` это папка провайдера, остальные два дашборда.

**Объясни себе**

- Почему нельзя удалять том `prom-data` ради этого опыта?
- Где в этой схеме хранятся «настоящие» данные метрик, а где только вид на них?

**Типичные ошибки**

- `Error response from daemon: remove monitoring_grafana-data: no such volume`: имя тома содержит префикс проекта Compose: смотри `docker volume ls` и удаляй по фактическому имени.
- Список пуст сразу после `up`: Grafana ещё стартует (создаёт базу): подожди 20-30 секунд и повтори.

### Задание 5. Шаг проекта: Grafana и дашборды в git

**Цель:** зафиксировать в `~/notes` состояние после урока 8.6.

**Шаги**

1. Проверь состав `monitoring/grafana/`:

```bash
find monitoring/grafana -type f | sort
```

2. Проверь конфигурацию Compose и коммит:

```bash
docker compose -f monitoring/compose.yml config -q && echo "compose OK"
git add monitoring/
git commit -m "Grafana 13.2.2: provisioning и дашборды Notes RED, Node USE"
```

3. Пароль `CHANGE_ME` замени на свой и не коммить его: перенеси в `monitoring/.env` (файл в `.gitignore`), а в compose укажи `GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}`. Эталон: [project/notes/monitoring/](https://github.com/distinguished-sre/devops/tree/devops/project/notes/monitoring).

**Что должно получиться**

```text
monitoring/grafana/dashboards/notes-red.json
monitoring/grafana/dashboards/notes-use.json
monitoring/grafana/provisioning/dashboards/dashboards.yml
monitoring/grafana/provisioning/datasources/prometheus.yml
compose OK
```

**Объясни себе**

- Почему пароль администратора нельзя коммитить, даже учебный?
- Что должен сделать новый коллега, чтобы получить твои дашборды?

**Типичные ошибки**

- `error while interpolating ... required variable GRAFANA_PASSWORD is missing`: нет `monitoring/.env`: создай его: `echo "GRAFANA_PASSWORD=$(openssl rand -base64 24)" > monitoring/.env`.
- `bind: address already in use` на 3000: порт занят другим процессом: `sudo ss -ltnp | grep 3000` и останови его.

## Сломай и почини

Скачай скрипт и запусти один из трёх сценариев (номер от 1 до 3, или `random`). Скрипт не читай: цель в том, чтобы найти причину диагностикой.

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/8.6/break.sh
bash break.sh random
```

### Симптом

Одно из трёх: панели показывают `No data`; после пересоздания контейнера Grafana дашборда нет; на дашборде столько панелей, что за минуту не понять, что горит.

### Гипотезы

- Datasource указывает не туда, у него другой uid или окно запроса слишком короткое.
- Дашборд был создан в UI и не лежит в provisioning, поэтому исчез вместе с томом.
- Дашборд разросся без структуры: нет приоритета, нет порогов.

### Проверки

```bash
# datasource: адрес и uid
curl -s -u admin:CHANGE_ME http://127.0.0.1:3000/api/datasources | jq '.[] | {uid, url}'
# отвечает ли Prometheus из контейнера Grafana
docker compose -f monitoring/compose.yml exec grafana wget -qO- http://prometheus:9090/-/ready
# есть ли дашборд в файлах и видит ли его Grafana
ls monitoring/grafana/dashboards
docker compose -f monitoring/compose.yml logs grafana | grep -i provision | tail
# сколько панелей в дашборде
jq '.panels | length' monitoring/grafana/dashboards/notes-red.json
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**1. No data.** Три типичные причины: неверный `url` datasource (`localhost` вместо `prometheus:9090`), uid панелей не совпадает с uid источника, диапазон времени короче двух скрапов или в нём не было запросов. Порядок проверки: сначала Explore с простым запросом `up` (жив ли источник), затем тот же запрос с временем «последние 5 минут», затем значение переменной `path`. Исправь `url` или uid в `provisioning/datasources/prometheus.yml`, перезапусти Grafana.

**2. Дашборд пропал после пересоздания.** Он был сохранён в UI и жил только в томе. Исправление: экспортировать JSON, положить в `monitoring/grafana/dashboards/`, закоммитить. Профилактика: `allowUiUpdates: false` и привычка «правки только в git».

**3. 30 панелей.** Оставь то, что отвечает на вопросы «есть ли ошибки, медленно ли, сколько запросов». Остальное вынеси в отдельный дашборд по компоненту или в Explore. Добавь пороги (цвет), единицы и говорящие заголовки, сверху поставь ошибки и p95. Проверка: коллега за 10 секунд говорит, здоров ли сервис.

</details>

## Вопросы с собеседований

### 1. [junior] Чем панель отличается от дашборда и что такое datasource?

Datasource это подключение к источнику данных (Prometheus, Loki). Панель это один запрос и способ его показа, дашборд это страница из панелей, хранящаяся как JSON. Сама Grafana метрики не хранит.

**Что хотят услышать:** Grafana только визуализирует; запрос на языке источника; JSON как формат.

**Красный флаг:** «Grafana собирает метрики с серверов».

### 2. [junior] Что должно быть на дашборде сервиса, если смотреть только на первый экран?

Я бы вывел RED: долю ошибок, задержку p95 против цели, число запросов. Сверху то, что горит, ниже разбивка по эндпоинтам. Ресурсы узла на отдельном дашборде.

**Что хотят услышать:** RED, порог и цвет, связь с SLO, не более 6-8 панелей.

**Красный флаг:** «Все метрики, какие есть».

### 3. [junior] Дашборд показывает No data. Что делаешь?

Иду в Explore с запросом `up` на том же datasource: жив ли источник. Проверяю диапазон времени, значения переменных и не переименована ли метрика. Затем смотрю сам запрос в Query inspector.

**Что хотят услышать:** порядок от источника к запросу, Explore, Query inspector, окно в `rate`.

**Красный флаг:** «Пересоздам дашборд».

### 4. [junior] Зачем нужен provisioning?

Чтобы Grafana поднималась с нужными datasource и дашбордами из файлов в git: воспроизводимо, с ревью и без ручных кликов. Пересоздали контейнер или окружение, всё вернулось.

**Что хотят услышать:** воспроизводимость, git, ревью, отсутствие ручного состояния.

**Красный флаг:** «Просто так удобнее».

### 5. [middle] Ночью пересоздали Grafana, и утром пропали дашборды, на которые ссылается runbook. Как это предотвратить?

Дашборды должны быть в git и подхватываться provisioning. Uid дашбордов и datasource фиксирую, чтобы ссылки из runbook и алертов не ломались. Правки в UI выключены (`allowUiUpdates: false`), процесс: правка, экспорт JSON, pull request.

**Что хотят услышать:** постоянные uid, файловый провайдер, том не источник правды, бэкап как запасной план.

**Красный флаг:** «Сделаем бэкап тома раз в сутки» как единственная мера.

### 6. [middle] Панель ошибок показывает 0%, а пользователи жалуются. Что проверишь?

Сначала не «нет данных» ли это выдано как ноль: при отсутствии запросов деление даёт пусто. Затем какие метрики считаются: возможно, ошибки отдаёт балансировщик, а приложение видит 200. Проверяю проверку снаружи (blackbox, урок 8.4), окно и фильтр переменной `path`.

**Что хотят услышать:** взгляд снаружи против изнутри, фильтры, пустота против нуля.

**Красный флаг:** «Значит, у пользователей проблемы с интернетом».

### 7. [middle] Что такое `$__rate_interval` и почему не писать `[5m]`?

Grafana подставляет окно не меньше четырёх интервалов скрапа и с учётом шага графика. При постоянном `[5m]` на большом масштабе график сглажен, на малом окно слишком широкое. С коротким жёстким окном при редком скрапе будут дыры.

**Что хотят услышать:** зависимость от scrape interval и масштаба, минимум две точки в окне.

**Красный флаг:** «Это просто удобное сокращение».

### 8. [middle] Дашборд тормозит: открывается по 20 секунд. Что делаешь?

Смотрю время запросов в Query inspector, нахожу тяжёлые (`histogram_quantile` по всем `path` за 30 дней, высокая кардинальность). Выношу расчёт в recording rules, сокращаю диапазон по умолчанию, убираю лишние панели, ставлю разумный `refresh`.

**Что хотят услышать:** recording rules, кардинальность, интервал обновления, число панелей.

**Красный флаг:** «Купить сервер побольше для Grafana».

### 9. [middle] Ты поменял панель в UI, а после деплоя изменение пропало. Почему и как правильно?

Источник правды файл в git, provisioning его перечитал. Правильно: правка, экспорт JSON, коммит и ревью. Для быстрых экспериментов можно сохранить копию как новый дашборд, но потом либо оформить в код, либо удалить.

**Что хотят услышать:** файл против UI, процесс через PR, uid.

**Красный флаг:** «Отключим provisioning, чтобы правки сохранялись».

### 10. [middle] Как показать команде на дашборде SLO и остаток error budget?

Строю панель на recording rule доступности за 30 дней (окно из `docs/slo.md`), рядом показываю цель как порог и остаток бюджета в минутах. Аннотации отмечают деплои: рядом с падением видно, что его вызвало.

**Что хотят услышать:** связь с SLO, порог как цель, аннотации деплоев, recording rules.

**Красный флаг:** «Просто график CPU».

### 11. [junior] Разница между Grafana alerting и Alertmanager: что выберешь и почему?

Для нашего стека основным беру Alertmanager: правила в git, тесты `promtool`, группировка и маршрутизация. Alerting Grafana подходит, когда нужны алерты по источникам без Prometheus или командам без доступа к конфигурации Prometheus.

**Что хотят услышать:** аргументы про код, тесты, один канал; понимание, когда Grafana alerting уместен.

**Красный флаг:** «Это одно и то же».

## Проверено на версиях

- Grafana: 13.2.2
- Prometheus: v3.15.0
- node_exporter: v1.12.1
- Docker Compose: версия не закреплена, проверь актуальную версию на странице проекта
- jq: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею поднять Grafana 13.2.2 в Compose рядом с Prometheus
- [ ] умею описать datasource и провайдер дашбордов файлами provisioning
- [ ] умею собрать дашборд RED и объяснить, что должно быть на первом экране
- [ ] умею собрать дашборд USE для узла
- [ ] умею использовать переменные и `$__rate_interval` в запросах
- [ ] умею хранить дашборды в git и восстановить Grafana с нуля
- [ ] умею диагностировать No data по порядку: источник, время, запрос, переменная

**Дальше:** [Урок 8.7: Логи: JSON, Loki и Grafana Alloy](07-logs-loki-alloy.md)
