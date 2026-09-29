---
layout: page
title: "Техническое задание для SRE"
redirect_from:
  - /задание-sre.html
---

### 3–4 дня до выхода на новую должность · Solo SRE · Greenfield Department

> **Философия плана:** Каждое задание — это не «ознакомление», а минимально жизнеспособный артефакт (MVA), который ты сможешь принести на новое место работы как готовый инструмент. К концу 4-го дня у тебя будет репозиторий с реальными конфигами, скриптами и шаблонами.

> **Что нужно пройти заранее:** весь курс, тема за темой. Этот план не учит с нуля — он собирает пройденное в рабочие артефакты в темпе, близком к боевому. Опорные темы: [4](../04-docker/index.md) (Compose), [5](../05-kubernetes/index.md) (Kubernetes, пробы, HPA, rollback), [8](../08-observability/index.md) (PromQL, SLO, burn rate, алерты), [3](../03-git-ci/index.md) (CI/CD), [1](../01-linux/index.md) (bash-скрипты)
>
> **Чем отличается от [задания для инженера мониторинга](monitoring.md):** то задание проверяет один навык вглубь и рассчитано на 12–16 часов. Этот план — четыре дня по 8 часов и охватывает весь цикл эксплуатации: мониторинг, логи, Kubernetes, CI/CD, базы, инциденты и планирование мощностей
>
> **Как проходить:** не подглядывая в ответы предыдущих тем. Если приходится возвращаться за каждой командой — вернись и добей соответствующую тему, план от этого только выиграет

---

## Предварительная настройка (30 мин до старта)

```bash
# Создай рабочий репозиторий — он станет твоим первым вкладом на новой работе
mkdir -p ~/sre-bootstrap/{monitoring,logging,kubernetes,cicd,database,incident,scripts}
cd ~/sre-bootstrap && git init

# Проверь что всё нужное установлено
docker --version          # должно быть 24+
docker compose version    # должно быть v2+
kubectl version --client  # должно быть 1.28+
minikube version          # должно быть 1.32+
jq --version              # нужен для скриптов, apt install jq если нет
bc --version              # нужен для health-report.sh
```

**Стек окружения:**
- Ubuntu 24.04 LTS (локально или VM, минимум 16 GB RAM для всех стеков одновременно)
- Docker 24+ / Docker Compose v2
- kubectl + minikube
- GitLab аккаунт (gitlab.com бесплатный tier)

---

## ДЕНЬ 1 — Мониторинг и наблюдаемость (Observability Foundation)

> **Цель дня:** Развернуть production-ready стек мониторинга с нуля, спроектировать первые SLO на реальных данных и настроить умные алерты.

**Время:** ~8–9 часов

---

### Задание 1.1 — Prometheus + Grafana + Alertmanager Stack (2.5 ч)

**Что делаешь:** Поднимаешь полный observability-стек через Docker Compose. Включаешь `fake-service` — он генерирует реалистичные HTTP-метрики (`http_requests_total`, `http_request_duration_seconds`), без которых задания 1.2 и 1.4 невыполнимы.

```yaml
# ~/sre-bootstrap/monitoring/compose.yml
services:
  prometheus:
    image: prom/prometheus:v3.1.0
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./prometheus/rules:/etc/prometheus/rules
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
      - '--web.enable-lifecycle'
    ports: ["9090:9090"]

  alertmanager:
    image: prom/alertmanager:v0.27.0
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
    ports: ["9093:9093"]

  grafana:
    image: grafana/grafana:11.4.0
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=sre_admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
      - grafana_data:/var/lib/grafana
    ports: ["3000:3000"]

  node-exporter:
    image: prom/node-exporter:v1.7.0
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'

  cadvisor:
    # ⚠️ Если gcr.io недоступен — используй: docker.io/google/cadvisor:latest
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports: ["8080:8080"]

  # ✅ ОБЯЗАТЕЛЬНО: демо-сервис, генерирующий реальные HTTP-метрики.
  # Без него SLO-дашборды в задании 1.2 покажут "No data".
  # Генерирует: http_requests_total, http_request_duration_seconds_bucket
  demo-app:
    image: nicholasjackson/fake-service:v0.26.2
    environment:
      - LISTEN_ADDR=0.0.0.0:9090
      - NAME=demo-api
      - MESSAGE=Hello from demo
      - ERROR_RATE=0.05          # 5% ошибок — будут видны в SLO
      - ERROR_TYPE=http_error
      - TIMING_50_PERCENTILE=30ms
      - TIMING_90_PERCENTILE=100ms
      - TIMING_99_PERCENTILE=400ms
    ports: ["19090:9090"]

volumes:
  prometheus_data:
  grafana_data:
```

```yaml
# ~/sre-bootstrap/monitoring/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: node-exporter
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: cadvisor
    static_configs:
      - targets: ["cadvisor:8080"]

  - job_name: demo-app
    static_configs:
      - targets: ["demo-app:9090"]
    metrics_path: /metrics
```

**Практические подзадачи:**

1. Поднять стек: `docker compose up -d` → убедиться что все контейнеры `Up`
2. Зайти в Prometheus UI (`:9090`) → Status → Targets: все должны быть `UP`
3. Настрой Grafana Provisioning (datasource as code):

   ```yaml
   # grafana/provisioning/datasources/prometheus.yml
   apiVersion: 1
   datasources:
     - name: Prometheus
       type: prometheus
       url: http://prometheus:9090
       isDefault: true
   ```

4. Импортируй дашборды: **Node Exporter Full (ID: 1860)**, **cAdvisor (ID: 14282)**
5. Создай свой кастомный дашборд с 6 панелями:
   CPU%, Memory%, Disk I/O, Network In/Out, Container restarts, HTTP error rate (с demo-app)

---

### Задание 1.2 — SLI/SLO/Error Budget Design (2 ч)

**Что делаешь:** Разрабатываешь полный SLO-фреймворк на реальных данных от demo-app.

> ℹ️ `demo-app` генерирует `http_request_duration_seconds_bucket` и `http_requests_total` с лейблом `job="demo-app"`. Все запросы ниже работают прямо в Prometheus UI.

**Шаг 1 — Проверь что метрики есть** (в Prometheus Expression Browser):

```promql
# Должно вернуть данные:
sum(rate(http_requests_total{job="demo-app"}[5m]))
```

**Шаг 2 — Задокументируй SLO в YAML-формате:**

```yaml
# ~/sre-bootstrap/monitoring/slo-definitions.yml
slos:
  - name: api-availability
    description: "API доступно 99.9% времени в rolling 30d window"
    sli_query: >
      sum(rate(http_requests_total{job="demo-app",status!~"5.."}[5m]))
      / sum(rate(http_requests_total{job="demo-app"}[5m]))
    target: 0.999
    window: 30d
    error_budget_minutes: 43.2  # = 30*24*60*(1-0.999)

  - name: api-latency
    description: "P99 latency ниже 500ms для 99% 30-дневного окна"
    sli_query: >
      histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{job="demo-app"}[5m]))
    target: 0.500  # секунды
    window: 30d
```

**Шаг 3 — Создай recording rules для burn rate** (они нужны ДО создания алертов в шаге 4):

```yaml
# ~/sre-bootstrap/monitoring/prometheus/rules/slo_recording_rules.yml
groups:
  - name: slo_recording
    interval: 30s
    rules:
      # availability error ratio (1 = 100% ошибок)
      - record: job:http_error_ratio:rate5m
        expr: >
          sum(rate(http_requests_total{job="demo-app",status=~"5.."}[5m]))
          / sum(rate(http_requests_total{job="demo-app"}[5m]))

      - record: job:http_error_ratio:rate1h
        expr: >
          sum(rate(http_requests_total{job="demo-app",status=~"5.."}[1h]))
          / sum(rate(http_requests_total{job="demo-app"}[1h]))

      - record: job:http_error_ratio:rate6h
        expr: >
          sum(rate(http_requests_total{job="demo-app",status=~"5.."}[6h]))
          / sum(rate(http_requests_total{job="demo-app"}[6h]))

      # burn rate = error_ratio / (1 - SLO_target)
      # Для SLO=99.9% знаменатель = 0.001
      - record: job:slo_burn_rate:rate5m
        expr: job:http_error_ratio:rate5m / 0.001

      - record: job:slo_burn_rate:rate1h
        expr: job:http_error_ratio:rate1h / 0.001

      - record: job:slo_burn_rate:rate6h
        expr: job:http_error_ratio:rate6h / 0.001
```

**Шаг 4 — Алерты на основе recording rules** (multi-window, Google SRE Book):

```yaml
# ~/sre-bootstrap/monitoring/prometheus/rules/slo_alerts.yml
groups:
  - name: slo_burnrate_alerts
    rules:
      # Page: быстрое сжигание — бюджет кончится через ~1ч
      # burn_rate > 14.4 = израсходуем весь месячный бюджет за 2ч
      - alert: SloBurnRateFast
        expr: >
          job:slo_burn_rate:rate5m > 14.4
          and
          job:slo_burn_rate:rate1h > 14.4
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Fast burn: при текущем темпе бюджет кончится через ~1ч"
          runbook: "https://wiki/runbook-high-error-rate"

      # Ticket: медленное сжигание — бюджет кончится через ~3 дня
      # burn_rate > 3 = весь бюджет за 10 дней
      - alert: SloBurnRateSlow
        expr: >
          job:slo_burn_rate:rate1h > 3
          and
          job:slo_burn_rate:rate6h > 3
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Slow burn: при текущем темпе бюджет кончится через ~3 дня"
```

**Шаг 5 — Error Budget Dashboard в Grafana** (4 панели):

```promql
# Панель 1: Remaining Error Budget (%)
(1 - job:http_error_ratio:rate1h / 0.001 * (1/720)) * 100

# Панель 2: Current burn rate (1h)
job:slo_burn_rate:rate1h

# Панель 3: Availability (%) за последние 24ч
(1 - job:http_error_ratio:rate1h) * 100

# Панель 4: SLO status — threshold line на 99.9
(1 - job:http_error_ratio:rate5m) * 100
```

Перезагрузи Prometheus после добавления rules: `curl -X POST http://localhost:9090/-/reload`

---

### Задание 1.3 — Alertmanager: Умная маршрутизация (1.5 ч)

**Что делаешь:** Настраиваешь production-ready routing с дедупликацией, группировкой и ингибицией.

{% raw %}
```yaml
# alertmanager/alertmanager.yml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'job', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'default-slack'
  routes:
    - matchers:
        - severity = "critical"
      receiver: 'slack-critical'
      continue: false
    - matchers:
        - severity = "warning"
      receiver: 'slack-warnings'
      group_wait: 2m

receivers:
  - name: 'default-slack'
    slack_configs:
      - api_url: 'YOUR_WEBHOOK_URL'  # создай тестовый webhook на webhook.site
        channel: '#alerts'
        title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'

  - name: 'slack-critical'
    slack_configs:
      - api_url: 'YOUR_WEBHOOK_URL'
        channel: '#oncall-critical'
        title: '🔥 CRITICAL: {{ .GroupLabels.alertname }}'

  - name: 'slack-warnings'
    slack_configs:
      - api_url: 'YOUR_WEBHOOK_URL'
        channel: '#alerts'

inhibit_rules:
  # Если critical — не шумим warning для того же сервиса
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'job']

  # Если весь node down — не шумим про сервисы на нём
  - source_matchers:
      - alertname = "NodeDown"
    target_matchers:
      - alertname =~ ".*"
    equal: ['instance']
```
{% endraw %}

**Подзадачи:**
1. Зарегистрируй бесплатный webhook на `https://webhook.site` — подставь URL в конфиг
2. Протестируй через `amtool`:

   ```bash
   # Установка amtool
   docker run --rm --network monitoring_default \
     prom/alertmanager:v0.27.0 amtool \
     --alertmanager.url=http://alertmanager:9093 \
     alert add alertname=TestCritical severity=critical job=demo-app \
     --annotation summary="Test alert"
   ```

3. Убедись что `inhibit_rules` работают: создай critical + warning алерт с одинаковым `job` лейблом — warning должен быть suppressed
4. Напиши ещё 3 собственных inhibit правила для типичных сценариев

---

### Задание 1.4 — Grafana Alerting (1 ч)

**Что делаешь:** Настраиваешь Grafana Unified Alerting (не legacy) с Contact Points и Notification Policies.

**Практика:**
1. Grafana → Alerting → Contact Points → Add: Slack webhook (тот же с webhook.site)
2. Notification Policies: группировка по лейблу `severity`
3. Создай 3 alert rules из Grafana UI:
   - `HighCPU`: `100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80`
   - `HighMemory`: `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85`
   - `HighErrorRate`: `job:http_error_ratio:rate5m > 0.05` (требует recording rules из задания 1.2)

4. Сохрани все дашборды как JSON для GitOps:

   ```bash
   # ✅ Исправленная версия — сохраняет каждый дашборд в отдельный файл
   mkdir -p ~/sre-bootstrap/monitoring/grafana/dashboards-export

   curl -s "http://admin:sre_admin@localhost:3000/api/search?type=dash-db" | \
     jq -r '.[].uid' | \
   while read -r uid; do
     curl -s "http://admin:sre_admin@localhost:3000/api/dashboards/uid/${uid}" | \
       jq '.dashboard' > \
       ~/sre-bootstrap/monitoring/grafana/dashboards-export/"${uid}.json"
     echo "Exported: ${uid}"
   done
   ```

---

## ДЕНЬ 2 — Логирование, Kubernetes и API Gateway

> **Цель дня:** Построить централизованный logging pipeline, освоить production паттерны k8s и настроить KrakenD как единую точку входа.

**Время:** ~8–9 часов

> ⚠️ **В самом начале дня** запусти minikube — он стартует 5–10 минут:
> ```bash
> minikube start --cpus=4 --memory=8192 --driver=docker
> minikube addons enable ingress
> minikube addons enable metrics-server
> ```
> Пока minikube стартует — приступай к заданию 2.1.

---

### Задание 2.1 — ELK Stack: Production Setup (2.5 ч)

**Что делаешь:** Разворачиваешь ELK с правильными index policies и structured logging.

```yaml
# ~/sre-bootstrap/logging/compose.yml
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.13.0
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
    volumes:
      - es_data:/usr/share/elasticsearch/data
    ports: ["9200:9200"]
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'"]
      interval: 10s
      timeout: 5s
      retries: 10

  logstash:
    image: docker.elastic.co/logstash/logstash:8.13.0
    # ✅ depends_on + healthcheck: Logstash стартует только когда ES готов
    depends_on:
      elasticsearch:
        condition: service_healthy
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml
    ports: ["5044:5044", "9600:9600"]

  kibana:
    image: docker.elastic.co/kibana/kibana:8.13.0
    depends_on:
      elasticsearch:
        condition: service_healthy
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    ports: ["5601:5601"]
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:5601/api/status | grep -q '\"level\":\"available\"'"]
      interval: 15s
      timeout: 5s
      retries: 10

  filebeat:
    image: docker.elastic.co/beats/filebeat:8.13.0
    depends_on:
      elasticsearch:
        condition: service_healthy
    user: root
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command: filebeat -e -strict.perms=false

volumes:
  es_data:
```

**Практические подзадачи:**

1. Напиши **Logstash pipeline** для парсинга Nginx access logs:

   ```ruby
   # logstash/pipeline/nginx.conf
   input {
     beats { port => 5044 }
   }
   filter {
     if [fields][log_type] == "nginx" {
       # ✅ %{NGINXACCESS} — НЕ существует.
       # Используем стандартный %{COMBINEDAPACHELOG} (совместим с Nginx combined format)
       grok {
         match => { "message" => "%{COMBINEDAPACHELOG}" }
       }
       date {
         match => ["timestamp", "dd/MMM/yyyy:HH:mm:ss Z"]
         target => "@timestamp"
       }
       geoip {
         source => "clientip"
         target => "geoip"
       }
       mutate {
         convert => {
           "response" => "integer"
           "bytes"    => "integer"
         }
         remove_field => ["message", "timestamp"]
       }
     }
   }
   output {
     elasticsearch {
       hosts => ["elasticsearch:9200"]
       index => "nginx-%{+YYYY.MM.dd}"
     }
   }
   ```

2. Настрой **Index Lifecycle Policy (ILM)** через Kibana Dev Tools (Stack Management → ILM):

   ```json
   PUT _ilm/policy/nginx-logs-policy
   {
     "policy": {
       "phases": {
         "hot":    { "min_age": "0ms", "actions": { "rollover": { "max_age": "7d" }, "set_priority": { "priority": 100 } } },
         "warm":   { "min_age": "7d",  "actions": { "forcemerge": { "max_num_segments": 1 }, "readonly": {}, "set_priority": { "priority": 50 } } },
         "cold":   { "min_age": "30d", "actions": { "set_priority": { "priority": 0 } } },
         "delete": { "min_age": "90d", "actions": { "delete": {} } }
       }
     }
   }
   ```

3. Настрой **Filebeat autodiscover**:

   ```yaml
   # filebeat/filebeat.yml
   filebeat.autodiscover:
     providers:
       - type: docker
         hints.enabled: true
         templates:
           - condition:
               contains:
                 docker.container.labels.collect_logs: "true"
             config:
               - type: container
                 paths:
                   - /var/lib/docker/containers/${data.docker.container.id}/*.log
                 fields:
                   log_type: nginx
                 fields_under_root: false

   output.logstash:
     hosts: ["logstash:5044"]
   ```

4. Создай **Kibana Dashboard** с 4 визуализациями:
   - HTTP status codes distribution (Pie)
   - Top 10 requested endpoints (Bar — aggregation на `request.keyword`)
   - Error rate over time (Line — filter на `response >= 400`)
   - Geographic map (Maps → Documents layer → поле `geoip.location`)

---

### Задание 2.2 — Kubernetes: Production Patterns (2.5 ч)

> ℹ️ minikube должен быть уже запущен (ты запустил его в начале дня). Проверь: `kubectl get nodes`

**Практика 1 — Namespace и деплой тестового приложения:**

```bash
kubectl create namespace production
```

```yaml
# k8s/app-deployment.yml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "80"
        prometheus.io/path: "/"
    spec:
      containers:
        - name: demo-app
          # ✅ nginx:alpine слушает на порту 80, НЕ 8080.
          # Используем его корректно — проверяем реально существующий путь /
          image: nginx:1.27.3-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /          # ✅ nginx:alpine отвечает на / с 200
              port: 80         # ✅ правильный порт
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /          # ✅ правильный путь
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: production
spec:
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
# Применяем и проверяем что поды действительно Running (не CrashLoopBackOff)
kubectl apply -f k8s/app-deployment.yml
kubectl get pods -n production --watch
# Все 3 пода должны показать: Running / 1/1 Ready
```

**Практика 2 — Ingress Nginx с rate limiting:**

```yaml
# k8s/ingress.yml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "10"           # ✅ правильная аннотация для rps
    nginx.ingress.kubernetes.io/limit-connections: "5"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  rules:
    - host: demo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo-app
                port:
                  number: 80
```

```bash
kubectl apply -f k8s/ingress.yml

# Добавь demo.local в /etc/hosts
echo "$(minikube ip) demo.local" | sudo tee -a /etc/hosts

# Проверь что ingress работает
curl http://demo.local
```

**Практика 3 — HorizontalPodAutoscaler:**

```yaml
# k8s/hpa.yml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: demo-app-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: demo-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: AverageValue
          averageValue: 200Mi
```

**Практика 4 — Нагрузка и наблюдение за автоскейлингом:**

```bash
kubectl apply -f k8s/hpa.yml

# Создай нагрузку (busybox доступен в minikube)
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -n production \
  -- sh -c "while true; do wget -q -O- http://demo-app.production.svc.cluster.local; done"

# В отдельном терминале — наблюдай за скейлингом
kubectl get hpa demo-app-hpa -n production --watch

# Остановить нагрузку:
kubectl delete pod load-generator -n production
```

---

### Задание 2.3 — KrakenD API Gateway (1.5 ч)

**Что делаешь:** Настраиваешь KrakenD как единую точку входа с rate limiting, circuit breaker и метриками в Prometheus.

> ℹ️ KrakenD запускается отдельным docker compose, но шлёт метрики в уже работающий Prometheus из Дня 1. Убедись что monitoring-стек запущен.

```yaml
# ~/sre-bootstrap/monitoring/krakend/compose.yml
services:
  krakend:
    image: devopsfaith/krakend:2.7
    volumes:
      - ./krakend.json:/etc/krakend/krakend.json
    ports:
      - "8090:8090"   # API gateway
      - "9091:9091"   # Prometheus metrics endpoint
    command: ["run", "-c", "/etc/krakend/krakend.json"]

  # Простой backend для тестирования circuit breaker и rate limiting
  httpbin:
    image: kennethreitz/httpbin:latest  # у образа нет версионных тегов — редкое исключение из правила
    ports: ["8091:80"]
```

```json
// ~/sre-bootstrap/monitoring/krakend/krakend.json
{
  "$schema": "https://www.krakend.io/schema/v2.7/krakend.json",
  "version": 3,
  "name": "SRE Demo Gateway",
  "timeout": "3000ms",
  "endpoints": [
    {
      "endpoint": "/api/v1/get",
      "method": "GET",
      "timeout": "2000ms",
      "backend": [
        {
          "url_pattern": "/get",
          "host": ["http://httpbin:80"],
          "timeout": "1500ms"
        }
      ],
      "extra_config": {
        "qos/ratelimit/router": {
          "max_rate": 20,
          "client_max_rate": 5,
          "strategy": "ip"
        },
        "qos/circuit-breaker": {
          "interval": 60,
          "timeout": 10,
          "max_errors": 5,
          "log_status_change": true
        }
      }
    },
    {
      "endpoint": "/api/v1/status/{code}",
      "method": "GET",
      "backend": [
        {
          "url_pattern": "/status/{code}",
          "host": ["http://httpbin:80"]
        }
      ]
    }
  ],
  "extra_config": {
    "telemetry/opentelemetry": {
      "service_name": "krakend-gateway",
      "metric_reporting_period": 1,
      "exporters": {
        "prometheus": [{ "port": 9091, "process_metrics": true }]
      }
    }
  }
}
```

```bash
# Запусти KrakenD
cd ~/sre-bootstrap/monitoring/krakend && docker compose up -d

# Проверь что metrics endpoint доступен
curl http://localhost:9091/metrics | grep krakend

# Протестируй rate limiting: выполни 10 запросов подряд
for i in {1..10}; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8090/api/v1/get; done
# После 5 запросов должен появиться 429 Too Many Requests
```

**Добавь KrakenD в prometheus.yml** (обновление конфига Дня 1):

```yaml
# Добавить в ~/sre-bootstrap/monitoring/prometheus/prometheus.yml
  - job_name: krakend
    static_configs:
      - targets: ["host.docker.internal:9091"]  # host.docker.internal = твой хост из контейнера
```

```bash
# Перезагрузи Prometheus
curl -X POST http://localhost:9090/-/reload

# Проверь в Prometheus UI: Status → Targets → krakend должен быть UP
```

**Подзадачи:**
1. Создай Grafana дашборд для KrakenD (3 панели): req/s по endpoint, error rate, p99 latency
2. Протестируй circuit breaker: `docker compose stop httpbin` → наблюдай как KrakenD начинает возвращать 500 и метрика `krakend_backend_requests_total` растёт с лейблом `error=true`
3. Верни `httpbin`: `docker compose start httpbin` → убедись что circuit breaker восстановился через 10с

---

## ДЕНЬ 3 — Автоматизация, CI/CD и PostgreSQL

> **Цель дня:** Создать инструменты, которые реально уберут ручной труд (toil elimination), автоматизировать операции с БД, построить надёжный CI/CD pipeline.

**Время:** ~8–9 часов

---

### Задание 3.1 — Shell Scripts: Toil Elimination Toolkit (2 ч)

**Что делаешь:** Создаёшь библиотеку SRE-скриптов, которую принесёшь на новую работу.

**Скрипт 1 — System Health Report:**
{% raw %}
```bash
#!/bin/bash
# ~/sre-bootstrap/scripts/health-report.sh
set -euo pipefail

THRESHOLD_CPU=80
THRESHOLD_MEM=85
THRESHOLD_DISK=90
REPORT_FILE="/tmp/health-report-$(date +%Y%m%d-%H%M%S).txt"

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$REPORT_FILE"; }
alert() { echo "🚨 ALERT: $*" | tee -a "$REPORT_FILE"; }

check_cpu() {
  local cpu_usage
  # top -bn1 вывод немного отличается на разных дистрибутивах; этот паттерн работает на Ubuntu
  cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d',' -f1)
  log "CPU Usage: ${cpu_usage}%"
  if (( $(echo "$cpu_usage > $THRESHOLD_CPU" | bc -l) )); then
    alert "CPU ${cpu_usage}% > threshold ${THRESHOLD_CPU}%"
  fi
}

check_memory() {
  local mem_usage
  mem_usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
  log "Memory Usage: ${mem_usage}%"
  if (( mem_usage > THRESHOLD_MEM )); then
    alert "Memory ${mem_usage}% > threshold ${THRESHOLD_MEM}%"
  fi
}

check_disk() {
  while IFS= read -r line; do
    local usage mount
    usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    if (( usage > THRESHOLD_DISK )); then
      alert "Disk ${mount}: ${usage}% > threshold ${THRESHOLD_DISK}%"
    fi
    log "Disk ${mount}: ${usage}%"
  done < <(df -h | grep -vE '^Filesystem|tmpfs|cdrom|udev')
}

check_docker_containers() {
  log "=== Docker Container Health ==="
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" | tee -a "$REPORT_FILE"
  docker ps --filter "status=restarting" --format "{{.Names}}" | while read -r name; do
    alert "Container $name is RESTARTING"
  done
}

main() {
  log "=== Health Report Start ==="
  check_cpu
  check_memory
  check_disk
  check_docker_containers
  log "=== Health Report End === File: $REPORT_FILE"
}

main "$@"
```
{% endraw %}

**Скрипт 2 — Docker Cleanup (Toil Elimination):**

```bash
#!/bin/bash
# scripts/docker-cleanup.sh
set -euo pipefail

echo "=== Before cleanup ==="
docker system df

docker container prune -f
docker image prune -f --filter "until=72h"
docker volume prune -f --filter "label!=keep"
docker network prune -f

echo "=== After cleanup ==="
docker system df
```

**Скрипт 3 — Service Availability Checker:**

```bash
#!/bin/bash
# scripts/check-services.sh
# Ассоциативные массивы требуют bash 4+. Проверь: bash --version
declare -A SERVICES=(
  ["Prometheus"]="http://localhost:9090/-/healthy"
  ["Grafana"]="http://localhost:3000/api/health"
  ["Alertmanager"]="http://localhost:9093/-/healthy"
  ["Kibana"]="http://localhost:5601/api/status"
  ["Elasticsearch"]="http://localhost:9200/_cluster/health"
  ["KrakenD"]="http://localhost:8090/__health"
)

check_service() {
  local name=$1 url=$2
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" ]]; then
    echo "✅ $name — UP (HTTP $http_code)"
  else
    echo "❌ $name — DOWN (HTTP $http_code) → $url"
  fi
}

echo "=== Service Health Check: $(date) ==="
for service in "${!SERVICES[@]}"; do
  check_service "$service" "${SERVICES[$service]}"
done
```

---

### Задание 3.2 — PostgreSQL: Backup, Restore, Monitoring (2 ч)

**Что делаешь:** Строишь полный цикл операций с PostgreSQL — от бэкапов до мониторинга.

```yaml
# ~/sre-bootstrap/database/compose.yml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: sre_demo
      POSTGRES_USER: sre_user
      POSTGRES_PASSWORD: sre_pass
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d
    ports: ["5432:5432"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sre_user -d sre_demo"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:v0.15.0
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATA_SOURCE_NAME: "postgresql://sre_user:sre_pass@postgres:5432/sre_demo?sslmode=disable"
    ports: ["9187:9187"]

volumes:
  pg_data:
```

**Скрипт автоматического бэкапа с ротацией:**

```bash
#!/bin/bash
# scripts/pg-backup.sh
set -euo pipefail

# ✅ Все переменные с дефолтами — скрипт работает и без env-переменных
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-sre_demo}"
DB_USER="${DB_USER:-sre_user}"
DB_PASSWORD="${DB_PASSWORD:-sre_pass}"   # ✅ была пропущена в предыдущей версии
BACKUP_DIR="${BACKUP_DIR:-/tmp/pg-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

mkdir -p "$BACKUP_DIR"

log "Starting backup: $DB_NAME → $BACKUP_FILE"
PGPASSWORD="$DB_PASSWORD" pg_dump \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  --format=plain \
  "$DB_NAME" | gzip > "$BACKUP_FILE"

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log "Backup complete. Size: $BACKUP_SIZE"

# Верификация целостности архива
if gzip -t "$BACKUP_FILE" 2>/dev/null; then
  log "✅ Integrity check PASSED"
else
  log "❌ Integrity check FAILED — removing corrupt file"
  rm -f "$BACKUP_FILE"
  exit 1
fi

# Ротация старых бэкапов
DELETED=$(find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
log "Rotated $DELETED old backup(s) older than $RETENTION_DAYS days"
log "Current backups: $(ls -1 "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l) files"
```

**Скрипт восстановления с проверкой:**

```bash
#!/bin/bash
# scripts/pg-restore.sh
set -euo pipefail

# ✅ Все переменные с дефолтами
BACKUP_FILE="${1:?Usage: $0 <backup_file.sql.gz> [target_db]}"
DB_NAME="${2:-sre_demo_restored}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-sre_user}"
DB_PASSWORD="${DB_PASSWORD:-sre_pass}"  # ✅ была пропущена в предыдущей версии

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

[[ -f "$BACKUP_FILE" ]] || { log "ERROR: File not found: $BACKUP_FILE"; exit 1; }

# Проверь целостность перед восстановлением
gzip -t "$BACKUP_FILE" || { log "ERROR: Backup file is corrupt"; exit 1; }

log "⚠️  Will restore $BACKUP_FILE → database: $DB_NAME on $DB_HOST:$DB_PORT"
read -r -p "Confirm destructive operation [yes/N]: " confirm
[[ "$confirm" == "yes" ]] || { log "Aborted."; exit 0; }

PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
  -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
  -c "CREATE DATABASE \"$DB_NAME\";"

log "Restoring data..."
gunzip -c "$BACKUP_FILE" | \
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"

TABLE_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
log "✅ Restore complete. Public tables: ${TABLE_COUNT// /}"
```

**Добавь postgres-exporter в Prometheus** (обновление конфига Дня 1):

```yaml
# Добавить в prometheus.yml
  - job_name: postgres
    static_configs:
      - targets: ["host.docker.internal:9187"]
```

**Prometheus алерты для PostgreSQL:**
{% raw %}
```yaml
# rules/postgresql_alerts.yml
groups:
  - name: postgresql
    rules:
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "PostgreSQL на {{ $labels.instance }} недоступен"

      - alert: PostgreSQLHighConnections
        expr: >
          pg_stat_activity_count
          / pg_settings_max_connections > 0.8
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "PostgreSQL connections >80% от max_connections ({{ $value | humanizePercentage }})"

      - alert: PostgreSQLLongRunningQuery
        expr: pg_stat_activity_max_tx_duration > 300
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: "Транзакция выполняется >5 минут"

      - alert: PostgreSQLDeadlocks
        expr: rate(pg_stat_database_deadlocks[5m]) > 0
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Обнаружены deadlocks в PostgreSQL"
```
{% endraw %}

---

### Задание 3.3 — GitLab CI/CD: Production Pipeline (2.5 ч)

**Что делаешь:** Создаёшь полный CI/CD pipeline с этапами сборки, тестирования, security scan и деплоя.

> ℹ️ Деплой в Kubernetes в учебном окружении требует настройки kubeconfig в GitLab CI. Для практики на локальном minikube — устанавливай GitLab Runner локально (`gitlab-runner install`) или используй `shell` executor.

```yaml
# .gitlab-ci.yml
stages:
  - validate
  - build
  - test
  - security
  - deploy-staging
  - integration-test
  - deploy-production

variables:
  DOCKER_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  DOCKER_BUILDKIT: "1"

# ──────────────── VALIDATE ────────────────
lint-dockerfile:
  stage: validate
  image: hadolint/hadolint:2.12.0-alpine
  script:
    - hadolint Dockerfile
  rules:
    - changes: [Dockerfile]

lint-k8s-manifests:
  stage: validate
  image: bitnami/kubectl:1.29
  script:
    - kubectl --dry-run=client apply -f k8s/ 2>&1
  rules:
    - changes: ["k8s/**/*"]

# ──────────────── BUILD ────────────────
build-image:
  stage: build
  image: docker:24-dind
  services: [docker:24-dind]
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    - docker build --cache-from $CI_REGISTRY_IMAGE:latest -t $DOCKER_IMAGE .
    - docker push $DOCKER_IMAGE
    - docker tag $DOCKER_IMAGE $CI_REGISTRY_IMAGE:latest
    - docker push $CI_REGISTRY_IMAGE:latest
  only: [main, merge_requests]

# ──────────────── SECURITY ────────────────
trivy-scan:
  stage: security
  image: aquasec/trivy:0.58.1
  script:
    - trivy image --exit-code 0 --severity LOW,MEDIUM --format table $DOCKER_IMAGE
    - trivy image --exit-code 1 --severity HIGH,CRITICAL $DOCKER_IMAGE
  needs: [build-image]
  only: [main]

secrets-scan:
  stage: security
  image: trufflesecurity/trufflehog:3.88.0
  script:
    - trufflehog git file://. --only-verified --fail
  allow_failure: true
  only: [main]

# ──────────────── DEPLOY STAGING ────────────────
deploy-staging:
  stage: deploy-staging
  image: bitnami/kubectl:1.29
  environment:
    name: staging
    url: https://staging.example.com
  before_script:
    # ✅ Правильная настройка kubeconfig из CI переменной
    - mkdir -p ~/.kube
    - echo "$KUBECONFIG_STAGING" | base64 -d > ~/.kube/config
    - chmod 600 ~/.kube/config
  script:
    - envsubst < k8s/deployment.yml | kubectl apply -f -
    - kubectl rollout status deployment/demo-app -n staging --timeout=120s
  only: [main]

# ──────────────── INTEGRATION TEST ────────────────
integration-tests:
  stage: integration-test
  image: curlimages/curl:8.11.1
  script:
    - curl -f --retry 5 --retry-delay 3 https://staging.example.com/ || exit 1
    - echo "✅ Integration tests passed"
  needs: [deploy-staging]
  only: [main]

# ──────────────── DEPLOY PRODUCTION ────────────────
deploy-production:
  stage: deploy-production
  image: bitnami/kubectl:1.29
  environment:
    name: production
    url: https://app.example.com
  before_script:
    - mkdir -p ~/.kube
    - echo "$KUBECONFIG_PROD" | base64 -d > ~/.kube/config
    - chmod 600 ~/.kube/config
  script:
    - envsubst < k8s/deployment.yml | kubectl apply -f -
    - kubectl rollout status deployment/demo-app -n production --timeout=300s
  when: manual
  only: [main]

rollback-production:
  stage: deploy-production
  image: bitnami/kubectl:1.29
  before_script:
    - mkdir -p ~/.kube
    - echo "$KUBECONFIG_PROD" | base64 -d > ~/.kube/config
    - chmod 600 ~/.kube/config
  script:
    - kubectl rollout undo deployment/demo-app -n production
    - kubectl rollout status deployment/demo-app -n production --timeout=120s
  when: manual
  only: [main]
```

```makefile
# Makefile
.PHONY: up-monitoring up-logging up-db up-all down-all logs health-check backup

up-monitoring:
	cd monitoring && docker compose up -d

up-logging:
	cd logging && docker compose up -d

up-db:
	cd database && docker compose up -d

up-all: up-monitoring up-logging up-db

down-all:
	cd monitoring && docker compose down
	cd logging && docker compose down
	cd database && docker compose down

logs:
	cd monitoring && docker compose logs -f --tail=100

health-check:
	bash scripts/check-services.sh

backup:
	bash scripts/pg-backup.sh
```

---

## ДЕНЬ 4 — Incident Management, Capacity Planning, Chaos Drill

> **Цель дня:** Выстроить процессы и документацию, которые делают тебя готовой к первому инциденту. Провести полный chaos drill с замером MTTR.

**Время:** ~7–8 часов

> ⚠️ **Перед началом Дня 4** убедись что все стеки запущены:
> ```bash
> # Запусти всё если не запущено
> make up-all
>
> # Проверь
> bash scripts/check-services.sh
> kubectl get pods -n production
> ```

---

### Задание 4.1 — Incident Response Playbooks (1.5 ч)

**Что делаешь:** Создаёшь набор runbooks для типичных инцидентов.

**Шаблон Runbook:**

````markdown
# Runbook: [НАЗВАНИЕ ИНЦИДЕНТА]

## Metadata
- Severity: P1/P2/P3/P4
- Estimated MTTR: X минут
- Last Updated: YYYY-MM-DD

## Симптомы
- [ ] Алерт X в Grafana/Alertmanager
- [ ] Метрики показывают Y

## Диагностика (выполнять последовательно)
1. Проверить состояние сервисов:
   ```bash

   kubectl get pods -n production | grep -v Running
   docker ps --filter "status=restarting"

   ```
2. Проверить логи:
   ```bash

   kubectl logs -n production -l app=demo-app --tail=100 | grep -iE "error|fatal|panic"

   ```
3. Открыть Grafana дашборд: [ссылка]

## Шаги восстановления
1. [Конкретное действие с командой]
2. [Конкретное действие с командой]
3. Подтвердить что алерт resolved в Alertmanager

## Эскалация
- MTTR > 30 мин → эскалировать на [роль]
- Затронуты данные → немедленно → Security/Legal

## Post-incident
- [ ] Обновить runbook если нашли новый паттерн
- [ ] Завести задачу на устранение первопричины (ticket)
- [ ] Провести постмортем если P1/P2
````

**Создай 5 runbooks:**

1. `runbook-high-cpu.md`
2. `runbook-pod-crashloopbackoff.md`
3. `runbook-postgresql-connections-exhausted.md`
4. `runbook-disk-space-critical.md`
5. `runbook-deployment-rollback.md`

---

### Задание 4.2 — Blameless Postmortem Template (1 ч)

```markdown
# Постмортем: [Краткое описание инцидента]

**Дата инцидента:** YYYY-MM-DD
**Длительность:** X часов Y минут
**Severity:** P1 | P2 | P3
**Автор:** [Имя]
**Статус:** Draft | In Review | Completed

---

## 📊 Влияние (Impact)
| Метрика                         | Значение                      |
|---------------------------------|-------------------------------|
| Затронутые пользователи         | ~X (Y% от общей базы)         |
| Недоступность сервиса           | X мин (из 43,200 мин/мес)     |
| Сжигание Error Budget           | X% (осталось Y%)              |
| Финансовые потери (если известно) | $X                          |

---

## 📅 Timeline (UTC)
| Время   | Событие                                       | Кто    |
|---------|-----------------------------------------------|--------|
| HH:MM   | Первый алерт в Alertmanager                   | System |
| HH:MM   | On-call инженер принял инцидент               | [Имя]  |
| HH:MM   | Первопричина выявлена                         | [Имя]  |
| HH:MM   | Митигация применена                           | [Имя]  |
| HH:MM   | Сервис восстановлен                           | System |
| HH:MM   | Постинцидентный мониторинг завершён           | [Имя]  |

**MTTD:** X мин | **MTTR:** X мин | **MTBF:** X дней

---

## 🔍 Root Cause Analysis (5 Whys)

**Симптом:** [что видели пользователи и системы]

| #  | Почему?                               | Ответ            |
|----|---------------------------------------|------------------|
| 1  | Почему сервис был недоступен?         |                  |
| 2  | Почему X произошло?                   |                  |
| 3  | Почему не было предотвращено Y?       |                  |
| 4  | Почему не сработал safeguard Z?       |                  |
| 5  | Коренная причина:                     | **[Root Cause]** |

**Способствующие факторы:**
- [фактор 1]
- [фактор 2]

---

## ✅ Что сработало хорошо
1. [без "повезло"]

## ⚠️ Что пошло не так
1. [без обвинений, только факты о системе]

---

## 🔧 Action Items
| Задача                 | Приоритет | Ответственный | Срок       | Статус |
|------------------------|-----------|---------------|------------|--------|
| [Конкретное действие]  | P1        | [Имя]         | YYYY-MM-DD | Open   |

---

## 📚 Выводы
[2–3 предложения: что команда вынесла из инцидента]

---
*Blameless postmortem: цель — улучшение систем, не поиск виноватых.*
```

---

### Задание 4.3 — Chaos Engineering Drill (2 ч)

**Что делаешь:** Намеренно ломаешь окружение и восстанавливаешь по своим runbooks. Замеряешь MTTD и MTTR.

**Упражнение 1 — Kill a container:**

```bash
# Терминал 1: наблюдение
watch -n 2 'bash ~/sre-bootstrap/scripts/check-services.sh'

# Терминал 2: сломай Grafana
# ✅ Правильная команда для Docker Compose v2 (имя контейнера зависит от имени директории)
cd ~/sre-bootstrap/monitoring
docker compose stop grafana

# Зафиксируй:
# MTTD = через сколько секунд watch показал ❌ ?
# Восстановление:
docker compose start grafana
# MTTR = время от kill до restart_policy поднял контейнер (если настроен restart: always)

# Важно: убедись что в compose.yml есть restart: unless-stopped для Grafana
```

**Упражнение 2 — Pod CrashLoopBackOff в Kubernetes:**

```bash
# Намеренно задеплой сломанную конфигурацию
kubectl set image deployment/demo-app demo-app=nginx:nonexistent-tag -n production

# Наблюдай
kubectl get pods -n production --watch
# Через ~30с поды перейдут в ImagePullBackOff → применяй runbook-pod-crashloopbackoff.md

# Восстановление через rollback
kubectl rollout undo deployment/demo-app -n production
kubectl rollout status deployment/demo-app -n production --timeout=60s
```

**Упражнение 3 — PostgreSQL disaster recovery (полный цикл):**

```bash
# Убедись что postgres запущен
cd ~/sre-bootstrap/database && docker compose up -d
sleep 5

# 1. Создай тестовые данные
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_demo -c "
  CREATE TABLE IF NOT EXISTS chaos_test AS
  SELECT generate_series(1,10000) AS id, now() AS created_at, md5(random()::text) AS data;
"

# 2. Верифицируй данные
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_demo \
  -c "SELECT count(*) FROM chaos_test;"

# 3. Сделай бэкап
bash ~/sre-bootstrap/scripts/pg-backup.sh

# 4. Симулируй catastrofic data loss
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_demo \
  -c "DROP TABLE chaos_test;"

# 5. Восстанови и замерь время
LATEST_BACKUP=$(ls -t /tmp/pg-backups/sre_demo_*.sql.gz | head -1)
time bash ~/sre-bootstrap/scripts/pg-restore.sh "$LATEST_BACKUP" sre_demo_restored

# 6. Верифицируй восстановление
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_demo_restored \
  -c "SELECT count(*) FROM chaos_test;"
# Должно быть 10000
```

**Drill Report (заполни по итогам каждого упражнения):**

```
=== CHAOS DRILL REPORT ===
Drill Name    : [название]
Start Time    : HH:MM
Detection Time: HH:MM    → MTTD = X мин
Recovery Time : HH:MM    → MTTR = X мин
Runbook Used  : [имя файла]
Runbook gaps  : [что runbook не покрыл — добавь это в runbook]
Action Item   : [что нужно автоматизировать/улучшить]
```

---

### Задание 4.4 — Capacity Planning (1.5 ч)

**Что делаешь:** Создаёшь модель capacity planning на реальных метриках Prometheus.

> ℹ️ `predict_linear` требует достаточного количества данных в lookback window. После 1–2 дней работы стека данных хватит. Если данных меньше — используй `[2h:1m]` вместо `[7d:1h]`.

**PromQL запросы для capacity planning:**

```promql
# CPU: прогноз сколько дней до 80% порога
# (возвращает значение в секундах, дели на 86400 для дней)
predict_linear(
  (100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)[2h:1m],
  7 * 24 * 3600
)

# Memory: сколько байт будет available через 30 дней
predict_linear(node_memory_MemAvailable_bytes[2h:1m], 30*24*3600)

# Disk: сколько байт будет available через 30 дней
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[2h:1m], 30*24*3600)

# ✅ Latency trend — используем subquery корректно:
predict_linear(
  histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{job="demo-app"}[5m]))[2h:1m],
  7*24*3600
)
```

**Grafana Capacity Planning Dashboard** (4 панели):
1. **CPU Days to 80%** — Stat panel, формула: `(0.8 * 100 - current_cpu) / rate_per_day` (рассчитай вручную)
2. **Memory trend** — Time series с двумя линиями: actual + predict_linear
3. **Disk trend** — Time series с двумя линиями: actual + predict_linear
4. **Overview table** — Table panel с текущими значениями и статусом ✅⚠️🔴

**Шаблон Capacity Planning Report:**

```markdown
# Capacity Planning Report — [Дата]

## Текущее состояние
| Ресурс | Использование | Порог | Тренд    | Статус |
|--------|--------------|-------|----------|--------|
| CPU    | X%           | 70%   | +Y%/нед  | ✅/⚠️/🔴 |
| Memory | X%           | 80%   | +Y%/нед  | ✅/⚠️/🔴 |
| Disk   | X%           | 85%   | +Y GB/нед | ✅/⚠️/🔴 |

## Прогнозы (7-дневный тренд)
- CPU достигнет 70% через: X дней
- Memory достигнет 80% через: X дней
- Disk заполнится на 85% через: X дней

## Рекомендации
1. [Конкретная рекомендация с обоснованием и ожидаемым эффектом]
```

---

## Итоговый чеклист перед выходом на работу

### Артефакты, которые ты берёшь с собой

```
~/sre-bootstrap/
├── monitoring/
│   ├── compose.yml                 ✅ Production-ready стек + demo-app
│   ├── prometheus/prometheus.yml   ✅ Scrape configs для всех сервисов
│   ├── prometheus/rules/
│   │   ├── slo_recording_rules.yml ✅ Recording rules (burn rate)
│   │   ├── slo_alerts.yml          ✅ Multi-window SLO алерты
│   │   └── postgresql_alerts.yml   ✅ PostgreSQL алерты
│   ├── alertmanager/alertmanager.yml ✅ Routing + inhibit rules
│   ├── grafana/provisioning/       ✅ Datasource as code
│   ├── krakend/
│   │   ├── compose.yml             ✅ KrakenD + httpbin
│   │   └── krakend.json            ✅ Rate limit + circuit breaker
│   └── slo-definitions.yml         ✅ SLO фреймворк
├── logging/
│   ├── compose.yml                 ✅ ELK + depends_on + healthchecks
│   ├── logstash/pipeline/nginx.conf ✅ COMBINEDAPACHELOG pipeline
│   └── filebeat/filebeat.yml       ✅ Docker autodiscover
├── kubernetes/
│   ├── app-deployment.yml          ✅ Проверенные probes (port 80 / path /)
│   ├── hpa.yml                     ✅ Autoscaling
│   └── ingress.yml                 ✅ Nginx Ingress + rate limiting
├── database/
│   └── compose.yml                 ✅ PostgreSQL + exporter + healthcheck
├── scripts/
│   ├── health-report.sh            ✅ System health check
│   ├── docker-cleanup.sh           ✅ Toil elimination
│   ├── check-services.sh           ✅ Service availability
│   ├── pg-backup.sh                ✅ Backup + rotation + integrity check
│   └── pg-restore.sh               ✅ Restore + verification
├── incident/
│   ├── runbook-*.md (5 штук)       ✅ Operational runbooks
│   └── postmortem-template.md      ✅ Blameless postmortem
├── .gitlab-ci.yml                  ✅ Pipeline с kubeconfig setup
└── Makefile                        ✅ Common operations wrapper
```

### Self-check: знания

- [ ] Могу объяснить разницу между SLI, SLO и Error Budget простыми словами
- [ ] Знаю зачем нужны recording rules перед alert rules — и что будет без них
- [ ] Могу объяснить multi-window burn rate (зачем два окна: 5m + 1h)
- [ ] Могу с нуля развернуть Prometheus + Grafana за < 10 минут
- [ ] Знаю PromQL: rate(), histogram_quantile(), predict_linear(), subquery syntax
- [ ] Знаю разницу между depends_on и healthcheck в docker-compose
- [ ] Знаю разницу между liveness и readiness probe и что будет при их неправильной настройке
- [ ] Могу выполнить rollback деплоя в Kubernetes и объяснить как работает rollout history
- [ ] Могу бэкапировать и восстанавливать PostgreSQL с верификацией
- [ ] Умею проводить blameless postmortem и формулировать конкретные action items
- [ ] Знаю 4 golden signals: Latency, Traffic, Errors, Saturation

---

## Первая неделя на новом месте

1. **День 1–2:** Аудит существующей инфраструктуры — документируй что есть
2. **День 3:** Предложи стек мониторинга (готовый docker-compose из этого плана)
3. **Неделя 1:** Договорись о первых SLO с командой разработки
4. **Месяц 1:** Полный стек мониторинга в проде, процесс постмортемов
5. **Квартал 1:** Error Budget policy, первый Capacity Planning Report
