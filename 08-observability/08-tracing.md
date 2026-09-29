---
layout: lesson
title: "Трейсинг: OpenTelemetry и Tempo"
topic: 8
lesson: "8.8"
time: "2 ч"
---

## Зачем это нужно

Метрики говорят, что запросы стали медленными. Логи говорят, что что-то пошло не так. Но ни то ни другое не отвечает на вопрос "где именно этот запрос потерял 900 мс: в приложении, в базе или по дороге". Для этого есть трейс (trace): запись пути одного запроса по всем компонентам.

На работе трейсинг включают, когда сервисов больше двух и "тормозит где-то" перестаёт быть диагнозом. Даже для одного сервиса с БД трейс сразу показывает, сколько времени заняли SQL и сама логика.

Шаг проекта: «Заметки» получают версию v7 (образ 0.7.0) с OpenTelemetry, в логах появляется `trace_id`, а в стеке мониторинга поднимаются Tempo и приём OTLP в Alloy.

## Что нужно знать

- [Урок 2.4: HTTP](../02-network/04-http.md) - заголовки запроса, из них будет состоять контекст трассировки
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - сеть `notes-net`, обращение приложения к БД
- [Урок 8.2: Prometheus](02-prometheus-basics.md) - как выглядит стек `monitoring/compose.yml`
- [Урок 8.6: Grafana как код](06-grafana-dashboards.md) - provisioning источников данных
- [Урок 8.7: Логи, Loki и Alloy](07-logs-loki-alloy.md) - JSON-логи и конфиг Alloy, который мы расширяем

## Теория

### Трейс, спан и контекст

Спан (span) это одна единица работы с началом, длительностью и атрибутами: "обработать HTTP GET /notes", "выполнить SELECT". Трейс это дерево спанов одного запроса. У всего трейса один `trace_id` (32 hex-символа), у каждого спана свой `span_id` (16 hex-символов) и ссылка на родителя.

```text
trace_id = 4bf92f3577b34da6a3ce929d0e0e4736

HTTP GET /notes                 [==============================] 42 ms   <- корневой (server) спан
  db SELECT notes               [        =============        ] 31 ms   <- дочерний спан
```

По такой картинке видно главное: 31 из 42 мс ушло в базу. Метрика с гистограммой показала бы только "42 мс".

> **Проверь понимание:** чем спан отличается от трейса и что у них общего?

<details>
<summary>Ответ</summary>

Трейс это всё дерево запроса, спан это один узел дерева. У всех спанов одного трейса общий `trace_id`, а `span_id` у каждого свой. Связь "родитель-потомок" задаёт поле `parent_span_id`.

</details>

### Пропагация контекста: как трейс не рвётся

Когда сервис A вызывает сервис B, B должен узнать, чьё продолжение он рисует. Для этого A кладёт в исходящий запрос HTTP-заголовок `traceparent` (стандарт W3C Trace Context):

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             |  |                                |                |
             |  trace_id (32 hex)                span_id родителя  флаги (01 = сохранять)
             версия
```

Это пропагация (propagation). Если хоть один участник цепочки заголовок потерял (прокси срезал, клиент не добавил), у следующего сервиса появится новый `trace_id`, и в Tempo вместо одного трейса окажутся два несвязанных огрызка. Это самая частая поломка трейсинга, ей посвящён первый сценарий в разделе "Сломай и почини".

> **Проверь понимание:** запрос пришёл в nginx, потом в приложение. В Tempo два трейса вместо одного. Что подозреваешь?

<details>
<summary>Ответ</summary>

Где-то потерян заголовок `traceparent`: nginx не проксирует его (или клиент не отправил), приложение стартует новый корневой спан. Проверять: что уходит в `/headers` (эндпоинт из урока 2.4 показывает заголовки, дошедшие до приложения), и пробрасывает ли прокси заголовки.

</details>

### OpenTelemetry: SDK, OTLP, Collector

OpenTelemetry (OTel) это стандарт CNCF для телеметрии: API и SDK в коде приложения, формат данных и протокол OTLP (OpenTelemetry Protocol). Приложение не знает, где хранятся трейсы: оно шлёт OTLP на адрес из переменной `OTEL_EXPORTER_OTLP_ENDPOINT`. Сменить хранилище (Jaeger на Tempo) можно без правки кода.

OTLP ходит по двум транспортам: gRPC (порт 4317) и HTTP (порт 4318, путь `/v1/traces`). Это не взаимозаменяемо: клиент, говорящий по HTTP, на порт 4317 попадёт как в стену. Нужный пункт диагностики в сценарии 3.

Между приложением и хранилищем ставят сборщик (collector). У нас его роль играет Grafana Alloy, который ты уже настроил в уроке 8.7 для логов: он принимает OTLP, пакует спаны в батчи и отправляет в Tempo.

```text
notes (SDK, OTLP/HTTP) --> Alloy :4318 --> Tempo (OTLP/gRPC :4317 внутри сети) --> Grafana :3000
```

> **Проверь понимание:** зачем между приложением и Tempo нужен сборщик, если приложение может слать в Tempo напрямую?

<details>
<summary>Ответ</summary>

Сборщик буферизует и батчит данные, переживает кратковременную недоступность хранилища, может добавлять атрибуты, отбрасывать лишнее и сэмплировать. Приложение при этом знает один стабильный адрес и не зависит от того, какое хранилище стоит за ним.

</details>

### Tempo, TraceQL и сэмплирование

Tempo (Grafana Tempo) хранит трейсы в блоках на диске или в объектном хранилище и не строит индекс по всем атрибутам, поэтому дёшев. Ищешь либо по `trace_id`, либо запросом на языке TraceQL:

```text
{ resource.service.name = "notes" && duration > 500ms }
{ span.http.status_code >= 500 }
```

Хранить трейс каждого запроса при большой нагрузке дорого, поэтому применяют сэмплирование (sampling). Head-сэмплирование решает в начале запроса ("сохраняем 10%"), tail-сэмплирование решает после завершения ("сохраняем все ошибки и все медленные"). В курсе сэмплирование не включаем: нагрузка мала, сохраняем всё.

> **Проверь понимание:** почему для поиска причин инцидента tail-сэмплирование полезнее head?

<details>
<summary>Ответ</summary>

Head принимает решение до того, как известно, будет ли запрос ошибочным или медленным, и выбросит часть как раз интересных трейсов. Tail видит результат целиком и оставляет все аномальные, а из нормальных берёт небольшую долю.

</details>

## Практика

Все команды выполняются из `~/notes`. Основной `compose.yml` и стек `monitoring/` из урока 8.7 должны работать.

### Задание 1. Tempo и приём OTLP в Alloy

**Цель:** запустить Tempo и научить Alloy принимать OTLP и отправлять спаны в Tempo.

**Предскажи:** какие из портов 3200, 4317, 4318 будут опубликованы на хосте? Подумай, кто с кем разговаривает.

<details>
<summary>Ответ</summary>

Наружу нужны 3200 (Tempo API, к нему ходит Grafana и ты с хоста) и 4317/4318 (принимает Alloy: с хоста удобно слать тестовые спаны). Tempo слушает OTLP на 4317 только внутри сети `notes-net`, публиковать его на хосте нельзя: порт 4317 уже занят Alloy.

</details>

**Шаги:**

1. Создай `monitoring/tempo/tempo.yml`:

```yaml
# Tempo в одиночном режиме: хранение на локальном диске, всё в одном процессе
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

storage:
  trace:
    backend: local
    wal:
      path: /var/tempo/wal
    local:
      path: /var/tempo/blocks

# хранить трейсы 24 часа: для учебного стенда достаточно
compactor:
  compaction:
    block_retention: 24h
```

2. Добавь в `monitoring/compose.yml` сервис `tempo` и том `tempo-data` (остальные сервисы не трогай):

```yaml
  tempo:
    image: grafana/tempo:v3.0.3
    command: ["-config.file=/etc/tempo/tempo.yml"]
    ports:
      - "3200:3200"
    volumes:
      - ./tempo/tempo.yml:/etc/tempo/tempo.yml:ro
      - tempo-data:/var/tempo
    restart: unless-stopped
```

В секции `volumes:` в конце файла добавь `tempo-data:`. В сервисе `alloy` опубликуй порты `"4317:4317"` и `"4318:4318"`.

3. Добавь в конец `monitoring/alloy/config.alloy` (блоки логов из урока 8.7 оставь как есть):

```text
// приём OTLP от приложений: gRPC на 4317 и HTTP на 4318
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }
  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

// батчи уменьшают число запросов к Tempo
otelcol.processor.batch "default" {
  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

// отправка в Tempo по gRPC внутри сети, без TLS (только для лаборатории)
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo:4317"
    tls {
      insecure = true
    }
  }
}
```

4. Примени и проверь готовность:

```bash
docker compose -f monitoring/compose.yml up -d tempo alloy
sleep 20
curl -s http://localhost:3200/ready
```

**Что должно получиться:**

```text
ready
```

Если сразу пришло `Ingester not ready: waiting for 15s after being ready`, подожди ещё 15 секунд.

**Объясни себе:**

- Почему Alloy шлёт в Tempo по gRPC, хотя приложение будет слать в Alloy по HTTP?

**Типичные ошибки:**

- `Error response from daemon: driver failed programming external connectivity ... Bind for 0.0.0.0:4317 failed: port is already allocated`: порт 4317 опубликован у двух сервисов. Убери публикацию 4317 у `tempo`, оставь у `alloy`.
- `failed to load config: ... field distributor not found` в логе Tempo: опечатка или неверный отступ в `tempo.yml`. Проверь `docker compose -f monitoring/compose.yml logs tempo`.

### Задание 2. Отправь трейс вручную

**Цель:** увидеть, что OTLP это обычный HTTP+JSON, и пройти путь спана от Alloy до Tempo без приложения.

**Предскажи:** если отправить один спан на `http://localhost:4318/v1/traces`, какой HTTP-код вернёт Alloy: 200, 202 или 204? И сразу ли спан появится в Tempo?

<details>
<summary>Ответ</summary>

Ответ OTLP/HTTP при успехе: 200 с телом `{"partialSuccess":{}}`. В Tempo спан появится не сразу: сначала он в памяти (ingest), поэтому запрос по `trace_id` может вернуть 404 в течение нескольких секунд.

</details>

**Шаги:**

```bash
# идентификаторы: trace_id 32 hex, span_id 16 hex
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
START=$(date +%s%N)
END=$((START + 250000000))   # спан длится 250 мс

curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"manual-test"}}]},
  "scopeSpans":[{"spans":[{"traceId":"'$TRACE_ID'","spanId":"'$SPAN_ID'","name":"hello","kind":1,
  "startTimeUnixNano":"'$START'","endTimeUnixNano":"'$END'"}]}]}]}' \
  http://localhost:4318/v1/traces

echo "trace_id=$TRACE_ID"
sleep 10
curl -s http://localhost:3200/api/v2/traces/$TRACE_ID | jq -r '.trace.resourceSpans[].scopeSpans[].spans[].name'
```

**Что должно получиться:**

```text
HTTP 200
trace_id=<32 hex-символа>
hello
```

**Объясни себе:**

- Из каких трёх идентификаторов и временных полей состоит минимальный спан?

**Типичные ошибки:**

- `HTTP 000` и `curl: (7) Failed to connect to localhost port 4318`: Alloy не запущен или порт не опубликован. Проверь `docker compose -f monitoring/compose.yml ps`.
- Пустой вывод последней команды или `trace not found`: спан ещё не дошёл, подожди 10 секунд и повтори запрос.

### Задание 3. Приложение v7: трейсы и trace_id в логах

**Цель:** подключить OpenTelemetry SDK к «Заметкам» и увидеть, как один запрос порождает серверный и БД-спан.

**Предскажи:** приложение получило заголовок `traceparent: 00-<trace_id>-<span_id>-01`. Какой `trace_id` будет у его серверного спана: новый или тот же?

<details>
<summary>Ответ</summary>

Тот же. SDK читает `traceparent`, берёт `trace_id` из него и делает свой спан дочерним к `span_id` из заголовка. Именно так трейс продолжается через границу сервисов.

</details>

**Шаги:**

1. Добавь в `requirements.txt` три пакета (точные версии возьми из [эталонного requirements.txt](https://github.com/distinguished-sre/devops/tree/devops/project/notes/requirements.txt), закрепляй их через `==`): `opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-http`.
2. В `app.py` добавь настройку трейсинга. Ниже суть изменений v7 (полный файл в [эталоне](https://github.com/distinguished-sre/devops/tree/devops/project/notes/app.py)):

```python
import os
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator


def setup_tracing():
    """Включает трейсинг, только если задан OTEL_EXPORTER_OTLP_ENDPOINT."""
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")
    if not endpoint:
        return None
    resource = Resource.create({"service.name": os.environ.get("OTEL_SERVICE_NAME", "notes")})
    provider = TracerProvider(resource=resource)
    # OTLP/HTTP: путь /v1/traces дописывается к адресу
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint.rstrip("/") + "/v1/traces")))
    trace.set_tracer_provider(provider)
    return trace.get_tracer("notes")


PROPAGATOR = TraceContextTextMapPropagator()

# в обработчике запроса: продолжить трейс из входящего traceparent
#   ctx = PROPAGATOR.extract(carrier=dict(self.headers))
#   with tracer.start_as_current_span("HTTP GET /notes", context=ctx, kind=trace.SpanKind.SERVER):
#       ...   # внутри: with tracer.start_as_current_span("db"): выполнить SQL
#
# в логгере: добавить trace_id текущего спана (32 hex), если спан активен
#   span_ctx = trace.get_current_span().get_span_context()
#   if span_ctx.is_valid:
#       record["trace_id"] = format(span_ctx.trace_id, "032x")
```

3. Добавь в основной `compose.yml`, сервису `notes`, переменные окружения (приложение и Alloy в одной сети `notes-net`, адрес по имени):

```yaml
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://alloy:4318"
      OTEL_SERVICE_NAME: "notes"
```

4. Пересобери и запусти, сделай запросы с явным `traceparent`:

```bash
docker compose up -d --build notes
TP_TRACE=$(openssl rand -hex 16)
curl -s -H "traceparent: 00-${TP_TRACE}-00f067aa0ba902b7-01" \
  -X POST -d '{"text":"проверка трейсинга"}' http://localhost:8080/notes
curl -s -H "traceparent: 00-${TP_TRACE}-00f067aa0ba902b7-01" http://localhost:8080/notes > /dev/null
sleep 10
# в логе приложения тот же trace_id, что мы передали
docker compose logs notes | grep "$TP_TRACE" | head -2
# и в Tempo два серверных спана и БД-спаны внутри одного трейса
curl -s http://localhost:3200/api/v2/traces/$TP_TRACE | jq -r '.trace.resourceSpans[].scopeSpans[].spans[].name' | sort | uniq -c
```

**Что должно получиться:**

```text
{"ts":"2026-09-29T10:00:00","level":"info","msg":"request","method":"POST","path":"/notes","status":201,"dur_ms":6,"version":"0.7.0","trace_id":"<тот же 32 hex>"}
{"ts":"2026-09-29T10:00:00","level":"info","msg":"request","method":"GET","path":"/notes","status":200,"dur_ms":3,"version":"0.7.0","trace_id":"<тот же 32 hex>"}
      2 db
      1 HTTP GET /notes
      1 HTTP POST /notes
```

Если у тебя `STORE=file`, спанов `db` не будет: они создаются вокруг PostgreSQL (контракт `app.py`).

**Объясни себе:**

- Почему имя спана `HTTP GET /notes`, а не `GET /notes/123` с настоящим URL (вспомни урок 8.7 про кардинальность)?

**Типичные ошибки:**

- `ModuleNotFoundError: No module named 'opentelemetry'`: образ собран до правки `requirements.txt`. Пересобери с `--build`.
- `Failed to export batch code: 404` в логах приложения: адрес указан без порта или указан не Alloy. Ожидается `http://alloy:4318`.
- В логах нет поля `trace_id`: запрос выполнялся вне активного спана или лог пишется до `start_as_current_span`. Сценарий 2 в разделе "Сломай и почини".

### Задание 4. Grafana: из лога в трейс и обратно

**Цель:** подключить Tempo как источник данных и сделать переход между логами и трейсами.

**Предскажи:** какое поле в Loki-источнике нужно, чтобы значение `trace_id` в строке лога стало ссылкой на трейс?

<details>
<summary>Ответ</summary>

Derived field (производное поле): регулярное выражение вытаскивает `trace_id` из строки, а внутренняя ссылка направляет его в источник Tempo.

</details>

**Шаги:**

1. Создай `monitoring/grafana/provisioning/datasources/tempo.yml`:

{% raw %}
```yaml
apiVersion: 1
datasources:
  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      # из спана переходим к логам того же trace_id
      tracesToLogsV2:
        datasourceUid: loki
        filterByTraceID: true
        customQuery: true
        query: '{service="notes"} | json | trace_id="${__span.traceId}"'
```
{% endraw %}

2. В файле источника Loki из урока 8.7 (в `monitoring/grafana/provisioning/datasources/`) убедись, что `uid: loki`, и добавь в `jsonData` производное поле:

{% raw %}
```yaml
    jsonData:
      derivedFields:
        - name: trace_id
          matcherRegex: '"trace_id":"(\w+)"'
          url: '$${__value.raw}'
          datasourceUid: tempo
```
{% endraw %}

3. Перезапусти Grafana и сгенерируй трафик:

```bash
docker compose -f monitoring/compose.yml restart grafana
# медленный запрос: его будет видно в трейсе
curl -s "http://localhost:8080/slow?sec=1"
for i in 1 2 3; do curl -s -X POST -d '{"text":"note"}' http://localhost:8080/notes > /dev/null; done
```

4. Открой Grafana (`http://localhost:3000`), Explore, источник Tempo, режим TraceQL. Выполни запрос:

```text
{ resource.service.name = "notes" && duration > 900ms }
```

5. Открой найденный трейс, в панели спана нажми на иконку логов (Logs for this span). Затем в Explore выбери Loki, запрос `{service="notes"} | json | trace_id != ""`, раскрой строку и нажми на ссылку у поля `trace_id`.

**Что должно получиться:** в Tempo найден один трейс `HTTP GET /slow` длительностью около 1 с. Из спана открываются логи, в которых ровно эта запись. Из строки лога открывается трейс.

**Объясни себе:**

- Что тут связывает лог и трейс: тег, время или идентификатор? Почему время не подходит?

**Типичные ошибки:**

- `No data` в панели логов у спана: у Loki-источника не совпал `uid` с `datasourceUid: loki`, либо лейбл `service` в Loki другой. Сверь с конфигом Alloy из 8.7.
- `Data source tempo was not found`: в Loki-источнике указан `datasourceUid: tempo`, а Tempo-источник не загрузился. Смотри `docker compose -f monitoring/compose.yml logs grafana | grep -i provisioning`.

### Задание 5. Шаг проекта: v7, образ 0.7.0, тег v0.7.0

**Цель:** зафиксировать состояние проекта после урока.

**Предскажи:** что покажет `curl localhost:8080/` после пересборки, если в `compose.yml` остался тег 0.6.0?

<details>
<summary>Ответ</summary>

`Notes service v0.6.0`: версию печатает то, что запущено, а не то, что лежит в `app.py`. Тег образа и переменная `APP_VERSION` в `compose.yml` должны быть обновлены вместе с кодом.

</details>

**Шаги:**

```bash
cd ~/notes
# версия образа и приложения
sed -i 's/0\.6\.0/0.7.0/g' compose.yml   # macOS: sed -i '' ...
docker build -t notes:0.7.0 .
docker compose up -d
curl -s http://localhost:8080/
# проверка, что в репозитории есть всё нужное для урока
ls monitoring/tempo/tempo.yml monitoring/alloy/config.alloy
git add -A
git commit -m "Урок 8.8: OpenTelemetry, Tempo, trace_id в логах"
git tag v0.7.0
git tag --list 'v0.7*'
```

**Что должно получиться:**

```text
Notes service v0.7.0
monitoring/alloy/config.alloy
monitoring/tempo/tempo.yml
v0.7.0
```

Эталон состояния после урока: [project/notes](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Объясни себе:**

- Почему приложение не падает, если Tempo недоступен? Что происходит с накопленными спанами?

**Типичные ошибки:**

- `fatal: pathspec 'monitoring' did not match any files`: команда выполнена не из `~/notes`.
- `Notes service v0.6.0` после запуска: не обновлён тег образа в `compose.yml` (см. "Предскажи").

### Если у тебя 8 ГБ

Останови то, что в этом уроке не нужно:

```bash
docker compose -f monitoring/compose.yml stop cadvisor node-exporter blackbox alertmanager
docker stats --no-stream
```

Если памяти всё равно мало, останови ещё и Prometheus: он понадобится в 8.9.

## Сломай и почини

Запусти один из сценариев и не читай скрипт, он сам себе спойлер:

```bash
bash ~/notes/break/8.8/break.sh 1     # можно 1, 2 или 3
```

### Симптом

Сценарий 1: в Tempo вместо одного трейса два, а запрос через nginx не связан с запросом приложения.
Сценарий 2: трейсы есть, а в логах нет `trace_id`, переход из лога в трейс невозможен.
Сценарий 3: приложение работает, трейсов в Tempo нет вообще.

### Гипотезы

Выпиши минимум по две на симптом. Для сценария 3, например: Alloy не запущен; порт или протокол не совпадает; Alloy не может передать в Tempo.

### Проверки

Иди от источника к хранилищу и проверяй один участок за раз.

```bash
docker compose logs notes | grep -i -E 'export|otel' | tail -5   # ошибки экспорта
docker compose -f monitoring/compose.yml logs alloy | grep -i -E 'error|refused' | tail -5
curl -s -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' http://localhost:8080/headers | jq .
```

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**Сценарий 1, обрыв трейса.** Проверка 3 показала, что `traceparent` до приложения не доходит: прокси или приложение сбрасывают заголовок. Обычная причина: nginx с `proxy_set_header` не передаёт неизвестные заголовки только если их явно обнулили (`proxy_set_header traceparent "";`) либо приложение не вызывает `extract`. Исправление: убрать обнуление в конфиге nginx, применить `docker compose exec nginx nginx -s reload`; в коде вызывать `PROPAGATOR.extract(...)` до создания спана. Проверка: тот же `curl` с `traceparent`, трейс в Tempo один.

**Сценарий 2, нет trace_id в логах.** Запись лога формируется вне активного спана (лог пишется после выхода из `with start_as_current_span`) либо в форматтер не добавлен `trace_id`. Исправление: писать лог внутри спана или брать `trace.get_current_span()` там, где спан ещё жив. Проверка: `docker compose logs notes | tail -1 | jq .trace_id` возвращает 32 hex.

**Сценарий 3, Tempo не принимает OTLP.** Типовые причины: в `OTEL_EXPORTER_OTLP_ENDPOINT` указан порт 4317 (gRPC) при HTTP-экспортёре (нужен 4318); в Alloy приёмник слушает `127.0.0.1` вместо `0.0.0.0`; порт не опубликован; Alloy отправляет в Tempo с TLS вместо `insecure = true`. Исправление: адрес `http://alloy:4318`, приёмник на `0.0.0.0`, `docker compose -f monitoring/compose.yml up -d alloy`. Проверка: задание 2 возвращает `hello`.

</details>

После собственного исправления верни эталон:

```bash
bash ~/notes/break/8.8/fix.sh
```

## Вопросы с собеседований

### 1. [junior] Чем трейсы отличаются от логов и метрик?

Метрики отвечают "сколько и как часто", логи "что случилось", трейсы "где в цепочке ушло время". Трейс показывает путь одного запроса с длительностью каждого шага.

**Что хотят услышать:** три сигнала не заменяют друг друга; трейс нужен, когда запрос проходит через несколько компонентов; метрика даёт агрегат, трейс даёт конкретный случай.

**Красный флаг:** "трейсы это просто логи с временем".

### 2. [junior] Что такое span и как он связан с trace_id?

Span это одна операция с началом и длительностью. Все спаны одного запроса имеют общий `trace_id` и образуют дерево по `parent_span_id`.

**Что хотят услышать:** root span, child span, атрибуты, статус (ошибка), длительность.

**Красный флаг:** путает `trace_id` и `span_id` или не понимает, что такое родитель.

### 3. [junior] Что такое OTLP и какие у него порты?

Протокол OpenTelemetry для передачи телеметрии. По gRPC порт 4317, по HTTP 4318 (`/v1/traces`).

**Что хотят услышать:** два транспорта, ошибка "HTTP на порт gRPC", OTLP не привязан к конкретному хранилищу.

**Красный флаг:** "OTLP это формат Jaeger".

### 4. [junior] Что такое traceparent?

Заголовок W3C Trace Context: версия, `trace_id`, `span_id` родителя, флаги. Клиент кладёт его в исходящий запрос, сервер продолжает трейс.

**Что хотят услышать:** это механизм пропагации между сервисами; формат `00-<32hex>-<16hex>-01`; флаг сэмплирования.

**Красный флаг:** не знает, как трейс связывается между двумя сервисами.

### 5. [middle] В Tempo вместо одного трейса запроса два несвязанных: nginx и приложение. Что проверяешь?

Иду по цепочке: доходит ли `traceparent` до приложения (`/headers`), не обнуляет ли его прокси, вызывает ли приложение extract. Если nginx сам не создаёт спаны, то трейс начинается в приложении, и два трейса значит, что заголовок теряется между клиентом и сервисом.

**Что хотят услышать:** пропагация контекста как первая гипотеза; проверка заголовков на каждом хопе; `proxy_set_header`; после починки один `trace_id` в логах обоих участников.

**Красный флаг:** "перезапущу Tempo".

### 6. [middle] Приложение работает, трейсов в Tempo нет. Твои действия?

Иду от источника: включён ли экспорт (endpoint не пуст), что пишет exporter в лог приложения, отвечает ли приёмник на тестовый спан вручную, порты и протокол (4317 gRPC против 4318 HTTP), потом ошибки Alloy при отправке в Tempo, потом Tempo `/ready` и запрос по `trace_id` с учётом задержки.

**Что хотят услышать:** деление цепочки на участки и проверка каждого; ручной OTLP-спан через curl; путаница портов как частая причина.

**Красный флаг:** правит сразу всё и не проверяет по участкам.

### 7. [middle] Как связать лог, метрику и трейс?

Пишу `trace_id` в каждую JSON-строку лога, в Grafana настраиваю derived field в Loki-источнике и `tracesToLogs` в Tempo-источнике. Для метрик используют exemplars: к точке гистограммы прикреплён `trace_id` конкретного запроса.

**Что хотят услышать:** общий идентификатор, а не время; двунаправленные ссылки в Grafana; exemplars; `trace_id` не является лейблом метрики или Loki.

**Красный флаг:** предлагает добавить `trace_id` лейблом в Prometheus или Loki.

### 8. [middle] Что такое сэмплирование и какое выбрать для прода?

Сохранение части трейсов из-за стоимости хранения. Head решает в начале запроса и прост, tail решает по итогу и оставляет ошибки и медленные запросы. Для прода обычно tail в сборщике плюс небольшая доля обычных запросов.

**Что хотят услышать:** компромисс цена против полноты; tail требует буферизации спанов в сборщике; ошибки и p99 не теряются.

**Красный флаг:** "сэмплирование не нужно, храним всё" для нагруженного сервиса.

### 9. [middle] Запросы стали медленнее: p95 вырос с 100 мс до 800 мс. Как найдёшь причину с помощью трейсов?

Беру по метрике время всплеска, в Tempo ищу TraceQL `{ resource.service.name = "notes" && duration > 500ms }`, открываю несколько трейсов и смотрю, какой спан занимает время: `db`, внешний вызов или сама обработка. Затем логи по `trace_id` этого запроса и, при необходимости, метрики БД.

**Что хотят услышать:** от метрики к трейсу, анализ структуры спанов, TraceQL, сравнение с нормальным трейсом.

**Красный флаг:** только "посмотрю логи" и не знает, как найти медленные конкретные запросы.

### 10. [middle] Разработчики хотят добавить в атрибуты спанов email пользователя и тело запроса. Что скажешь?

Не соглашусь на персональные данные и секреты в атрибутах: телеметрия хранится долго и читается многими. Предложу идентификатор пользователя без ПДн, ограничение размера, фильтрацию атрибутов в сборщике. Отдельно помню про стоимость: тяжёлые атрибуты раздувают хранилище.

**Что хотят услышать:** ПДн и секреты в телеметрии как риск; фильтрация в Alloy или в SDK; ограничение кардинальности и размера.

**Красный флаг:** "трейсы внутренние, значит можно".

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- Docker Engine и Compose: версии из урока 4.1
- Grafana Tempo: v3.0.3
- Grafana Alloy: v1.20.1
- Grafana: 13.2.2
- Loki: 3.7.8
- Python: 3.13
- OpenTelemetry SDK для Python: версия не закреплена, проверь актуальную версию на странице проекта (закреплена в эталонном `requirements.txt`)
- Формат конфигурации Tempo v3.0.3: проверь актуальную версию на странице проекта, схема настроек менялась между 2.x и 3.x

## Итог урока: ты умеешь

- [ ] объяснить, что такое трейс, спан, `trace_id` и `traceparent`
- [ ] описать путь спана: приложение, Alloy (OTLP 4318), Tempo, Grafana
- [ ] отправить тестовый спан по OTLP/HTTP через curl и найти его в Tempo по `trace_id`
- [ ] найти медленный запрос в Grafana запросом TraceQL
- [ ] перейти из строки лога в трейс и из спана в логи по `trace_id`
- [ ] найти обрыв трейса и починить пропагацию
- [ ] отличить проблему порта и протокола OTLP (4317 против 4318) от других поломок
- [ ] собрать образ 0.7.0 и поставить тег v0.7.0

**Дальше:** [Урок 8.9: Мониторинг в Kubernetes: kube-prometheus-stack](09-k8s-monitoring.md)
