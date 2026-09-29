---
layout: lesson
title: "Prometheus: сбор метрик и /metrics в «Заметках»"
topic: 8
lesson: "8.2"
time: "2 ч"
---

## Зачем это нужно

В 8.1 ты решил, что считать надёжностью: SLI и SLO. Чтобы их посчитать, нужны числа: сколько запросов пришло, сколько закончилось ошибкой, сколько они длились, сколько памяти съел контейнер. Prometheus собирает эти числа, хранит их как временные ряды и отвечает на вопросы про прошлое.

Ночью «сервис тормозит» без метрик означает угадывание по логам. С метриками видно: ошибки выросли в 02:14, память растёт с релиза, диск закончится через шесть часов. Prometheus есть почти в каждом Kubernetes-кластере, на собеседованиях по нему спрашивают всегда.

Шаг проекта: «Заметки» получают `GET /metrics` (app.py v5, образ 0.5.0), появляется каталог `monitoring/` со стеком Prometheus, node_exporter и cAdvisor, и Prometheus собирает метрики приложения, хоста и контейнеров.

## Что нужно знать

- [Урок 8.1: наблюдаемость, SLI и SLO](01-observability-slo.md) - три сигнала и то, какие числа нам нужны
- [Урок 4.5: Compose с PostgreSQL](../04-docker/05-compose-postgres.md) - сервисы, тома и сеть Compose
- [Урок 4.6: nginx и TLS перед «Заметками»](../04-docker/06-compose-nginx-tls.md) - сеть `notes-net`, запросы через `https://notes.lab`
- [Урок 4.7: образы и теги](../04-docker/07-images-registry.md) - сборка образа с семантическим тегом
- [Урок 2.4: HTTP](../02-network/04-http.md) - коды ответов, `curl`, демонстрационные `/error` и `/slow`
- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - что происходит с процессом при остановке

## Теория

### Pull-модель: Prometheus сам ходит за метриками

Prometheus работает по схеме pull: раз в `scrape_interval` (интервал сбора, у нас 15 секунд) он делает HTTP GET на адрес цели (target), обычно `/metrics`, разбирает ответ и записывает значения с текущей меткой времени. Приложение ничего не знает о Prometheus, оно лишь отдаёт текущее состояние своих счётчиков.

Три слова, которые путают чаще всего. Цель (target) это один адрес, например `notes:8080`. Задача (job) это группа целей одного вида, например все реплики `notes`. Экземпляр (instance) это конкретный адрес внутри задачи. Prometheus сам добавляет к каждому ряду метки `job` и `instance`.

Главный бонус pull: сам факт сбора даёт метрику `up`. Ответ получен и разобран, `up = 1`. Таймаут, отказ соединения, ошибка HTTP, `up = 0`. Отдельного «пульса» приложению писать не надо. Если цель исчезла, ряд не «застывает» на последнем значении: через 5 минут Prometheus помечает его устаревшим (staleness), и запрос перестаёт его возвращать. Отсюда важное следствие для алертов: условие `метрика > порога` не сработает, если метрика пропала совсем (разберём в 8.5).

> **Проверь понимание:** сервис перестал отвечать. Что в Prometheus покажет это быстрее всего и почему это не надо программировать в самом сервисе?

<details>
<summary>Ответ</summary>

Метрика `up{job="notes"}` станет 0. Её создаёт сам Prometheus по итогам каждого сбора, приложению ничего дописывать не нужно. Если приложение зависло, оно просто не ответит на запрос, и это тоже даст `up = 0`.

</details>

### Формат exposition и четыре типа метрик

Ответ `/metrics` это обычный текст (text exposition format): строки `# HELP` (описание), `# TYPE` (тип) и сами значения `имя{метка="значение"} число`. Его можно прочитать глазами через `curl`, и это главный инструмент отладки.

Типы метрик:

| Тип | Что это | Пример |
|---|---|---|
| counter (счётчик) | только растёт, при рестарте процесса сбрасывается в 0 | `notes_http_requests_total` |
| gauge (датчик) | значение идёт вверх и вниз | `notes_notes_total`, память процесса |
| histogram (гистограмма) | считает наблюдения по корзинам (bucket) с верхней границей `le` | `notes_http_request_duration_seconds` |
| summary (сводка) | квантили считаются на стороне приложения, их нельзя складывать между репликами | редко, в новом коде обычно histogram |

Гистограмма даёт три вида рядов: `_bucket{le="0.1"}` (сколько наблюдений не больше 0.1), `_sum` (сумма всех значений) и `_count` (число наблюдений). Корзины кумулятивные: `le="0.5"` включает всё, что попало в `le="0.1"`. Последняя корзина `le="+Inf"` равна `_count`. Из корзин Prometheus потом оценивает p95 (это тема 8.3), поэтому границы надо выбирать под свои задержки.

Счётчик после рестарта обнуляется. Это нормально: функция `rate()` (8.3) умеет обнаруживать сброс. Смотреть на «голое» значение счётчика бессмысленно, интересна скорость его роста.

> **Проверь понимание:** в гистограмме `_bucket{le="0.5"} 30`, `_bucket{le="1"} 30`, `_count 34`. Что можно сказать о четырёх запросах?

<details>
<summary>Ответ</summary>

30 запросов уложились в 0.5 секунды, а четыре оказались медленнее секунды (34 минус 30, они попали только в корзину `+Inf`). Корзины кумулятивные, поэтому `le="1"` не отличается от `le="0.5"`: между 0.5 и 1 секундой запросов не было.

</details>

### Метки и кардинальность

Метка (label) превращает один рядок метрики в семейство рядов: `notes_http_requests_total{method="GET",path="/notes",status="200"}` и `{...status="500"}` это два разных временных ряда. Метки удобны: можно суммировать по `path`, отфильтровать по `status`.

Но каждая уникальная комбинация значений меток это отдельный ряд в памяти и на диске. Число рядов называется кардинальностью (cardinality). Если положить в метку что-то неограниченное (id пользователя, id запроса, сырой URL с id заметки), рядов станет миллионы, память Prometheus раздуется, и он упадёт по OOM. Правило: значения метки должны быть из короткого конечного списка. Именно поэтому в «Заметках» метка `path` берётся только из фиксированного списка маршрутов, а всё незнакомое превращается в `other`. Сырой URL в метку не попадает никогда.

Уникальность и подробности хороши для логов (8.7) и трейсов (8.8), а метки метрик должны быть скучными.

> **Проверь понимание:** разработчик хочет добавить в `notes_http_requests_total` метку `note_id`, чтобы видеть популярные заметки. Что ответишь?

<details>
<summary>Ответ</summary>

Нельзя: значений столько же, сколько заметок, и каждое даёт новый ряд для каждой комбинации `method/status`. Это взрыв кардинальности. Популярные заметки смотрят в логах или трейсах, а метрика остаётся с ограниченным набором меток.

</details>

### Хранение, exporters и границы pull

Данные Prometheus пишет в собственную базу временных рядов (TSDB, time series database) в каталоге `--storage.tsdb.path`. Срок хранения задаёт `--storage.tsdb.retention.time` (по умолчанию 15 дней). Данные лежат на одном узле: это не долговременное хранилище и не кластер. Для долгого хранения и нескольких кластеров существуют Thanos, Mimir и VictoriaMetrics, но начинают всегда с одного Prometheus и разумного retention.

Не всё умеет отдавать `/metrics` само. Для этого есть экспортёры (exporters): небольшие сервисы, которые читают состояние чужой системы и показывают его в формате Prometheus. Сегодня подключаем два. node_exporter отдаёт метрики хоста: CPU, память, диски, сеть. cAdvisor отдаёт метрики контейнеров: память и CPU каждого. Остальные экспортёры (PostgreSQL, nginx, проверки снаружи через blackbox) разберём в 8.4.

Pull не подходит там, где процесс живёт слишком мало, чтобы его успели опросить (CronJob, разовая задача), или он недоступен из сети Prometheus. Для коротких задач есть Pushgateway: задача при завершении отправляет туда итог, а Prometheus забирает его как обычную цель. Это исключение, а не основной путь.

Как Prometheus узнаёт список целей. У нас он статический: адреса записаны в `prometheus.yml`. В Kubernetes цели находятся автоматически через service discovery (обнаружение служб), этим займёмся в 8.9.

> **Проверь понимание:** скрипт бэкапа работает 40 секунд раз в час. Как получить по нему метрику «время последнего успешного бэкапа»?

<details>
<summary>Ответ</summary>

Скрипт в конце отправляет gauge (например, Unix-время успеха) в Pushgateway, а Prometheus собирает Pushgateway как обычную цель. Прямой pull бесполезен: 15 секунд опроса почти всегда попадут в момент, когда процесса нет.

</details>

## Практика

### Задание 1. Прочитай `/metrics` глазами на игрушечном примере

**Цель:** увидеть формат exposition и понять, как гистограмма превращается в корзины, до того как это станет частью «Заметок».

**Предскажи:** мы запишем в гистограмму четыре значения: 0.05, 0.3, 0.3 и 2.0 секунды, с корзинами 0.1, 0.5 и 1. Какое число будет в `le="0.5"`? А в `le="+Inf"`?

<details>
<summary>Ответ</summary>

В `le="0.5"` будет 3 (0.05 и два по 0.3, корзины кумулятивные), в `le="+Inf"` будет 4 (все наблюдения).

</details>

**Шаги:**

1. Создай отдельный каталог и виртуальное окружение (не в `~/notes`):

   ```bash
   mkdir -p ~/metrics-demo && cd ~/metrics-demo
   python3 -m venv .venv
   .venv/bin/pip install prometheus_client
   ```

2. Создай `demo.py`:

   ```python
   import time
   from prometheus_client import Counter, Gauge, Histogram, start_http_server

   # счётчик с меткой status: два ряда
   REQS = Counter("demo_requests", "Сколько запросов обработано", ["status"])
   # гистограмма с тремя корзинами (плюс автоматическая +Inf)
   LAT = Histogram("demo_latency_seconds", "Время обработки", buckets=(0.1, 0.5, 1))
   # датчик: значение можно ставить любое
   QUEUE = Gauge("demo_queue_size", "Размер очереди")

   start_http_server(8000)  # /metrics на порту 8000

   REQS.labels("200").inc(3)
   REQS.labels("500").inc()
   for value in (0.05, 0.3, 0.3, 2.0):
       LAT.observe(value)
   QUEUE.set(7)

   time.sleep(3600)
   ```

3. Запусти в фоне и прочитай метрики:

   ```bash
   .venv/bin/python demo.py &
   sleep 1
   curl -s localhost:8000/metrics | grep '^demo_' | grep -v _created
   ```

**Что должно получиться:**

```text
demo_requests_total{status="200"} 3.0
demo_requests_total{status="500"} 1.0
demo_latency_seconds_bucket{le="0.1"} 1.0
demo_latency_seconds_bucket{le="0.5"} 3.0
demo_latency_seconds_bucket{le="1.0"} 3.0
demo_latency_seconds_bucket{le="+Inf"} 4.0
demo_latency_seconds_count 4.0
demo_latency_seconds_sum 2.65
demo_queue_size 7.0
```

Последние знаки `_sum` могут отличаться из-за чисел с плавающей точкой. Убери фоновый процесс: `kill %1`.

**Объясни себе:**

- Почему счётчик назван `demo_requests`, а в выводе он `demo_requests_total`?
- Как из этих строк узнать среднее время запроса? (подсказка: `_sum` и `_count`)
- Что изменится в выводе, если сделать `LAT.observe(0.1)`: в какую корзину попадёт значение ровно на границе?

**Типичные ошибки:**

- `OSError: [Errno 98] Address already in use`: порт 8000 занят прошлым запуском демо. Найди процесс `ss -ltnp | grep 8000` и останови его (`kill`), либо смени порт.
- `ModuleNotFoundError: No module named 'prometheus_client'`: запустил системным `python3`, а не `.venv/bin/python`. Пакеты в venv видит только его интерпретатор.
- `error: externally-managed-environment` при `pip install`: ставишь в системный Python. Используй venv, как в шаге 1.

### Задание 2. Подними стек мониторинга и увидь первый target DOWN

**Цель:** запустить Prometheus, node_exporter и cAdvisor в Compose, подключить их к сети «Заметок» и прочитать состояние целей.

**Предскажи:** основной стек «Заметок» работает на образе 0.4.1, там ещё нет `/metrics`. Какой будет статус цели `notes` и что напишет Prometheus в поле ошибки? Как отреагирует `up`?

<details>
<summary>Ответ</summary>

Цель `notes` будет `down`, а `up{job="notes"}` равен 0. Приложение живо и отвечает, но на `/metrics` возвращает 404 (в 4.2 «Заметок» такого пути нет), поэтому текст ошибки: `server returned HTTP status 404 Not Found`. Prometheus считает успехом только ответ 200 с корректным телом.

</details>

**Шаги:**

1. Убедись, что основной стек запущен (без него сеть `notes-net` не существует), из каталога `~/notes`:

   ```bash
   cd ~/notes
   docker compose ps
   ```

2. Создай каталоги и файл `monitoring/compose.yml`:

   ```bash
   mkdir -p monitoring/prometheus
   ```

   ```yaml
   # Стек мониторинга. Основной compose.yml должен быть запущен раньше:
   # сеть notes-net создаёт он, здесь мы к ней только подключаемся.
   services:
     prometheus:
       image: prom/prometheus:v3.15.0
       command:
         - --config.file=/etc/prometheus/prometheus.yml
         - --storage.tsdb.path=/prometheus
         - --storage.tsdb.retention.time=15d
       ports:
         - "9090:9090"
       volumes:
         - ./prometheus:/etc/prometheus:ro
         - prom-data:/prometheus
       restart: unless-stopped

     node_exporter:
       image: prom/node-exporter:v1.12.1
       command:
         - --path.rootfs=/host
       pid: host
       ports:
         - "9100:9100"
       volumes:
         - /:/host:ro,rslave
       restart: unless-stopped

     cadvisor:
       image: gcr.io/cadvisor/cadvisor:v0.60.6
       ports:
         - "8081:8080"  # наружу 8081, внутри сети cAdvisor слушает 8080
       volumes:
         - /:/rootfs:ro
         - /var/run:/var/run:ro
         - /sys:/sys:ro
         - /var/lib/docker/:/var/lib/docker:ro
         - /dev/disk/:/dev/disk:ro
       devices:
         - /dev/kmsg
       restart: unless-stopped

   networks:
     default:
       name: notes-net
       external: true

   volumes:
     prom-data:
   ```

3. Создай `monitoring/prometheus/prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s

   scrape_configs:
     # само приложение: /metrics по умолчанию
     - job_name: notes
       static_configs:
         - targets: ["notes:8080"]

     # метрики хоста
     - job_name: node
       static_configs:
         - targets: ["node_exporter:9100"]

     # метрики контейнеров (внутри сети порт 8080)
     - job_name: cadvisor
       static_configs:
         - targets: ["cadvisor:8080"]
   ```

4. Проверь конфиг до запуска, затем подними стек и через 20 секунд посмотри цели:

   ```bash
   docker run --rm -v "$PWD/monitoring/prometheus:/etc/prometheus:ro" \
     --entrypoint promtool prom/prometheus:v3.15.0 \
     check config /etc/prometheus/prometheus.yml
   docker compose -f monitoring/compose.yml up -d
   sleep 20
   curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"'
   ```

**Что должно получиться:**

```text
Checking /etc/prometheus/prometheus.yml
  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

cadvisor	up	
node	up	
notes	down	server returned HTTP status 404 Not Found
```

Порядок строк может отличаться. Заодно загляни в экспортёры: `curl -s localhost:9100/metrics | grep -E '^node_load1 '` и `curl -s localhost:8081/metrics | grep -c '^container_'`. Открой в браузере `http://localhost:9090/targets` и найди ту же ошибку. Если браузера нет на сервере, пробрось порт: `ssh -L 9090:localhost:9090 <сервер>`.

**Объясни себе:**

- Почему в `prometheus.yml` адрес `notes:8080`, а не `localhost:8080`?
- Почему cAdvisor опрашивается на порту 8080, хотя снаружи он на 8081?
- Зачем монтировать `/` хоста в node_exporter и что бы он показывал без этого?

**Типичные ошибки:**

- `network notes-net declared as external, but could not be found`: основной стек не запущен, сети нет. Запусти `docker compose up -d` в `~/notes`, затем стек мониторинга.
- `Bind for 0.0.0.0:9090 failed: port is already allocated`: порт занят другим контейнером или процессом. Найди `ss -ltnp | grep 9090`.
- `parsing YAML file /etc/prometheus/prometheus.yml: yaml: line 9: did not find expected key`: сбился отступ в `prometheus.yml`. Проверь `promtool check config` (шаг 4).
- `cadvisor` перезапускается и в логах `failed to open /dev/kmsg`: в ВМ нет этого устройства. Убери секцию `devices` и добавь `privileged: true` только для учебного стенда.

### Задание 3. Шаг проекта: `/metrics` в «Заметках», образ 0.5.0

**Цель:** добавить в `app.py` метрики (v5), пересобрать образ 0.5.0, увидеть `up = 1` и зафиксировать состояние тегом `v0.5.0`.

**Предскажи:** мы отправим несколько запросов, включая `/error` и несуществующий путь `/nope`. Под какой меткой `path` будет виден `/nope` и почему?

<details>
<summary>Ответ</summary>

Под `path="other"`. Метка берётся только из фиксированного списка маршрутов, всё остальное схлопывается в `other`, чтобы посторонние URL не размножали ряды. Статус при этом настоящий: 404.

</details>

**Шаги:**

1. Добавь зависимость. Установи пакет в виртуальное окружение проекта и закрепи ту версию, которая поставилась:

   ```bash
   cd ~/notes
   .venv/bin/pip install prometheus_client
   .venv/bin/pip freeze | grep -i prometheus
   ```

   Строку из вывода (`prometheus_client==<версия>`) допиши в `requirements.txt`.

2. В `app.py` добавь импорты и объявления метрик выше класса обработчика:

   ```python
   import time

   from prometheus_client import (CONTENT_TYPE_LATEST, Counter, Gauge,
                                  Histogram, generate_latest)

   # маршруты, которые допустимы в метке path; всё остальное станет "other"
   KNOWN_ROUTES = {"/", "/notes", "/healthz", "/readyz", "/headers", "/slow",
                   "/error", "/leak", "/burn", "/slowsql", "/metrics"}

   HTTP_REQUESTS = Counter(
       "notes_http_requests_total", "Число HTTP-запросов",
       ["method", "path", "status"])
   HTTP_DURATION = Histogram(
       "notes_http_request_duration_seconds", "Длительность запроса, секунды",
       ["method", "path"],
       buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))
   NOTES_TOTAL = Gauge("notes_notes_total", "Сколько заметок сохранено")
   BUILD_INFO = Gauge("notes_build_info", "Версия сборки", ["version"])


   def route_label(path):
       # сырой URL в метку не попадает никогда: только известные маршруты
       return path if path in KNOWN_ROUTES else "other"
   ```

3. В классе обработчика добавь два метода. `parse_request` вызывается после разбора строки запроса и запоминает время старта, а `log_request` вызывается стандартной библиотекой при отправке статуса ответа, там мы записываем метрики и передаём управление прежнему access-логу:

   ```python
       def parse_request(self):
           self._t0 = time.monotonic()
           return super().parse_request()

       def log_request(self, code="-", size="-"):
           path = route_label(urlparse(self.path).path)
           HTTP_REQUESTS.labels(self.command, path, str(code)).inc()
           HTTP_DURATION.labels(self.command, path).observe(
               time.monotonic() - self._t0)
           super().log_request(code, size)
   ```

4. Добавь обработку пути `/metrics` в `do_GET` рядом с остальными маршрутами (тело отправляем с `Content-Length`, как остальные ответы):

   ```python
           if path == "/metrics":
               body = generate_latest()  # весь реестр в текстовом формате
               self.send_response(200)
               self.send_header("Content-Type", CONTENT_TYPE_LATEST)
               self.send_header("Content-Length", str(len(body)))
               self.end_headers()
               self.wfile.write(body)
               return
   ```

5. При старте процесса и при каждой записи обновляй датчики: после инициализации хранилища вызови `BUILD_INFO.labels(APP_VERSION).set(1)` и `NOTES_TOTAL.set(<число заметок>)`, а после успешного `POST /notes` снова `NOTES_TOTAL.set(<число заметок>)`. Полный вариант файла: [versions/v5.py в эталоне](https://github.com/distinguished-sre/devops/tree/devops/project/notes/versions).

6. Пересобери образ и перезапусти сервис. В `compose.yml` у сервиса `notes` укажи `image: notes:0.5.0` рядом с `build: .`, в `.env` поставь `APP_VERSION=0.5.0`:

   ```bash
   docker build -t notes:0.5.0 .
   docker compose up -d notes
   curl -sk https://notes.lab/metrics | grep -E '^(notes_build_info|notes_notes_total)'
   ```

7. Дай Prometheus что посчитать и проверь цель:

   ```bash
   for i in $(seq 10); do curl -sk -X POST https://notes.lab/notes -d '{"text":"метрика"}' >/dev/null; done
   for i in $(seq 3); do curl -sk https://notes.lab/error >/dev/null; done
   for i in $(seq 2); do curl -sk https://notes.lab/nope >/dev/null; done
   sleep 20
   curl -s localhost:9090/api/v1/query \
     --data-urlencode 'query=notes_http_requests_total{path=~"/notes|/error|other"}' \
     | jq -r '.data.result[] | "\(.metric.method) \(.metric.path) \(.metric.status) \(.value[1])"'
   ```

8. Проверь `up` и поведение при остановке сервиса, затем зафиксируй результат:

   ```bash
   docker compose stop notes
   sleep 30
   curl -s localhost:9090/api/v1/query --data-urlencode 'query=up{job="notes"}' | jq -r '.data.result[0].value[1]'
   docker compose start notes
   git add app.py requirements.txt compose.yml monitoring
   git commit -m "Метрики Prometheus: /metrics, monitoring/ (v0.5.0)"
   git tag v0.5.0
   ```

**Что должно получиться:**

```text
notes_build_info{version="0.5.0"} 1.0
notes_notes_total 0.0
POST /notes 201 10
GET /error 500 3
GET other 404 2
0
```

Значение `notes_notes_total` зависит от того, сколько заметок уже записано. После `docker compose start notes` через 15-30 секунд `up{job="notes"}` вернётся в 1, а счётчики `notes_http_requests_total` начнут с нуля: процесс перезапустился. Состояние эталона: app.py v5, образ 0.5.0, тег `v0.5.0`. Метрики доступны и через `https://notes.lab/metrics` (nginx проксирует всё подряд); в реальной среде этот путь закрывают от внешнего мира, к теме вернёмся в 8.4.

**Объясни себе:**

- Почему время старта запоминается в `parse_request`, а не в `handle_one_request`? (подсказка: keep-alive из HTTP/1.1, урок 2.4)
- Почему после `stop` значение `up` стало 0 не сразу, а через один-два интервала сбора?
- Что случилось со счётчиками после рестарта и почему на графике это не должно выглядеть провалом скорости?

**Типичные ошибки:**

- `ModuleNotFoundError: No module named 'prometheus_client'` в логах контейнера: пакет не попал в `requirements.txt` или образ не пересобран. Проверь файл, выполни `docker build` заново.
- `Duplicated timeseries in CollectorRegistry: {'notes_http_requests_total'}`: метрика объявлена дважды (например, объявление попало внутрь метода или файл импортируется повторно). Объявляй метрики один раз на уровне модуля.
- `ValueError: Incorrect label count`: `labels()` вызван с другим числом значений, чем в объявлении. У `Counter` три метки, у `Histogram` две.
- Цель `notes` остаётся `down` с `server returned HTTP status 404 Not Found`: контейнер всё ещё на старом образе. Проверь `docker compose ps` и тег образа, выполни `docker compose up -d notes`.

## Сломай и почини

Запусти скрипт из корня `~/notes` и не читай его: цель в том, чтобы найти причину по симптомам.

```bash
cd ~/notes
./break/8.2/break.sh random
```

Скрипт выберет один из трёх сценариев и что-то сломает в стеке мониторинга или приложении. Твоя задача: описать симптом, назвать не менее двух гипотез, проверить их командами и починить. Подсматривать в `git diff` можно только после того, как нашёл причину.

### Симптом

Стек запущен, но что-то не так с метриками: цель `notes` красная в `/targets`, или `up` показывает 0, или Prometheus стал заметно тяжелее, а его память растёт. Опиши, что именно видишь: текст в поле ошибки цели, значение `up`, число рядов.

### Гипотезы

Составь список причин, которые дают такой симптом, и проверь их в порядке дешевизны. Например: цель недоступна по сети; путь `/metrics` отдаёт не 200; приложение отдаёт слишком много рядов; конфиг Prometheus не перечитан.

### Проверки

Порядок диагностики:

```bash
# 1. что говорит сам Prometheus о цели (health и lastError)
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"'
# 2. отвечает ли приложение изнутри сети мониторинга
docker compose -f monitoring/compose.yml exec prometheus wget -qO- http://notes:8080/metrics | head -5
# 3. сколько рядов у метрики приложения
curl -s localhost:9090/api/v1/query \
  --data-urlencode 'query=count({__name__=~"notes_.*"})' | jq -r '.data.result[0].value[1]'
# 4. какие метрики самые жирные
curl -s localhost:9090/api/v1/status/tsdb | jq -r '.data.seriesCountByMetricName[:5][] | "\(.name) \(.value)"'
```

### Исправление

<details>
<summary>Разбор трёх сценариев</summary>

**Сценарий 1. `connection refused`.** В `lastError` видно `Get "http://notes:8080/metrics": dial tcp 172.18.0.4:8080: connect: connection refused`. Имя резолвится (контейнер есть), но порт никто не слушает: приложение запущено на другом порту или не слушает вовсе. Проверь `docker compose logs notes` и переменную `PORT`, верни 8080. Если в ошибке `no such host`, то контейнера нет в сети `notes-net`. Правка после восстановления: `docker compose up -d notes`, через 15-30 секунд `up = 1`.

**Сценарий 2. Неверный `metrics_path`.** Цель `down` с `server returned HTTP status 404 Not Found`, хотя приложение живо и `curl` на `/metrics` внутри контейнера даёт 200. В `prometheus.yml` у job появилось `metrics_path: /metric` (или другое неверное имя). Исправь путь (по умолчанию он `/metrics`, ключ можно вовсе убрать), затем проверь конфиг `promtool check config` и перечитай его: `docker compose -f monitoring/compose.yml restart prometheus`. Признак, что дело в конфиге, а не в сервисе: `curl` руками работает, а Prometheus видит 404.

**Сценарий 3. Взрыв кардинальности.** Цель `up`, но `count({__name__=~"notes_.*"})` растёт с каждой минутой, а `seriesCountByMetricName` показывает `notes_http_requests_total` с тысячами рядов. В приложении в метку `path` попал сырой URL или появилась метка вроде `user_id`. Починка: вернуть `route_label(...)` вместо сырого пути, пересобрать образ, перезапустить сервис. Уже созданные ряды не исчезнут сразу: они станут устаревшими и уйдут после retention, а чтобы очистить сразу на стенде, выполни `docker compose -f monitoring/compose.yml down -v` (удалит том `prom-data` и всю историю). Главный вывод: метки метрик должны иметь конечный список значений.

</details>

Верни репозиторий в чистое состояние (`git status`, `git restore .` для незакоммиченных правок) и убедись, что все три цели `up`.

## Вопросы с собеседований

### 1. [junior] Коллега предлагает слать метрики из cron-скрипта прямо в Prometheus. Что скажешь?

Prometheus сам забирает метрики по HTTP (pull), принимать «пуш» напрямую он не умеет. Скрипт живёт секунды, его не успеют опросить. Для таких задач в конце скрипта отправляют итог в Pushgateway, а Prometheus собирает уже Pushgateway. Но это для коротких задач, обычные сервисы остаются на pull.

**Что хотят услышать:** pull-модель, Pushgateway для короткоживущих задач, оговорку, что у Pushgateway нет автоматической очистки старых значений и `up` показывает живость шлюза, а не задачи.

**Красный флаг:** «просто поставим там push вместо pull» без понимания, зачем Prometheus ходит сам.

### 2. [junior] В Prometheus цель красная (DOWN). Твои действия

Сначала смотрю страницу `/targets` и текст `lastError`. `connection refused` значит, что процесс не слушает порт; `no such host` значит, что нет имени в сети; `context deadline exceeded` значит, что цель не успела ответить за таймаут; `404` значит, что неверный `metrics_path`. Потом иду `curl`-ом к цели из той же сети, где работает Prometheus.

**Что хотят услышать:** разбор по тексту ошибки, проверка из сети самого Prometheus (а не с ноутбука), сверка порта и `metrics_path`, статус `up`.

**Красный флаг:** «перезапущу Prometheus» без чтения ошибки.

### 3. [junior] Чем counter отличается от gauge и что у них происходит при рестарте процесса?

Counter только растёт: число запросов, число ошибок. Gauge показывает текущее значение: размер очереди, память. При рестарте процесса счётчик сбрасывается в 0, датчик принимает новое текущее значение. Поэтому по счётчику смотрят `rate()`, а не значение.

**Что хотят услышать:** примеры для каждого типа, сброс счётчика, что `rate` его обрабатывает.

**Красный флаг:** «счётчик может уменьшаться» или использование gauge для числа запросов.

### 4. [junior] После деплоя график `requests_total` упал в ноль. Это баг?

Скорее всего нет: процесс перезапустился, и счётчик обнулился. `rate()` и `increase()` замечают такой сброс и не показывают провала. Проверяю, что цель снова `up`, и смотрю на скорость запросов, а не на сырое значение.

**Что хотят услышать:** сброс счётчика, `rate` против сырого значения, проверка `up` и времени старта процесса.

**Красный флаг:** «откатим релиз», не посмотрев на график скорости.

### 5. [middle] Prometheus падает по OOM. Память растёт после вчерашнего релиза. Что делаешь?

Подозреваю рост кардинальности: в метку попало что-то неограниченное. Смотрю число рядов и самые «тяжёлые» метрики: страница `/status` TSDB в UI или `/api/v1/status/tsdb`, запрос `topk(10, count by (__name__)({__name__=~".+"}))`. Нахожу метрику и метку, откатываю или исправляю код, чтобы значения были из конечного списка. Временно поднимаю лимит памяти, но это не лечение.

**Что хотят услышать:** кардинальность, `seriesCountByMetricName`, связь с релизом, чистка на стороне приложения, а не «добавить памяти». Плюс упоминание, что можно ограничить ряды на цель параметром `sample_limit`.

**Красный флаг:** «увеличу память и retention», без поиска причины.

### 6. [middle] Алерт «ошибок больше порога» молчит, а сервис лежит. Почему?

Если сервис не отвечает, ряды `notes_http_requests_total` перестают приходить и через 5 минут устаревают. Выражение `... > порога` на пустом множестве ничего не возвращает, и алерт не срабатывает. Пропажу ловят отдельным алертом на `up == 0` (или на `absent()`), это обязательная пара к алертам по значениям.

**Что хотят услышать:** staleness, пустой результат вместо нуля, `up == 0`, `absent`, `for`.

**Красный флаг:** «у алерта неправильный порог».

### 7. [middle] Какие корзины выбрать для гистограммы задержек и что будет, если выбрать плохо?

Корзины должны покрывать реальные задержки и границы SLO (например, есть корзина ровно на пороге 0.5 с). Если все запросы по 20 мс, а первая корзина 100 мс, то p95 окажется где-то внутри неё, оценка будет грубой (квантиль вычисляется интерполяцией внутри корзины). Слишком много корзин раздувают число рядов: каждая корзина это ряд на каждую комбинацию меток.

**Что хотят услышать:** интерполяция внутри корзины, корзина на границе SLO, цена за каждую корзину, что менять корзины потом больно.

**Красный флаг:** «корзины любые, Prometheus разберётся».

### 8. [middle] Единственный Prometheus упал ночью, на графиках дыра. Как сделать надёжнее?

Первый шаг: два одинаковых Prometheus, которые собирают одни и те же цели независимо (HA-пара), с постоянным диском и алертом на `up` самого Prometheus. Вторая проблема: данные у каждого свои, а графики надо смотреть с одного из них. Для долгого хранения и единого запроса добавляют Thanos, Mimir или VictoriaMetrics с записью в объектное хранилище (remote write). Начинаю с одного узла и разумным retention, пока он не упирается в объём.

**Что хотят услышать:** независимые реплики, а не кластер; персистентный том; внешнее хранилище для долгой истории; не усложнять раньше времени.

**Красный флаг:** «Prometheus кластеризуется из коробки».

### 9. [middle] Метрики CronJob пропадают, между запусками в Prometheus пусто. Что делать?

Задача живёт слишком мало, поэтому её не успевают опросить. Решение: Pushgateway. Джоб перед завершением отправляет туда gauge `last_success_timestamp` и длительность, Prometheus забирает их у шлюза. Алерт строится на возрасте последнего успеха, а не на самой метрике.

**Что хотят услышать:** Pushgateway, метрику «время последнего успеха», оговорку про застывшие значения, алерт по возрасту.

**Красный флаг:** «уменьшим scrape_interval до секунды».

### 10. [middle] Аудит показал, что `/metrics` доступен всем из интернета через nginx. Это проблема?

Да: там имена маршрутов, версии, счётчики, иногда внутренние адреса и состояние процесса. Это разведка для атакующего. Закрываю `/metrics` на прокси (отдельный `location` с `deny` или доступ только из сети мониторинга), а Prometheus продолжает ходить к приложению напрямую по внутренней сети.

**Что хотят услышать:** `/metrics` это внутренний интерфейс, закрытие на уровне прокси, отдельный порт или сеть, а не аутентификация «чтобы было».

**Красный флаг:** «метрики не секретные, пусть будут открыты».

## Проверено на версиях

- Prometheus: v3.15.0
- node_exporter: v1.12.1
- cAdvisor: v0.60.6
- prometheus_client (Python): версия не закреплена, проверь актуальную версию на странице проекта
- Python: 3.13
- Docker Compose: без ключа `version:`, версия плагина не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею объяснить, почему Prometheus собирает метрики сам (pull) и что означает `up`
- [ ] умею прочитать `/metrics` руками и разобрать `# HELP`, `# TYPE`, корзины гистограммы
- [ ] умею отличить counter, gauge и histogram и выбрать тип под задачу
- [ ] умею поднять Prometheus, node_exporter и cAdvisor в Compose и подключить их к сети «Заметок»
- [ ] умею проверить конфиг через `promtool check config` и по `lastError` найти причину DOWN
- [ ] умею добавить `/metrics` в приложение с ограниченным набором значений меток
- [ ] умею находить взрыв кардинальности по числу рядов и `status/tsdb`

**Дальше:** [Урок 8.3: PromQL: rate, агрегации, квантили](03-promql.md)
