---
layout: lesson
title: "Пробы, ресурсы и обновление без простоя"
topic: 5
lesson: "5.7"
time: "2.5 ч"
---

## Зачем это нужно

Кубернетес по умолчанию считает под здоровым, если процесс в контейнере запущен. Но процесс может висеть, не успеть подняться или съесть всю память узла, а выкатка новой версии может на секунды оставить пользователей без ответа. На работе это классические 502 после релиза и `OOMKilled` в три часа ночи.

Пробы (probes) говорят кластеру, когда под живой и когда готов принимать трафик. Ресурсы (requests и limits) говорят, сколько нужно и сколько можно. Стратегия обновления (rolling update) связывает всё вместе: новый под принимает трафик только после готовности, старый уходит только после нового.

Шаг проекта: «Заметки» получают версию приложения v4.1 (образ `0.4.1`), а Deployment получает пробы, ресурсы, безопасную стратегию выкатки и `preStop`.

## Что нужно знать

- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - SIGTERM, SIGKILL и код выхода 137
- [Урок 1.5: диск, память, CPU](../01-linux/05-disk-memory-cpu.md) - что такое OOM killer и `/leak`, `/burn`
- [Урок 4.2: Dockerfile](../04-docker/02-dockerfile.md) - сборка образа
- [Урок 5.2: поды и Deployment](02-pods-deployments.md) - ReplicaSet, `rollout`
- [Урок 5.3: Service и DNS](03-services-dns.md) - endpoints, `port-forward`
- [Урок 5.4: Ingress и Gateway API](04-ingress-gateway.md) - вход `http://notes.lab`
- [Урок 5.6: ConfigMap и Secret](06-config-secrets.md) - `envFrom`, Deployment из `10-deployment.yaml`

## Теория

### Три пробы и что делает кластер при провале

Kubelet на узле периодически проверяет контейнер и по результату принимает разные решения:

| Проба | Вопрос | Что происходит при провале |
|---|---|---|
| `startupProbe` | Приложение уже запустилось? | Перезапуск контейнера; пока она не прошла, liveness и readiness не работают |
| `livenessProbe` | Приложение живо, не зависло? | Контейнер перезапускается (restart) |
| `readinessProbe` | Готово принимать трафик? | Под убирают из endpoints Service, контейнер не трогают |

Проверка бывает `httpGet` (код 200-399 значит успех), `tcpSocket` и `exec`. У «Заметок» `/healthz` отвечает 200, пока жив процесс, и не смотрит зависимости; `/readyz` отвечает 200, если хранилище работает (в режиме postgres `SELECT 1`), иначе 503.

Главное правило: liveness проверяет только сам процесс. Если liveness ходит в базу, то при моргании базы кластер перезапустит все реплики сразу, а нагрузка на базу вырастет. Зависимости проверяет readiness: тогда под просто временно выпадает из балансировки.

> **Проверь понимание:** у пода 3 реплики, PostgreSQL недоступен 30 секунд. Что произойдёт с подами при `readinessProbe: /readyz` и `livenessProbe: /healthz`?

<details>
<summary>Ответ</summary>

Все три пода перестанут проходить readiness и выпадут из endpoints: Service отдаёт ошибки (нет адресов), но контейнеры не перезапускаются. Когда база вернётся, поды снова станут Ready сами. Liveness `/healthz` базу не проверяет, поэтому перезапусков нет.

</details>

### Параметры проб и startupProbe

У каждой пробы есть параметры: `periodSeconds` (как часто), `timeoutSeconds` (сколько ждать ответа), `failureThreshold` (сколько неудач подряд считать провалом), `successThreshold` (сколько успехов подряд считать успехом, для liveness и startup только 1). Старый приём `initialDelaySeconds` угадывает время старта и всегда ошибается: то слишком много, то слишком мало. Современный способ: `startupProbe` с большим запасом (`failureThreshold * periodSeconds`), после её успеха включаются остальные пробы с короткими интервалами.

Запас `startupProbe` это `periodSeconds * failureThreshold`: при 2 и 30 получается 60 секунд. Быстрое приложение стартует за 3 секунды и сразу переходит к liveness, лишнего ожидания нет.

> **Проверь понимание:** зачем `startupProbe`, если можно поставить `livenessProbe` с `initialDelaySeconds: 60`?

<details>
<summary>Ответ</summary>

Фиксированная задержка ждёт все 60 секунд, даже если приложение поднялось за 3, и не защищает, если старт занял 70. `startupProbe` ждёт ровно до успеха, но не дольше лимита, а после успеха liveness работает быстро и со своими короткими порогами.

</details>

### Requests, limits и QoS

`requests` это гарантия, по ней планировщик (scheduler) выбирает узел: под сядет туда, где свободно столько CPU и памяти. `limits` это потолок, его применяет ядро через cgroups (см. урок 1.5). CPU считается в милли-ядрах (`200m` это 0.2 ядра), память в байтах (`128Mi`).

- CPU сжимаемый: при превышении процесс притормаживают (throttling), но не убивают.
- Память несжимаемая: ядро убивает процесс (OOM killer), контейнер завершается с кодом 137 (128 + сигнал 9), причина `OOMKilled`, kubelet его перезапускает.

По соотношению requests и limits под получает класс QoS (Quality of Service): `Guaranteed` (requests равны limits у всех контейнеров), `Burstable` (requests заданы, но меньше limits) и `BestEffort` (ничего не задано). При нехватке памяти на узле первыми вытесняются BestEffort, потом Burstable, последними Guaranteed. Под без requests планировщик считает «ничего не просит» и набивает такими подами узел.

> **Проверь понимание:** контейнер упёрся в CPU limit и в memory limit. Чем отличаются последствия?

<details>
<summary>Ответ</summary>

Упёрся в CPU: сервис замедляется (throttling), латентность растёт, но контейнер живёт. Упёрся в память: процесс убит с кодом 137, контейнер перезапущен, соединения потеряны, при повторе будет `CrashLoopBackOff`.

</details>

### Rolling update и завершение пода

Deployment обновляет поды стратегией `RollingUpdate`. Два параметра управляют скоростью: `maxSurge` (сколько подов можно создать сверх нужного числа) и `maxUnavailable` (сколько можно потерять). Для 3 реплик с `maxSurge: 1` и `maxUnavailable: 0` кластер сначала поднимает 4-й под, ждёт его Ready и только потом гасит старый. Без readiness «Ready» наступает сразу после запуска процесса, и трафик уходит на под, который ещё не слушает порт.

Остановка пода тоже не мгновенная. Под помечается `Terminating`, параллельно запускается `preStop` и под убирают из endpoints, потом контейнер получает SIGTERM (урок 1.4), а через `terminationGracePeriodSeconds` (по умолчанию 30) SIGKILL. Удаление из endpoints доходит до всех узлов не сразу, и несколько секунд трафик ещё летит на умирающий под. Поэтому в `preStop` делают `sleep 5`. «Заметки» с v2.1 при SIGTERM дорабатывают запросы до 10 секунд.

Если новая версия не становится Ready, выкатка зависает: старые поды остаются и обслуживают пользователей. Вернуться на предыдущую ревизию можно командой `kubectl rollout undo`.

> **Проверь понимание:** зачем `maxUnavailable: 0`, если есть readiness?

<details>
<summary>Ответ</summary>

При умолчании (25%) кластер может сначала убить старый под, а потом создавать новый, и на время выкатки мощность падает. С `maxUnavailable: 0` старый под уходит только когда новый уже Ready: ёмкость никогда не ниже нужной. Платой служит временный лишний под (`maxSurge`) и ресурсы под него.

</details>

## Практика

Все команды выполняются в кластере kind `notes` (контекст `kind-notes`, namespace `notes`) из каталога `~/notes`. Убедись:

```bash
kubectl config use-context kind-notes
kubectl -n notes get pods
```

### Задание 1. Ресурсы, QoS и OOMKilled

**Цель:** увидеть, что память имеет жёсткий потолок, и научиться читать код 137.

**Предскажи:** мы зададим лимит памяти 128Mi и попросим под удержать 200 МБ через `/leak`. Что случится с контейнером и что покажет `RESTARTS`? Какой QoS-класс получит под с requests 50m/64Mi и limits 200m/128Mi?

<details>
<summary>Ответ</summary>

Контейнер будет убит ядром (OOMKilled, код 137), kubelet перезапустит его, `RESTARTS` станет 1. Класс QoS `Burstable`: requests меньше limits.

</details>

**Шаги:**

1. Задай ресурсы текущему Deployment (образ пока `0.4.0`):

```bash
kubectl -n notes set resources deployment/notes \
  --requests=cpu=50m,memory=64Mi --limits=cpu=200m,memory=128Mi
kubectl -n notes rollout status deployment/notes
```

2. Проверь класс QoS и пробросьте порт (порт 5.3):

```bash
POD=$(kubectl -n notes get pod -l app.kubernetes.io/name=notes -o name | head -1)
kubectl -n notes get "$POD" -o jsonpath='{.status.qosClass}{"\n"}'
kubectl -n notes port-forward "$POD" 18080:8080 >/dev/null &
sleep 2
```

3. Попроси удержать 200 МБ (демонстрационный эндпоинт, в реальном сервисе его бы не было):

```bash
curl -s "http://127.0.0.1:18080/leak?mb=200"; echo
kubectl -n notes get pods -l app.kubernetes.io/name=notes
kubectl -n notes describe "$POD" | grep -A6 'Last State'
```

**Что должно получиться:**

```text
Burstable
curl: (52) Empty reply from server
NAME                     READY   STATUS    RESTARTS      AGE
notes-6f7d9c5b8d-4kx2p   1/1     Running   1 (5s ago)    2m
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

**Объясни себе:**
- Почему клиент получил пустой ответ, а не ошибку приложения?
- Чем 137 отличается от кода 143 при обычном SIGTERM?

**Типичные ошибки:**
- `error: unable to forward port because pod is not running. Current status=Pending`: под ещё пересоздаётся, дождись `rollout status`.

### Задание 2. Приложение v4.1 и образ 0.4.1

**Цель:** добавить в приложение управляемые сбои, чтобы пробы можно было тренировать на реальном поведении.

**Предскажи:** какое минимальное изменение приложения позволит смоделировать медленный старт и «не готов»? Подсказка: нужны две переменные окружения.

<details>
<summary>Ответ</summary>

`STARTUP_DELAY` (пауза перед началом прослушивания порта: до неё порт закрыт, и `httpGet` получает connection refused) и `READY_FAIL` (сколько секунд после старта `/readyz` отвечает 503; `-1` значит 503 всегда).

</details>

**Шаги:**

1. В `app.py` добавь чтение переменных (ошибочное значение завершает процесс с кодом 2, как в контракте) и паузу перед созданием сервера `ThreadingHTTPServer(...)`:

```python
# v4.1: демонстрационные сбои для тренировки проб
def _int_env(name, default):
    raw = os.environ.get(name, str(default))
    try:
        return int(raw)
    except ValueError:
        print(f"{name} must be an integer, got {raw!r}", file=sys.stderr)
        sys.exit(2)

STARTUP_DELAY = _int_env("STARTUP_DELAY", 0)
READY_FAIL = _int_env("READY_FAIL", 0)
STARTED_AT = time.monotonic()

if STARTUP_DELAY > 0:
    time.sleep(STARTUP_DELAY)  # порт ещё не слушается
```

2. В обработчике `/readyz` перед проверкой хранилища (имя метода отправки ответа возьми из своего `app.py`):

```python
if READY_FAIL == -1 or (READY_FAIL > 0 and time.monotonic() - STARTED_AT < READY_FAIL):
    self._send(503, "not ready")
    return
```

3. Обнови `APP_VERSION` в `notes-config` на `4.1`, собери образ и загрузи в kind (версия закреплена, `latest` не используем):

```bash
docker build -t notes:0.4.1 .
kind load docker-image notes:0.4.1 --name notes
docker exec notes-control-plane crictl images | grep 'notes.*0.4.1'
```

Эталон: [project/notes/app.py](https://github.com/distinguished-sre/devops/blob/devops/project/notes/app.py).

**Что должно получиться:**

```text
docker.io/library/notes                 0.4.1               3f1c0a9d2b7e1       58.4MB
```

**Объясни себе:**
- Почему пауза `STARTUP_DELAY` стоит до создания сервера, а не после?
- Чем `READY_FAIL=-1` отличается от `READY_FAIL=30`?

**Типичные ошибки:**
- `ERROR: image "notes:0.4.1" not found locally`: образ не собран, повтори `docker build`.
- `ErrImagePull` в поде после выкатки: образ не загружен в узлы kind (`kind load`) или `imagePullPolicy` пытается идти в интернет; для локального образа нужен `IfNotPresent`.

### Задание 3. Пробы на живом поде

**Цель:** убедиться на опыте, что startup держит медленный старт, readiness выводит под из трафика, а liveness перезапускает зависший.

**Предскажи:** мы включим `STARTUP_DELAY=20` при `startupProbe` с запасом 60 секунд и потом `READY_FAIL=-1`. Что покажет `READY` у пода в первом и втором случае и будут ли перезапуски?

<details>
<summary>Ответ</summary>

Первый случай: 20 секунд `0/1 Running`, потом `1/1`, перезапусков нет (startup успевает). Второй: под `Running`, но `0/1` навсегда, `RESTARTS` остаётся 0: readiness не перезапускает.

</details>

**Шаги:**

1. Создай файл `k8s/base/10-deployment.yaml` целиком (это итоговая версия урока, объяснение блоков ниже):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notes
  namespace: notes
  labels:
    app.kubernetes.io/name: notes
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: notes
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # можно поднять один лишний под
      maxUnavailable: 0    # старый уходит только после готового нового
  template:
    metadata:
      labels:
        app.kubernetes.io/name: notes
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: notes
          image: notes:0.4.1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: notes-config
            - secretRef:
                name: notes-db
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          # Запуск: ждём до 60 секунд (30 попыток по 2 секунды)
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 2
            failureThreshold: 30
          # Жив ли процесс: зависимости не проверяем
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          # Готов ли к трафику: проверяет хранилище
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "5"]   # даём убрать под из endpoints до SIGTERM
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
```

2. Примени, включи медленный старт и смотри за подами (выход `Ctrl+C`):

```bash
kubectl apply -f k8s/base/10-deployment.yaml
kubectl -n notes rollout status deployment/notes
kubectl -n notes set env deployment/notes STARTUP_DELAY=20
kubectl -n notes get pods -l app.kubernetes.io/name=notes -w
```

3. Сломай готовность, посмотри выкатку и верни как было:

```bash
kubectl -n notes set env deployment/notes STARTUP_DELAY- READY_FAIL=-1
kubectl -n notes rollout status deployment/notes --timeout=40s
kubectl -n notes get pods -l app.kubernetes.io/name=notes
kubectl -n notes rollout undo deployment/notes
kubectl -n notes set env deployment/notes READY_FAIL-
```

**Что должно получиться:**

```text
notes-7c9d8f6b5-abcde   0/1   Running   0   8s
notes-7c9d8f6b5-abcde   1/1   Running   0   24s
Waiting for deployment "notes" rollout to finish: 3 of 3 updated replicas are available...
error: timed out waiting for the condition
NAME                     READY   STATUS    RESTARTS   AGE
notes-5b4f7d96c8-2hq8z   1/1     Running   0          3m
notes-5b4f7d96c8-7mv4k   1/1     Running   0          3m
notes-5b4f7d96c8-x9c2t   1/1     Running   0          3m
notes-84c6d5f7b9-lp2nw   0/1     Running   0          40s
```

Три старых пода живы и обслуживают трафик, новый не Ready.

**Объясни себе:**
- Почему выкатка с `READY_FAIL=-1` зависла, а не уронила сервис?
- Почему `STARTUP_DELAY=20` не вызвал перезапуск?

**Типичные ошибки:**
- `Startup probe failed: Get "http://10.244.1.7:8080/healthz": dial tcp 10.244.1.7:8080: connect: connection refused`: это нормальное событие во время старта; тревога, только если оно повторяется дольше запаса `startupProbe` (тогда контейнер перезапускается).
- `Liveness probe failed: Get ...: context deadline exceeded (Client.Timeout exceeded while awaiting headers)`: приложение не успело ответить за `timeoutSeconds`; либо оно занято (`/slow`), либо таймаут слишком мал.

### Задание 4. Обновление без простоя

**Цель:** доказать цифрами, что выкатка с readiness и `preStop` не теряет запросы, а без них теряет.

**Предскажи:** мы запустим цикл запросов на `http://notes.lab/` и выполним `rollout restart`. Сколько ответов не 200 ожидаешь при нашем манифесте? А если убрать `readinessProbe`, `preStop` и поставить `maxUnavailable: 1`?

<details>
<summary>Ответ</summary>

С нашим манифестом: ноль. Без readiness кластер сочтёт под готовым сразу после старта процесса, и часть запросов получит ошибки (502/503 от Envoy) или сброс соединения; проверим это в разделе «Сломай и почини».

</details>

**Шаги:**

1. В первом терминале запусти непрерывные запросы и подсчёт кодов (вход `notes.lab` из 5.4; вывод считает частоту кодов):

```bash
for i in $(seq 1 300); do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 http://notes.lab/
  sleep 0.1
done | sort | uniq -c
```

2. Во втором терминале, не дожидаясь конца цикла:

```bash
kubectl -n notes rollout restart deployment/notes
kubectl -n notes rollout status deployment/notes
```

**Что должно получиться:**

```text
    300 200
```

и

```text
deployment.apps/notes restarted
Waiting for deployment "notes" rollout to finish: 1 out of 3 new replicas have been updated...
deployment "notes" successfully rolled out
```

**Объясни себе:**
- Что делает `preStop: sleep 5` и почему без него бывают единичные ошибки в момент выхода старого пода?
- Что даёт `maxSurge: 1` и почему для 3 реплик на выкатку нужно ресурсов на 4 пода?

**Типичные ошибки:**
- `curl: (6) Could not resolve host: notes.lab`: нет записи в `/etc/hosts` (`127.0.0.1 notes.lab`, урок 5.4).
- `error: deployment "notes" exceeded its progress deadline`: новая версия не стала Ready за 600 секунд; смотри `kubectl describe pod` и `logs`, откатывай `rollout undo`.

### Задание 5. Шаг проекта: v0.4.1

**Цель:** зафиксировать состояние проекта: приложение v4.1, образ 0.4.1, Deployment с пробами и ресурсами в git.

**Предскажи:** совпадает ли то, что запущено в кластере, с файлом `10-deployment.yaml`? Как это проверить одной командой без изменений?

<details>
<summary>Ответ</summary>

`kubectl diff -f k8s/base/10-deployment.yaml` показывает разницу между файлом и кластером; пустой вывод и код 0 значат, что расхождений нет. После заданий 3-4 расхождений быть не должно: env-переменные мы откатили.

</details>

**Шаги:**

1. Проверь, что кластер соответствует манифесту, и что все реплики Ready:

```bash
kubectl diff -f k8s/base/10-deployment.yaml; echo "код: $?"
kubectl -n notes get deployment notes
kubectl -n notes get pods -l app.kubernetes.io/name=notes \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image
```

2. Проверь вход: `curl -s http://notes.lab/` и `curl -s http://notes.lab/readyz`.

3. Зафиксируй в git и поставь тег:

```bash
git add app.py k8s/base/10-deployment.yaml
git commit -m "feat: пробы, ресурсы и rolling update, app v4.1"
git tag v0.4.1
git log --oneline -1
```

**Что должно получиться:**

```text
код: 0
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
notes   3/3     3            3           2d
NAME                     READY   IMAGE
notes-5b4f7d96c8-2hq8z   true    notes:0.4.1
Notes service v4.1
ready
```

Состояние проекта: `app.py` v4.1, образ `0.4.1`, git-тег `v0.4.1`, Deployment с `startupProbe`, `livenessProbe /healthz`, `readinessProbe /readyz`, requests 50m/64Mi, limits 200m/128Mi, RollingUpdate 1/0 и `preStop`. Эталон: [project/notes/k8s/base](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/base).

**Объясни себе:**

**Типичные ошибки:**
- `error: the path "k8s/base/10-deployment.yaml" does not exist`: команда запущена не из `~/notes`.

## Сломай и почини

Скачай скрипт поломки и запусти сценарий (сам скрипт не читай, иначе теряется смысл упражнения):

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/5.7/break.sh
bash break.sh 1
```

Сценарии 1-4, номер передаётся аргументом. Вернуть рабочее состояние: `kubectl apply -f k8s/base/10-deployment.yaml`.

### Симптом

1: поды уходят в перезапуски (`CrashLoopBackOff`), хотя вручную приложение работает. 2: `RESTARTS` растёт, а в логах нет ошибки. 3: при выкатке `curl` ловит 502 и 503. 4: под `Running`, но `0/1`, перезапусков нет.

### Гипотезы

1: liveness убивает контейнер раньше конца старта. 2: контейнер убивают по памяти. 3: под считается Ready до готовности или слишком много подов уходит разом. 4: readiness проба падает.

### Проверки

Смотри `kubectl -n notes describe pod <имя>` (блоки `Last State` и `Events`), `kubectl -n notes logs <имя> --previous`, `kubectl -n notes get endpoints notes` и `kubectl -n notes get deployment notes -o jsonpath='{.spec.strategy}'`. Ищи: `Reason: OOMKilled` с `Exit Code: 137`, события `Liveness probe failed` и `Readiness probe failed: HTTP probe failed with statuscode: 503`, пустой список `ENDPOINTS`.

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**1. Liveness убивает медленный старт.** В `describe` видно `Liveness probe failed: ... connection refused` сразу после старта, код выхода 137 и повтор через фиксированные интервалы. Причина: приложение с `STARTUP_DELAY` не успело открыть порт до трёх неудач liveness. Исправление: добавить `startupProbe` с запасом (`periodSeconds: 2`, `failureThreshold: 30`), а не увеличивать `initialDelaySeconds` и не ослаблять liveness.

**2. OOMKilled.** `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`, логи чистые. Причина: работа процесса превысила `limits.memory` (`/leak`, большой ответ, утечка). Исправление зависит от причины: если утечка, чинить код; если реально нужно больше, поднять limit и request по замеру (`kubectl top pod`), не ставить limit "с запасом наугад". Помни, что requests выше фактического потребления занимают место на узле.

**3. 502 во время выкатки.** Причина: нет `readinessProbe` (или она проверяет то, что готово сразу), стоит `maxUnavailable` больше 0, нет `preStop`. Исправление: `readinessProbe` на `/readyz`, `maxSurge: 1`, `maxUnavailable: 0`, `preStop: sleep 5`. Проверка: цикл из задания 4 даёт только 200.

**4. `READY_FAIL`: под не Ready.** Причина: `/readyz` возвращает 503 (в этом сценарии по переменной `READY_FAIL`, в жизни: недоступна БД, нет прав на каталог). Перезапусков нет: так работает readiness. Исправление: убрать причину (`kubectl set env deployment/notes READY_FAIL-`) или, если катилась новая версия, `kubectl rollout undo deployment/notes`. Старые поды при `maxUnavailable: 0` всё это время обслуживали трафик.

</details>

## Вопросы с собеседований

### 1. [junior] Чем liveness отличается от readiness и что случится, если проверить в liveness базу данных?

Liveness отвечает «процесс завис, перезапусти», readiness отвечает «можно ли слать трафик». Если liveness ходит в базу и база моргнёт, кластер перезапустит все реплики сразу, что усилит проблему: рестарты, холодные кеши, шторм переподключений. Зависимости проверяют в readiness: под просто выпадает из балансировки.

**Что хотят услышать:** разные последствия провала (рестарт против исключения из endpoints), каскадный отказ, легковесность liveness.

**Красный флаг:** «это одно и то же, обе проверяют здоровье» или «в liveness проверяем всё подряд».

### 2. [middle] После релиза пользователи видят 502, хотя `kubectl rollout status` показывает успех. Твои действия?

Сначала смотрю, когда именно 502 (только во время выкатки или постоянно), затем `get endpoints`, события подов и логи входа. Проверяю, есть ли у Deployment `readinessProbe` и правильный ли путь, стоит ли `maxUnavailable: 0`, есть ли `preStop`. Для кратких 502 в момент замены пода: гонка между удалением из endpoints и SIGTERM, лечится `preStop sleep` и корректной обработкой SIGTERM. Для постоянных: не тот порт или label селектора.

**Что хотят услышать:** порядок от симптома к слою, endpoints, гонка при остановке, связь readiness и балансировки.

**Красный флаг:** сразу «перезапущу все поды» без выяснения причины.

### 3. [junior] Под перезапускается, в логах ничего нет. Что проверишь?

`kubectl describe pod`: в `Last State` смотрю `Reason` и `Exit Code`. 137 и `OOMKilled` значит память, 137 без OOM значит SIGKILL после провала liveness или по таймауту остановки, 1 или 2 значит падение приложения. Дополнительно `logs --previous`, потому что текущий контейнер новый и пустой.

**Что хотят услышать:** `--previous`, коды выхода, разница OOM и liveness.

**Красный флаг:** смотреть только `kubectl logs` текущего контейнера.

### 4. [middle] Приложение стартует 90 секунд и постоянно уходит в CrashLoopBackOff. Как исправишь?

Подозреваю, что liveness убивает контейнер до окончания старта. Добавляю `startupProbe` с запасом `failureThreshold * periodSeconds` больше 90 секунд, liveness оставляю короткой. Параллельно спрашиваю, почему старт такой долгий (миграции, прогрев), возможно, стоит вынести в отдельный Job.

**Что хотят услышать:** `startupProbe` вместо большого `initialDelaySeconds`, причина долгого старта.

**Красный флаг:** «просто поставлю liveness с задержкой 300 секунд».

### 5. [middle] Под с limits memory 128Mi часто `OOMKilled`. Просто поднимешь лимит?

Нет, сначала выясню, это утечка или реальная потребность: `kubectl top pod`, метрики памяти во времени, профиль. Если потребление растёт бесконечно, лимит лишь отсрочит падение. Если пик реальный, поднимаю request и limit по замеру с запасом 20-30%.

**Что хотят услышать:** утечка против нагрузки, метрики, request выше или равен типичному потреблению.

**Красный флаг:** «ставлю лимит 4Gi и забываю».

### 6. [middle] Что будет с подом без requests и limits и почему это плохо для кластера?

Под получает `BestEffort`: планировщик считает, что он ничего не просит, и набивает такими подами узел; при нехватке ресурсов их вытесняют первыми, и они мешают соседям, отъедая память. Без limit один под может съесть всю память узла.

**Что хотят услышать:** QoS-классы, порядок вытеснения, влияние на планирование.

**Красный флаг:** «ресурсы нужны только для красоты».

### 7. [junior] Deployment завис на выкатке: `1 out of 3 new replicas have been updated`. Что делать?

Смотрю новый под: `get pods`, `describe`, `logs`. Обычно это `ImagePullBackOff`, не проходит readiness или не хватает ресурсов. Старые поды продолжают работать (`maxUnavailable: 0`), поэтому спешки нет: исправляю причину или откатываю `kubectl rollout undo`.

**Что хотят услышать:** старые поды сохраняются, диагностика нового, `rollout undo`, `progressDeadlineSeconds`.

**Красный флаг:** удалять Deployment и создавать заново.

### 8. [middle] Как сделать, чтобы при выкатке не терялись запросы, идущие в момент остановки пода?

Корректная остановка: приложение обрабатывает SIGTERM и дорабатывает открытые запросы; `terminationGracePeriodSeconds` больше времени доработки; `preStop sleep` даёт время убрать под из endpoints и у входных прокси. Плюс `readinessProbe` и `maxUnavailable: 0` для того, чтобы новые поды принимали трафик только когда готовы.

**Что хотят услышать:** параллельность удаления из endpoints и SIGTERM, `preStop`, grace period.

**Красный флаг:** «Kubernetes сам всё делает без потерь».

### 9. [middle] Ночью алерт: ошибки 503 у сервиса, все поды `Running`, но `0/1`. Твои действия?

Это readiness: смотрю `describe` (код ответа пробы) и общие причины: недоступна БД, зависимость или сломанный релиз. Проверяю недавние изменения (`rollout history`), при плохом релизе откатываю `rollout undo` (митигация раньше поиска причины). Перезапуск подов не поможет, если причина внешняя.

**Что хотят услышать:** митигация первой, связь readiness с зависимостями, история ревизий.

**Красный флаг:** «удалю поды, они пересоздадутся».

### 10. [middle] Поды тормозят, а `kubectl top` показывает CPU ниже лимита. Что может быть?

CPU throttling: лимит выбирается внутри 100-миллисекундного периода, и в среднем нагрузка выглядит низкой. Смотрю `container_cpu_cfs_throttled_periods_total`: если растёт, поднимаю limit. Отличие от памяти: процесс замедляется, но не убивается.

**Что хотят услышать:** throttling, квантование cfs, разница с OOM.

**Красный флаг:** «CPU не кончился, значит дело не в нём».

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- Python: 3.13 (образ `python:3.13-slim`)
- PostgreSQL: 18
- Envoy Gateway: v1.9.2
- Kubernetes (kind, kubectl): версия не закреплена, проверь актуальную версию на странице проекта
- kind: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею объяснить разницу между startup, liveness и readiness и выбрать, что проверяет каждая
- [ ] умею настроить пробы с запасом на старт без `initialDelaySeconds`
- [ ] умею задать requests и limits и определить класс QoS пода
- [ ] умею распознать `OOMKilled` по коду 137 и `Last State` и отличить его от провала liveness
- [ ] умею настроить RollingUpdate с `maxSurge: 1` и `maxUnavailable: 0` и доказать отсутствие потерь запросами
- [ ] умею добавить `preStop` и объяснить, зачем он нужен при остановке пода
- [ ] умею откатить выкатку `kubectl rollout undo` и найти причину зависшей выкатки

**Дальше:** [Урок 5.8: Job, CronJob и DaemonSet](08-jobs-cronjob-daemonset.md)
