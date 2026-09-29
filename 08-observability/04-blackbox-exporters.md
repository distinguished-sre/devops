---
layout: lesson
title: "Проверки снаружи: blackbox и exporters"
topic: 8
lesson: "8.4"
time: "1.5 ч"
---

## Зачем это нужно

Приложение может честно показывать `notes_http_requests_total` и `up == 1`, а пользователь при этом видит ошибку: истёк сертификат, nginx не стартовал, DNS указывает не туда, порт закрыт файрволом. Метрики из `/metrics` (8.2) это взгляд изнутри. Проверка снаружи (blackbox monitoring) делает то же, что пользователь: резолвит имя, открывает TCP, проходит TLS, отправляет HTTP-запрос и смотрит на ответ.

На работе это первый алерт, который просыпается при настоящей аварии, и единственный, который ловит «всё зелёное, а сайта нет». Ещё здесь нужно уметь брать метрики у программ, которые сами не умеют `/metrics`: для этого нужны exporters.

Шаг проекта: в `monitoring/` появляется blackbox_exporter на порту 9115 с тремя модулями, а Prometheus начинает проверять `https://notes.lab` снаружи.

## Что нужно знать

- [Урок 8.2: Prometheus и /metrics](02-prometheus-basics.md) - scrape, targets, `prometheus.yml`, `up`.
- [Урок 8.3: PromQL](03-promql.md) - `avg_over_time`, агрегации, чтение результата запроса.
- [Урок 8.1: SLI и SLO](01-observability-slo.md) - доступность как SLI, зачем нужен взгляд пользователя.
- [Урок 2.4: HTTP и curl](../02-network/04-http.md) - коды ответов, `curl -w`.
- [Урок 2.6: TLS](../02-network/06-tls.md) - сертификат, срок, цепочка доверия, самоподписанный сертификат.
- [Урок 2.8: путь запроса](../02-network/08-request-path-troubleshooting.md) - слои: DNS, порт, TLS, HTTP.
- [Урок 4.6: Compose, nginx и TLS](../04-docker/06-compose-nginx-tls.md) - сервисы `proxy`, `notes`, `db`, сеть `notes-net`, `deploy/tls`.

## Теория

### Изнутри и снаружи

Метрика приложения отвечает на вопрос «что процесс думает о себе». Она не знает, дошёл ли до него запрос. Пока Prometheus ходит на `notes:8080/metrics` по внутренней сети `notes-net`, он никак не проходит через `proxy`, TLS и DNS, а пользователь проходит.

Отсюда два вида наблюдения:

- **whitebox** (белый ящик): приложение само отдаёт внутренние метрики, это `/metrics` из 8.2. Показывает причины: очередь, ошибки, время SQL.
- **blackbox** (чёрный ящик): внешний наблюдатель делает запрос и смотрит на результат. Показывает симптом: работает или нет, как быстро, когда истекает сертификат.

Хороший мониторинг использует оба. Алерт «сайт недоступен» берут из blackbox (он не зависит от того, что приложение о себе думает), а разбираться идут по whitebox-метрикам.

> **Проверь понимание:** приложение перезапустили с ошибкой в конфиге nginx. `up{job="notes"}` равен 1, ошибки 5xx в метриках нулевые, пользователи получают отказ. Почему метрики приложения молчат?

<details>
<summary>Ответ</summary>

Prometheus собирает метрики напрямую с `notes:8080`, минуя nginx. Приложение живо и никаких запросов не получает, поэтому счётчики ошибок не растут. Отказ случается на слое, которого приложение не видит. Только проверка через тот же адрес, что использует пользователь (`https://notes.lab`), это заметит.

</details>

### Как работает blackbox_exporter

blackbox_exporter (далее blackbox) это отдельный сервис, который по запросу выполняет проверку и отдаёт результат как метрики. Он ничего не собирает сам. Prometheus обращается к нему так:

```text
http://blackbox:9115/probe?target=https://notes.lab/healthz&module=http_2xx_tls
```

Параметры: `target` (что проверять) и `module` (как проверять). Ответ это обычные метрики на один проход проверки:

- `probe_success` - 1 или 0, итог проверки;
- `probe_duration_seconds` - сколько заняла вся проверка;
- `probe_http_status_code` - код ответа;
- `probe_http_ssl` - был ли TLS;
- `probe_ssl_earliest_cert_expiry` - время истечения самого раннего сертификата в цепочке (Unix time);
- `probe_dns_lookup_time_seconds` - время DNS;
- `probe_http_duration_seconds{phase="..."}` - разбивка по фазам: `resolve`, `connect`, `tls`, `processing`, `transfer`.

Модули описываются в `blackbox.yml`: `http` (HTTP и HTTPS), `tcp` (просто открыть порт), `icmp` (ping, требует прав), `dns`, `grpc`. Модуль это набор правил: какие коды считать успехом, проверять ли TLS, какое тело ожидать.

### Multi-target pattern: relabeling

Prometheus должен передать blackbox адрес цели. Для этого в `scrape_configs` используется `relabel_configs`: то, что записано в `targets`, переезжает в параметр `target`, а реальный адрес scrape становится адресом blackbox.

```yaml
scrape_configs:
  - job_name: blackbox
    metrics_path: /probe
    params:
      module: [http_2xx_tls]
    static_configs:
      - targets:
          - https://notes.lab/healthz
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target     # цель уходит в ?target=
      - source_labels: [__param_target]
        target_label: instance           # в метриках instance = проверяемый URL
      - target_label: __address__
        replacement: blackbox:9115       # реально ходим в blackbox
```

Запомни порядок: сначала адрес цели копируется в параметр, потом в `instance`, и только потом `__address__` подменяется. Без подмены `__address__` Prometheus будет пытаться сам открыть `/probe` на `https://notes.lab/healthz`, а без `instance` все проверки сольются в одну серию с адресом blackbox.

### Что проверять и как выбирать цели

Проверяй то, что делает пользователь, и на слое, где он входит:

| Проверка | Модуль | Что ловит |
|---|---|---|
| `https://notes.lab/healthz` | `http_2xx_tls` | DNS, порт 443, сертификат, nginx, приложение живо |
| `https://notes.lab/readyz` | `http_2xx_tls` | то же плюс готовность хранилища (БД) |
| `http://notes:8080/healthz` | `http_2xx` | приложение напрямую, без nginx (сузить место отказа) |
| `db:5432` | `tcp_connect` | порт PostgreSQL открыт (внутренняя зависимость) |

Пара «через nginx» и «напрямую» сразу локализует отказ: если внешняя красная, а прямая зелёная, проблема между пользователем и приложением (nginx, TLS, DNS, файрвол).

Срок сертификата тоже проверка снаружи: `probe_ssl_earliest_cert_expiry - time()` даёт секунды до истечения. Про то, почему сертификаты подводят чаще, чем кажется, смотри урок 2.6.

> **Проверь понимание:** внешняя проверка `https://notes.lab/healthz` красная, а `http://notes:8080/healthz` зелёная. Куда идти?

<details>
<summary>Ответ</summary>

Приложение здоровое, значит смотрим слои перед ним: работает ли контейнер `proxy`, отвечает ли порт 443, не истёк ли сертификат, резолвится ли `notes.lab`, что в логе nginx. Действуй по слоям из урока 2.8.

</details>

### Exporters: метрики у тех, кто не умеет /metrics

Postgres, Linux, nginx, Redis не отдают метрики в формате Prometheus. Для них есть exporters: маленькая программа рядом с целью, которая читает внутренности (файлы, статистику, API) и публикует `/metrics`. Ты уже использовал два:

- `node_exporter` (9100) читает `/proc` и `/sys` хоста: CPU, память, диск, сеть;
- `cAdvisor` (8081) читает cgroups и показывает потребление контейнеров.

Есть и другие: `postgres_exporter`, `nginx-prometheus-exporter`, `redis_exporter`. Правила одни: exporter запускают рядом с целью (тот же хост или сеть), у него свой порт, Prometheus добавляет его как обычный job. Для своих скриптов есть textfile collector в `node_exporter`: скрипт пишет `.prom` файл, node_exporter его отдаёт. Так метрики получают, например, от cron-задачи бэкапа.

Blackbox это тоже exporter, но особый: он делает проверки по запросу, а не публикует состояние одной цели.

### Zabbix и Prometheus: вставка для сравнения

Ты можешь прийти на работу, где стоит Zabbix. Это нормально, вот главные отличия:

| | Zabbix | Prometheus |
|---|---|---|
| Модель | агент на хосте (чаще push), сервер и БД | pull: сервер сам ходит на цели |
| Данные | items, triggers, шаблоны на хосты | метрики с лейблами, PromQL |
| Динамика (контейнеры, поды) | discovery-правила, тяжелее | service discovery, лейблы из коробки |
| Алерты | триггеры в самом Zabbix | правила в Prometheus, доставка в Alertmanager (8.5) |
| Сильная сторона | инвентарь, SNMP, «классическая» инфраструктура | облако, контейнеры, Kubernetes |

Проверки «порт открыт» и «HTTP отвечает» Zabbix умеет как простые проверки (simple checks) и как веб-сценарии. Blackbox в Prometheus это их аналог. Различие в подходе: в Prometheus проверка это метрика, из которой строятся запросы, SLO и алерты одной и той же PromQL.

## Практика

Перед началом: основной стек из урока 4.6 запущен (`proxy`, `notes`, `db`, сеть `notes-net`), мониторинг из 8.2 работает, в `/etc/hosts` есть `127.0.0.1 notes.lab`, сертификат лежит в `~/notes/deploy/tls/notes.crt`.

### Задание 1. Запустить blackbox_exporter и дёрнуть его вручную

**Цель:** поднять blackbox, написать модули и вызвать `/probe` руками с `debug=true`.

**Предскажи:** какие модули должны быть в `blackbox.yml`, чтобы `https://notes.lab` с самоподписанным сертификатом прошёл проверку? Что вернёт `probe_success` для модуля без указанного сертификата?

<details>
<summary>Ответ</summary>

Нужен модуль `http` с `tls_config.ca_file`, указывающим на `notes.crt`. Модуль без доверенного сертификата вернёт `probe_success 0`: blackbox проверяет TLS так же строго, как curl без `-k`.

</details>

**Шаги:**

1. Создай конфигурацию модулей:

   ```bash
   mkdir -p monitoring/blackbox
   cat > monitoring/blackbox/blackbox.yml <<'YAML'
   modules:
     # HTTP без TLS-требований: для внутренних адресов вида http://notes:8080
     http_2xx:
       prober: http
       timeout: 5s
       http:
         valid_status_codes: []      # пусто = любой 2xx
         method: GET
         follow_redirects: true
         preferred_ip_protocol: ip4
     # HTTPS с проверкой сертификата: наш самоподписанный сертификат служит и CA
     http_2xx_tls:
       prober: http
       timeout: 5s
       http:
         valid_status_codes: []
         method: GET
         follow_redirects: true
         fail_if_not_ssl: true       # если ответ пришёл без TLS, проверка красная
         preferred_ip_protocol: ip4
         tls_config:
           ca_file: /etc/blackbox/notes.crt
     # Просто открыть TCP-порт (PostgreSQL и подобное)
     tcp_connect:
       prober: tcp
       timeout: 5s
   YAML
   ```

2. Добавь сервис в `monitoring/compose.yml` (в раздел `services:`, рядом с остальными; сеть `notes-net` там уже подключена как внешняя):

   ```yaml
     blackbox:
       image: prom/blackbox-exporter:v0.28.0
       command:
         - --config.file=/etc/blackbox/blackbox.yml
       volumes:
         - ./blackbox/blackbox.yml:/etc/blackbox/blackbox.yml:ro
         - ../deploy/tls/notes.crt:/etc/blackbox/notes.crt:ro
       extra_hosts:
         # notes.lab внутри контейнера указывает на хост, где опубликованы 80 и 443
         - "notes.lab:host-gateway"
       ports:
         - "127.0.0.1:9115:9115"
       restart: unless-stopped
   ```

3. Сначала убедись руками, что сертификат работает как CA (curl без `--cacert` вернёт `curl: (60) SSL certificate problem: self-signed certificate`), затем подними blackbox и вызови пробу:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' --cacert deploy/tls/notes.crt https://notes.lab/healthz
   docker compose -f monitoring/compose.yml up -d blackbox
   curl -s 'http://localhost:9115/probe?target=https://notes.lab/healthz&module=http_2xx_tls' \
     | grep -E '^probe_(success|http_status_code|http_ssl|duration_seconds)'
   ```

4. Отладочный режим, если что-то красное:

   ```bash
   curl -s 'http://localhost:9115/probe?target=https://notes.lab/healthz&module=http_2xx_tls&debug=true' | tail -15
   ```

**Что должно получиться:**

```text
probe_duration_seconds 0.019
probe_http_ssl 1
probe_http_status_code 200
probe_success 1
```

**Объясни себе:**
- Почему контейнеру нужен `extra_hosts` и почему не помогает запись в `/etc/hosts` хоста?
- Почему `ca_file` смонтирован только для чтения?
- Что покажет `probe_success` для модуля `http_2xx` на тот же `https://notes.lab/healthz`? Проверь и объясни.

**Типичные ошибки:**
- `no such file or directory: /etc/blackbox/notes.crt` в `debug`-выводе: файл сертификата не смонтирован или пути не совпали: проверь `../deploy/tls/notes.crt` относительно `monitoring/`.
- `x509: certificate signed by unknown authority`: используется модуль без `ca_file` (например, `http_2xx`): выбери `http_2xx_tls`.
- `yaml: unmarshal errors` при старте blackbox: отступы в `blackbox.yml`: проверь пробелами, не табами; `docker compose -f monitoring/compose.yml logs blackbox`.

### Задание 2. Подключить пробы в Prometheus и читать метрики

**Цель:** Prometheus сам проверяет `notes.lab`; ты видишь результат в PromQL.

**Предскажи:** сколько серий `probe_success` получится, если в `targets` четыре адреса, и чем они будут отличаться?

<details>
<summary>Ответ</summary>

Четыре серии, различаются лейблом `instance` (проверяемый URL, благодаря relabeling). Если пропустить подмену `instance`, все цели получат `instance="blackbox:9115"`, и серии будут отличаться только лейблом `module`.

</details>

**Шаги:**

1. Добавь три job в конец `scrape_configs` в `monitoring/prometheus/prometheus.yml` (рядом с `notes`, `node`, `cadvisor`; отступ два пробела, как у соседних):

   ```yaml
     # Проверки снаружи по HTTPS: путь пользователя через nginx
     - job_name: blackbox-https
       metrics_path: /probe
       params:
         module: [http_2xx_tls]
       static_configs:
         - targets:
             - https://notes.lab/healthz
             - https://notes.lab/readyz
       relabel_configs:
         - source_labels: [__address__]
           target_label: __param_target
         - source_labels: [__param_target]
           target_label: instance
         - target_label: __address__
           replacement: blackbox:9115
     # Проверка приложения напрямую, без nginx: сужает место отказа
     - job_name: blackbox-direct
       metrics_path: /probe
       params:
         module: [http_2xx]
       static_configs:
         - targets:
             - http://notes:8080/healthz
       relabel_configs:
         - source_labels: [__address__]
           target_label: __param_target
         - source_labels: [__param_target]
           target_label: instance
         - target_label: __address__
           replacement: blackbox:9115
     # Порт PostgreSQL (тот же шаблон relabel_configs, модуль tcp_connect)
     - job_name: blackbox-tcp
       metrics_path: /probe
       params:
         module: [tcp_connect]
       static_configs:
         - targets: [db:5432]
       relabel_configs:
         - source_labels: [__address__]
           target_label: __param_target
         - source_labels: [__param_target]
           target_label: instance
         - target_label: __address__
           replacement: blackbox:9115
   ```

2. Проверь конфиг и перезагрузи Prometheus:

   ```bash
   docker compose -f monitoring/compose.yml exec prometheus promtool check config /etc/prometheus/prometheus.yml
   docker compose -f monitoring/compose.yml restart prometheus
   ```

3. Подожди 30 секунд и посмотри цели: `http://localhost:9090/targets`, затем запросы в `http://localhost:9090/graph`:

   ```promql
   probe_success
   ```

   ```promql
   probe_http_duration_seconds{instance="https://notes.lab/healthz"}
   ```

   ```promql
   (probe_ssl_earliest_cert_expiry{instance="https://notes.lab/healthz"} - time()) / 86400
   ```

   ```promql
   avg_over_time(probe_success{job="blackbox-https"}[5m])
   ```

**Что должно получиться:**

```text
probe_success{instance="https://notes.lab/healthz", job="blackbox-https"}   1
probe_success{instance="https://notes.lab/readyz", job="blackbox-https"}    1
probe_success{instance="http://notes:8080/healthz", job="blackbox-direct"}  1
probe_success{instance="db:5432", job="blackbox-tcp"}                       1
```

Третий запрос вернёт около 364 (дней до истечения сертификата; у тебя число по дате выпуска). Четвёртый запрос даёт долю успешных проверок за 5 минут, у здорового стека 1.

**Объясни себе:**
- Чем `up{job="blackbox-https"}` отличается от `probe_success{job="blackbox-https"}`? Что каждая метрика говорит?
- Зачем `avg_over_time(probe_success[5m])`, если можно смотреть `probe_success`?
- Почему `blackbox-direct` и `blackbox-https` вынесены в разные job?

**Типичные ошибки:**
- `Error loading config ... field module not found in type config.ScrapeConfig`: `module` написан на уровне job, а не внутри `params`: перенеси в `params: module: [...]`.
- Все серии с `instance="blackbox:9115"`: нет правила `source_labels: [__param_target]` -> `instance`: добавь.
- Target в состоянии DOWN и `connection refused` на `blackbox:9115`: blackbox не в сети `notes-net` или не запущен: `docker compose -f monitoring/compose.yml ps blackbox`.
- `probe_success 0` при рабочем `curl` с хоста: контейнер не резолвит `notes.lab` или не доверяет сертификату: смотри `debug=true`.

### Задание 3. Шаг проекта: проверки «Заметок» снаружи под контролем git

**Цель:** зафиксировать blackbox в репозитории и убедиться, что проверка красная при настоящем отказе.

**Предскажи:** остановим только `notes` (приложение). Какие из четырёх проб станут красными, какие останутся зелёными? Потом остановим только `proxy`: как изменится картина?

<details>
<summary>Ответ</summary>

Без `notes`: красными станут `notes.lab/healthz` (nginx вернёт 502), `notes.lab/readyz` и прямая проба `notes:8080` (контейнера нет, имя не резолвится). Зелёной останется TCP-проба `db:5432`. Без `proxy`: красные обе HTTPS-пробы (порт 443 закрыт), зелёные прямая `notes:8080` и `db:5432`. По сочетанию красных и зелёных видно, какой слой упал.

</details>

**Шаги:**

1. Убедись, что стек здоров, и все четыре пробы равны 1 (запрос `min(probe_success)` должен дать 1).

2. Останови приложение и через 40 секунд посмотри пробы:

   ```bash
   docker compose stop notes
   sleep 40
   curl -s 'http://localhost:9090/api/v1/query?query=probe_success' \
     | jq -r '.data.result[] | "\(.metric.instance) \(.value[1])"'
   docker compose start notes
   ```

3. То же для `proxy` (`docker compose stop proxy`, пауза, тот же запрос, `docker compose start proxy`). Сверь с предсказанием.

4. Зафиксируй в git:

   ```bash
   git add monitoring/blackbox/blackbox.yml monitoring/compose.yml monitoring/prometheus/prometheus.yml
   git commit -m "Add blackbox_exporter probes for notes.lab"
   ```

**Что должно получиться:**

```text
https://notes.lab/healthz 0
https://notes.lab/readyz 0
http://notes:8080/healthz 0
db:5432 1
```

Это вывод для остановленного `notes`. Порядок строк может отличаться. После `start` через минуту всё снова 1.

**Объясни себе:**
- Как по одной картине красных и зелёных определить слой отказа?
- Почему внешний алерт должен опираться на HTTPS-пробу, а не на прямую?

**Типичные ошибки:**
- Значения остались 1 после `stop`: не подождал минимум один интервал (15 секунд) плюс timeout: подожди ещё 30 секунд.

## Сломай и почини

Запусти сценарий из корня репозитория и ничего не читай в скрипте:

```bash
cd ~/notes
bash break/8.4/break.sh random
```

Скрипт что-то меняет в blackbox, Prometheus или стеке. Твоя задача найти причину и вернуть все четыре пробы в 1.

### Симптом

В Prometheus одна или несколько проб показывают `probe_success 0`, хотя в браузере `https://notes.lab` открывается (или наоборот, красная проба при живом приложении).

### Гипотезы

Составь список до того, как что-то менять. Например:

- сертификат не принят: истёк, не тот, blackbox ему не доверяет;
- в job указан модуль, которого нет, или модуль не подходит цели;
- цель недоступна из сети контейнера blackbox (имя не резолвится, порт закрыт);
- отказал слой между пользователем и приложением (nginx, порт), а приложение живо.

### Проверки

1. Какая проба красная и какие зелёные: `probe_success`. По сочетанию определи слой.
2. Отладочный вывод blackbox для красной цели: `curl -s 'http://localhost:9115/probe?target=<URL>&module=<модуль>&debug=true' | tail -20`. Ищи слова `x509`, `no such host`, `connection refused`, `unknown module`.
3. Лог blackbox: `docker compose -f monitoring/compose.yml logs --tail 30 blackbox`.
4. Та же проверка руками с хоста (`curl --cacert`) и состояние стека: `docker compose ps`.

### Исправление

<details>
<summary>Разбор сценариев</summary>

**Сценарий 1: `probe_success 0` из-за TLS.** В `debug` виден `x509: certificate signed by unknown authority` или `x509: certificate has expired`. Причины: убран `ca_file` из модуля `http_2xx_tls`, сертификат перевыпущен (новый `notes.crt` не тот, что смонтирован) или истёк. Починка: верни `tls_config.ca_file: /etc/blackbox/notes.crt`, проверь, что монтируется актуальный файл, и перезапусти blackbox (`docker compose -f monitoring/compose.yml restart blackbox`). Не лечи это `insecure_skip_verify: true`: проба перестанет видеть проблемы сертификата, ради которых она нужна.

**Сценарий 2: неверный module.** В `debug` или в логе: `unknown module "http_2xx_tsl"` (опечатка) либо модуль `tcp_connect` на HTTP-адрес. Prometheus показывает `probe_success 0` и часто отсутствие `probe_http_status_code`. Починка: в `params.module` укажи существующий модуль из `blackbox.yml`; тип модуля должен соответствовать цели (http для URL, tcp для `host:port`). Перезагрузи Prometheus.

**Сценарий 3: проверка снаружи красная при живом приложении.** Прямая проба `notes:8080` зелёная, внешние красные. Причины: остановлен или сломан `proxy`, неверный конфиг nginx, закрыт порт 443, сертификат не смонтирован. `docker compose ps` покажет `proxy` не в состоянии `running`, лог nginx объяснит причину (например, `cannot load certificate`). Починка: исправь конфиг или верни сертификат, `docker compose up -d proxy`. Вывод: метрики приложения не заметили бы этой аварии, а blackbox заметил.

</details>

## Вопросы с собеседований

### 1. [junior] Чем blackbox-мониторинг отличается от whitebox и зачем нужны оба?

Whitebox это метрики изнутри приложения (`/metrics`): показывают причину, например рост ошибок или задержку SQL. Blackbox это проверка снаружи, как пользователь: показывает симптом, то есть работает или нет. Алерт «недоступно» строю по blackbox, потому что он не зависит от того, что приложение думает о себе, а разбираться иду по whitebox.

**Что хотят услышать:** симптом и причина, независимость проверки, реальный пример (nginx упал, приложение живо).

**Красный флаг:** «blackbox это когда ничего не знаем о системе» без примера.

### 2. [middle] Дашборд зелёный, `up == 1`, ошибок 5xx нет, а клиенты жалуются, что сайт не открывается. Твои действия?

Первым делом проверяю внешнюю пробу и иду тем же путём, что пользователь: DNS (`getent hosts`), порт (`nc -z`), TLS (`openssl s_client`, срок сертификата), потом HTTP через `curl -v`. Метрики приложения могут молчать, если запросы до него не доходят. Сравниваю внешнюю пробу с прямой: если прямая зелёная, ищу проблему в nginx, TLS, DNS или файрволе.

**Что хотят услышать:** слои, сравнение внешнего и внутреннего, срок сертификата, наличие blackbox-проб.

**Красный флаг:** «перезапущу приложение» без диагностики.

### 3. [middle] `probe_success 0` при том, что `curl` с твоей машины отвечает 200. Почему так бывает?

Blackbox работает из своего контейнера, а не с моей машины. Разница может быть в DNS (имя не резолвится в его сети), в доверии к сертификату (у контейнера свой набор CA), в маршруте или файрволе, в таймауте, в заголовках. Смотрю `probe` с `debug=true`: там точная ошибка, например `x509: certificate signed by unknown authority` или `no such host`.

**Что хотят услышать:** проба выполняется в другом окружении, `debug=true`, TLS и DNS как частые причины.

**Красный флаг:** «включу `insecure_skip_verify` и всё» как первая реакция.

### 4. [junior] Как Prometheus передаёт blackbox, что именно проверять?

Через параметры `/probe`: `target` и `module`. В `scrape_config` цель пишут в `targets`, а `relabel_configs` переносят её в `__param_target`, копируют в `instance` и подменяют `__address__` на адрес blackbox.

**Что хотят услышать:** `__param_target`, `instance`, `__address__`, `params.module`.

**Красный флаг:** думает, что Prometheus ходит на цель напрямую.

### 5. [middle] Как настроить алерт на скорое истечение сертификата и почему одного `up` мало?

Метрика `probe_ssl_earliest_cert_expiry` даёт время истечения. Выражение `(probe_ssl_earliest_cert_expiry - time()) / 86400 < 14` показывает меньше 14 дней. `up` про то, что scrape прошёл, и не знает про срок. Алерт по сроку заводят с запасом, чтобы человек успел выпустить сертификат в рабочее время.

**Что хотят услышать:** имя метрики, вычитание `time()`, запас по дням, что один целевой сертификат проверять недостаточно, если цепочка длиннее (смотрим самый ранний).

**Красный флаг:** «узнаем, когда сайт упадёт».

### 6. [middle] Прод отвечает 502. Как blackbox и метрики помогают сузить причину?

Внешняя проба красная с кодом 502 означает, что nginx жив, а upstream нет. Проверяю прямую пробу приложения: если она красная, смотрю приложение и его зависимости (`/readyz`, порт БД); если зелёная, то в nginx неверный upstream или сетевая проблема между ними. Дальше `error.log` nginx и `docker compose ps`.

**Что хотят услышать:** 502 значит «прокси жив», сравнение проб, `error.log`, порядок сверху вниз.

**Красный флаг:** перезапуск всего подряд.

### 7. [junior] Что такое exporter и когда он нужен?

Это программа рядом с целью, которая читает её внутреннее состояние и отдаёт `/metrics` для Prometheus, когда сама цель так не умеет. Примеры: node_exporter для хоста, postgres_exporter для БД. Запускается рядом с целью, добавляется как обычный job.

**Что хотят услышать:** пример, где запускают (рядом с целью), порт, отдельный job.

**Красный флаг:** думает, что Prometheus умеет читать любую БД сам.

### 8. [middle] Проверку «сайт жив» предлагают делать через POST /notes: «так надёжнее». Согласишься?

Нет. Проба выполняется каждые 15 секунд, и запись создаёт мусор в базе и нагрузку, а сбой пробы не должен менять данные. Для «жив» и «готов» есть `/healthz` и `/readyz`. Если нужна проверка записи, делаю отдельный тестовый сценарий с очисткой и небольшой частотой.

**Что хотят услышать:** проба не должна менять состояние, идемпотентность, liveness против readiness.

**Красный флаг:** «пусть пишет, места хватит».

### 9. [junior] Чем Prometheus с blackbox отличается от Zabbix для проверки «порт открыт и HTTP отвечает»?

Zabbix делает такие проверки как simple checks и веб-сценарии, результат живёт в его items и триггерах. В Prometheus проверка это метрики с лейблами (`probe_success`, `probe_duration_seconds`), и из них PromQL строит SLI, алерты и графики. В контейнерной среде Prometheus проще за счёт service discovery, Zabbix силён в классической инфраструктуре и SNMP.

**Что хотят услышать:** pull и агент, метрики с лейблами и PromQL, честное «зависит от среды».

**Красный флаг:** «Zabbix устарел» без аргументов.

### 10. [middle] Алерт по blackbox срабатывает и сразу проходит. Что сделаешь?

Одна неудачная проба (таймаут, потерянный пакет) не отказ. Смотрю `avg_over_time(probe_success[5m])` вместо мгновенного значения, в алерте задаю `for`, проверяю `timeout` модуля. Подробности про `for` в уроке 8.5.

**Что хотят услышать:** `for`, усреднение, timeout, устойчивая проблема.

**Красный флаг:** отключить алерт или поднять порог «на глаз».

## Проверено на версиях

- Prometheus: v3.15.0
- blackbox_exporter: v0.28.0 (версия образа не подтверждена контрактом, проверь актуальную версию на странице проекта)
- node_exporter: v1.12.1
- cAdvisor: v0.60.6
- Docker Engine с Compose: версия из урока 4.1
- nginx: 1.30 (образ из урока 4.6)

## Итог урока: ты умеешь

- [ ] объяснить разницу между whitebox и blackbox и сказать, какой из них поднимает алерт «недоступно»;
- [ ] описать модули в `blackbox.yml` для HTTP, HTTPS с проверкой сертификата и TCP;
- [ ] подключить цели в Prometheus через `relabel_configs` и проверить `probe_success`;
- [ ] вызвать `/probe` вручную с `debug=true` и по выводу найти причину красной пробы;
- [ ] посчитать дни до истечения сертификата из `probe_ssl_earliest_cert_expiry`;
- [ ] по сочетанию внешней и прямой проб определить, какой слой отказал;
- [ ] объяснить, что такое exporter, и назвать примеры;
- [ ] сравнить Zabbix и Prometheus для базовых проверок.

**Дальше:** [Урок 8.5: Алерты и Alertmanager](05-alertmanager.md)
