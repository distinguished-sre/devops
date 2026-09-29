---
layout: lesson
title: "Алерты и Alertmanager: правила, маршрутизация, runbook"
topic: 8
lesson: "8.5"
time: "2 ч"
---

## Зачем это нужно

Дашборд никто не смотрит в три часа ночи. Если сервис лежит, об этом должна узнать система, а не клиент, написавший в поддержку. Плохой алертинг ломается в обе стороны: молчит при аварии или будит дежурного сотней одинаковых сообщений, после чего его начинают игнорировать (alert fatigue, усталость от алертов).

Хороший алерт сообщает о боли пользователя, приходит один раз и содержит ссылку на runbook (инструкцию, что делать). На работе ты будешь писать правила, настраивать маршрутизацию по срочности и разбирать «почему меня не разбудило» и «почему разбудило зря».

Шаг проекта: в «Заметки» добавляются 4 алерта, Alertmanager с маршрутизацией по `severity`, юнит-тест правил через `promtool` и runbook на каждый алерт.

## Что нужно знать

- [Урок 8.1: наблюдаемость, SLI и SLO](01-observability-slo.md) - алерт строится от SLO и симптомов, а не от загрузки CPU.
- [Урок 8.2: Prometheus и /metrics](02-prometheus-basics.md) - job `notes`, метрика `up`, `prometheus.yml`, том `prom-data`.
- [Урок 8.3: PromQL](03-promql.md) - `rate`, доля ошибок, `histogram_quantile`, recording rules `notes:http_errors:ratio5m` и `notes:http_latency:p95_5m`.
- [Урок 8.4: blackbox и exporters](04-blackbox-exporters.md) - проверка снаружи, `node_exporter` и метрики диска.
- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - перечитывание конфигурации по SIGHUP.

## Теория

### Как устроена цепочка алерта

Prometheus и Alertmanager делят работу. Prometheus каждые 15 секунд (`evaluation_interval`) вычисляет правила оповещения (alerting rules) и решает, «болит» ли что-то. Alertmanager ничего не измеряет: он принимает уже сработавшие алерты и решает, кому, когда и сколько раз о них сказать.

Цепочка: метрики, правило (`expr`, `for`), Alertmanager (дедупликация, группировка), маршрут, получатель. Правило состоит из полей: `alert` (имя), `expr` (условие в PromQL, алерт есть, пока выражение возвращает хоть один ряд), `for` (сколько подряд условие должно держаться), `labels` (по ним идёт маршрутизация), `annotations` (текст для человека: `summary`, `description`, `runbook_url`).

Состояния алерта: `inactive` (условие ложно), `pending` (условие истинно, но `for` ещё не прошёл), `firing` (алерт отправлен в Alertmanager). Поле `for` это фильтр от кратковременных всплесков. Без него один плохой scrape (опрос цели) разбудит человека. Слишком длинный `for` задерживает уведомление: при `for: 10m` о падении ты узнаешь через десять минут.

> **Проверь понимание:** алерт с `for: 5m` и условием, которое было истинным 4 минуты 50 секунд, а потом стало ложным. Сколько уведомлений придёт?

<details markdown="1">
<summary>Ответ</summary>

Ни одного. Алерт всё это время был в `pending` и вернулся в `inactive`, не став `firing`. Именно так `for` гасит шум от коротких скачков.

</details>

### Что мониторить: симптомы, а не причины

Алерт, который будит человека (page), должен отвечать на вопрос «пользователю сейчас плохо?». Это симптомы: сайт недоступен, доля ошибок выше нормы, ответы медленные. Причины (CPU 90%, мало памяти у одного пода) полезны на дашборде и в диагностике, но будить ими нельзя: CPU 90% при нормальных ответах не проблема, а у упавшего сервиса CPU может быть 0%.

Исключение: то, что через время станет симптомом и требует действий заранее. Диск, который заполнится через сутки, алерт-предупреждение (warning) в рабочее время, а не ночная тревога. Отсюда две срочности:

- `critical` (page): пользователи страдают прямо сейчас, человек нужен немедленно;
- `warning` (ticket): нужно разобраться в рабочие часы, заводится задача.

Правило для каждого алерта: он требует действия человека, и у него есть runbook. Если реагировать нечем, это не алерт, а строка на дашборде. Алерты на бюджет ошибок SLO (burn rate) разбираются в [уроке 8.11](11-reliability-patterns-burn-rate.md), здесь мы работаем с простыми порогами.

> **Проверь понимание:** почему «CPU выше 80%» плохой критичный алерт, а «доля 5xx выше 5% в течение 5 минут» хороший?

<details markdown="1">
<summary>Ответ</summary>

CPU это причина и часто рабочая норма (сервис просто занят). Доля 5xx это прямой симптом: часть пользователей получает ошибки, и на него всегда есть что делать. Первый даёт ложные тревоги и приучает игнорировать алерты, второй нет.

</details>

### Alertmanager: маршрутизация, группировка, подавление

Alertmanager получает алерты и применяет по порядку:

- **Дедупликация**: Prometheus повторно шлёт один и тот же firing-алерт каждый цикл, Alertmanager считает его одним.
- **Маршрутизация** (routing tree): дерево `route` с `matchers` по labels. Алерт идёт по первой подошедшей ветке (при `continue: false`) и уходит её получателю (`receiver`). Корневой `route` ловит всё остальное.
- **Группировка** (`group_by`): алерты с одинаковыми значениями перечисленных labels собираются в одно уведомление. При падении десяти подов придёт одно сообщение «10 алертов», а не десять.
- **Тайминги**: `group_wait` (сколько ждать новых алертов группы до первой отправки, обычно 30 секунд), `group_interval` (как часто слать новые алерты в уже отправленную группу, 5 минут), `repeat_interval` (как часто повторять напоминание о том же неснятом алерте, у нас 4 часа).
- **Подавление** (inhibit): пока горит главный алерт, зависимые молчат. Сервис упал, значит алерт «медленные ответы» про него же лишний.
- **Silence**: ручное заглушение по labels на время, например на плановые работы. Silence не удаляет алерт, а только глушит уведомления, и заканчивается сам.

Получатели (receivers) бывают разные: Telegram, Slack, почта, PagerDuty, webhook. В уроке используем webhook: это универсальная точка, в которую Alertmanager делает POST с JSON, а к ней подключается что угодно. Telegram подключается так же, блоком `telegram_configs` с токеном бота (токен в секретах, а не в git, см. [урок 9.1](../09-secrets-gitops/01-secrets-problem-vault.md)).

> **Проверь понимание:** ночью упал узел, и за минуту сработали 30 алертов. Какие настройки Alertmanager превратят это в одно-два сообщения?

<details markdown="1">
<summary>Ответ</summary>

`group_by` по общим меткам (например `alertname` и `service`) склеит однотипные алерты в одно уведомление, `group_wait` подождёт остальных участников группы, а `inhibit_rules` заглушит зависимые предупреждения, пока горит основной критичный алерт.

</details>

### Как узнать, что алертинг сам не сломался

Самая неприятная авария: молчит не сервис, а система оповещения. Поэтому держат «сторожевой» алерт (Watchdog, dead man's switch) с условием `vector(1)`: он горит всегда, и внешний сервис ждёт его регулярных повторов. Пропали повторы значит сломан Prometheus, Alertmanager или канал доставки. В проект его не добавляем (нет внешнего приёмника), но на проде он обязателен.

Ещё одна защита: правила тестируются до выкатки. `promtool check rules` проверяет синтаксис, `promtool test rules` подаёт синтетические метрики и проверяет, что алерт сработал в нужный момент. Так правило не окажется «мёртвым» из-за опечатки в labels.

> **Проверь понимание:** что даёт `promtool test rules`, чего не даёт `promtool check rules`?

<details markdown="1">
<summary>Ответ</summary>

`check` проверяет только синтаксис и корректность выражений. `test` проверяет поведение: на заданных входных рядах алерт становится `firing` в нужную минуту с нужными labels. Правило с опечаткой в имени метрики пройдёт `check`, но провалит `test`.

</details>

## Практика

Перед началом основной стек «Заметок» запущен (`docker compose up -d` в `~/notes`), мониторинг из уроков 8.2-8.4 работает (`docker compose -f ~/notes/monitoring/compose.yml ps`). Все файлы ниже лежат в `~/notes/monitoring/` и `~/notes/docs/`, эталон: [project/notes/monitoring](https://github.com/distinguished-sre/devops/tree/devops/project/notes/monitoring).

### Задание 1. Четыре алерта и проверка правил

**Цель:** написать правила оповещения и проверить их без запуска Alertmanager.

**Предскажи:** в файле правил `NotesDown` использует `up{job="notes"} == 0`. Что вернёт этот запрос, пока «Заметки» работают: пустой результат или ряд со значением 1?

<details markdown="1">
<summary>Ответ</summary>

Пустой результат. Оператор сравнения `== 0` фильтрует ряды: у живого target `up` равен 1, он отбрасывается. Алерт есть, только пока запрос возвращает хотя бы один ряд.

</details>

**Шаги:**

1. Создай каталоги и файл правил. Шаблоны аннотаций (Go-шаблоны Prometheus) содержат двойные фигурные скобки, поэтому в уроке они обёрнуты в `raw`, а в твоём файле это обычный текст:

{% raw %}
```bash
mkdir -p ~/notes/monitoring/prometheus/rules ~/notes/monitoring/prometheus/tests
cat > ~/notes/monitoring/prometheus/rules/alerts.yml <<'YAML'
groups:
  - name: notes-alerts
    rules:
      # Симптом: приложение не отвечает на сбор метрик
      - alert: NotesDown
        expr: up{job="notes"} == 0
        for: 1m
        labels: {severity: critical, service: notes}
        annotations:
          summary: "Заметки недоступны"
          description: "Target {{ $labels.instance }} не отвечает больше минуты."
          runbook_url: "https://github.com/distinguished-sre/devops/blob/devops/project/notes/docs/runbooks/NotesDown.md"

      # Симптом: доля ответов 5xx выше 5% (recording rule из урока 8.3)
      - alert: NotesHighErrorRate
        expr: notes:http_errors:ratio5m > 0.05
        for: 5m
        labels: {severity: critical, service: notes}
        annotations:
          summary: "Доля ошибок 5xx выше 5%"
          runbook_url: "https://github.com/distinguished-sre/devops/blob/devops/project/notes/docs/runbooks/NotesHighErrorRate.md"

      # Симптом: 95-й перцентиль задержки выше 500 мс
      - alert: NotesHighLatency
        expr: notes:http_latency:p95_5m > 0.5
        for: 10m
        labels: {severity: warning, service: notes}
        annotations:
          summary: "p95 задержки выше 500 мс"
          runbook_url: "https://github.com/distinguished-sre/devops/blob/devops/project/notes/docs/runbooks/NotesHighLatency.md"

      # Предупреждение заранее: диск закончится в ближайшие сутки
      - alert: NotesDiskFillingUp
        expr: predict_linear(node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}[6h], 24 * 3600) < 0
        for: 30m
        labels: {severity: warning, service: notes}
        annotations:
          summary: "Диск заполнится меньше чем за 24 часа"
          runbook_url: "https://github.com/distinguished-sre/devops/blob/devops/project/notes/docs/runbooks/NotesDiskFillingUp.md"
YAML
```
{% endraw %}

2. Проверь синтаксис командой `promtool` из образа Prometheus (ставить ничего не нужно):

```bash
cd ~/notes/monitoring
docker run --rm --entrypoint promtool \
  -v "$PWD/prometheus:/p:ro" prom/prometheus:v3.15.0 \
  check rules /p/rules/alerts.yml
```

3. Напиши юнит-тест: подаём синтетические метрики и проверяем, что сработало (и что не сработало).

```bash
cat > ~/notes/monitoring/prometheus/tests/alerts_test.yml <<'YAML'
rule_files:
  - ../rules/alerts.yml

evaluation_interval: 15s

tests:
  # Приложение лежит 10 минут: после 1 минуты NotesDown должен гореть
  - interval: 15s
    input_series:
      - series: 'up{job="notes", instance="notes:8080"}'
        values: '0x40'
    alert_rule_test:
      - eval_time: 30s
        alertname: NotesDown
        exp_alerts: []          # for ещё не прошёл: алерт в pending
      - eval_time: 2m
        alertname: NotesDown
        exp_alerts:
          - exp_labels:
              severity: critical
              service: notes
              job: notes
              instance: "notes:8080"
            exp_annotations:
              summary: "Заметки недоступны"
              description: "Target notes:8080 не отвечает больше минуты."
              runbook_url: "https://github.com/distinguished-sre/devops/blob/devops/project/notes/docs/runbooks/NotesDown.md"

  # Всплеск ошибок на 2 минуты: за счёт for уведомления быть не должно
  - interval: 15s
    input_series:
      - series: 'notes:http_errors:ratio5m'
        values: '0.10x8 0x60'
    alert_rule_test:
      - eval_time: 6m
        alertname: NotesHighErrorRate
        exp_alerts: []
YAML
docker run --rm --entrypoint promtool \
  -v "$PWD/prometheus:/p:ro" prom/prometheus:v3.15.0 \
  test rules /p/tests/alerts_test.yml
```

**Что должно получиться:**

```text
Checking /p/rules/alerts.yml
  SUCCESS: 4 rules found

Unit Testing:  /p/tests/alerts_test.yml
  SUCCESS
```

**Объясни себе:**

- Почему в тесте `eval_time: 30s` ждёт пустой список `exp_alerts`, хотя ряд `up` уже ноль?
- Что второй тест (всплеск на 2 минуты) доказывает про поле `for`?

**Типичные ошибки:**

- `FAILED: ... expected 1 alerts, got 0`: правило не сработало на данных теста. Проверь имя метрики и labels в `input_series`, и что `eval_time` больше `for`.
- `exp_labels` не совпали (`missing/extra labels`): в ожидаемых labels должны быть все labels алерта, включая унаследованные от метрики (`job`, `instance`), но без `alertname`: его `promtool` подставляет сам.

### Задание 2. Alertmanager: конфиг и маршрутизация

**Цель:** запустить Alertmanager и приёмник вебхуков, описать дерево маршрутов и проверить его без реальных алертов.

**Предскажи:** что попадёт в получателя `ticket`: алерт `NotesHighLatency` с `severity: warning`, или он уйдёт получателю по умолчанию? Как убедиться, не ломая ничего?

<details markdown="1">
<summary>Ответ</summary>

Он уйдёт в `ticket`: ветка с `severity = "warning"` подходит. Проверить можно без аварии командой `amtool config routes test --labels=...`, которая показывает, какому получателю достанется набор labels. Ниже мы её запустим.

</details>

**Шаги:**

1. Создай конфигурацию Alertmanager:

```bash
mkdir -p ~/notes/monitoring/alertmanager
cat > ~/notes/monitoring/alertmanager/alertmanager.yml <<'YAML'
route:
  receiver: webhook            # по умолчанию, если ни одна ветка не подошла
  group_by: ["alertname", "service"]
  group_wait: 30s              # ждём остальных участников группы
  group_interval: 5m           # новые алерты в уже отправленную группу
  repeat_interval: 4h          # напоминание о неснятом алерте
  routes:
    - matchers: ['severity = "critical"']
      receiver: page
    - matchers: ['severity = "warning"']
      receiver: ticket

receivers:
  - name: webhook
    webhook_configs:
      - url: http://webhook:8080/anything/default
  - name: page                 # будит человека
    webhook_configs:
      - url: http://webhook:8080/anything/page
  - name: ticket               # заводит задачу
    webhook_configs:
      - url: http://webhook:8080/anything/ticket

inhibit_rules:
  # Пока сервис лежит, предупреждения про него же не нужны
  - source_matchers: ['alertname = "NotesDown"']
    target_matchers: ['severity = "warning"']
    equal: ["service"]
YAML
```

2. Добавь в `monitoring/compose.yml` два сервиса в секцию `services:` (сеть `notes-net` уже описана в конце файла с урока 8.2):

```yaml
  alertmanager:
    image: prom/alertmanager:v0.34.1
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager:/etc/alertmanager:ro
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
    restart: unless-stopped

  # Приёмник вебхуков: логирует каждый POST от Alertmanager
  webhook:
    image: mccutchen/go-httpbin:v2.18.3
    restart: unless-stopped
```

3. Подключи правила и Alertmanager в `monitoring/prometheus/prometheus.yml`. Добавь на верхний уровень (рядом с `scrape_configs`):

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

Если в `compose.yml` у сервиса `prometheus` ещё нет тома `./prometheus/rules:/etc/prometheus/rules:ro` (в 8.3 он мог быть смонтирован), добавь его. Проверь: `grep -n rules ~/notes/monitoring/compose.yml`.

4. Проверь конфиг и запусти:

```bash
cd ~/notes/monitoring
docker run --rm --entrypoint amtool \
  -v "$PWD/alertmanager:/a:ro" prom/alertmanager:v0.34.1 \
  check-config /a/alertmanager.yml
docker compose up -d
docker compose kill -s HUP prometheus   # перечитать конфиг без перезапуска (сигнал SIGHUP)
```

5. Спроси у дерева маршрутов, кому достанется набор labels:

```bash
for sev in warning critical; do
  docker run --rm --entrypoint amtool -v "$PWD/alertmanager:/a:ro" \
    prom/alertmanager:v0.34.1 config routes test \
    --config.file=/a/alertmanager.yml severity=$sev service=notes
done
```

**Что должно получиться:**

```text
Checking '/a/alertmanager.yml'  SUCCESS
Found:
 - global config
 - route
 - 1 inhibit rules
 - 3 receivers
 - 0 templates
```

Затем `ticket` для `severity=warning` и `page` для `severity=critical`. В браузере http://localhost:9093 открывается интерфейс, на http://localhost:9090/rules видны 4 правила в состоянии `OK`, а `http://localhost:9090/config` содержит секцию `alerting`.

**Объясни себе:**

- Что произойдёт с алертом `severity=info`, для которого нет ветки?

**Типичные ошибки:**

- `err="yaml: unmarshal errors: line 3: field group_by_ not found"` или `unknown fields in route`: опечатка в имени ключа. Alertmanager строго проверяет схему и не стартует.
- `level=ERROR msg="Error on notify" ... dial tcp: lookup webhook on 127.0.0.11:53: no such host`: приёмник в другой сети или не запущен. Оба сервиса должны быть в одном `compose.yml` и сети `notes-net`.
- В Prometheus на странице Status - Runtime нет Alertmanager: не выполнена перезагрузка. `docker compose kill -s HUP prometheus` перечитывает конфиг, перезапуск не нужен.

### Задание 3. Уроним сервис и проследим алерт до webhook

**Цель:** пройти весь путь: `inactive`, `pending`, `firing`, уведомление; попробовать silence.

**Предскажи:** алерт `NotesDown` имеет `for: 1m`, `group_wait: 30s`, scrape каждые 15 секунд. Через сколько примерно после остановки сервиса в приёмник придёт первый POST?

<details markdown="1">
<summary>Ответ</summary>

Около двух минут: до 15 секунд на обнаружение (`up` стал 0), минута `for` в состоянии `pending`, плюс до 15 секунд на цикл вычисления правил и 30 секунд `group_wait` в Alertmanager. Итого от 1 минуты 45 секунд до 2 минут 15 секунд.

</details>

**Шаги:**

1. Остановь приложение и следи за состоянием правила:

```bash
cd ~/notes
docker compose stop notes
watch -n 5 "curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | [.labels.alertname, .state] | @tsv'"
```

Сначала `pending`, через минуту `firing` (выход из `watch`: `Ctrl+C`).

2. Через 30 секунд проверь, что Alertmanager получил алерт и куда его отправил, и что дошёл вебхук:

```bash
curl -s localhost:9093/api/v2/alerts | jq -r '.[] | [.labels.alertname, .labels.severity, .status.state] | @tsv'
docker compose -f monitoring/compose.yml logs webhook --tail 5
```

3. Верни сервис командой `docker compose start notes`: через минуту-две алерт снимется и придёт уведомление `resolved`.

4. Заглуши алерт на 10 минут (silence) и убедись, что он виден как заглушенный:

```bash
docker compose stop notes
docker run --rm --network host --entrypoint amtool prom/alertmanager:v0.34.1 \
  --alertmanager.url=http://localhost:9093 silence add alertname=NotesDown \
  --duration=10m --author=me --comment="плановые работы"
docker compose start notes
```

**Что должно получиться:**

```text
NotesDown	pending
NotesDown	firing
```

Затем в Alertmanager `NotesDown	critical	active`, а в логах приёмника строка с `POST /anything/page`. `silence add` печатает id заглушки, а при остановленном сервисе алерт в интерфейсе Alertmanager помечен suppressed и в приёмник не идёт.

**Объясни себе:**

- Почему после `docker compose start notes` алерт не снимается мгновенно?
- Чем silence отличается от удаления правила или от `inhibit`? Что будет, когда его срок истечёт, а сервис ещё лежит?

**Типичные ошибки:**

- В логах приёмника пусто: Alertmanager не видит Prometheus. Смотри секцию `alerting:` (см. сценарий 4 ниже).

### Задание 4. Шаг проекта: runbook на каждый алерт

**Цель:** к каждому алерту приложить инструкцию, по которой его сможет разобрать любой дежурный, а не только автор.

**Предскажи:** какие 5 разделов должен содержать runbook, чтобы человек, разбуженный в 3:00, не думал, а действовал?

<details markdown="1">
<summary>Ответ</summary>

Симптом (что видит пользователь и что сработало), влияние (насколько всё плохо), проверки (команды по порядку), действия (как починить и как откатить), эскалация (кому звать, если не помогло). Каждая ссылка `runbook_url` из алерта ведёт именно на такой документ.

</details>

**Шаги:**

1. Создай четыре файла в `~/notes/docs/runbooks/` (команды основаны на том, что уже пройдено в темах 1, 4 и 8):

```bash
mkdir -p ~/notes/docs/runbooks
cat > ~/notes/docs/runbooks/NotesDown.md <<'MD'
# NotesDown: «Заметки» не отвечают
## Симптом
`up{job="notes"} == 0` больше минуты, пользователи видят 502 или таймаут.
## Влияние
Сервис недоступен полностью. Критично, будит дежурного.
## Проверки
1. `docker compose ps` в `~/notes`: жив ли `notes`, нет ли `Restarting`.
2. `docker compose logs notes --tail 50`: причина падения.
3. `curl -i http://127.0.0.1:8080/healthz`: отвечает ли приложение изнутри.
4. `docker compose ps db`: жива ли и `healthy` ли PostgreSQL.
## Действия
- Контейнер остановлен: `docker compose up -d notes`.
- Падает после смены конфига или образа: вернуть прошлый `.env` или тег, `docker compose up -d`.
- Причина в БД: разобрать `docker compose logs db`, потом перезапустить `notes`.
## Эскалация
Не поднялся за 15 минут: звать владельца сервиса, записать время начала для постмортема.
MD
cat > ~/notes/docs/runbooks/NotesHighErrorRate.md <<'MD'
# NotesHighErrorRate: доля 5xx выше 5%
## Симптом
`notes:http_errors:ratio5m > 0.05` дольше 5 минут.
## Влияние
Часть пользователей получает 500/502/503, расходуется бюджет ошибок.
## Проверки
1. Какие пути: `sum by (path, status) (rate(notes_http_requests_total{status=~"5.."}[5m]))`.
2. Была ли выкатка или правка `.env` перед началом ошибок.
3. `docker compose logs notes --since 15m | grep -i error`.
4. `curl -s http://127.0.0.1:8080/readyz`: отвечает ли БД.
## Действия
- Ошибки после выкатки: откатить на прошлый тег образа, `docker compose up -d notes`.
- Причина в БД: проверить `db`, место на диске, число соединений.
- Причина неясна, а ошибки идут: сначала снизить ущерб (откат, перезапуск), потом разбираться.
## Эскалация
Ошибки не падают 30 минут после отката: звать разработчика приложения.
MD
cat > ~/notes/docs/runbooks/NotesHighLatency.md <<'MD'
# NotesHighLatency: p95 выше 500 мс
## Симптом
`notes:http_latency:p95_5m > 0.5` дольше 10 минут.
## Влияние
Сервис отвечает медленно, возможны таймауты клиентов. Предупреждение: завести задачу.
## Проверки
1. Где медленно: `histogram_quantile(0.95, sum by (le, path) (rate(notes_http_request_duration_seconds_bucket[5m])))`.
2. `docker stats --no-stream`: CPU и память контейнера `notes`.
3. Долгие запросы БД: `docker compose exec db psql -U notes -d notes -c "select pid, now() - query_start as age, query from pg_stat_activity where state = 'active' order by age desc"`.
## Действия
- Медленный SQL: индекс или ограничение выборки.
- Не хватает ресурсов: поднять лимиты или число экземпляров.
- Ожидаемый всплеск нагрузки: убедиться, что он ожидаем.
## Эскалация
Растут и задержки, и ошибки: работать по NotesHighErrorRate.
MD
cat > ~/notes/docs/runbooks/NotesDiskFillingUp.md <<'MD'
# NotesDiskFillingUp: диск заполнится меньше чем за сутки
## Симптом
`predict_linear` по `node_filesystem_avail_bytes` даёт отрицательное свободное место через 24 часа.
## Влияние
Сейчас сервис работает, через часы возможны отказы БД и логов. Предупреждение: разобрать в рабочее время.
## Проверки
1. `df -h /`: сколько занято.
2. `sudo du -xh / --max-depth=2 2>/dev/null | sort -h | tail -15`: что занимает место.
3. `docker system df`: образы, тома, кэш сборки.
4. `df` и `du` расходятся: `sudo lsof +L1` покажет удалённые, но открытые файлы.
## Действия
- Старые образы и кэш: `docker image prune`, сначала прочитай, что удалится.
- Разросшиеся логи: настроить ротацию `json-file` с `max-size`.
- Данные растут по делу: расширить диск и завести задачу на ёмкость.
## Эскалация
Свободно меньше 10%: поднять приоритет, звать владельца платформы.
MD
```

2. Закоммить результат: правила, конфигурация, тест и документация живут в git, как и код.

```bash
cd ~/notes
git add monitoring docs/runbooks
git commit -m "Алерты, Alertmanager и runbook (урок 8.5)"
```

**Что должно получиться:**

```text
[main 3f1c2ab] Алерты, Alertmanager и runbook (урок 8.5)
 9 files changed, 291 insertions(+)
```

Хеш и число строк будут другими. Проверка: `ls ~/notes/docs/runbooks` показывает ровно 4 файла, имена совпадают со значениями `alertname` (по ним построены `runbook_url`), а `promtool check rules` из задания 1 по-прежнему проходит.

**Объясни себе:**

**Типичные ошибки:**

- `fatal: pathspec 'monitoring' did not match any files`: команда запущена не из `~/notes`. Перейди в корень репозитория.
- `runbook_url` ведёт на 404: файл ещё не запушен на GitHub, или имя файла отличается от `alertname` регистром.

## Сломай и почини

Скачай скрипт поломки и запусти его. Читать скрипт не нужно: цель в диагностике по симптомам.

```bash
cd ~/notes
curl -fsSLo /tmp/break-8.5.sh https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/8.5/break.sh
bash /tmp/break-8.5.sh random
```

### Симптом

Одна из четырёх ситуаций (скрипт выберет случайно):

1. Ты остановил `notes`, ждёшь 10 минут, а `NotesDown` не приходит.
2. Уведомления приходят пачками «сработал, снялся, сработал» каждые несколько минут.
3. Один и тот же алерт приходит в приёмник заново каждую минуту.
4. В Alertmanager пусто при том, что в Prometheus алерт `firing`.

### Гипотезы

Выпиши свои по каждому симптому. Типичные причины: лишний фильтр в `expr` или слишком длинный `for` (нет срабатывания); нет `for` и порог на границе нормы (флаппинг); слишком короткий `repeat_interval` или лишние labels в `group_by` (дубли); нет секции `alerting:` или Prometheus не перечитан (пустой Alertmanager).

### Проверки

```bash
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[] | [.name, .health, .state] | @tsv'   # загружены ли правила
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | [.labels.alertname, .state] | @tsv'      # состояние алертов
curl -s localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers'                              # видит ли Prometheus Alertmanager
```

Пустой `activeAlertmanagers` означает сценарий 4. Метрики `prometheus_notifications_dropped_total` и `prometheus_notifications_errors_total` показывают недоставку.

### Исправление

<details markdown="1">
<summary>Разбор всех сценариев</summary>

1. **Алерт не срабатывает.** В выражении стоит условие, которому `up` не соответствует, или `for` выставлен в 30 минут. Вставь выражение в интерфейс Prometheus (Graph) и посмотри, возвращает ли оно ряды. Верни `for: 1m`, проверь `promtool test rules`, перечитай конфиг (`docker compose kill -s HUP prometheus`). Тест из задания 1 должен был поймать это заранее.
2. **Флаппинг.** Убери порог с границы или добавь/увеличь `for`. Дополнительно можно сравнивать с окном (`avg_over_time`), чтобы сгладить шум. Флаппинг лечится в правиле, а не в Alertmanager: `group_interval` лишь прячет его.
3. **Дубли.** Верни `repeat_interval: 4h`, а `group_by` оставь только по `alertname` и `service`. Уведомление «ещё горит» приходит редко, а не раз в минуту.
4. **Нет `alerting:`.** Добавь блок с целью `alertmanager:9093` (имя сервиса в сети `notes-net`), перечитай конфиг. Проверь `api/v1/alertmanagers`: должен быть один активный.

После исправления запусти `bash /tmp/break-8.5.sh fix`, если хочешь вернуть эталонное состояние, и удали временный файл: `rm /tmp/break-8.5.sh`.

</details>

## Вопросы с собеседований

### 1. [junior] Ночью пришёл алерт «CPU 92%», сервис отвечает нормально. Что делаешь и что предложишь после?

Сначала смотрю, есть ли боль у пользователей: ошибки, задержки, доступность. Если их нет, реагировать нечем, сервис просто занят. После: убираю ночной алерт по CPU, оставляю метрику на дашборде, а будить людей предлагаю по симптомам (ошибки, задержки).

**Что хотят услышать:** симптом против причины, алерт должен требовать действия, борьба с alert fatigue.

**Красный флаг:** «просто перезагрузил сервер» или «ничего страшного, игнорируем такие алерты».

### 2. [junior] Зачем в правиле поле `for`?

Оно требует, чтобы условие держалось всё указанное время. Один неудачный scrape или короткий скачок не дают уведомления: алерт остаётся в `pending`. Слишком большой `for` задерживает реакцию, поэтому я подбираю его под цену ошибки: для падения сервиса минута, для медленных ответов десять.

**Что хотят услышать:** состояния `pending` и `firing`, защита от флаппинга, компромисс между шумом и задержкой.

**Красный флаг:** «`for` это как часто проверять правило».

### 3. [junior] Чем группировка отличается от подавления (inhibit)?

Группировка склеивает похожие алерты в одно уведомление, но все они остаются актуальными. Подавление молчит про зависимый алерт, пока горит главный: если сервис лежит, алерт про медленные ответы этого же сервиса не нужен.

**Что хотят услышать:** `group_by`, `inhibit_rules` с `equal`, пример с зависимостью.

**Красный флаг:** путает inhibit и silence или считает, что группировка «удаляет» алерты.

### 4. [middle] Упал узел, дежурному пришло 40 сообщений в Telegram. Как исправить конфигурацию?

Проверю `group_by`: если группировка по `instance` или `pod`, то для каждого пода отдельное уведомление. Оставлю `alertname` и `service`, подберу `group_wait` (30 секунд, чтобы собрать всех). Добавлю inhibit: алерт «узел недоступен» глушит алерты подов на нём. Отдельно проверю `repeat_interval`.

**Что хотят услышать:** `group_by`, `group_wait`, `inhibit_rules` с `source_matchers`/`target_matchers`, `equal`.

**Красный флаг:** «уберу часть алертов, чтобы их было меньше».

### 5. [middle] Алерт «горит» уже неделю, все привыкли и не реагируют. Что с этим делать?

Это признак плохого алерта: если он неделю горит и никто не действует, он либо не нужен, либо порог неверен. Либо чиню причину, либо меняю порог, либо перевожу в предупреждения и удаляю из пейджера. Регулярно пересматриваю самые частые алерты и удаляю те, на которые не было действий.

**Что хотят услышать:** alert fatigue, каждый алерт требует действия, ревью шума раз в неделю или спринт.

**Красный флаг:** «пусть висит, это информационный алерт».

### 6. [middle] Как убедиться, что алертинг вообще жив, а не молчит из-за поломки?

Держу сторожевой алерт (Watchdog, `vector(1)`), который горит всегда. Внешний сервис ждёт его регулярных повторов и сам поднимает тревогу, если они пропали. Так ловится падение Prometheus, Alertmanager и канала доставки. Плюс тестирую правила `promtool test rules` и периодически проверяю доставку реальным тестовым алертом.

**Что хотят услышать:** dead man's switch, внешняя проверка, тесты правил, проверка канала.

**Красный флаг:** «алертов давно не было, значит всё хорошо».

### 7. [middle] Что должно быть в хорошем runbook и как ты поймёшь, что он плохой?

Симптом, влияние, пошаговые проверки командами, действия и откат, эскалация. Плохой runbook состоит из общих слов, не содержит команд и устарел. Проверяю его на учениях: дежурный, который систему не знает, разбирает по нему инцидент. Если споткнулся, дополняю.

**Что хотят услышать:** конкретные команды, эскалация, актуальность через учения, ссылка в `runbook_url`.

**Красный флаг:** «runbook это wiki-страница про архитектуру».

### 8. [junior] Прод отвечает 502 и приходит алерт. Каков порядок твоих действий?

Подтверждаю масштаб: это все пользователи или часть, смотрю алерт и runbook. Затем снижаю ущерб (откат последней выкатки, перезапуск, переключение) и только после этого ищу корневую причину. Сообщаю о ситуации коллегам и фиксирую время для постмортема.

**Что хотят услышать:** митигация раньше исправления, runbook, коммуникация, фиксация времени.

**Красный флаг:** сразу лезет править код на проде и не сообщает о проблеме.

### 9. [middle] Ты добавил новое правило, оно валидно по `promtool check`, но никогда не срабатывает. Как проверить?

`check` смотрит только синтаксис. Пишу `promtool test rules` с синтетическим рядом и ожидаемыми labels, тогда видно, где расходятся имена метрик и labels. В самом Prometheus запускаю выражение в Graph и проверяю, возвращает ли оно ряды на реальных данных, а на странице правил смотрю `health`.

**Что хотят услышать:** unit-тесты правил, запуск выражения на реальных данных, типичные причины (неверный label, неподходящий job).

**Красный флаг:** «подожду, вдруг сработает» или «поменяю пороги наугад».

### 10. [middle] Как проверить, что алерт уйдёт куда нужно, не устраивая аварию на проде?

Правила проверяю `promtool test rules` на синтетических рядах, маршрут `amtool config routes test` с нужным набором labels: он покажет получателя. Конфиг перед выкаткой прогоняю `amtool check-config`. Для сквозной проверки шлю тестовый алерт `amtool alert add` с отдельным label и слежу за доставкой.

**Что хотят услышать:** тесты правил и маршрутов до выкатки, тестовый алерт, проверка канала доставки.

**Красный флаг:** «сломаю что-нибудь на стенде и посмотрю, придёт ли».

## Проверено на версиях

- Prometheus: v3.15.0 (`promtool` из того же образа)
- Alertmanager: v0.34.1 (`amtool` из образа)
- go-httpbin: v2.18.3 (тег зафиксирован в `monitoring/compose.yml`, проверь актуальную версию на странице проекта)
- node_exporter: v1.12.1
- Docker Compose: v2 (плагин `docker compose`)

## Итог урока: ты умеешь

- [ ] умею написать alerting rule с `for`, `labels` и `annotations` и объяснить состояния `inactive`, `pending`, `firing`
- [ ] умею отличить алерт по симптому от алерта по причине и выбрать для него срочность `critical` или `warning`
- [ ] умею настроить Alertmanager: `route`, `group_by`, `repeat_interval`, receivers, `inhibit_rules`
- [ ] умею проверить маршрутизацию командой `amtool config routes test` и создать silence
- [ ] умею проверить правила через `promtool check rules` и написать юнит-тест `promtool test rules`
- [ ] умею проследить алерт от остановленного сервиса до webhook и найти, где цепочка оборвалась
- [ ] умею написать runbook с симптомом, проверками, действиями и эскалацией и привязать его через `runbook_url`

**Дальше:** [Урок 8.6: Grafana, дашборды как код](06-grafana-dashboards.md)
