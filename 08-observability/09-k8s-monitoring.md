---
layout: lesson
title: "Мониторинг в Kubernetes: kube-prometheus-stack"
topic: 8
lesson: "8.9"
time: "2 ч"
---

## Зачем это нужно

В Docker Compose ты писал `prometheus.yml` руками и перечислял цели. В Kubernetes поды приходят и уходят, их IP меняются, а статичный список целей мёртв через час. Кроме того, кластер сам нуждается в наблюдении: упавший под, нехватка памяти на узле, застрявший Deployment. На работе это первый пункт после «поставили кластер»: ставят `kube-prometheus-stack`, и через полчаса есть дашборды узлов и подов, а команды подключают свои сервисы одним манифестом.
Шаг проекта: в кластер `kind-notes` ставится стек мониторинга (ns `monitoring`), чарт `helm/notes` получает `ServiceMonitor` и `PrometheusRule` (chart 0.3.0, appVersion 0.7.0), и Prometheus сам находит «Заметки».

## Что нужно знать

- [Урок 5.3: Service и DNS кластера](../05-kubernetes/03-services-dns.md) - ServiceMonitor находит поды через Service и его labels
- [Урок 5.9: Helm](../05-kubernetes/09-helm.md) - ставим стек чартом и расширяем чарт `helm/notes`
- [Урок 5.11: HPA и metrics-server](../05-kubernetes/11-scaling-hpa.md) - чем metrics-server отличается от полноценного мониторинга
- [Урок 8.2: Prometheus](02-prometheus-basics.md) - scrape, target, `/metrics`
- [Урок 8.3: PromQL](03-promql.md) - `rate`, агрегации
- [Урок 8.5: Alertmanager](05-alertmanager.md) - правила алертов и runbook
- [Урок 8.6: Grafana](06-grafana-dashboards.md) - дашборды и datasource

## Теория

### Что ставит kube-prometheus-stack

`kube-prometheus-stack` - один Helm-чарт, который разворачивает связанный набор компонентов:

- **Prometheus Operator** (оператор, operator) - контроллер, который следит за кастомными ресурсами и сам пишет конфиг Prometheus;
- **Prometheus** и **Alertmanager** - создаются из ресурсов `Prometheus` и `Alertmanager`;
- **Grafana** с готовыми дашбордами кластера;
- **node-exporter** - DaemonSet (урок 5.8), метрики каждого узла;
- **kube-state-metrics** - превращает состояние объектов Kubernetes в метрики (`kube_pod_status_phase`, `kube_deployment_status_replicas_available`);
- набор готовых правил алертов и recording rules.

Важно различать источники метрик. cAdvisor (встроен в kubelet) даёт CPU и память контейнеров. node-exporter даёт метрики железа узла. kube-state-metrics говорит, что должно быть (реплики, фазы подов), а не сколько ресурсов съедено. metrics-server из урока 5.11 хранит только последние значения для `kubectl top` и HPA, истории в нём нет.

> **Проверь понимание:** какой компонент подскажет, что у Deployment 3 желаемых реплики, а доступна одна: cAdvisor, node-exporter или kube-state-metrics?

<details>
<summary>Ответ</summary>

kube-state-metrics: метрики `kube_deployment_spec_replicas` и `kube_deployment_status_replicas_available`. cAdvisor и node-exporter измеряют потребление ресурсов, а не состояние объектов.

</details>

### Custom Resource Definition и ServiceMonitor

Prometheus Operator добавляет в кластер новые типы объектов, CRD (Custom Resource Definition). Главные три:

- `ServiceMonitor` - «собирай метрики с подов за этим Service»;
- `PodMonitor` - то же, но без Service, напрямую по подам;
- `PrometheusRule` - правила алертов и recording rules в виде объекта.

Вместо `scrape_configs` в файле ты создаёшь `ServiceMonitor` рядом с приложением, в его же чарте. Оператор видит объект, генерирует конфиг и перезагружает Prometheus. Команда, которая владеет сервисом, владеет и его мониторингом.

Связь такая: `ServiceMonitor.spec.selector` выбирает Service по labels, `endpoints[].port` указывает **имя** порта в Service (не номер), `namespaceSelector` говорит, в каких namespace искать. Сам `ServiceMonitor` Prometheus находит по своему селектору `serviceMonitorSelector`. В этом чарте по умолчанию он требует label `release: <имя релиза стека>`. Это самая частая причина «ServiceMonitor создан, а target нет».

> **Проверь понимание:** в Service порт объявлен как `port: 8080` без `name`. Можно ли в ServiceMonitor написать `port: 8080`?

<details>
<summary>Ответ</summary>

Нет. В `endpoints[].port` указывается имя порта. Поле `targetPort` принимает число, но лучше дать порту имя (`name: http`) в Service и ссылаться на него. Без имени оператор не сможет сопоставить endpoint, и target не появится.

</details>

### Цепочка от метрики до алерта

Полный путь в кластере: приложение отдаёт `/metrics` -> `ServiceMonitor` описывает, как собирать -> оператор обновляет конфиг Prometheus -> Prometheus считает метрики -> `PrometheusRule` превращается в файл правил -> Alertmanager маршрутизирует (урок 8.5). Любое звено может быть сломано молча: объект создан, ошибок нет, а данных нет. Поэтому диагностика идёт по цепочке снизу вверх: target в UI Prometheus, затем ServiceMonitor, затем label и порт.

Дефолтные правила стека (`KubePodCrashLooping`, `KubeDeploymentReplicasMismatch`, `NodeFilesystemSpaceFillingUp`) покрывают инфраструктуру. Правила про пользовательскую боль (доля 5xx, латентность) пишешь ты, и лежат они рядом с приложением.

> **Проверь понимание:** алерт `KubePodCrashLooping` сработал, но метрики самого приложения пропали. Какой из двух источников данных для этого алерта жив, а какой нет?

<details>
<summary>Ответ</summary>

Алерт строится на метриках kube-state-metrics (`kube_pod_container_status_restarts_total`), они живут независимо от `/metrics` приложения. Приложение в CrashLoop не отвечает, поэтому его собственные метрики пропали, а состояние пода kube-state-metrics видит по-прежнему.

</details>

### Ресурсы и хранение

Стек тяжёлый: Prometheus, Grafana, Alertmanager, оператор и kube-state-metrics вместе просят порядка 1-2 ГБ RAM. Для kind в values мы отключаем компоненты, которых в нём нет (etcd, scheduler, controller-manager, kube-proxy недоступны для scrape с узла-контейнера) и задаём небольшие requests. Данные Prometheus лежат в PVC (урок 5.5), период хранения `retention` ограничиваем, иначе диск заполнится.

## Практика

Перед началом убедись, что кластер жив и приложение развёрнуто релизом `notes` (урок 5.9).

```bash
kubectl config current-context
helm list -n notes
```

```text
kind-notes
NAME    NAMESPACE       REVISION        UPDATED                                 STATUS          CHART           APP VERSION
notes   notes           4               2026-09-29 09:12:44.51 +0300 MSK        deployed        notes-0.2.0     0.7.0
```

Если `APP VERSION` другой, образ 0.7.0 нужен из урока 8.8: собери его и загрузи в kind командой `kind load docker-image notes:0.7.0 --name notes` (урок 5.2).

### Если у тебя 8 ГБ

Стек и приложение вместе в 8 ГБ тесны. Останови Compose-стек из уроков 8.2-8.8 (`docker compose -f monitoring/compose.yml down`), не поднимай Loki и Tempo, оставь в кластере одну реплику `notes` и в values ниже уменьши `retention` до `2d`. Alertmanager можно выключить (`alertmanager.enabled: false`), но тогда пропустишь часть задания 3.

### Задание 1. Ставим kube-prometheus-stack

**Цель.** Развернуть стек в namespace `monitoring` с минимальными ресурсами и открыть Prometheus и Grafana.

**Предскажи:** сколько подов будет в namespace `monitoring` после установки и какой из них DaemonSet?

<details>
<summary>Ответ</summary>

Обычно 6-7: оператор, Prometheus (StatefulSet), Alertmanager (StatefulSet), Grafana, kube-state-metrics и node-exporter (по одному на узел, это DaemonSet). При одном узле kind получится 6 подов.

</details>

**Шаги.**

1. Создай файл `monitoring/k8s/values-kps.yaml`:

```yaml
# Значения для kube-prometheus-stack 91.8.2 под учебный кластер kind
fullnameOverride: kps

# Компоненты control-plane в kind недоступны для scrape, отключаем
kubeEtcd:
  enabled: false
kubeScheduler:
  enabled: false
kubeControllerManager:
  enabled: false
kubeProxy:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 3d
    resources:
      requests:
        cpu: 100m
        memory: 400Mi
      limits:
        memory: 800Mi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi

alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 10m
        memory: 50Mi

grafana:
  adminPassword: CHANGE_ME
  resources:
    requests:
      cpu: 50m
      memory: 128Mi

kube-state-metrics:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi

prometheusOperator:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
```

2. Добавь репозиторий и поставь чарт с закреплённой версией:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack \
  --version 91.8.2 \
  --namespace monitoring --create-namespace \
  -f monitoring/k8s/values-kps.yaml \
  --wait --timeout 8m
```

3. Проверь поды и CRD:

```bash
kubectl get pods -n monitoring
kubectl get crd | grep monitoring.coreos.com
```

4. Открой интерфейсы (в двух терминалах):

```bash
kubectl port-forward -n monitoring svc/kps-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

**Что должно получиться.**

```text
NAME                                     READY   STATUS    RESTARTS   AGE
alertmanager-kps-alertmanager-0          2/2     Running   0          2m
kps-grafana-6f7c9d8b5-x2k4p              3/3     Running   0          2m
kps-kube-state-metrics-7d9c6b5f4-9tqzd   1/1     Running   0          2m
kps-operator-5b8f7c6d9-lm8vw             1/1     Running   0          2m
kps-prometheus-node-exporter-4hkxs       1/1     Running   0          2m
prometheus-kps-prometheus-0              2/2     Running   0          2m
alertmanagerconfigs.monitoring.coreos.com   2026-09-29T07:20:11Z
alertmanagers.monitoring.coreos.com         2026-09-29T07:20:11Z
podmonitors.monitoring.coreos.com           2026-09-29T07:20:11Z
prometheuses.monitoring.coreos.com          2026-09-29T07:20:11Z
prometheusrules.monitoring.coreos.com       2026-09-29T07:20:11Z
servicemonitors.monitoring.coreos.com       2026-09-29T07:20:11Z
```

На `http://localhost:9090/targets` десяток целей в состоянии UP, в Grafana на `http://localhost:3000` (логин `admin`, пароль из values) есть папка дашбордов Kubernetes.

**Объясни себе.**
- Почему Prometheus - StatefulSet, а не Deployment (урок 5.5)?
- Зачем отключены `kubeEtcd` и `kubeScheduler` и что случится, если оставить включёнными?

**Типичные ошибки.**
- `Error: INSTALLATION FAILED: context deadline exceeded`: не хватило времени или памяти, поды Pending. Смотри `kubectl get pods -n monitoring` и `kubectl describe pod`, увеличь Docker-ресурсы или включи режим 8 ГБ.
- `Error: INSTALLATION FAILED: cannot re-use a name that is still in use`: релиз `kps` уже есть. Используй `helm upgrade --install` или `helm uninstall kps -n monitoring`.
- Цели etcd и scheduler в состоянии DOWN с `connection refused`: не отключены в values, поправь и сделай `helm upgrade`.

### Задание 2. Подключаем «Заметки» через ServiceMonitor

**Цель.** Добавить в чарт `helm/notes` шаблон ServiceMonitor, включаемый флагом, и увидеть цель `notes` в Prometheus.

**Предскажи:** если создать ServiceMonitor без label `release: kps`, появится ли цель в `/targets`? Что покажет `kubectl get servicemonitor`?

<details>
<summary>Ответ</summary>

Цели не будет. `kubectl get servicemonitor -n notes` покажет объект как ни в чём не бывало, ошибок нет: Prometheus просто не выбирает его своим `serviceMonitorSelector` (по умолчанию требуется `release: kps`).

</details>

**Шаги.**

1. Убедись, что порт в Service назван. В `helm/notes/templates/service.yaml` порт должен быть таким (изменена только строка `name`):

{% raw %}
```yaml
  ports:
    - name: http          # имя порта нужно ServiceMonitor
      port: 8080
      targetPort: 8080
```
{% endraw %}

2. Добавь в `helm/notes/values.yaml` блок:

```yaml
# Метрики (урок 8.9)
metrics:
  enabled: false
  serviceMonitor:
    enabled: false
    interval: 15s
    # label, по которому Prometheus выбирает ServiceMonitor (имя релиза стека)
    release: kps
```

3. Создай `helm/notes/templates/servicemonitor.yaml`:

{% raw %}
```yaml
{{- if and .Values.metrics.enabled .Values.metrics.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "notes.fullname" . }}
  labels:
    {{- include "notes.labels" . | nindent 4 }}
    release: {{ .Values.metrics.serviceMonitor.release }}
spec:
  selector:
    matchLabels:
      {{- include "notes.selectorLabels" . | nindent 6 }}
  namespaceSelector:
    matchNames:
      - {{ .Release.Namespace }}
  endpoints:
    - port: http
      path: /metrics
      interval: {{ .Values.metrics.serviceMonitor.interval }}
{{- end }}
```
{% endraw %}

4. Подними версию чарта: в `Chart.yaml` `version: 0.3.0`, `appVersion: "0.7.0"`. Проверь рендер и обнови релиз:

```bash
helm lint helm/notes
helm upgrade notes helm/notes -n notes \
  --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true
kubectl get servicemonitor -n notes
```

5. В `http://localhost:9090/targets` найди цель `serviceMonitor/notes/notes/0`. Выполни запрос:

```promql
sum by (path, status) (rate(notes_http_requests_total[5m]))
```

**Что должно получиться.**

```text
Release "notes" has been upgraded. Happy Helming!
NAME    AGE
notes   6s
```

В `/targets` цель в состоянии UP (`1/1 up`) с адресом вида `10.244.0.12:8080/metrics`. PromQL возвращает серии с `path="/notes"` после нескольких запросов к приложению.

**Объясни себе.**
- Откуда Prometheus узнал IP подов, если ты нигде их не писал?
- Почему в `matchLabels` берём selector-labels, а не все labels чарта?

**Типичные ошибки.**
- `Error: UPGRADE FAILED: unable to build kubernetes objects from current manifest: resource mapping not found for name: "notes" namespace: "notes" from "": no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"`: CRD стека не установлены (задание 1 не выполнено). Поставь стек.
- Цель есть, но `DOWN` и `Error: 404`: неверный `path`. Приложение отдаёт метрики на `/metrics`.
- Цели нет, объект создан: нет label `release: kps` или порт в Service без имени (разбор в блоке «Сломай и почини»).

### Задание 3. PrometheusRule: алерт на долю 5xx

**Цель.** Добавить правила как объект Kubernetes и увидеть их в Prometheus.

**Предскажи:** ты добавишь правило и в Prometheus UI на вкладке Alerts оно появится через сколько: мгновенно, несколько секунд или после рестарта пода? Почему?

<details>
<summary>Ответ</summary>

Через несколько секунд, рестарт не нужен. Оператор следит за объектами `PrometheusRule`, сам обновляет ConfigMap с правилами, а sidecar `config-reloader` в поде Prometheus перечитывает их.

</details>

**Шаги.**

1. Добавь в `values.yaml` под `metrics:` ключ для правил (правила включаются тем же `metrics.enabled`, отдельного ключа не заводим) и создай `helm/notes/templates/prometheusrule.yaml`. Шаблон Prometheus с `$labels` экранируем, чтобы Helm его не разворачивал:

{% raw %}
```yaml
{{- if .Values.metrics.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ include "notes.fullname" . }}
  labels:
    {{- include "notes.labels" . | nindent 4 }}
    release: {{ .Values.metrics.serviceMonitor.release }}
spec:
  groups:
    - name: notes.rules
      rules:
        - record: notes:http_errors:ratio5m
          expr: |
            sum(rate(notes_http_requests_total{status=~"5.."}[5m]))
            /
            sum(rate(notes_http_requests_total[5m]))
        - alert: NotesHighErrorRatio
          expr: notes:http_errors:ratio5m > 0.05
          for: 5m
          labels:
            severity: page
          annotations:
            summary: "Доля 5xx у Заметок выше 5% уже 5 минут"
            runbook_url: "https://github.com/distinguished-sre/devops/tree/devops/project/notes/docs/runbooks/NotesHighErrorRatio.md"
        - alert: NotesTargetDown
          expr: up{job="{{ include "notes.fullname" . }}"} == 0
          for: 2m
          labels:
            severity: page
          annotations:
            summary: "Prometheus не может собрать метрики с {{ "{{ $labels.instance }}" }}"
{{- end }}
```
{% endraw %}

2. Обнови релиз и проверь:

```bash
helm upgrade notes helm/notes -n notes \
  --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true
kubectl get prometheusrule -n notes
```

3. На `http://localhost:9090/alerts` найди группу `notes.rules` и оба алерта в состоянии Inactive. Затем выполни `notes:http_errors:ratio5m` в Graph.

**Что должно получиться.**

```text
NAME    AGE
notes   5s
```

В интерфейсе алерты `NotesHighErrorRatio` и `NotesTargetDown` в состоянии Inactive (зелёные). Запрос `notes:http_errors:ratio5m` возвращает 0 либо `no data`, если 5xx-ответов не было (`no data` при делении на ноль запросов это нормально).

**Объясни себе.**
- Почему правило `NotesTargetDown` смотрит на метрику `up`, а не на метрики приложения?
- Чем этот алерт отличается от `KubePodCrashLooping` из стека?

**Типичные ошибки.**
- `Error: UPGRADE FAILED: YAML parse error ... did not find expected key`: не экранирован шаблон `$labels.instance`, Helm попытался развернуть его сам. Оборачивай Prometheus-шаблоны в строку-литерал Helm (см. пример выше).
- Правило создано, но в `/alerts` его нет: нет label `release: kps` на `PrometheusRule` (те же причины, что у ServiceMonitor).
- `Error from server (BadRequest): admission webhook "prometheusrulemutate.monitoring.coreos.com" denied the request`: синтаксическая ошибка в `expr`, проверь PromQL в Graph.

### Задание 4. Шаг проекта: chart 0.3.0 и выкат метрик

**Цель.** Закрепить состояние проекта: чарт `helm/notes` версии 0.3.0 с метриками включаемыми через values, приложение 0.7.0 в кластере.

**Предскажи:** какие три ресурса появятся в namespace `notes` после `helm upgrade` с включёнными метриками, которых там не было раньше?

<details>
<summary>Ответ</summary>

`ServiceMonitor/notes`, `PrometheusRule/notes` и (косвенно) новая ревизия релиза Helm. Deployment и Service не изменятся, кроме имени порта в Service.

</details>

**Шаги.**

1. Включи метрики по умолчанию для кластера в `helm/notes/values-dev.yaml` (в `values.yaml` они остаются `false`, чтобы чарт ставился и без стека):

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

2. Убедись, что в `Chart.yaml` версия 0.3.0 и appVersion 0.7.0, и выкати:

```bash
helm lint helm/notes -f helm/notes/values-dev.yaml
helm upgrade --install notes helm/notes -n notes -f helm/notes/values-dev.yaml
helm list -n notes
kubectl get servicemonitor,prometheusrule -n notes
```

3. Сгенерируй немного трафика и посмотри на дашборд. В Grafana (`Dashboards -> Kubernetes / Compute Resources / Namespace (Pods)`) выбери namespace `notes`.

```bash
for i in $(seq 1 30); do curl -s -o /dev/null -H 'Host: notes.lab' http://127.0.0.1/notes; done
```

4. Зафиксируй в git:

```bash
git add monitoring/k8s helm/notes
git commit -m "8.9: kube-prometheus-stack, ServiceMonitor и PrometheusRule (chart 0.3.0)"
```

**Что должно получиться.**

```text
NAME    NAMESPACE       REVISION        UPDATED                                 STATUS          CHART           APP VERSION
notes   notes           6               2026-09-29 10:05:31.20 +0300 MSK        deployed        notes-0.3.0     0.7.0
NAME                                           AGE
servicemonitor.monitoring.coreos.com/notes     20s

NAME                                        AGE
prometheusrule.monitoring.coreos.com/notes  20s
```

Эталон: [project/notes/helm/notes](https://github.com/distinguished-sre/devops/tree/devops/project/notes/helm/notes) и [values-kps.yaml](https://github.com/distinguished-sre/devops/tree/devops/project/notes/monitoring/k8s).

**Объясни себе.**
- Почему метрики выключены в `values.yaml` и включены в `values-dev.yaml`?
- Что сломается у человека без стека, если бы флаг был включён по умолчанию (подсказка: ошибка из задания 2)?

**Типичные ошибки.**
- `Error: rendered manifests contain a resource that already exists`: ServiceMonitor создан руками через `kubectl apply`. Удали его (`kubectl delete servicemonitor notes -n notes`) и повтори `helm upgrade`.
- В Grafana дашборд пуст: не выбран namespace `notes` в переменной или ещё не прошло 1-2 минуты после первого scrape.

## Сломай и почини

Запусти поломку скриптом. Сценарий выбирается номером 1-3 или `random`; скрипт не читай, диагностируй по симптомам.

```bash
bash project/notes/break/8.9/break.sh random
```

### Симптом

Ты выкатил изменения, `helm upgrade` прошёл без ошибок, а Prometheus чего-то не видит: нет цели `notes`, либо цель есть, но пустая, либо алерты не появились в `/alerts`. Дашборд и алерты по «Заметкам» пусты, при этом приложение отвечает 200.

### Гипотезы

1. Оператор не выбрал объект: label не совпадает с `serviceMonitorSelector` Prometheus.
2. ServiceMonitor не находит порт: у порта Service нет имени или оно другое.
3. `PrometheusRule` не загружен: нет нужного label, либо ошибка в выражении.
4. Приложение действительно не отдаёт `/metrics` или Service не выбирает поды.

### Проверки

```bash
# 1. Что именно выбирает Prometheus по label
kubectl get prometheus -n monitoring kps-prometheus -o jsonpath='{.spec.serviceMonitorSelector}{"\n"}{.spec.ruleSelector}{"\n"}'

# 2. Какие label у наших объектов
kubectl get servicemonitor,prometheusrule -n notes --show-labels

# 3. Есть ли у Service именованный порт и endpoints
kubectl get svc notes -n notes -o jsonpath='{.spec.ports}{"\n"}'
kubectl get endpoints notes -n notes

# 4. Что говорит сам Prometheus (в /targets и /config), логи оператора
kubectl logs -n monitoring deploy/kps-operator --tail=30
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**Сценарий 1: ServiceMonitor не находится.** Селектор Prometheus `{"matchLabels":{"release":"kps"}}`, а у объекта label `release` нет или в нём другое значение. Исправление: вернуть `release: kps` (значение `metrics.serviceMonitor.release`) и сделать `helm upgrade`. Альтернатива на стороне стека: `serviceMonitorSelectorNilUsesHelmValues: false`, тогда Prometheus выбирает все ServiceMonitor, но это ослабляет изоляцию.

**Сценарий 2: порт без имени.** `endpoints[].port: http`, а в Service у порта нет `name` (или он назван `web`). Объект принимается, target не появляется. Исправление: дать порту в Service имя `http` и выкатить.

**Сценарий 3: PrometheusRule не загружен.** Нет label `release: kps` (селектор `ruleSelector`) либо объект отклонён валидацией. Исправление: вернуть label, проверить PromQL в Graph, затем `kubectl get prometheusrule -n notes` и вкладка Alerts.

Общий алгоритм: цепочка снизу вверх, target в `/targets` -> label на объекте -> имя порта -> endpoints у Service -> `/metrics` через `kubectl port-forward`.

</details>

## Вопросы с собеседований

### 1. [junior] Тебя просят «поставить мониторинг в кластер». С чего начнёшь?

Поставлю `kube-prometheus-stack` Helm-чартом с закреплённой версией и своим values: ресурсы, retention, PVC. Он даёт Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics и базовые правила. Потом подключу приложения через ServiceMonitor.

**Что хотят услышать:** Prometheus Operator, закреплённая версия чарта, отдельный namespace, PVC и retention, дефолтные дашборды и правила, затем свои сервисы.

**Красный флаг:** «установлю Prometheus и напишу scrape_configs с IP подов».

### 2. [junior] Ты создал ServiceMonitor, а цели в Prometheus нет. Твои действия?

Иду по цепочке. Смотрю label на ServiceMonitor и сравниваю с `serviceMonitorSelector` у Prometheus (обычно `release: <релиз стека>`). Проверяю, что в Service у порта есть имя, на которое ссылается endpoint, что у Service есть endpoints и что `namespaceSelector` указывает на нужный namespace. Логи оператора подтвердят догадку.

**Что хотят услышать:** label `release`, именованный порт, `selector` против labels Service, `namespaceSelector`, логи оператора, `/targets` и `/config`.

**Красный флаг:** «пересоздам Prometheus» или «перезапущу под».

### 3. [middle] Чем ServiceMonitor отличается от PodMonitor и когда нужен каждый?

ServiceMonitor работает через Service и его endpoints, подходит для обычных приложений. PodMonitor выбирает поды напрямую, нужен, когда Service нет (Job, DaemonSet, сайдкары) или нужно собирать метрики с портов, которых нет в Service.

**Что хотят услышать:** источник обнаружения (Service endpoints против pods), примеры без Service, `podMetricsEndpoints`.

**Красный флаг:** считает, что это одно и то же с разными названиями.

### 4. [junior] Prometheus в кластере перезапустился, и графики за неделю пропали. Что не так?

Скорее всего хранилище без PVC: данные лежали в emptyDir и потерялись с подом. Нужно задать `storageSpec` с PersistentVolumeClaim и разумный `retention`.

**Что хотят услышать:** PVC в `prometheusSpec.storageSpec`, retention и размер, долгосрочное хранение (Thanos, Mimir, remote write) как следующий шаг.

**Красный флаг:** «Prometheus всегда хранит данные сам, значит сломался диск».

### 5. [middle] Prometheus в кластере падает по OOMKilled. Что проверишь?

Число серий (`prometheus_tsdb_head_series`), кардинальность лейблов: кто добавил `user_id` или сырой URL. Топ метрик по числу серий, интервал scrape, retention. Затем лимиты памяти и, если серии обоснованы, шардирование или вынос части в другой Prometheus.

**Что хотят услышать:** кардинальность, `prometheus_tsdb_head_series`, `topk` по `__name__`, `metric_relabel_configs` и `sample_limit`, а не просто «увеличу лимит».

**Красный флаг:** «подниму limits в три раза и забуду».

### 6. [middle] Поды нового релиза в статусе Running, но алерт `KubeDeploymentReplicasMismatch` горит. Как разбираться?

Алерт строится на kube-state-metrics: желаемых реплик больше, чем доступных. Running не значит Ready. Смотрю `kubectl get deploy`, `describe`, состояние readiness-проб, события. Часто readiness падает из-за зависимости (БД) или нехватки ресурсов, и часть подов Pending.

**Что хотят услышать:** разница Running и Ready, `kube_deployment_status_replicas_available`, readiness-проба, events, requests и Pending.

**Красный флаг:** «алерт ложный, заглушу».

### 7. [junior] Чем kube-state-metrics отличается от node-exporter и cAdvisor?

kube-state-metrics публикует состояние объектов Kubernetes (реплики, фазы подов, Jobs). node-exporter отдаёт метрики железа и ОС узла. cAdvisor, встроенный в kubelet, даёт потребление ресурсов контейнерами.

**Что хотят услышать:** по одному примеру метрики на компонент, что «что должно быть» и «сколько потребляется» разные вопросы.

**Красный флаг:** путает kube-state-metrics с metrics-server.

### 8. [middle] Алерт на CPU пода срабатывает постоянно, хотя жалоб нет. Что сделаешь?

Пойму, что измеряет алерт. Алерт на «CPU выше 80% от limit» бывает шумным из-за троттлинга без реальной боли. Заменю его или дополню симптомным алертом (латентность, доля 5xx), а причинный оставлю как информационный. Проверю `container_cpu_cfs_throttled_periods_total`, подправлю requests и limits.

**Что хотят услышать:** симптом против причины, троттлинг, привязка к SLO, отказ от алертов, на которые нечего делать.

**Красный флаг:** «подниму порог до 99%» без разбирательства.

### 9. [middle] Нужно, чтобы команды сами подключали мониторинг и алерты, не трогая центральный конфиг. Как устроишь?

Каждая команда кладёт ServiceMonitor и PrometheusRule в чарт своего сервиса. Prometheus выбирает их по label (или по всем namespace через `NilUsesHelmValues: false`). Общие правила инфраструктуры остаются в стеке, а маршрутизацию алертов по командам делают через `AlertmanagerConfig` или label `team`.

**Что хотят услышать:** мониторинг как код рядом с приложением, селекторы, границы ответственности, label `team` и маршрутизация.

**Красный флаг:** все правила в одном файле у SRE, команды просят его править в тикетах.

### 10. [junior] Метрики в Grafana есть, но алерт по ним ни разу не сработал, хотя ошибки были. Куда смотришь?

Проверяю, загружено ли правило (вкладка Rules, `/alerts`), верно ли выражение на реальных данных, длится ли условие дольше `for`, попал ли алерт в Alertmanager и ушёл ли по маршруту. Цепочка: правило -> Prometheus -> Alertmanager -> получатель.

**Что хотят услышать:** `for`, отсутствие данных (`absent`), загрузка PrometheusRule, маршрутизация, silence и inhibit.

**Красный флаг:** «алерты, наверное, не работают вообще».

### 11. [middle] Helm-релиз стека нужно обновить с 91.8.2 на новую версию. Что сделаешь?

Прочитаю release notes чарта, особенно про CRD: Helm не обновляет CRD из каталога `crds/` при `upgrade`, их применяют отдельно (`kubectl apply --server-side`). Сначала пробую на тестовом кластере, сравниваю `helm diff` или `helm template`, затем обновляю и проверяю targets и правила.

**Что хотят услышать:** CRD и Helm, закреплённая версия, тест на стенде, откат `helm rollback`, проверка после обновления.

**Красный флаг:** `helm upgrade` на проде без чтения changelog.

### 12. [middle] В кластере есть Prometheus, но нужен единый обзор трёх кластеров. Варианты?

Federation (простой, но грубый), remote write в центральное хранилище (Mimir, Thanos Receive, VictoriaMetrics) или Thanos Sidecar с общим запросом. Выбор зависит от объёма и хранения. Обязательно добавляю лейбл `cluster` через `externalLabels`.

**Что хотят услышать:** `externalLabels`, remote write против federation, долгосрочное хранение, компромисс стоимости.

**Красный флаг:** «пусть открывают три Grafana».

## Проверено на версиях

- kube-prometheus-stack: chart 91.8.2
- Helm: v4 (см. урок 5.9)
- Kubernetes: kind, кластер `notes`, версия узла не закреплена, проверь актуальную версию на странице проекта
- Приложение «Заметки»: 0.7.0 (app v7), chart `helm/notes` 0.3.0

## Итог урока: ты умеешь

- [ ] умею поставить kube-prometheus-stack с закреплённой версией и своим values
- [ ] умею объяснить, что делают Prometheus Operator, kube-state-metrics и node-exporter
- [ ] умею подключить приложение через ServiceMonitor и проверить цель в `/targets`
- [ ] умею описать алерт и recording rule объектом PrometheusRule в чарте
- [ ] умею находить причину, по которой ServiceMonitor не находится (label, имя порта, namespace)
- [ ] умею открывать Prometheus и Grafana кластера через `kubectl port-forward`
- [ ] умею включать метрики в чарте флагом и не ломать установку без стека

**Дальше:** [Урок 8.10: Service mesh: Istio ambient](10-service-mesh-istio.md)
