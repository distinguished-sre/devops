---
layout: lesson
title: "Job, CronJob и DaemonSet"
topic: 5
lesson: "5.8"
time: "1.5 ч"
---

## Зачем это нужно

Не всё в кластере это сервер, который должен жить вечно. Миграция базы, ночной бэкап, пересчёт отчёта работают и завершаются. Если запихнуть такую задачу в Deployment, Kubernetes будет бесконечно перезапускать её после успешного завершения. А агент сбора логов или метрик должен быть на каждом узле ровно один, и Deployment с тремя репликами этого не гарантирует. Для этих случаев есть Job, CronJob и DaemonSet. На работе их встречаешь в каждом кластере: бэкапы, миграции, очистка, node-exporter, сборщики логов.

Шаг проекта: «Заметки» получают почасовой бэкап PostgreSQL (`k8s/base/60-pg-backup-cronjob.yaml`, CronJob `pg-backup` и PVC `pg-backups`); примеры Job и DaemonSet лежат отдельно в `k8s/examples/`.

## Что нужно знать

- [Урок 5.2: Pod и Deployment](02-pods-deployments.md) - шаблон пода, `restartPolicy`, `kubectl get/describe/logs`
- [Урок 5.5: StatefulSet и PVC](05-storage-statefulset-postgres.md) - PostgreSQL `postgres` и Service `db`, PVC как хранилище
- [Урок 5.6: ConfigMap и Secret](06-config-secrets.md) - Secret `notes-db` с ключом `POSTGRES_PASSWORD`
- [Урок 1.7: Bash в эксплуатации](../01-linux/07-bash-in-ops.md) - формат расписания из пяти полей, бэкап-скрипт

## Теория

### Job: задача, которая должна завершиться успешно

Job (задание) создаёт под и следит, чтобы задача закончилась кодом выхода 0. Если под упал, Job создаёт новый, пока не наберётся нужное число успехов или не исчерпается лимит попыток. Главные поля:

- `completions` - сколько успешных завершений нужно (по умолчанию 1);
- `parallelism` - сколько подов работают одновременно;
- `backoffLimit` - сколько раз можно повторить после сбоя (по умолчанию 6), паузы между попытками растут: 10 с, 20 с, 40 с и так далее до 6 минут;
- `activeDeadlineSeconds` - жёсткий потолок времени на всё задание;
- `ttlSecondsAfterFinished` - через сколько секунд после завершения Kubernetes сам удалит Job и его поды.

У пода в Job `restartPolicy` может быть только `Never` или `OnFailure`. `Always`, как у Deployment, запрещён: задача, которая должна закончиться, не должна перезапускаться вечно. `Never` создаёт новый под при сбое (старый остаётся для разбора логов), `OnFailure` перезапускает контейнер в том же поде.

Важное следствие: задача должна быть идемпотентной (idempotent), то есть безопасной при повторном запуске. Kubernetes гарантирует «минимум один раз», а не «ровно один».

> **Проверь понимание:** миграция базы упала на середине, `backoffLimit: 6`. Что произойдёт и почему это опасно?

<details markdown="1">
<summary>Ответ</summary>

Job создаст новый под и запустит миграцию заново, до шести раз. Если миграция не идемпотентна (например, добавляет колонку без `IF NOT EXISTS`), повтор упадёт на уже сделанной части. Поэтому миграции пишут так, чтобы повторный запуск был безопасен, а `backoffLimit` ставят небольшой.

</details>

### CronJob: Job по расписанию

CronJob (периодическое задание) сам не запускает поды. Он по расписанию создаёт объекты Job, а Job уже создаёт под. Расписание в формате cron из [урока 1.7](../01-linux/07-bash-in-ops.md): пять полей `минута час день месяц день_недели`. Часовой пояс по умолчанию это пояс контроллера (в kind обычно UTC); задать свой можно полем `timeZone: "Europe/Moscow"`.

Поля, которые определяют поведение:

| Поле | Что делает |
|---|---|
| `concurrencyPolicy` | `Allow` (по умолчанию) разрешает параллельные запуски, `Forbid` пропускает новый, пока идёт старый, `Replace` убивает старый |
| `startingDeadlineSeconds` | насколько запоздавший запуск ещё считается допустимым |
| `suspend` | `true` ставит расписание на паузу |
| `successfulJobsHistoryLimit` | сколько успешных Job хранить (по умолчанию 3) |
| `failedJobsHistoryLimit` | сколько упавших Job хранить (по умолчанию 1) |

Для бэкапа выбирай `Forbid`: два `pg_dump` одновременно только мешают друг другу. Пропущенные запуски (кластер был выключен) CronJob не догоняет пачкой: если пропущено больше 100 запусков подряд, он вообще перестаёт создавать Job. Поэтому `startingDeadlineSeconds` ставят осознанно.

> **Проверь понимание:** CronJob запускается каждый час, а очередной бэкап идёт уже полтора часа. Что произойдёт при `concurrencyPolicy: Forbid`?

<details markdown="1">
<summary>Ответ</summary>

Запуск, который наступил в момент работы предыдущего, будет пропущен (в событиях появится `JobAlreadyActive`). Следующий запуск пройдёт, если к нему предыдущий уже завершится. При `Allow` два бэкапа шли бы параллельно, при `Replace` первый был бы убит.

</details>

### DaemonSet: по одному поду на узел

DaemonSet (набор демонов) гарантирует, что на каждом подходящем узле работает ровно один под. Появился новый узел, под создаётся сам, узел удалён, под удаляется. Число реплик не задаётся: оно равно числу подходящих узлов. Типичные жильцы: сборщик логов (Alloy, Fluent Bit, в [уроке 8.7](../08-observability/07-logs-loki-alloy.md)), node-exporter, сетевой плагин (kindnet, kube-proxy у нас уже DaemonSet).

Где запускать, определяют `nodeSelector` и tolerations (допуски). Узлы control-plane имеют taint (метку-отталкивание) `node-role.kubernetes.io/control-plane:NoSchedule`, поэтому обычные поды туда не попадают. Агенту мониторинга обычно нужно быть и там, и тогда в DaemonSet добавляют toleration к этому taint. Это ровно то, что ты увидишь руками в задании 2.

> **Проверь понимание:** в кластере 1 control-plane и 2 worker, в DaemonSet нет tolerations. Сколько подов будет и почему?

<details markdown="1">
<summary>Ответ</summary>

Два, по одному на каждый worker. На control-plane под не сядет из-за taint `NoSchedule`, а DaemonSet «желаемых» подов считает только по узлам, куда под допустим (в `kubectl get ds` это столбец `DESIRED`).

</details>

## Практика

Кластер kind `notes`, контекст `kind-notes`, namespace `notes` из [урока 5.1](01-why-k8s-cluster.md) уже работают, StatefulSet `postgres` и Secret `notes-db` из уроков 5.5 и 5.6 на месте. Проверь:

```bash
kubectl config use-context kind-notes
kubectl -n notes get statefulset postgres
```

```text
Switched to context "kind-notes".
NAME       READY   AGE
postgres   1/1     3d
```

Примеры для заданий 1-2 кладём в `~/notes/k8s/examples/`:

```bash
mkdir -p ~/notes/k8s/examples
```

### Задание 1. Разовый Job и его сбой

**Цель:** увидеть, как Job доводит задачу до успеха и что он делает при сбое.

**Предскажи:** запускаем Job, который печатает строку и завершается с кодом 0. Сколько подов будет у Job и в каком статусе они останутся? Потом меняем команду на `exit 1` и ставим `backoffLimit: 2`. Сколько подов создастся до того, как Job сдастся?

<details markdown="1">
<summary>Ответ</summary>

Успешный Job: один под в статусе `Completed`, он не удаляется, чтобы можно было прочитать логи. Упавший с `backoffLimit: 2`: первый запуск плюс две повторные попытки, то есть 3 пода в статусе `Error`, после чего Job получает условие `BackoffLimitExceeded`.

</details>

**Шаги:**

1. Создай файл `~/notes/k8s/examples/job-hello.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: hello
  namespace: notes
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600   # через 10 минут Job уберётся сам
  template:
    spec:
      restartPolicy: Never       # для Job допустимы только Never и OnFailure
      containers:
        - name: hello
          image: busybox:1.37.0
          command: ["sh", "-c", "echo 'привет из Job'; sleep 3"]
```

2. Запусти и дождись завершения:

```bash
kubectl apply -f ~/notes/k8s/examples/job-hello.yaml
kubectl -n notes wait --for=condition=complete job/hello --timeout=60s
kubectl -n notes get pods -l job-name=hello
kubectl -n notes logs job/hello
```

3. Теперь сломай задачу. Удали Job, замени в файле команду на `["sh", "-c", "echo сбой; exit 1"]`, применить заново и понаблюдай:

```bash
kubectl -n notes delete job hello
sed -i 's/echo .привет из Job.; sleep 3/echo сбой; exit 1/' ~/notes/k8s/examples/job-hello.yaml
kubectl apply -f ~/notes/k8s/examples/job-hello.yaml
sleep 45
kubectl -n notes get pods -l job-name=hello
kubectl -n notes describe job hello | grep -A3 -i 'events\|failed'
```

(На macOS `sed -i` требует пустой аргумент: `sed -i ''`.)

**Что должно получиться:**

```text
job.batch/hello condition met
NAME          READY   STATUS      RESTARTS   AGE
hello-x7k2p   0/1     Completed   0          8s
привет из Job
```

и после поломки:

```text
NAME          READY   STATUS   RESTARTS   AGE
hello-4tmqz   0/1     Error    0          44s
hello-8d5vn   0/1     Error    0          31s
hello-r2jwl   0/1     Error    0          11s
...
  Warning  BackoffLimitExceeded  Job  Job has reached the specified backoff limit
```

**Объясни себе:**

- Почему под `Completed` не пропал и зачем он нужен?
- Почему при `restartPolicy: Never` у упавшего Job несколько подов, а при `OnFailure` был бы один под с растущим `RESTARTS`?
- Что изменится, если убрать `ttlSecondsAfterFinished`?

**Типичные ошибки:**

- `The Job "hello" is invalid: spec.template.spec.restartPolicy: Unsupported value: "Always": supported values: "OnFailure", "Never"`: у Job нельзя `Always`. Поставь `Never` или `OnFailure`.

### Задание 2. DaemonSet: по одному поду на узел

**Цель:** понять, как DaemonSet выбирает узлы, и добавить toleration для control-plane.

**Предскажи:** в кластере 3 узла (`notes-control-plane`, `notes-worker`, `notes-worker2`). Сколько подов создаст DaemonSet без tolerations? А с toleration на `node-role.kubernetes.io/control-plane`?

<details markdown="1">
<summary>Ответ</summary>

Без toleration 2 пода (только worker), с toleration 3 (и control-plane тоже).

</details>

**Шаги:**

1. Создай `~/notes/k8s/examples/daemonset-agent.yaml`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: notes
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-agent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-agent
    spec:
      containers:
        - name: agent
          image: busybox:1.37.0
          env:
            - name: NODE_NAME            # имя узла, на котором запущен под
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          command: ["sh", "-c", "while true; do echo \"агент на узле $NODE_NAME\"; sleep 30; done"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi
```

2. Примени и посмотри, куда сели поды:

```bash
kubectl apply -f ~/notes/k8s/examples/daemonset-agent.yaml
kubectl -n notes rollout status ds/node-agent
kubectl -n notes get ds node-agent
kubectl -n notes get pods -l app.kubernetes.io/name=node-agent -o wide
```

3. Добавь в `spec.template.spec` (на одном уровне с `containers`) допуск для control-plane:

```yaml
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
```

4. Примени ещё раз и сравни:

```bash
kubectl apply -f ~/notes/k8s/examples/daemonset-agent.yaml
kubectl -n notes rollout status ds/node-agent
kubectl -n notes get ds node-agent
kubectl -n notes delete ds node-agent
kubectl -n notes delete job hello
```

**Что должно получиться:**

```text
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-agent   2         2         2       2            2           <none>          20s
```

```text
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-agent   3         3         3       3            3           <none>          70s
```

**Объясни себе:**

- Откуда у DaemonSet берётся число подов, если поля `replicas` нет?
- Чем `tolerations` отличается от `nodeSelector`: что один разрешает, а другой требует?
- Почему сборщик логов обязан иметь `requests` и `limits`, хотя он «просто агент»?

**Типичные ошибки:**

- `The DaemonSet "node-agent" is invalid: spec.template.metadata.labels: Invalid value: ...: selector does not match template labels`: метки шаблона не совпадают с `selector.matchLabels`. Приведи их к одному виду.
- `error: unknown field "spec.template.spec.containers[0].tolerations"`: `tolerations` вставлен внутрь контейнера. Он относится к поду, на уровень `containers`.

### Задание 3. Шаг проекта: бэкап PostgreSQL по расписанию

**Цель:** добавить в «Заметки» почасовой `pg_dump` в отдельный PVC, запустить его вручную и проверить, что дамп восстановим.

**Предскажи:** мы создаём PVC `pg-backups`, а CronJob монтирует его. Кластер kind использует StorageClass `standard` с режимом `WaitForFirstConsumer`. В каком статусе будет PVC сразу после `kubectl apply` и когда он станет `Bound`?

<details markdown="1">
<summary>Ответ</summary>

Сразу `Pending`: том не создаётся, пока нет пода, который его использует (так планировщик выбирает узел). Станет `Bound`, когда стартует первый под бэкапа, то есть после ручного запуска Job. Это нормально, а не поломка.

</details>

**Шаги:**

1. Создай `~/notes/k8s/base/60-pg-backup-cronjob.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-backups
  namespace: notes
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-backup
  namespace: notes
spec:
  schedule: "0 * * * *"              # каждый час в 00 минут, UTC
  concurrencyPolicy: Forbid          # два pg_dump одновременно не нужны
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 900     # бэкап не должен идти дольше 15 минут
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: pg-dump
              image: postgres:18     # версия клиента совпадает с сервером
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: notes-db
                      key: POSTGRES_PASSWORD
              command:
                - sh
                - -c
                - |
                  set -e
                  f=/backups/notes-$(date -u +%Y%m%d-%H%M%S).dump
                  pg_dump -h db -U notes -d notes -Fc -f "$f"
                  # хранить только дампы за 7 дней
                  find /backups -name 'notes-*.dump' -mtime +7 -delete
                  ls -l /backups
              volumeMounts:
                - name: backups
                  mountPath: /backups
          volumes:
            - name: backups
              persistentVolumeClaim:
                claimName: pg-backups
```

2. Примени, проверь PVC, запусти бэкап вручную:

```bash
kubectl apply -f ~/notes/k8s/base/60-pg-backup-cronjob.yaml
kubectl -n notes get pvc pg-backups
kubectl -n notes create job --from=cronjob/pg-backup pg-backup-manual-1
kubectl -n notes wait --for=condition=complete job/pg-backup-manual-1 --timeout=120s
kubectl -n notes logs job/pg-backup-manual-1
kubectl -n notes get pvc pg-backups
```

3. Проверь, что дамп читается. Под-«смотритель» подключает тот же PVC и показывает оглавление дампа (восстановление целиком с замером времени делает [урок 10.3](../10-capstone/03-backup-dr-capacity.md), здесь только проверка читаемости):

```bash
kubectl -n notes run pg-check --rm -i --restart=Never --image=postgres:18 \
  --overrides='{"spec":{"containers":[{"name":"pg-check","image":"postgres:18","command":["sh","-c","pg_restore -l /backups/notes-*.dump | head -12"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"pg-backups"}}]}}'
```

**Что должно получиться:**

```text
NAME         STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pg-backups   Pending                                       standard       3s
```

```text
total 16
-rw-r--r-- 1 root root 5834 Sep 29 10:31 notes-20260929-103101.dump
```

```text
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pg-backups   Bound    pvc-3c1f0f52-6a8e-4d8b-9b7e-0d1f4a0d5c11   1Gi        RWO            standard       50s
```

```text
;
; Archive created at 2026-09-29 10:31:01 UTC
;     dbname: notes
;     TOC Entries: 14
;     Compression: gzip
;     Dump Version: 1.16-0
;     Format: CUSTOM
```

Состояние проекта после урока: добавлен `k8s/base/60-pg-backup-cronjob.yaml`, в кластере CronJob `pg-backup` и PVC `pg-backups`, примеры в `k8s/examples/` вне цепочки. Образ и app не меняются (`0.4.1`). Долг: бэкапы лежат в том же кластере, что и база; потеря кластера убьёт и данные, и копии. Это закрывается выносом копий за пределы кластера ([урок 10.3](../10-capstone/03-backup-dr-capacity.md)).

```bash
cd ~/notes
git add k8s/base/60-pg-backup-cronjob.yaml k8s/examples/
git commit -m "k8s: почасовой pg_dump (CronJob pg-backup) и примеры Job/DaemonSet"
```

**Объясни себе:**

- Почему версия образа `postgres:18` для клиента должна совпадать с версией сервера?
- Что даёт `activeDeadlineSeconds` и что бы случилось, если БД зависла и `pg_dump` ждёт вечно?
- Почему копия в том же кластере это не настоящий бэкап?

**Типичные ошибки:**

- `pg_dump: error: connection to server at "db" (10.96.14.7), port 5432 failed: FATAL:  password authentication failed for user "notes"`: в Secret `notes-db` не тот пароль, что у базы. Сверь: `kubectl -n notes get secret notes-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d` (вывод не публикуй).
- `Error from server (BadRequest): container "pg-dump" in pod ... is waiting to start: CreateContainerConfigError`: в Secret нет ключа `POSTGRES_PASSWORD`. Добавь ключ и запусти Job заново.
- `pg_dump: error: could not translate host name "db" to address: Name or service not known`: Job запущен в другом namespace. Ресурсы должны быть в `notes`.

## Сломай и почини

Запусти сценарий, не читая скрипт:

```bash
cd ~/notes
bash break/5.8/break.sh 1
```

Номера 1-3 или `random`.

### Симптом

Тебе сообщили: «ночной бэкап не делается, новых файлов в `/backups` нет». Или: «Job упал, а в логах пусто». Или: «агент мониторинга есть на воркерах, но не на control-plane». Начни с наблюдений: что показывают `kubectl -n notes get cronjob,job,ds,pods`.

### Гипотезы

Составь свой список причин до проверок: расписание и `suspend` у CronJob, пароль и сеть у Job, taint узла у DaemonSet.

### Проверки

```bash
kubectl -n notes get cronjob pg-backup -o wide
kubectl -n notes describe cronjob pg-backup | tail -15
kubectl -n notes get jobs,pods
kubectl -n notes logs <под-упавшего-job>
kubectl -n notes get ds
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

**Сценарий 1: CronJob не запускается.** В `kubectl get cronjob pg-backup` столбец `LAST SCHEDULE` пустой, а `ACTIVE` равен 0. Расписание изменено на валидное по синтаксису, но никогда не наступающее (`0 0 30 2 *`, 30 февраля), либо `suspend: true`. Синтаксис API не проверяет на осмысленность, поэтому ошибки при `apply` нет. Исправление: вернуть `schedule: "0 * * * *"` и `suspend: false`, проверить `kubectl create job --from=cronjob/pg-backup check-1`. Урок: после правки расписания смотри `LAST SCHEDULE` на следующем запуске, а не радуйся отсутствию ошибки.

**Сценарий 2: Job упал по backoffLimit.** `kubectl get pods` показывает поды `Error`, `describe job` заканчивается `BackoffLimitExceeded`. `logs` пода: `FATAL: password authentication failed for user "notes"`. Причина: Secret ссылается на неверный пароль. Исправление: вернуть правильное значение в Secret `notes-db`, удалить упавший Job (`kubectl -n notes delete job <имя>`) и запустить заново из CronJob. Упавший Job сам не воскреснет: он остаётся в статусе Failed, пока его не удалить.

**Сценарий 3: DaemonSet не садится на control-plane.** `DESIRED 2`, а узлов 3. `kubectl get nodes -o custom-columns=...` показывает taint `node-role.kubernetes.io/control-plane:NoSchedule`. Исправление: добавить в шаблон DaemonSet `tolerations` для этого ключа (как в задании 2). Если агент там не нужен, ничего не чинить: это штатное поведение.

</details>

После разбора возврат к нормальному состоянию: `kubectl apply -f k8s/base/60-pg-backup-cronjob.yaml`.

## Вопросы с собеседований

### 1. [junior] Чем Job отличается от Deployment и когда что использовать?

Deployment держит приложение живым и перезапускает его при любом завершении. Job запускает задачу до успешного завершения и после этого ничего не делает. Миграция, разовый расчёт, бэкап это Job, веб-сервис это Deployment. У пода Job `restartPolicy` только `Never` или `OnFailure`.

**Что хотят услышать:** «до успешного завершения», restartPolicy, идемпотентность, `backoffLimit`.

**Красный флаг:** «Job это Deployment с одной репликой».

### 2. [junior] Ночной бэкап через CronJob не сработал. Твои действия?

Смотрю `kubectl get cronjob`: заполнено ли `LAST SCHEDULE`, не стоит ли `suspend`. Если запусков нет, проверяю расписание, часовой пояс и `startingDeadlineSeconds`, события `describe cronjob`. Если Job есть, но упал, смотрю `describe job` и `logs` пода. Для проверки запускаю вручную: `kubectl create job --from=cronjob/...`.

**Что хотят услышать:** цепочка CronJob -> Job -> под, `LAST SCHEDULE`, ручной запуск из шаблона, UTC по умолчанию.

**Красный флаг:** «пересоздам CronJob» без диагностики.

### 3. [junior] Зачем нужен DaemonSet? Приведи примеры.

Он гарантирует по одному поду на каждом (подходящем) узле: сборщик логов, node-exporter, сетевой плагин, агент безопасности. Число реплик не задаётся, оно равно числу узлов. Появился узел, под создаётся автоматически.

**Что хотят услышать:** «на каждом узле», агенты, автоматическое появление на новых узлах, tolerations.

**Красный флаг:** «это Deployment с несколькими репликами».

### 4. [junior] Что такое `backoffLimit` и что будет, когда он исчерпан?

Это число повторных попыток для упавшего Job (по умолчанию 6, паузы растут экспоненциально). После исчерпания Job получает условие `Failed` с причиной `BackoffLimitExceeded` и больше поды не создаёт. Поды с ошибкой остаются для разбора логов.

**Что хотят услышать:** экспоненциальная пауза, статус Failed, логи упавших подов.

**Красный флаг:** «Job будет пробовать бесконечно».

### 5. [middle] DaemonSet показывает DESIRED 2 при трёх узлах. Почему и что делать?

Скорее всего, на третьем узле taint (у control-plane это `NoSchedule`), а в DaemonSet нет соответствующего toleration. Проверяю `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints`, смотрю `nodeSelector` и `affinity`. Если агент нужен и там, добавляю toleration; если нет, всё штатно.

**Что хотят услышать:** taints и tolerations, nodeSelector, DESIRED считается по подходящим узлам.

**Красный флаг:** «удалю taint с узла» ради агента без понимания последствий.

### 6. [middle] Бэкап-CronJob иногда идёт дольше часа и запуски накладываются. Как поступить?

Ставлю `concurrencyPolicy: Forbid`, чтобы новый запуск пропускался, пока идёт старый, и `activeDeadlineSeconds`, чтобы зависший бэкап не жил вечно. Дальше разбираюсь, почему он растёт (объём базы, сеть, блокировки), и при необходимости увеличиваю интервал или делаю бэкап с реплики.

**Что хотят услышать:** Forbid vs Replace vs Allow, дедлайн, алерт на длительность и на отсутствие успешного запуска.

**Красный флаг:** оставить `Allow` по умолчанию и не мониторить.

### 7. [middle] Кластер был выключен сутки. Что произойдёт с почасовым CronJob после включения?

Пропущенные запуски не догоняются пачкой. Контроллер смотрит, сколько запусков пропущено за окно (`startingDeadlineSeconds`); если окно не задано и пропущено больше 100, CronJob перестаёт создавать Job с ошибкой `too many missed start times`. Если окно задано, считаются только пропуски внутри него, и обычно запускается один запуск.

**Что хотят услышать:** `startingDeadlineSeconds`, лимит 100, не «догоняет всё».

**Красный флаг:** «выполнится 24 раза подряд».

### 8. [middle] Job миграции упал, но при повторе результат «испорчен». В чём проблема?

Kubernetes гарантирует «минимум один раз»: под мог быть запущен повторно после сбоя узла или упасть на середине. Если задача не идемпотентна, повтор приведёт к дублям или ошибке. Пишу миграции так, чтобы повтор был безопасен (`IF NOT EXISTS`, транзакции, метка «уже сделано»), и запускаю их отдельным Job перед выкатом, а не в старте приложения.

**Что хотят услышать:** at-least-once, идемпотентность, транзакции, Job перед выкатом.

**Красный флаг:** «просто поставлю `backoffLimit: 0` и всё».

### 9. [middle] В кластере накопились сотни завершённых Job и подов. Откуда и как убрать?

Job и его поды не удаляются автоматически. Для ручных Job ставлю `ttlSecondsAfterFinished`, для CronJob ограничиваю `successfulJobsHistoryLimit` и `failedJobsHistoryLimit`. Существующее чищу: `kubectl delete job` (поды удалятся каскадно) или по статусу `--field-selector status.successful=1`.

**Что хотят услышать:** TTL, лимиты истории, каскадное удаление.

**Красный флаг:** «удаляю поды руками, Job остаётся».

### 10. [middle] Нужно раз в сутки запускать очистку ровно в 03:00 по Москве. Что пропишешь и на что обратишь внимание?

`schedule: "0 3 * * *"` и `timeZone: "Europe/Moscow"`. Без `timeZone` расписание считается по поясу контроллера, обычно UTC, и очистка пойдёт в 06:00 по Москве. Проверяю столбец `TIMEZONE` в `kubectl get cronjob` и `LAST SCHEDULE` после первого запуска.

**Что хотят услышать:** `timeZone`, UTC по умолчанию, проверка после первого срабатывания.

**Красный флаг:** пересчитывать время в голове и забывать про переход на летнее время в других поясах.

## Проверено на версиях

- Kubernetes: 1.36.x, kubectl 1.37.1
- kind: версия не закреплена, проверь актуальную версию на странице проекта
- PostgreSQL (образ `postgres:18`): 18
- busybox (образ): 1.37.0

## Итог урока: ты умеешь

- [ ] умею выбрать между Deployment, StatefulSet, Job, CronJob и DaemonSet под задачу
- [ ] умею написать Job с `backoffLimit`, `ttlSecondsAfterFinished` и понять, почему он упал
- [ ] умею читать расписание CronJob, задавать `timeZone` и `concurrencyPolicy`
- [ ] умею запустить CronJob вручную командой `kubectl create job --from=cronjob/...`
- [ ] умею добавить toleration в DaemonSet и объяснить, почему поды не сели на узел
- [ ] умею настроить почасовой `pg_dump` в PVC и проверить, что дамп читается
- [ ] умею объяснить, почему бэкап внутри того же кластера не решает проблему потери кластера

**Дальше:** [Урок 5.9: Helm](09-helm.md)
