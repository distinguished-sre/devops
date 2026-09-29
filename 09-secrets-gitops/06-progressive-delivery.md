---
layout: lesson
title: "Canary и откат по метрикам: Argo Rollouts"
topic: 9
lesson: "9.6"
time: "2 ч"
---

## Зачем это нужно

Обычный `RollingUpdate` (5.8, урок про пробы и выкатки) заменяет поды по одному и смотрит только на пробы готовности. Если новая версия отвечает 200 на `/readyz`, но отдаёт 500 на каждый третий запрос, Kubernetes спокойно докатит её на 100% трафика, а о проблеме ты узнаешь из алерта или от пользователей. На работе это классика: «релиз прошёл зелёным, а через 10 минут упала конверсия».

Canary (канареечный релиз) даёт новой версии малую долю трафика, сравнивает метрики и сам решает: продолжать или откатывать. Argo Rollouts делает это декларативно, внутри кластера, вместе с Gateway API и Prometheus, которые у тебя уже есть.

Шаг проекта: «Заметки» выкатываются как `Rollout` с шагами 10/30/60/100% и анализом доли ошибок; плохая версия 0.7.1 откатывается сама.

## Что нужно знать

- [Урок 5.7: пробы, ресурсы, выкатки](../05-kubernetes/07-probes-resources-rollouts.md) - `RollingUpdate`, `maxUnavailable`, `kubectl rollout undo`.
- [Урок 5.4: Gateway API](../05-kubernetes/04-ingress-gateway.md) - `HTTPRoute`, `backendRefs` с весами.
- [Урок 5.9: Helm](../05-kubernetes/09-helm.md) - шаблоны чарта, `values.yaml`, `helm template`.
- [Урок 8.3: PromQL](../08-observability/03-promql.md) - `rate`, доля ошибок, recording rules.
- [Урок 8.9: мониторинг в Kubernetes](../08-observability/09-k8s-monitoring.md) - Prometheus в ns `monitoring`, ServiceMonitor.
- [Урок 9.3: GitOps с Flux](03-gitops-flux.md) - релиз чарта идёт через git.
- [Урок 9.5: CloudNativePG](05-cnpg.md) - БД, с которой работает каждая версия приложения.

## Теория

### Стратегии релизов

| Стратегия | Как работает | Плюс | Минус |
|---|---|---|---|
| Recreate | Остановить старое, запустить новое | Просто, нет смеси версий | Простой |
| Rolling | Поды заменяются по одному | Без простоя, из коробки | Смотрит только пробы, откат вручную |
| Blue/green | Рядом полная копия новой версии, трафик переключается разом | Мгновенный откат | Двойные ресурсы, весь трафик сразу |
| Canary | Новая версия получает 10%, 30%, ... | Ошибку видит малая доля | Нужны хорошие метрики и трафик |
| Shadow | Копия трафика уходит на новую версию, ответы выбрасываются | Проверка без риска | Сложно с записью в БД |

Feature flag (переключатель функции) отделяет включение фичи от выкатки кода: код уже в проде, а фичу включают для 1% пользователей. Canary защищает от плохого кода, флаг от плохой идеи; их часто используют вместе.

> **Проверь понимание:** у тебя два пода, а хочется отдать новой версии ровно 10% трафика. Почему `RollingUpdate` этого не умеет?

<details markdown="1">
<summary>Ответ</summary>

`RollingUpdate` управляет числом подов, а не долей трафика. Из двух подов минимальный шаг 50%. Service раскидывает запросы примерно поровну по подам. Долю трафика задаёт маршрутизатор: Gateway API с весами или service mesh.

</details>

### Как устроен Argo Rollouts

Argo Rollouts (проект CNCF) добавляет в кластер контроллер и CRD (custom resource definition, пользовательский тип ресурса):

- `Rollout` заменяет `Deployment`: тот же шаблон пода, но вместо `strategy` блок `canary` или `blueGreen` с шагами.
- `AnalysisTemplate` описывает проверку: запрос к метрике, условие успеха и провала.
- `AnalysisRun` создаётся контроллером на каждый релиз и хранит результат: `Successful`, `Failed`, `Inconclusive`.

Под капотом контроллер управляет двумя ReplicaSet: stable (проверенная версия) и canary (новая). Для распределения трафика нужны два Service (`notes` для stable и `notes-canary` для canary) и плагин маршрутизации. Он двигает веса в `HTTPRoute`. Без плагина Rollouts умеет только менять число подов, то есть работает как продвинутый rolling.

Состояния анализа важны для диагностики. `Successful`: условие выполнено. `Failed`: превышен `failureLimit`, релиз автоматически прерывается (abort) и трафик возвращается на stable. `Inconclusive`: не удалось вычислить (нет данных, пустой ответ), релиз замирает и ждёт человека.

> **Проверь понимание:** что произойдёт с трафиком, когда `AnalysisRun` перешёл в `Failed` на шаге 30%?

<details markdown="1">
<summary>Ответ</summary>

Контроллер прерывает релиз: вес canary в `HTTPRoute` возвращается в 0, весь трафик идёт на stable ReplicaSet. Canary-поды масштабируются вниз через `scaleDownDelaySeconds`. Rollout получает статус `Degraded`. Чтобы выкатить повторно, нужна новая ревизия пода.

</details>

### Какую метрику проверять

Ошибка новичка: анализировать общую долю ошибок сервиса. При весе canary 10% и 30% ошибок в новой версии общая доля будет около 3%, то есть ниже любого разумного порога. Поэтому запрос строится только по подам canary: их имена содержат хеш шаблона (`notes-<hash>-...`), который Rollouts подставляет в аргумент анализа. Recording rule `notes:http_errors:ratio5m` из 8.3 полезна для алертов на весь сервис, а для canary берём сырую метрику `notes_http_requests_total` с фильтром по `pod`.

Второе: на малом трафике доля ошибок шумит. Одна ошибка на пять запросов это 20%. Поэтому условие задают с запасом, а окно `rate` делают не короче двух-трёх интервалов сбора (scrape).

> **Проверь понимание:** почему для анализа canary нельзя использовать `rate5m`, а лучше окно 2m?

<details markdown="1">
<summary>Ответ</summary>

Пятиминутное окно смешивает данные до и после начала canary и реагирует с опозданием: новая версия уже получила бы 30% трафика. Окно 2m при scrape раз в 15 секунд даёт достаточно точек и быстрее показывает плохую версию.

</details>

### Blue/green и совместимость с БД

Blue/green в Rollouts включается блоком `blueGreen` (сервисы `activeService` и `previewService`, переключение командой `promote`). Мы его только знаем, руками не собираем. Flagger (Flux-проект) решает ту же задачу другим способом, через объект `Canary`; в этом курсе он не используется.

Откат кода не откатывает схему БД. Поэтому миграции делают в стиле expand/contract (расширить, потом сузить): релиз N добавляет колонку, но не требует её; релиз N+1 начинает писать в неё; и только релиз N+2 удаляет старую колонку. Тогда любая пара соседних версий совместима, и автоматический откат безопасен.

> **Проверь понимание:** релиз переименовал колонку `text` в `body` и сразу удалил старую. Автоматический откат сработал. Что будет?

<details markdown="1">
<summary>Ответ</summary>

Старая версия кода ищет колонку `text`, которой уже нет, и падает с ошибкой SQL на каждом запросе. Откат кода не вернул схему. Правильно: добавить `body`, писать в обе колонки, и только через релиз удалить `text`.

</details>

## Практика

Ты в кластере `kind-notes`, ns `notes`. Prometheus из 8.9 работает в ns `monitoring`, приложение публикуется через Gateway `notes-gw`, релиз чарта идёт из git через Flux.

### Если у тебя 8 ГБ

Оставь `replicaCount: 2` и не запускай Grafana (`kubectl -n monitoring scale deploy -l app.kubernetes.io/name=grafana --replicas=0`). Canary работает по весам трафика, а не по числу подов, поэтому двух реплик достаточно. Не держи CNPG с двумя инстансами одновременно с этим уроком: `instances: 1`.

### Задание 1. Ставим Argo Rollouts и плагин Gateway API

**Цель:** контроллер Argo Rollouts работает и умеет менять веса в `HTTPRoute`.

**Предскажи:** контроллеру нужно менять `HTTPRoute`. Хватит ли ему прав из стандартной установки? Что произойдёт, если нет?

<details markdown="1">
<summary>Ответ</summary>

Не хватит: в стандартной установке нет прав на ресурсы `gateway.networking.k8s.io`. Контроллер запустится, но при первой попытке сдвинуть вес выдаст ошибку `forbidden` в событиях Rollout, и релиз застрянет на первом шаге.

</details>

**Шаги:**

1. Установи контроллер из манифеста релиза v1.10.0 в ns `argo-rollouts`.
2. Добавь плагин в ConfigMap контроллера. Версию плагина смотри на странице проекта `argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi`: проверь актуальную версию на странице проекта и подставь в `PLUGIN_VERSION`.
3. Выдай права на `httproutes`.

```bash
# Контроллер Argo Rollouts фиксированной версии
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/download/v1.10.0/install.yaml

# Версию плагина подставь со страницы релизов проекта
export PLUGIN_VERSION=<версия-со-страницы-проекта>

# Регистрируем плагин: контроллер скачает бинарник при старте
kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-rollouts-config
  namespace: argo-rollouts
data:
  trafficRouterPlugins: |-
    - name: "argoproj-labs/gatewayAPI"
      location: "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/${PLUGIN_VERSION}/gatewayapi-plugin-linux-amd64"
YAML

# Права контроллера на HTTPRoute
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-rollouts-gatewayapi
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "watch", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-rollouts-gatewayapi
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argo-rollouts-gatewayapi
subjects:
  - kind: ServiceAccount
    name: argo-rollouts
    namespace: argo-rollouts
YAML

# Перезапуск, чтобы контроллер прочитал ConfigMap
kubectl -n argo-rollouts rollout restart deploy/argo-rollouts
kubectl -n argo-rollouts rollout status deploy/argo-rollouts
```

Плагин для командной строки `kubectl argo rollouts` скачай бинарником `kubectl-argo-rollouts-linux-amd64` со страницы релиза v1.10.0, сверь SHA256 с файлом контрольных сумм на той же странице, положи в `~/.local/bin/kubectl-argo-rollouts` и сделай исполняемым.

**Что должно получиться:**

```text
deployment "argo-rollouts" successfully rolled out
```

и в логах контроллера видна загрузка плагина:

```bash
kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i plugin
```

```text
level=info msg="Downloading plugin argoproj-labs/gatewayAPI from: https://github.com/argoproj-labs/..."
```

**Объясни себе:**
- Почему контроллеру, а не Kubernetes, нужны права на `HTTPRoute`?
- Что будет с трафиком, если контроллер Rollouts упадёт посреди релиза?

**Типичные ошибки:**
- `unable to load plugin ... 404 Not Found` в логах: неверный `PLUGIN_VERSION` или имя файла. Открой страницу релизов плагина и скопируй имя ассета дословно.
- `Error from server (NotFound): namespaces "argo-rollouts" not found`: пропущен `kubectl create namespace`.

### Задание 2. Rollout, AnalysisTemplate и веса в чарте

**Цель:** чарт 0.5.0 умеет выкатывать «Заметки» как `Rollout`, если `rollout.enabled=true`.

**Предскажи:** сколько `Service` и сколько `backendRefs` в `HTTPRoute` нужно для canary и какие у них веса до начала релиза?

<details markdown="1">
<summary>Ответ</summary>

Два Service (`notes` для stable, `notes-canary` для canary) и два `backendRef` в маршруте. Исходные веса: stable 100, canary 0. Плагин будет менять именно эти числа.

</details>

**Шаги:**

1. В `helm/notes/values.yaml` добавь блок (`Chart.yaml`: `version: 0.5.0`, `appVersion: "0.7.1"`):

```yaml
# Выкатка через Argo Rollouts вместо Deployment
rollout:
  enabled: false
  steps:
    - setWeight: 10
    - pause: {duration: 60s}
    - setWeight: 30
    - pause: {duration: 60s}
    - setWeight: 60
    - pause: {duration: 60s}
    - setWeight: 100
  analysis:
    prometheus: http://prometheus-operated.monitoring.svc:9090
    interval: 30s
    maxErrorRatio: 0.05
    failureLimit: 1
```

2. Вынеси шаблон пода из `deployment.yaml` в `_helpers.tpl` как `notes.podTemplate` (образ, `envFrom`, пробы, ресурсы, аннотация `checksum/config` с хешем ConfigMap: смена конфигурации создаёт новую ревизию). Обёртка Deployment: {% raw %}`{{- if not .Values.rollout.enabled }}`{% endraw %}.

3. Создай `templates/rollout.yaml`:

{% raw %}
```yaml
{{- if .Values.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ include "notes.fullname" . }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: notes
  template:
    {{- include "notes.podTemplate" . | nindent 4 }}
  strategy:
    canary:
      stableService: notes
      canaryService: notes-canary
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: notes
            namespace: {{ .Release.Namespace }}
      # Фоновый анализ идёт всё время релиза
      analysis:
        templates:
          - templateName: notes-error-ratio
        startingStep: 0
        args:
          - name: canary-hash
            valueFrom:
              podTemplateHash: Latest
      steps:
        {{- toYaml .Values.rollout.steps | nindent 8 }}
---
apiVersion: v1
kind: Service
metadata:
  name: notes-canary
spec:
  selector:
    app.kubernetes.io/name: notes
  ports:
    - port: 8080
      targetPort: 8080
{{- end }}
```
{% endraw %}

4. Создай `templates/analysistemplate.yaml`. Запрос считает долю ошибок только по подам canary:

{% raw %}
```yaml
{{- if .Values.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: notes-error-ratio
spec:
  args:
    - name: canary-hash
  metrics:
    - name: error-ratio
      interval: {{ .Values.rollout.analysis.interval }}
      initialDelay: 60s
      failureLimit: {{ .Values.rollout.analysis.failureLimit }}
      # Пустой ответ (нет метрики) не считается успехом: будет Inconclusive
      successCondition: result[0] < {{ .Values.rollout.analysis.maxErrorRatio }}
      provider:
        prometheus:
          address: {{ .Values.rollout.analysis.prometheus }}
          query: |
            sum(rate(notes_http_requests_total{namespace="notes",pod=~"notes-{{`{{args.canary-hash}}`}}-.*",status=~"5.."}[2m]))
            /
            sum(rate(notes_http_requests_total{namespace="notes",pod=~"notes-{{`{{args.canary-hash}}`}}-.*"}[2m]))
{{- end }}
```
{% endraw %}

5. В `templates/httproute.yaml` при `rollout.enabled` `backendRefs` содержит оба сервиса:

{% raw %}
```yaml
      backendRefs:
        - name: notes
          port: 8080
          weight: 100
        {{- if .Values.rollout.enabled }}
        - name: notes-canary
          port: 8080
          weight: 0
        {{- end }}
```
{% endraw %}

6. Проверь шаблоны без установки:

```bash
helm lint helm/notes
helm template notes helm/notes --set rollout.enabled=true | grep -E '^kind: (Rollout|AnalysisTemplate|Service)'
```

**Что должно получиться:**

```text
==> Linting helm/notes
1 chart(s) linted, 0 chart(s) failed
kind: Service
kind: Rollout
kind: Service
kind: AnalysisTemplate
```

**Объясни себе:**
- Зачем в запросе `pod=~"notes-<hash>-.*"`, а не общая метрика сервиса?
- Почему `successCondition` выбран, а не `failureCondition`? Что изменится на пустом ответе?

**Типичные ошибки:**
- `Error: template: notes/templates/analysistemplate.yaml: ... function "args" not defined`: Helm попытался раскрыть аргумент Rollouts как свой шаблон. Экранируй так, как показано выше (обратные кавычки внутри двойных фигурных скобок).
- `Error: unable to build kubernetes objects from release manifest: no matches for kind "Rollout" in version "argoproj.io/v1alpha1"`: CRD Argo Rollouts не установлены, вернись к заданию 1.

### Задание 3. Хороший и плохой релиз

**Цель:** увидеть, как версия проходит все шаги, а вторая, с ошибками, откатывается сама.

Сначала образ приложения. В `app.py` v7.1 появляется переменная `FAIL_RATE` (доля искусственных 500 на `GET /notes` и `POST /notes`; `/healthz`, `/readyz`, `/metrics` не затрагиваются). Суть изменения:

```python
# Доля искусственных ошибок, 0..1. Некорректное значение: ошибка и код 2
try:
    FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))
    if not 0 <= FAIL_RATE <= 1:
        raise ValueError
except ValueError:
    print("FAIL_RATE должен быть числом от 0 до 1", file=sys.stderr)
    sys.exit(2)


def should_fail():
    # Вызывается в начале обработки GET /notes и POST /notes
    return FAIL_RATE > 0 and random.random() < FAIL_RATE
```

Если `should_fail()` вернул `True`, обработчик отвечает 500 `{"error":"injected failure"}`. Полный файл: [эталон v7.1](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Предскажи:** новая версия 0.7.1 с `FAIL_RATE=0.3` получает 10% трафика. Какая доля ошибок будет у сервиса в целом, и какая у canary-подов?

<details markdown="1">
<summary>Ответ</summary>

Примерно 3% у сервиса в целом (10% от 30%) и 30% у canary-подов. Порог 5% проходит общая метрика, но не проходит метрика canary. Поэтому мы смотрим на поды canary.

</details>

**Шаги:**

1. Собери и загрузи образ в kind, включи Rollout в git (в `gitops/apps/notes/` у HelmRelease: чарт 0.5.0, `values: rollout.enabled: true`, `image.tag: "0.7.0"`), дождись синхронизации Flux.
2. Запусти фоновую нагрузку. Canary получает лишь долю запросов, без потока метрикам не на чем считаться.

```bash
# Учебная нагрузка: около 10 запросов в секунду
while true; do curl -s -o /dev/null http://notes.lab/notes; sleep 0.1; done &
echo $! > /tmp/load.pid
```

3. Хороший релиз: `image.tag: "0.7.1"`, `FAIL_RATE` не задан (по умолчанию 0). Коммит, push, наблюдение:

```bash
kubectl argo rollouts get rollout notes -n notes -w
```

4. Плохой релиз: в values добавь `config.FAIL_RATE: "0.3"`, коммит, push. Следи за тем же выводом и за `AnalysisRun`:

```bash
kubectl -n notes get analysisrun
kubectl -n notes describe analysisrun -l rollouts-pod-template-hash | tail -20
```

5. Останови нагрузку: `kill $(cat /tmp/load.pid); rm /tmp/load.pid`.

**Что должно получиться:** для хорошего релиза:

```text
Name:            notes
Status:          ✔ Healthy
Strategy:        Canary
  Step:          7/7
  SetWeight:     100
  ActualWeight:  100
```

Для плохого:

```text
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 3: Metric "error-ratio" assessed Failed due to failed (2) > failureLimit (1)
Strategy:        Canary
  Step:          0/7
  SetWeight:     0
  ActualWeight:  0
```

Проверь, что трафик вернулся на stable: `kubectl -n notes get httproute notes -o jsonpath='{.spec.rules[0].backendRefs[*].weight}'` печатает `100 0`.

**Объясни себе:**
- Где именно принято решение об откате: в Kubernetes, Prometheus или контроллере Rollouts?
- Что бы случилось без нагрузки? Какой статус получил бы `AnalysisRun`?
- Что в git после автоматического отката: какая версия там записана, и чем это опасно для GitOps?

**Типичные ошибки:**
- `Metric "error-ratio" assessed Inconclusive due to inconclusive (1) > inconclusiveLimit (0)`: запрос вернул пустой результат (нет запросов к canary или метрика не доехала). Запусти нагрузку, проверь запрос в Prometheus.
- `HTTPRoute "notes" ... is forbidden` в событиях: не выдан RBAC из задания 1.
- Rollout завис на `Paused` без таймера: шаг `pause: {}` без `duration` ждёт ручной команды. Продолжи: `kubectl argo rollouts promote notes -n notes`.

### Задание 4. Шаг проекта: релиз 0.7.1 в «Заметках»

**Цель:** состояние проекта совпадает с контрактом: app v7.1, образ 0.7.1, тег git `v0.7.1`, чарт 0.5.0.

**Предскажи:** Flux увидел новый коммит, а `Rollout` откатился по анализу. Flux видит расхождение между git и кластером или нет?

<details markdown="1">
<summary>Ответ</summary>

Нет. Откат Rollouts не меняет манифест `Rollout`: в git и кластере записан один и тот же шаблон пода (новый), просто контроллер держит canary в состоянии abort и весь трафик на stable. Поэтому Flux ничего не «чинит», а исправлять надо коммитом в git.

</details>

**Шаги:**

1. Убери плохой `FAIL_RATE` из values (пусть по умолчанию 0) и оставь `rollout.enabled: true`.
2. Проверь, что версия и файлы на месте, и выпусти релиз:

```bash
cd ~/notes
git add app.py helm/notes gitops
git commit -m "Canary-релиз через Argo Rollouts, FAIL_RATE, образ 0.7.1"
git tag v0.7.1
git push origin main v0.7.1
```

3. Убедись, что Flux применил и Rollout здоров:

```bash
flux get helmreleases -n notes
kubectl argo rollouts get rollout notes -n notes | head -4
```

**Что должно получиться:**

```text
NAME   REVISION  SUSPENDED  READY  MESSAGE
notes  0.5.0     False      True   Helm upgrade succeeded for release notes/notes.v5 with chart notes@0.5.0
```

```text
Name:            notes
Namespace:       notes
Status:          ✔ Healthy
Strategy:        Canary
```

**Объясни себе:**
- Почему тег образа и тег git совпадают (`0.7.1` и `v0.7.1`)?
- Что нужно добавить в процесс, чтобы плохой релиз не мог получить тот же тег ещё раз?

**Типичные ошибки:**
- `error: src refspec main does not match any`: ветка в репозитории называется иначе; проверь `git branch --show-current`.
- `Helm upgrade failed: ... rollouts.argoproj.io "notes" is invalid`: несовместимая правка `steps` в values; проверь `helm template`.

## Сломай и почини

Запусти сценарий (файлы читать не надо):

```bash
project/notes/break/9.6/break.sh random
```

### Симптом

Одно из четырёх: (1) релиз завис, `AnalysisRun` в состоянии `Inconclusive`; (2) canary-поды получают трафик не по весу, вес в `HTTPRoute` не меняется; (3) плохая версия откатилась сама и это надо объяснить; (4) после отката приложение возвращает ошибки БД.

### Гипотезы

- Запрос анализа не возвращает данных (метка, окно, нет нагрузки).
- Плагин не загружен или у контроллера нет прав на `HTTPRoute`.
- Порог анализа сработал верно: canary действительно отдаёт 500.
- Схема БД изменилась несовместимо с предыдущей версией кода.

### Проверки

```bash
kubectl -n notes describe analysisrun | tail -30
kubectl -n argo-rollouts logs deploy/argo-rollouts | tail -30
kubectl -n notes get httproute notes -o yaml | grep -A8 backendRefs
kubectl -n notes logs deploy/notes --tail=20
```

### Исправление

<details markdown="1">
<summary>Разбор всех сценариев</summary>

1. `Inconclusive`. Смотри `Message` в `AnalysisRun`: пустой результат запроса. Скопируй запрос в Prometheus (port-forward на 9090). Причины: опечатка в метке (`namespace`, `pod`), окно `rate` короче двух интервалов сбора, нет нагрузки на canary. Исправь запрос или запусти нагрузку. Rollout после `Inconclusive` стоит на паузе: `kubectl argo rollouts retry rollout notes -n notes` перезапускает анализ.
2. Вес не меняется. В логах контроллера `plugin ... not found` или `forbidden`. Проверь ConfigMap `argo-rollouts-config` (имя плагина и URL) и ClusterRoleBinding, потом `rollout restart` контроллера. Без плагина Rollout меняет только число подов, и 10% трафика превращаются в долю подов.
3. Автоматический abort. Это штатная работа: `FAIL_RATE=0.3` даёт около 30% ошибок на canary, порог 5%. Убери причину, выкати новую ревизию.
4. Схема БД. Релиз удалил или переименовал колонку. Откат кода не вернёт схему. Верни колонку миграцией вперёд (roll-forward), а в будущем делай expand/contract.

</details>

## Вопросы с собеседований

### 1. [junior] Чем canary отличается от blue/green?

Blue/green держит две полные копии и переключает весь трафик разом: откат мгновенный, но нужны двойные ресурсы. Canary пускает на новую версию малую долю трафика и растит её по шагам, поэтому плохую версию увидит малая часть пользователей.

**Что хотят услышать:** доля трафика против переключения целиком, цена (ресурсы против нужды в метриках), когда что выбрать.

**Красный флаг:** «canary это когда мало подов».

### 2. [junior] Что делает `RollingUpdate` и чего он не проверяет?

Заменяет поды по одному с учётом `maxSurge` и `maxUnavailable`, ориентируясь на readiness-пробу. Не смотрит на бизнес-метрики: если под готов, но отдаёт ошибки на реальных запросах, выкатка продолжится.

**Что хотят услышать:** пробы как единственный критерий, ручной `kubectl rollout undo`.

**Красный флаг:** уверенность, что rolling сам откатит плохую версию.

### 3. [junior] Что такое feature flag и чем он отличается от canary?

Флаг включает функциональность без выкатки кода и позволяет отключить её мгновенно. Canary проверяет новую сборку на части трафика. Флаг защищает от плохой идеи, canary от плохого кода.

**Что хотят услышать:** развязка релиза и включения, риски (долг по флагам).

**Красный флаг:** считает их одним и тем же.

### 4. [middle] Канарейка получила 10% трафика, метрики «зелёные», но пользователи жалуются. Что проверишь?

Смотрю, что именно измеряет анализ: если общая доля ошибок сервиса, то 10% трафика с 30% ошибок дают 3% и проходят порог. Нужна метрика именно по canary. Проверяю и трафик: не слишком ли мало запросов, чтобы метрика значила что-то, и попадают ли запросы вообще на canary (веса в `HTTPRoute`).

**Что хотят услышать:** разбавление метрики, фильтр по подам или версии, минимальный объём трафика, латентность и p95 рядом с ошибками.

**Красный флаг:** «в Grafana всё зелёное, значит проблема на стороне пользователей».

### 5. [middle] Анализ Argo Rollouts завис в `Inconclusive`. Что делаешь?

Читаю `Message` в `AnalysisRun`, копирую запрос в Prometheus и смотрю, что он возвращает. Обычно пустой результат: опечатка в метках, окно короче двух интервалов сбора или нет трафика на canary. Исправляю причину и делаю `retry`. Это не «зелёный» и не «красный», и релиз честно ждёт человека.

**Что хотят услышать:** отличие `Inconclusive` от `Failed`, три причины пустого результата, `kubectl argo rollouts retry`.

**Красный флаг:** «уберу анализ, чтобы прошло».

### 6. [middle] После автоматического отката сервис всё равно возвращает ошибки БД. Почему?

Откат вернул код, но не схему. Релиз изменил схему несовместимо (переименовал или удалил колонку), и старый код с ней не работает. Чиню миграцией вперёд, а в процессе перехожу на expand/contract: добавить, писать в обе, читать из новой, удалить старую через релиз.

**Что хотят услышать:** rollback против roll-forward, expand/contract, соседние версии обязаны быть совместимы.

**Красный флаг:** «сделаю `down`-миграцию автоматически при откате».

### 7. [middle] Как в Kubernetes сделать canary на 10% трафика, если реплик две?

Через маршрутизатор, а не через число подов: Gateway API с весами в `backendRefs` двух Service (stable и canary) либо service mesh. Argo Rollouts с плагином двигает веса сам. Без такого слоя доля определяется числом подов и шаг минимум 50%.

**Что хотят услышать:** трафик против подов, два Service, веса в HTTPRoute.

**Красный флаг:** «поставлю 10 реплик и одну на новой версии».

### 8. [middle] Выкатка на малопосещаемом сервисе: 2 запроса в минуту. Как делать canary?

Метрики шумят, один сбой даёт огромную долю. Увеличиваю окно и число проверок, ставлю абсолютные условия (например, число ошибок), добавляю синтетический трафик (нагрузочный webhook или проверочный запрос) и увеличиваю паузы. Иногда canary на таком сервисе просто не даёт смысла, и лучше blue/green с smoke-тестом.

**Что хотят услышать:** статистическая значимость, синтетический трафик, честный отказ от метода.

**Красный флаг:** «оставлю тот же порог 2%».

### 9. [middle] Что такое DORA-метрики и как канареечный релиз влияет на них?

Четыре показателя: частота деплоев, время от коммита до прода (lead time), доля неудачных релизов (change failure rate), время восстановления (MTTR). Автоматический откат по метрикам снижает MTTR и делает неудачный релиз дешёвым, поэтому команда безопаснее выкатывает чаще.

**Что хотят услышать:** все четыре метрики, связь безопасных релизов с частотой.

**Красный флаг:** называет только «скорость деплоя».

### 10. [junior] Что такое shadow-трафик и где он опасен?

Копия боевых запросов уходит на новую версию, ответы отбрасываются. Проверяем нагрузку и ошибки без риска для пользователя. Опасно там, где версия делает побочные действия: пишет в БД, шлёт письма, платежи.

**Что хотят услышать:** зеркалирование против canary, побочные эффекты, идемпотентность.

**Красный флаг:** «безопасно везде».

## Проверено на версиях

- Argo Rollouts: v1.10.0
- Плагин Gateway API для Argo Rollouts: версия не закреплена, проверь актуальную версию на странице проекта
- Envoy Gateway: v1.9.2
- kube-prometheus-stack: chart 91.8.2
- Flux: v2.9.5
- Helm-чарт `notes`: 0.5.0, appVersion 0.7.1
- app.py: v7.1, образ `notes:0.7.1`

## Итог урока: ты умеешь

- [ ] умею объяснить разницу между rolling, blue/green, canary и shadow
- [ ] умею установить Argo Rollouts и подключить плагин Gateway API
- [ ] умею описать `Rollout` с шагами 10/30/60/100 и двумя Service
- [ ] умею написать `AnalysisTemplate` с запросом только по подам canary
- [ ] умею отличить `Failed` от `Inconclusive` и починить пустой запрос
- [ ] умею показать автоматический откат плохой версии и объяснить, где он произошёл
- [ ] умею объяснить, почему откат кода не откатывает схему БД и что такое expand/contract

**Дальше:** [Урок 9.7: Платформа целиком: разбор и слабые места](07-platform-review.md)
