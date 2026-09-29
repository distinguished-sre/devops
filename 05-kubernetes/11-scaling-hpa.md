---
layout: lesson
title: "Масштабирование: HPA и metrics-server"
topic: 5
lesson: "5.11"
time: "1.5 ч"
---

## Зачем это нужно

Днём «Заметки» получают в десять раз больше запросов, чем ночью. Держать круглосуточно шесть реплик дорого, держать две опасно: под нагрузкой сервис начнёт отвечать медленно и упадёт. Горизонтальный автоскейлер подов (Horizontal Pod Autoscaler, HPA) сам меняет число реплик по нагрузке. На работе его ставят почти на каждый stateless-сервис, а на собеседованиях спрашивают, почему HPA показывает `<unknown>` и почему реплики то растут, то падают.

HPA работает только при двух условиях: в кластере есть metrics-server, а у подов заданы `requests`. Без них он молчит.

Шаг проекта: в чарт `helm/notes` добавляется `templates/hpa.yaml` (включается `hpa.enabled`), в кластере ставится metrics-server, нагрузка создаётся эндпоинтом `/burn`. Версия чарта становится 0.1.1.

## Что нужно знать

- [Урок 1.5: диск, память и процессор](../01-linux/05-disk-memory-cpu.md) - эндпоинт `/burn`, загрузка CPU, cgroups
- [Урок 5.2: Pod и Deployment](02-pods-deployments.md) - реплики, ReplicaSet, метки
- [Урок 5.3: Service и DNS](03-services-dns.md) - обращение к сервису по имени `notes.notes.svc`
- [Урок 5.7: пробы, ресурсы, rolling update](07-probes-resources-rollouts.md) - `requests` и `limits`, readiness
- [Урок 5.9: Helm](09-helm.md) - чарт `helm/notes`, `values.yaml`, `helm upgrade`

## Теория

### Откуда HPA берёт цифры: metrics-server

Kubelet на каждом узле знает, сколько CPU и памяти съел каждый контейнер (он берёт это из cgroups, см. урок 1.5). Metrics-server (сборщик метрик ресурсов) раз в 15 секунд опрашивает kubelet'ы всех узлов и отдаёт последние значения через API `metrics.k8s.io`. Он хранит только текущий снимок в памяти, истории нет. Это источник для двух вещей: команды `kubectl top` и HPA.

Metrics-server не заменяет Prometheus (тема 8): он не хранит историю, не строит графики и не годится для алертов. Его задача одна: быстро ответить «сколько сейчас».

В kind kubelet'ы используют самоподписанные сертификаты, и metrics-server им не доверяет. Для лаборатории добавляют флаг `--kubelet-insecure-tls`. В проде так делать нельзя: там kubelet'ы получают нормальные сертификаты от кластерного CA.

> **Проверь понимание:** чем `kubectl top pod` отличается от метрик контейнера в Prometheus и почему HPA использует первое?

<details markdown="1">
<summary>Ответ</summary>

`kubectl top` и HPA читают снимок из metrics-server через API кластера: он лёгкий, обновляется каждые 15 секунд и есть в любом кластере. Prometheus хранит историю и умеет запросы, но это отдельная система, которую нужно ставить и поддерживать. Штатный HPA не зависит от неё. Метрики из Prometheus в HPA можно подключить через адаптер или KEDA, но это отдельная настройка.

</details>

### Как HPA считает число реплик

HPA (`autoscaling/v2`) это контроллер, который каждые 15 секунд сравнивает текущую метрику с целевой и считает:

```text
нужно реплик = ceil(текущих реплик * текущее значение / целевое значение)
```

Пример: 3 пода, целевая загрузка CPU 50%, текущая 100%. Получается `ceil(3 * 100 / 50) = 6`. Если метрика в пределах допуска 10% от цели (tolerance), HPA ничего не меняет, чтобы не дёргаться по мелочам. Результат всегда зажат между `minReplicas` и `maxReplicas`.

Важная деталь: загрузка считается в процентах от `requests`, а не от `limits` и не от ядра. Под с `requests.cpu: 50m`, который использует 100m, загружен на 200%. Поэтому без `requests` процент посчитать не из чего, и HPA показывает `<unknown>`. Поды с загрузкой выше 100% возможны только пока limit выше request.

> **Проверь понимание:** 4 пода, цель 50% CPU, сейчас средняя загрузка 25%. Сколько реплик потребует HPA при `minReplicas: 2`?

<details markdown="1">
<summary>Ответ</summary>

`ceil(4 * 25 / 50) = 2`. Это равно минимуму, значит HPA уменьшит до 2, но не сразу: см. окно стабилизации ниже.

</details>

### Быстро вверх, медленно вниз

Если бы HPA сразу убирал реплики при каждом падении нагрузки, сервис «качало» бы: нагрузка чуть упала, реплик стало меньше, нагрузка на оставшихся выросла, реплики добавились. Это называется флаппинг (flapping). Поэтому у HPA есть поле `behavior`:

- `scaleUp` по умолчанию работает без задержки и может быстро удваивать число реплик;
- `scaleDown` использует окно стабилизации (stabilization window) 300 секунд: HPA берёт максимальную из рекомендаций за последние 5 минут и только потом уменьшает.

Новый под не мгновенно готов принимать трафик: образ, запуск, `startupProbe`, `readinessProbe` (урок 5.7). Пока под не Ready, метрики новых подов HPA игнорирует. Быстрая реакция на пик означает, что запас должен быть заложен заранее, поэтому цель ставят не 90%, а 50-70%.

### Что HPA не умеет

- Не работает без `requests`. Это самая частая причина `<unknown>`.
- Не масштабирует StatefulSet с БД смысловым образом: PostgreSQL от лишних реплик сам не станет масштабируемым.
- Не спасает от узкого места ниже по цепочке: если все реплики упираются в одну БД, их число ничего не изменит.
- Не добавляет узлы. Если реплики некуда поставить, они зависнут в `Pending`. Узлы добавляет Cluster Autoscaler или Karpenter (в облаке, тема 6).

Соседи, о которых спрашивают на собеседованиях. VPA (Vertical Pod Autoscaler) меняет `requests` и `limits` самого пода, а не число реплик: подходит для приложений, которые нельзя размножить. KEDA (Kubernetes Event-driven Autoscaling) масштабирует по событиям: длина очереди, метрика Prometheus, cron, и умеет уводить в ноль реплик. HPA и VPA на одну и ту же метрику CPU вешать нельзя: они будут бороться друг с другом.

> **Проверь понимание:** HPA поднял реплики до `maxReplicas`, но часть подов в `Pending`. Что это значит и кто должен добавить узлы?

<details markdown="1">
<summary>Ответ</summary>

В кластере не хватает ресурсов для `requests` новых подов, планировщик не находит узел. HPA узлы не добавляет. В облаке это делает Cluster Autoscaler или Karpenter, в kind нужно освободить ресурсы или увеличить размер узлов.

</details>

## Практика

### Задание 1. Ставим metrics-server и смотрим `kubectl top`

**Цель:** получить метрики ресурсов в кластере kind и научиться читать `kubectl top`.

**Предскажи:** что ответит `kubectl top pods -n notes` в кластере без metrics-server? А сразу после установки, до того как ты поправишь TLS?

<details markdown="1">
<summary>Ответ</summary>

Без metrics-server: `error: Metrics API not available`. Сразу после установки без флага `--kubelet-insecure-tls` под metrics-server будет запущен, но не `Ready` (не может проверить сертификаты kubelet), и `top` продолжит ругаться.

</details>

**Шаги:**

1. Убедись, что кластер и контекст на месте:

   ```bash
   kubectl config use-context kind-notes
   kubectl top pods -n notes
   ```

2. Установи metrics-server манифестом релиза. Версию подставь актуальную со страницы релизов проекта kubernetes-sigs/metrics-server (тег `latest` не используем, версия закрепляется в команде):

   ```bash
   # проверь актуальную версию на странице проекта, v0.8.0 здесь пример
   MS_VERSION=v0.8.0
   kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${MS_VERSION}/components.yaml"
   ```

3. Добавь флаг для kind (только для лаборатории):

   ```bash
   kubectl patch deployment metrics-server -n kube-system --type=json \
     -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
   kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
   ```

4. Подожди 30-60 секунд (первый опрос) и смотри метрики:

   ```bash
   kubectl top nodes
   kubectl top pods -n notes
   ```

**Что должно получиться:**

```text
NAME                  CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
notes-control-plane   118m         2%       745Mi           9%
notes-worker          47m          1%       412Mi           5%
notes-worker2         44m          1%       398Mi           5%
```

```text
NAME                     CPU(cores)   MEMORY(bytes)
notes-6d9f8c7b5d-2xk4q   1m           31Mi
notes-6d9f8c7b5d-9tqzr   1m           30Mi
notes-6d9f8c7b5d-mw7lp   1m           31Mi
postgres-0               4m           58Mi
```

**Объясни себе:**

- Почему CPU у «Заметок» в покое 1m, а `requests` 50m? Что из этого HPA возьмёт за 100%?
- Почему флаг `--kubelet-insecure-tls` допустим в kind и недопустим в проде?
- Через какой API `kubectl top` получает данные?

**Типичные ошибки:**

- `error: Metrics API not available`: metrics-server не установлен или ещё не Ready. Проверь `kubectl get pods -n kube-system -l k8s-app=metrics-server`.
- `E... scraper.go: "Failed to scrape node" err="Get \"https://172.18.0.3:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs"` (в логах metrics-server): kubelet с самоподписанным сертификатом. Добавь `--kubelet-insecure-tls` (шаг 3).
- `error: metrics not available yet`: прошло меньше минуты с запуска. Подожди и повтори.

### Задание 2. HPA руками: `requests`, цель и нагрузка

**Цель:** увидеть, как число реплик следует за нагрузкой, и посчитать результат по формуле.

**Предскажи:** Deployment `notes` (requests `50m`, limits `200m`) получает нагрузку, которая держит каждый под на пределе limit. HPA настроен на цель 50%, `min 2`, `max 6`. Сколько реплик будет через 2-3 минуты и почему именно столько?

<details markdown="1">
<summary>Ответ</summary>

Под на пределе limit использует 200m, то есть 400% от request 50m. По формуле `ceil(3 * 400 / 50) = 24`, но `maxReplicas` равен 6, поэтому будет 6. Число упирается в потолок.

</details>

**Шаги:**

1. Убедись, что приложение развёрнуто (из 5.9 чартом или из 5.7 манифестом) и `requests` заданы:

   ```bash
   kubectl -n notes get deploy notes -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
   ```

2. Создай HPA командой (в задании 3 он переедет в чарт):

   ```bash
   kubectl -n notes autoscale deployment notes --cpu=50% --min=2 --max=6
   kubectl -n notes get hpa notes
   ```

3. В первом терминале следи за HPA:

   ```bash
   kubectl -n notes get hpa notes -w
   ```

4. Во втором терминале создай нагрузку. Четыре параллельных цикла ходят на `/burn`, каждый запрос жжёт один поток пода 5 секунд (урок 1.5):

   ```bash
   kubectl -n notes run load --image=busybox:1.37.0 --restart=Never -- /bin/sh -c '
   for i in 1 2 3 4; do
     ( while true; do wget -q -O /dev/null "http://notes.notes.svc:8080/burn?sec=5"; done ) &
   done
   wait'
   ```

5. Через 2-3 минуты в третьем терминале посмотри итог и события:

   ```bash
   kubectl -n notes get pods -l app.kubernetes.io/name=notes
   kubectl -n notes describe hpa notes | tail -15
   ```

6. Останови нагрузку и наблюдай спад (займёт около 5 минут из-за окна стабилизации):

   ```bash
   kubectl -n notes delete pod load --now
   ```

**Что должно получиться:**

```text
NAME    REFERENCE          TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
notes   Deployment/notes   cpu: 2%/50%     2         6         3          20s
notes   Deployment/notes   cpu: 187%/50%   2         6         3          75s
notes   Deployment/notes   cpu: 187%/50%   2         6         6          90s
notes   Deployment/notes   cpu: 102%/50%   2         6         6          2m
```

```text
Events:
  Type    Reason             Age   From                       Message
  ----    ------             ----  ----                       -------
  Normal  SuccessfulRescale  95s   horizontal-pod-autoscaler  New size: 6; reason: cpu resource utilization (percentage of request) above target
```

Точные проценты у тебя будут другие. Важно: реплик стало 6, а после остановки нагрузки через несколько минут стало 2.

**Объясни себе:**

- Почему после `SuccessfulRescale` загрузка упала с 187% до 102%, но реплик всё равно 6?
- Почему уменьшение занимает минуты, а увеличение секунды?
- Что бы произошло, если бы у контейнера не было `requests`?

**Типичные ошибки:**

- `TARGETS` показывает `<unknown>/50%`, в событиях `failed to get cpu utilization: missing request for cpu in container notes of Pod notes-...`: у контейнера нет `resources.requests.cpu`. Задай его в Deployment (для чарта в `values.yaml`).
- `unable to get metrics for resource cpu: unable to fetch metrics from resource metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)`: нет metrics-server, вернись к заданию 1.
- `Error from server (AlreadyExists): horizontalpodautoscalers.autoscaling "notes" already exists`: HPA уже создан. Удали его `kubectl -n notes delete hpa notes` и создай заново.

### Задание 3. Шаг проекта: HPA в Helm-чарте «Заметок»

**Цель:** перенести HPA в чарт, включаемый флагом `hpa.enabled`, и поднять версию чарта до 0.1.1.

**Предскажи:** что произойдёт с числом реплик, если оставить в Deployment {% raw %}`replicas: {{ .Values.replicaCount }}`{% endraw %} и при этом включить HPA, а потом сделать `helm upgrade`?

<details markdown="1">
<summary>Ответ</summary>

Каждый `helm upgrade` будет сбрасывать реплики к `replicaCount`, а HPA будет снова их менять. Возникает борьба двух источников истины: реплики дёргаются при каждой выкатке. Поэтому при включённом HPA поле `replicas` в шаблоне пропускают.

</details>

**Шаги:**

1. Удали HPA, созданный командой (чарт создаст свой):

   ```bash
   kubectl -n notes delete hpa notes
   ```

2. Добавь в конец `helm/notes/values.yaml`:

   ```yaml
   # автомасштабирование по CPU (включается флагом)
   hpa:
     enabled: false
     minReplicas: 2
     maxReplicas: 6
     targetCPU: 50
   ```

3. Создай `helm/notes/templates/hpa.yaml`:

   {% raw %}
   ```yaml
   {{- if .Values.hpa.enabled }}
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: {{ .Release.Name }}
     labels:
       {{- include "notes.labels" . | nindent 4 }}
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: {{ .Release.Name }}
     minReplicas: {{ .Values.hpa.minReplicas }}
     maxReplicas: {{ .Values.hpa.maxReplicas }}
     metrics:
       - type: Resource
         resource:
           name: cpu
           target:
             type: Utilization
             averageUtilization: {{ .Values.hpa.targetCPU }}
     behavior:
       scaleDown:
         # окно короче умолчания 300 с, чтобы урок шёл быстрее
         stabilizationWindowSeconds: 60
   {{- end }}
   ```
   {% endraw %}

4. В `helm/notes/templates/deployment.yaml` замени строку `replicas: ...` на условие (остальное не трогай):

   {% raw %}
   ```yaml
   spec:
     {{- if not .Values.hpa.enabled }}
     replicas: {{ .Values.replicaCount }}
     {{- end }}
   ```
   {% endraw %}

5. Подними версию чарта в `helm/notes/Chart.yaml` до `0.1.1` (`appVersion` остаётся `"0.4.1"`):

   ```bash
   # GNU sed; на macOS: sed -i '' ...
   sed -i 's/^version: 0.1.0$/version: 0.1.1/' helm/notes/Chart.yaml
   grep -E '^(version|appVersion)' helm/notes/Chart.yaml
   ```

6. Проверь рендер в обоих режимах:

   ```bash
   helm lint helm/notes
   helm template notes helm/notes -n notes | grep -c HorizontalPodAutoscaler
   helm template notes helm/notes -n notes --set hpa.enabled=true | grep -E 'kind: Horizontal|replicas:|minReplicas|maxReplicas'
   ```

7. Выкати чарт с включённым HPA и проверь:

   ```bash
   helm upgrade --install notes helm/notes -n notes -f helm/notes/values-dev.yaml \
     --set hpa.enabled=true --atomic --timeout 3m
   kubectl -n notes get hpa,deploy notes
   ```

8. Повтори нагрузку из задания 2 (шаг 4), убедись, что реплики растут до 6, затем `kubectl -n notes delete pod load --now`.

9. Зафиксируй в git:

   ```bash
   git add helm/notes
   git commit -m "helm: HPA (hpa.enabled), chart 0.1.1"
   ```

**Что должно получиться:**

```text
version: 0.1.1
appVersion: "0.4.1"
```

```text
==> Linting helm/notes
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

```text
0
kind: HorizontalPodAutoscaler
  minReplicas: 2
  maxReplicas: 6
```

Первое число `0` это рендер без флага: HPA нет. Во втором рендере строки `replicas:` нет, потому что её пропустил шаблон Deployment.

```text
NAME                                        REFERENCE          TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/notes   Deployment/notes   cpu: 3%/50%   2         6         2          40s

NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/notes   2/2     2            2           3h
```

**Объясни себе:**

- Почему `replicaCount` в `values.yaml` остаётся, хотя при `hpa.enabled=true` он не используется?
- Что бы случилось при `hpa.minReplicas: 1` для сервиса, который должен выдерживать падение одного узла?
- Как связаны `hpa.targetCPU` и `resources.requests.cpu` из `values.yaml`?

**Типичные ошибки:**

- `Error: UPGRADE FAILED: ... horizontalpodautoscalers.autoscaling "notes" already exists` (или `invalid ownership metadata`): HPA, созданный командой, ещё жив. Удали его (шаг 1) и повтори.
- `Error: template: notes/templates/hpa.yaml:1:14: executing "notes/templates/hpa.yaml" at <.Values.hpa.enabled>: nil pointer evaluating interface {}.enabled`: в `values.yaml` нет блока `hpa`. Добавь его (шаг 2).
- `Error: INSTALLATION FAILED: ... hpa.yaml: yaml: line 12: did not find expected key`: неверный `nindent` в `include`. Смотри `helm template --debug`.

## Сломай и почини

Запусти сценарий, не читая скрипт:

```bash
cd ~/notes
bash break/5.11/break.sh 1
```

Номера 1-3 или `random`. Если нужно вернуть как было: `bash break/5.11/fix.sh`.

### Симптом

Тебе пишут: «после нагрузочного теста реплики не выросли, хотя сервис тормозит» или «реплики то растут, то падают каждые пару минут». Начни с `kubectl -n notes get hpa` и `kubectl -n notes get pods`.

### Гипотезы

Составь список причин до проверок: нет метрик (metrics-server, `requests`), цель выставлена неверно, слишком короткое окно уменьшения, упёрлись в `maxReplicas`, нет места для подов.

### Проверки

```bash
kubectl -n notes get hpa notes
kubectl -n notes describe hpa notes | tail -20
kubectl -n notes get deploy notes -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl top pods -n notes
kubectl get apiservice v1beta1.metrics.k8s.io
```

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

**Сценарий 1: `<unknown>/50%` из-за отсутствия requests.** В `describe hpa` событие `failed to get cpu utilization: missing request for cpu in container notes of Pod ...`. Из Deployment убрали `resources.requests`. Исправление: вернуть `requests.cpu: 50m` (в чарте: блок `resources` в `values.yaml`) и выкатить. Через минуту `TARGETS` покажет число. Урок: HPA считает проценты от `requests`, без них считать нечего.

**Сценарий 2: нет metrics-server.** `kubectl top` отвечает `Metrics API not available`, `get apiservice` показывает `False (MissingEndpoints)` или `FailedDiscoveryCheck`. Deployment metrics-server удалён или не Ready. Исправление: вернуть установку из задания 1 и дождаться `rollout status`. Урок: HPA зависит от системного компонента, и его нужно мониторить так же, как приложение.

**Сценарий 3: флаппинг реплик.** В `describe hpa` события `SuccessfulRescale` чередуются вверх и вниз с интервалом в минуту-две. В HPA убрано окно стабилизации (`stabilizationWindowSeconds: 0`) и цель занижена до 10%. Нагрузка на грани, каждое изменение числа реплик перескакивает через допуск. Исправление: вернуть `behavior.scaleDown.stabilizationWindowSeconds` (60 в лаборатории, 300 в проде) и цель 50-70%, при необходимости ограничить скорость уменьшения политикой `policies`. Урок: медленно вниз, быстро вверх.

</details>

## Вопросы с собеседований

### 1. [junior] `kubectl get hpa` показывает `<unknown>/50%` в колонке TARGETS. Что проверишь?

Смотрю `kubectl describe hpa`: в событиях будет причина. Обычно две: у контейнера нет `requests.cpu` (нечего делить на процент) или не работает metrics-server (`kubectl top pods` не отвечает). Проверяю `resources` в Deployment, состояние пода metrics-server и `apiservice v1beta1.metrics.k8s.io`.

**Что хотят услышать:** `describe hpa`, `requests`, metrics-server, `kubectl top` как быстрый тест.

**Красный флаг:** «перезапущу HPA» или «подожду», без чтения событий.

### 2. [junior] Как HPA решает, сколько реплик нужно?

Раз в 15 секунд сравнивает среднюю метрику по подам с целевой: `ceil(реплики * текущее / цель)`. Результат зажимается между `min` и `max`. Для CPU процент считается от `requests`.

**Что хотят услышать:** формула, `requests` как база процента, min и max, допуск 10%.

**Красный флаг:** «считает от limits» или «смотрит на нагрузку узла».

### 3. [junior] Зачем нужен metrics-server и чем он отличается от Prometheus?

Он даёт текущий снимок CPU и памяти подов и узлов через API `metrics.k8s.io` для `kubectl top` и HPA. Истории и алертов в нём нет. Prometheus хранит временные ряды, строит графики и алерты, но это отдельная система.

**Что хотят услышать:** снимок без истории, источник для HPA, Prometheus для мониторинга.

**Красный флаг:** «metrics-server это замена Prometheus».

### 4. [junior] Чем горизонтальное масштабирование отличается от вертикального?

Горизонтальное добавляет реплики (HPA), вертикальное увеличивает ресурсы одного пода (VPA). Горизонтальное подходит stateless-сервисам вроде «Заметок», вертикальное для того, что нельзя размножить.

**Что хотят услышать:** HPA и VPA, применимость, невозможность вешать оба на CPU.

**Красный флаг:** «vertical это когда больше узлов».

### 5. [middle] Нагрузка выросла в 5 раз, а HPA держит 2 реплики и ничего не делает. Твои действия?

Начинаю с `kubectl describe hpa`: в `Conditions` видно `ScalingActive` и причину. Проверяю `TARGETS`: если `<unknown>`, чиню метрики (`requests`, metrics-server). Если число есть, сверяю с целью и допуском 10%. Потом смотрю, не упёрлись ли в `maxReplicas` и не отключён ли scaling (`ScalingLimited`). Если метрика честная, а нагрузка идёт не через CPU (например, ждём БД), CPU не вырос и HPA прав: нужна другая метрика.

**Что хотят услышать:** `Conditions`, `ScalingActive`, `ScalingLimited`, метрика не всегда CPU.

**Красный флаг:** «увеличу replicas в Deployment руками» без выяснения причины.

### 6. [middle] HPA поднял реплики до максимума, но часть подов в `Pending`. Что дальше?

Планировщику не хватает ресурсов узлов под `requests` новых подов. `kubectl describe pod` покажет `0/3 nodes are available: 3 Insufficient cpu`. HPA узлов не добавляет. В облаке нужен Cluster Autoscaler или Karpenter, локально освобождаю ресурсы или снижаю `requests`. Заодно проверяю, что `requests` не завышены.

**Что хотят услышать:** `Insufficient cpu`, разница между HPA и Cluster Autoscaler, правильные `requests`.

**Красный флаг:** «HPA сам создаст узлы».

### 7. [middle] Реплики то растут, то падают каждые несколько минут. В чём дело и как чинить?

Флаппинг: нагрузка около границы цели, а уменьшение слишком быстрое. Проверяю `describe hpa`, чередование `SuccessfulRescale`. Лечу `behavior.scaleDown.stabilizationWindowSeconds` (по умолчанию 300 с), ограничением скорости уменьшения и более осторожной целью (50-70%). Проверяю, что под быстро становится Ready, иначе новые реплики не успевают взять нагрузку.

**Что хотят услышать:** окно стабилизации, `behavior`, цель с запасом, время старта пода.

**Красный флаг:** «выключу автоскейлинг и поставлю 6 реплик навсегда».

### 8. [middle] Deployment описан в Git с `replicas: 3` и есть HPA. Что не так и как исправить?

Два источника истины. Каждый деплой из Git вернёт 3, HPA будет менять обратно, и реплики дёргаются при выкатке. Исправление: убрать `replicas` из манифеста при включённом HPA (в Helm под условие). В GitOps (тема 9) это ещё и постоянный дрейф.

**Что хотят услышать:** борьба HPA и Git, удаление `replicas`, ссылка на GitOps.

**Красный флаг:** «оставлю replicas и буду перезапускать деплой».

### 9. [middle] Как выбрать `requests.cpu` и цель для HPA у нового сервиса?

Сначала измеряю: нагрузочный тест, `kubectl top` или метрики Prometheus, смотрю обычное потребление и пик. `requests` ставлю около типичной нагрузки (например, p50-p90), цель HPA 50-70% от них, чтобы был запас на время старта новых подов. Слишком маленькие `requests` дают постоянные скачки процента и лишние реплики, слишком большие ведут к недогрузке узлов и `Pending`.

**Что хотят услышать:** измерение вместо угадывания, запас, влияние на планировщик.

**Красный флаг:** «ставлю 1 CPU везде, чтобы не думать».

### 10. [middle] Очередь заданий растёт, а CPU воркеров низкий. Подойдёт ли HPA по CPU?

Нет: воркеры ждут ввода-вывода, CPU не растёт, и HPA не сработает. Нужна метрика очереди: KEDA, либо пользовательские метрики через Prometheus Adapter. KEDA умеет и уводить в ноль реплик.

**Что хотят услышать:** ограничение CPU-метрики, KEDA, событийное масштабирование.

**Красный флаг:** «увеличу limits CPU».

## Проверено на версиях

- Kubernetes: 1.36.x, kubectl 1.37.1
- kind: v0.33.0
- Helm: v4.3.0
- metrics-server: версия не закреплена, проверь актуальную версию на странице проекта
- busybox (образ): 1.37.0

## Итог урока: ты умеешь

- [ ] умею поставить metrics-server в kind и проверить его через `kubectl top`
- [ ] умею объяснить, почему HPA без `requests` показывает `<unknown>`
- [ ] умею посчитать по формуле, сколько реплик запросит HPA
- [ ] умею создать нагрузку через `/burn` и наблюдать масштабирование
- [ ] умею читать `kubectl describe hpa`: события, `Conditions`, текущую и целевую метрику
- [ ] умею добавить HPA в Helm-чарт под флаг `hpa.enabled` и убрать `replicas` при включённом HPA
- [ ] умею объяснить флаппинг и настроить `behavior.scaleDown`
- [ ] умею отличить HPA, VPA, KEDA и Cluster Autoscaler по задачам

**Дальше:** [Урок 5.12: Безопасность кластера: RBAC, NetworkPolicy, PSS](12-k8s-security.md)
