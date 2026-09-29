---
layout: lesson
title: "CloudNativePG: PostgreSQL-оператор"
topic: 9
lesson: "9.5"
time: "2 ч"
---

## Зачем это нужно

Ты уже гонял PostgreSQL в StatefulSet и делал `pg_dump` по крону. Но при падении primary никто не поднимет реплику, восстановление из бэкапа придётся вспоминать по памяти, а бэкапы лежат в том же кластере. Оператор (operator) кодирует эту эксплуатацию: репликация, failover, бэкапы и restore описываются ресурсами, а контроллер сам приводит систему к описанному.

На работе это ключевой вопрос собеседований: «стоит ли держать БД в Kubernetes и как это делают взрослые».

Шаг проекта: в `notes-gitops` появляется `Cluster notes-db` (CloudNativePG), приложение ходит в `notes-db-rw.notes.svc:5432`, пароль приходит из Vault через ESO, бэкапы уходят в MinIO, а StatefulSet `postgres` и CronJob `pg-backup` удалены.

## Что нужно знать

- [Урок 5.5: хранилище и StatefulSet с PostgreSQL](../05-kubernetes/05-storage-statefulset-postgres.md) - PVC, почему БД не Deployment, `pg_dump` из пода
- [Урок 5.8: Job, CronJob, DaemonSet](../05-kubernetes/08-jobs-cronjob-daemonset.md) - CronJob `pg-backup`, который мы сегодня заменим
- [Урок 6.4: управляемые сервисы](../06-cloud/04-managed-services.md) - что даёт облачная БД и чего оператору не хватает
- [Урок 9.2: Vault и External Secrets Operator](02-vault-k8s-eso.md) - пароль БД в Vault, `ExternalSecret`
- [Урок 9.3: GitOps, Flux](03-gitops-flux.md) - `HelmRelease`, `dependsOn`, всё меняется коммитом
- [Урок 9.4: cert-manager](04-cert-manager-tls.md) - паттерн «CRD плюс контроллер» ты уже видел

## Теория

### Оператор: CRD плюс контроллер

CRD (Custom Resource Definition) добавляет в API кластера новый тип объекта, например `Cluster` в группе `postgresql.cnpg.io`. Контроллер (controller) в цикле согласования (reconcile loop) сравнивает желаемое состояние из `spec` с фактическим и устраняет разницу: создаёт под, промоутит реплику, запускает бэкап. Это тот же принцип, что у Deployment, только знания про PostgreSQL зашиты в код.

CloudNativePG (CNPG) не использует StatefulSet. Он сам управляет подами и PVC напрямую, поэтому может выбрать, какую реплику повысить, и не ждёт упорядоченного старта. Каждый инстанс (instance) это отдельный под `notes-db-1`, `notes-db-2` со своим PVC.

Оператор ставится один раз на кластер (Helm-чарт `cloudnative-pg`, у нас через `HelmRelease` из 9.3), а базы описываются ресурсами `Cluster` в нужных namespace.

> **Проверь понимание:** чем оператор отличается от Helm-чарта, который просто рисует StatefulSet?

<details markdown="1">
<summary>Ответ</summary>

Helm один раз рендерит манифесты и уходит. Оператор живёт в кластере постоянно: замечает смерть primary, повышает реплику, перенастраивает Service, запускает бэкапы по расписанию. Helm описывает начальное состояние, оператор поддерживает и меняет его в ходе жизни.

</details>

### Сервисы, репликация и failover

Для кластера `notes-db` CNPG создаёт три Service:

| Service | Куда ведёт | Для чего |
|---|---|---|
| `notes-db-rw` | только primary | запись и чтение, его использует приложение |
| `notes-db-ro` | только реплики | тяжёлые read-only запросы |
| `notes-db-r` | любой инстанс | чтение, когда всё равно откуда |

Репликация потоковая (streaming replication): реплики получают WAL (write-ahead log, журнал изменений) от primary. При смерти primary оператор выбирает реплику с наименьшим отставанием, повышает её и переключает селектор `notes-db-rw` на новый под. Приложение не меняет адрес, оно лишь переподключается. Обычно это десятки секунд, по умолчанию `failoverDelay` равен 0, но время уходит на обнаружение сбоя и на промоут.

Асинхронная репликация означает, что при внезапной смерти primary последние транзакции могут не доехать до реплики (RPO не строго ноль). Про RPO и RTO как понятия смотри [урок 10.3](../10-capstone/03-backup-dr-capacity.md), здесь только механика.

> **Проверь понимание:** почему приложение должно ходить в `notes-db-rw`, а не в `notes-db-1`?

<details markdown="1">
<summary>Ответ</summary>

Имя пода привязано к конкретному инстансу, а primary может переехать на `notes-db-2`. Service `notes-db-rw` всегда указывает на текущий primary, оператор переставляет селектор сам.

</details>

### Бэкапы: base backup и WAL в объектное хранилище

CNPG использует Barman: периодически делает полный (base) бэкап и непрерывно архивирует WAL в S3-совместимое хранилище. Из base backup плюс WAL можно восстановить состояние на любой момент (PITR, point-in-time recovery). `ScheduledBackup` это cron для полных бэкапов, а архив WAL идёт постоянно, поэтому RPO для бэкапа измеряется секундами и минутами, а не «раз в час», как у нашего CronJob.

Хранилище не должно жить в том же отказном домене, что и БД. У нас в учебном kind это MinIO в namespace `minio`, поэтому долг остаётся: MinIO без репликации, а весь kind на одной машине. В продакшене это бакет в другом ЦОД или облаке.

Проверь актуальность: в новых релизах CNPG встроенный `barmanObjectStore` объявлен устаревшим в пользу плагина Barman Cloud, проверь актуальную схему на странице проекта cloudnative-pg.io. Для урока используем встроенный вариант, он короче.

> **Проверь понимание:** что лучше для восстановления после случайного `DROP TABLE` в 14:03: ночной `pg_dump` или base backup плюс WAL?

<details markdown="1">
<summary>Ответ</summary>

Base backup плюс WAL: восстанавливаешь новый кластер на 14:02:59 (PITR). С ночным дампом потеряешь всё, что произошло после ночи.

</details>

### Секреты и bootstrap

При создании кластера `bootstrap.initdb` создаёт базу и владельца. Пароль владельца можно передать секретом `secret.name` типа `kubernetes.io/basic-auth` с ключами `username` и `password`. Мы делаем этот секрет через `ExternalSecret` из Vault, поэтому пароля в git нет. Если секрет не задать, CNPG сгенерирует его сам в Secret `notes-db-app`, что тоже допустимо, но тогда источник правды не Vault.

Для миграции существующих данных есть `bootstrap.initdb.import`, но мы сделаем ручной `pg_dump` и `psql`: так виден каждый шаг и это то, что просят на собеседовании.

## Практика

Предполагается кластер `kind-notes` из урока 9.3 с Flux, Vault, ESO и cert-manager. Репозиторий `notes-gitops` склонирован в `~/notes-gitops`. Эталон лежит в [project/notes/gitops](https://github.com/distinguished-sre/devops/tree/devops/project/notes/gitops).

### Если у тебя 8 ГБ

Два инстанса PostgreSQL плюс MinIO лишние. Поставь `instances: 1` в `cnpg-cluster.yaml`. Failover в задании 3 не получится, вместо него убей под и посмотри, как оператор его пересоздаёт и подключает тот же PVC. Остальные задания не меняются.

### Задание 1. Оператор через Flux и MinIO для бэкапов

**Цель:** поставить CNPG v1.30.1 как `HelmRelease` и поднять MinIO в namespace `minio` под бэкапы.

**Предскажи:** сколько новых CRD появится после установки оператора: 0, 1 или больше? И в каком namespace они видны?

<details markdown="1">
<summary>Ответ</summary>

Больше одного: `clusters`, `backups`, `scheduledbackups`, `poolers` и другие. CRD кластерные, namespace у типа нет, у объектов есть.

</details>

**Шаги:**

1. Добавь оператор в инфраструктуру:

```bash
cd ~/notes-gitops
mkdir -p infrastructure/controllers/cnpg
cat > infrastructure/controllers/cnpg/release.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cnpg
  namespace: cnpg-system
spec:
  interval: 1h
  url: https://cloudnative-pg.github.io/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cnpg
  namespace: cnpg-system
spec:
  interval: 10m
  chart:
    spec:
      chart: cloudnative-pg
      # версия чарта: проверь соответствие оператору v1.30.1 на странице проекта
      version: "0.28.x"
      sourceRef:
        kind: HelmRepository
        name: cnpg
  install:
    crds: CreateReplace
  upgrade:
    crds: CreateReplace
YAML
cat > infrastructure/controllers/cnpg/kustomization.yaml <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - release.yaml
YAML
```

2. Подключи каталог в `infrastructure/controllers/kustomization.yaml` (добавь строку `- cnpg` в `resources`).
3. Поднимай MinIO для бэкапов (учебный, один под, версия образа не закреплена курсом, возьми свежий тег релиза со страницы quay.io/minio/minio, не `latest`):

```bash
kubectl create namespace minio
kubectl -n minio create secret generic minio-creds \
  --from-literal=rootUser=minio \
  --from-literal=rootPassword="$(openssl rand -base64 24)"
```

4. Манифест MinIO и бакет `cnpg-backups` создай по своему шаблону Deployment из урока 5.2 (порт 9000, аргументы `server /data`, PVC 2Gi) и Service `minio`, затем создай бакет клиентом `mc`. Секрет для CNPG в namespace `notes` возьми из тех же ключей:

```bash
kubectl -n notes create secret generic minio-creds \
  --from-literal=ACCESS_KEY_ID=minio \
  --from-literal=ACCESS_SECRET_KEY="$(kubectl -n minio get secret minio-creds -o jsonpath='{.data.rootPassword}' | base64 -d)"
```

5. Закоммить и запушь, дождись Flux:

```bash
git add -A && git commit -m "cnpg: оператор" && git push
flux reconcile kustomization infrastructure --with-source
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg
kubectl get crd | grep cnpg.io
```

**Что должно получиться:**

```text
deployment "cnpg-cloudnative-pg" successfully rolled out
backups.postgresql.cnpg.io                 2026-09-29T10:12:04Z
clusters.postgresql.cnpg.io                2026-09-29T10:12:04Z
poolers.postgresql.cnpg.io                 2026-09-29T10:12:04Z
scheduledbackups.postgresql.cnpg.io        2026-09-29T10:12:04Z
```

**Объясни себе:**
- Почему `install.crds: CreateReplace`, а не оставить по умолчанию?
- Почему оператор в отдельном namespace, а базы в `notes`?

**Типичные ошибки:**
- `no matches for kind "Cluster" in version "postgresql.cnpg.io/v1"`: CRD ещё не установлены, приложение применилось раньше оператора: проверь `dependsOn` из 9.3, оператор в `controllers`, кластер в `apps`.
- `Error: chart "cloudnative-pg" version "0.28.x" not found`: такой версии нет: `helm search repo cnpg/cloudnative-pg --versions` и укажи реальную.
- `pod has unbound immediate PersistentVolumeClaims`: у kind нет свободного PV на MinIO: проверь `kubectl get sc`, должен быть `standard`.

### Задание 2. Cluster с паролем из Vault

**Цель:** описать `Cluster notes-db`, пароль взять из Vault через ESO и увидеть три Service.

**Предскажи:** сколько подов появится при `instances: 2` и чем они отличаются в `kubectl get pods -L cnpg.io/instanceRole`?

<details markdown="1">
<summary>Ответ</summary>

Два: `notes-db-1` с ролью `primary` и `notes-db-2` с ролью `replica`. Также сначала появится короткоживущий Job `notes-db-1-initdb`.

</details>

**Шаги:**

1. Пароль уже лежит в Vault по пути `secret/notes/db` (урок 9.1), поле `password`. Опиши ExternalSecret, создающий Secret `notes-db-app`:

{% raw %}
```bash
cd ~/notes-gitops
cat > apps/notes/cnpg-secret.yaml <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: notes-db-app
  namespace: notes
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: notes-db-app
    template:
      type: kubernetes.io/basic-auth
      data:
        username: notes
        password: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef:
        key: secret/notes/db
        property: password
YAML
```
{% endraw %}

2. Опиши кластер:

```bash
cat > apps/notes/cnpg-cluster.yaml <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: notes-db
  namespace: notes
spec:
  # 2 инстанса: primary и реплика (в режиме 8 ГБ поставь 1)
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6
  storage:
    size: 2Gi
  bootstrap:
    initdb:
      database: notes
      owner: notes
      secret:
        name: notes-db-app
  backup:
    retentionPolicy: "7d"
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/notes-db
      endpointURL: http://minio.minio.svc:9000
      s3Credentials:
        accessKeyId:
          name: minio-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: minio-creds
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
YAML
```

3. Добавь оба файла в `apps/notes/kustomization.yaml`, закоммить, запушь и дождись:

```bash
git add -A && git commit -m "cnpg: cluster notes-db" && git push
flux reconcile kustomization apps --with-source
kubectl -n notes wait cluster/notes-db --for=condition=Ready --timeout=300s
kubectl -n notes get pods -L cnpg.io/instanceRole
kubectl -n notes get svc | grep notes-db
```

**Что должно получиться:**

```text
cluster.postgresql.cnpg.io/notes-db condition met
NAME         READY   STATUS    RESTARTS   AGE   INSTANCEROLE
notes-db-1   1/1     Running   0          2m    primary
notes-db-2   1/1     Running   0          80s   replica
notes-db-r    ClusterIP   10.96.41.7     <none>   5432/TCP   2m
notes-db-ro   ClusterIP   10.96.12.90    <none>   5432/TCP   2m
notes-db-rw   ClusterIP   10.96.201.33   <none>   5432/TCP   2m
```

**Объясни себе:**
- Почему пароля нет в git, но кластер его получает?
- Что случится, если ESO ещё не создал `notes-db-app`, а Cluster уже применился?

**Типичные ошибки:**
- `secret "notes-db-app" not found`: ExternalSecret не синхронизировался: `kubectl -n notes get externalsecret`, смотри статус и путь в Vault.
- `Error: cannot fetch secret ... permission denied`: политика `notes-read` не покрывает путь: поправь политику Vault из 9.1.
- `unable to create pod: exceeded quota` или `Pending` у `notes-db-2`: на kind не хватает памяти: режим 8 ГБ, `instances: 1`.

### Задание 3. Failover: убей primary

**Цель:** увидеть переключение и замерить, сколько записей приложение не смогло сделать.

**Предскажи:** после `kubectl delete pod notes-db-1` какой под станет primary и сменится ли адрес `notes-db-rw`?

<details markdown="1">
<summary>Ответ</summary>

Primary станет `notes-db-2`. ClusterIP сервиса `notes-db-rw` останется прежним, изменится только endpoint за ним. Удалённый `notes-db-1` вернётся как реплика.

</details>

**Шаги:**

1. В первом терминале запусти запись раз в секунду через временный под (пароль берём из Secret):

```bash
kubectl -n notes run writer --rm -it --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:18.6 \
  --env="PGPASSWORD=$(kubectl -n notes get secret notes-db-app -o jsonpath='{.data.password}' | base64 -d)" \
  --command -- bash -c 'while true; do psql -h notes-db-rw -U notes notes -tAc "select now(), pg_is_in_recovery()" 2>&1 | head -1; sleep 1; done'
```

2. Во втором удали primary и смотри роли:

```bash
kubectl -n notes delete pod notes-db-1 --wait=false
kubectl -n notes get pods -L cnpg.io/instanceRole -w
```

**Что должно получиться:** в терминале записи пара строк ошибок, потом снова успешные ответы.

```text
2026-09-29 10:31:12.4+00|f
2026-09-29 10:31:13.4+00|f
psql: error: connection to server at "notes-db-rw" (10.96.201.33), port 5432 failed: Connection refused
psql: error: connection to server at "notes-db-rw" (10.96.201.33), port 5432 failed: Connection refused
2026-09-29 10:31:21.9+00|f
```

Окно недоступности обычно от нескольких секунд до полуминуты. Это твой измеренный RTO для сбоя primary, запиши его в `docs/` для урока 10.3.

**Объясни себе:**
- Почему ошибки были, если реплика уже стояла?
- Что бы произошло, если бы приложение держало пул соединений без переподключения?

**Типичные ошибки:**
- `Error from server (NotFound): pods "notes-db-1" not found`: primary уже был `notes-db-2`: смотри `-L cnpg.io/instanceRole` и удаляй того, у кого `primary`.
- `FATAL: the database system is not yet accepting connections`: соединился с только что поднявшимся инстансом: подожди и проверь `kubectl cnpg status notes-db -n notes`.

### Задание 4. Бэкап и восстановление в новый Cluster

**Цель:** снять бэкап в MinIO и поднять из него отдельный кластер.

**Предскажи:** можно ли восстановить в кластер с тем же именем `notes-db`, пока старый жив?

<details markdown="1">
<summary>Ответ</summary>

Нет: имена конфликтуют, поды и PVC уже существуют. Восстанавливаем в новый `Cluster` с другим именем, например `notes-db-restore`, проверяем данные и потом решаем, что с ним делать.

</details>

**Шаги:**

1. Расписание и ручной бэкап:

```bash
cat > apps/notes/cnpg-backup.yaml <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: notes-db-daily
  namespace: notes
spec:
  # формат с секундами: каждый день в 03:00
  schedule: "0 0 3 * * *"
  cluster:
    name: notes-db
  backupOwnerReference: self
YAML
kubectl -n notes apply -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: notes-db-manual
  namespace: notes
spec:
  cluster:
    name: notes-db
YAML
kubectl -n notes get backup -w
```

2. Когда `PHASE` станет `completed`, создай кластер для проверки (не коммить, это временный эксперимент):

```bash
kubectl -n notes apply -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: notes-db-restore
  namespace: notes
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6
  storage:
    size: 2Gi
  bootstrap:
    recovery:
      source: notes-db
  externalClusters:
    - name: notes-db
      barmanObjectStore:
        destinationPath: s3://cnpg-backups/notes-db
        endpointURL: http://minio.minio.svc:9000
        s3Credentials:
          accessKeyId:
            name: minio-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: minio-creds
            key: ACCESS_SECRET_KEY
YAML
kubectl -n notes wait cluster/notes-db-restore --for=condition=Ready --timeout=300s
kubectl -n notes exec notes-db-restore-1 -c postgres -- psql -U postgres notes -tAc "select count(*) from notes"
```

3. Убери эксперимент: `kubectl -n notes delete cluster notes-db-restore`.

**Что должно получиться:**

```text
NAME              AGE   CLUSTER    METHOD              PHASE       ERROR
notes-db-manual   40s   notes-db   barmanObjectStore   completed
cluster.postgresql.cnpg.io/notes-db-restore condition met
3
```

Число строк равно числу заметок на момент бэкапа. Полноценный учебный restore drill с замером RTO проводится один раз в [уроке 10.3](../10-capstone/03-backup-dr-capacity.md), здесь только механика.

**Объясни себе:**
- Чем `Backup` отличается от `ScheduledBackup`?
- Почему бэкап в MinIO внутри того же kind защищает только от логических ошибок, а не от потери машины?

**Типичные ошибки:**
- `Error: The specified bucket does not exist`: бакет `cnpg-backups` не создан в MinIO: создай через `mc mb`.
- `PHASE failed ... Access Denied`: неверные ключи в `minio-creds` namespace `notes`: сверь с секретом в `minio`.
- `WAL archiving failed` в `kubectl cnpg status`: неверный `endpointURL` (нужен `http://`, не `https://`, без TLS в MinIO): исправь адрес.

### Задание 5. Шаг проекта: «Заметки» переезжают на CNPG

**Цель:** перенести данные из StatefulSet `postgres`, переключить приложение на `notes-db-rw` и удалить старое.

**Предскажи:** что произойдёт с приложением, если сначала удалить StatefulSet, а потом делать дамп?

<details markdown="1">
<summary>Ответ</summary>

Дамп сделать будет не из чего, если удалён и PVC (у StatefulSet PVC остаётся, но проще ошибиться). Порядок всегда: дамп, восстановление, проверка, переключение, и только потом удаление старого.

</details>

**Шаги:**

1. Дамп из старой БД и заливка в новую (`postgres-0` из урока 5.5):

```bash
kubectl -n notes exec postgres-0 -- pg_dump -U notes --no-owner notes > /tmp/notes-dump.sql
kubectl -n notes exec -i notes-db-1 -c postgres -- psql -U postgres notes < /tmp/notes-dump.sql
kubectl -n notes exec notes-db-1 -c postgres -- psql -U postgres notes -tAc "select count(*) from notes"
```

2. Приложение читает `DATABASE_URL` из Secret `notes-db` (создаётся ExternalSecret из 9.2). Поменяй хост на `notes-db-rw` в шаблоне, откуда он собирается (`apps/notes/externalsecret.yaml`), значение станет `postgresql://notes:<пароль>@notes-db-rw.notes.svc:5432/notes`. Закоммить и запушь, приложение перечитает Secret после рестарта:

```bash
git add -A && git commit -m "notes: БД на CNPG (notes-db-rw)" && git push
flux reconcile kustomization apps --with-source
kubectl -n notes rollout restart deploy/notes
kubectl -n notes rollout status deploy/notes
curl -s --cacert ca.crt https://notes.lab/notes
```

3. Убедись, что заметки на месте, и только потом удали старое из git (`apps/notes/`: файлы StatefulSet `postgres`, Service `db`, CronJob `pg-backup`, PVC `pg-backups`), закоммить и запушь. Flux с `prune: true` удалит объекты. PVC `data-postgres-0` удали вручную после проверки: `kubectl -n notes delete pvc data-postgres-0`.
4. Сохрани `/tmp/notes-dump.sql` как последнюю страховку до конца урока, потом удали файл.

**Что должно получиться:**

```text
3
deployment "notes" successfully rolled out
[{"id":1,"text":"первая","created_at":"2026-09-29T09:01:11Z"},{"id":2,"text":"вторая","created_at":"2026-09-29T09:02:03Z"},{"id":3,"text":"третья","created_at":"2026-09-29T09:02:40Z"}]
```

Проверь, что старого нет:

```bash
kubectl -n notes get sts,cronjob
```

```text
No resources found in notes namespace.
```

Состояние проекта: версия 0.7.0, Cluster `notes-db`, Service `notes-db-rw`, бэкапы в MinIO. Долг: MinIO без репликации.

**Объясни себе:**
- Почему `pg_dump` с `--no-owner`?
- Как убедиться, что в новой БД не меньше строк, чем в старой?

**Типичные ошибки:**
- `psql: error: connection to server ... FATAL: password authentication failed for user "notes"`: в Vault и в `notes-db-app` разные пароли, либо в `DATABASE_URL` остался старый: сравни `kubectl get secret` обоих и обнови из Vault.
- `ERROR: role "notes" does not exist` при заливке: дамп без `--no-owner` ссылается на роль, которой нет: сделай дамп заново с флагом.
- `pg_dump: error: connection to server on socket ... failed`: пода `postgres-0` нет, StatefulSet уже удалён: восстанови из последнего `pg-backup` (PVC `pg-backups`) или из `/tmp/notes-dump.sql`.

## Сломай и почини

Запусти один из сценариев (не читай скрипт, там подсказки):

```bash
project/notes/break/9.5/break.sh random
```

Сценарии: 1 запись в реплику, 2 бэкап падает, 3 primary удалён и не возвращается. Диагностируй и почини через git (Flux откатит ручные правки), не через `kubectl edit`.

### Симптом

Приложение отвечает 500 на `POST /notes`, в логах `cannot execute INSERT in a read-only transaction`, либо `kubectl get backup` показывает `failed`, либо в `kubectl get pods` один из подов `notes-db` не в `Running`.

### Гипотезы

- Приложение ходит в `notes-db-ro` или в имя реплики, а не в `-rw`.
- Бэкап: неверный endpoint, ключи или нет бакета.
- Primary недоступен: под не стартует, PVC потерян, нет места, отсутствует реплика для повышения.

### Проверки

```bash
kubectl cnpg status notes-db -n notes
kubectl -n notes get cluster notes-db -o wide
kubectl -n notes describe backup <имя>
kubectl -n notes logs deploy/notes --tail=20
kubectl -n notes get endpoints notes-db-rw
```

Подумай, какая проверка сужает поиск быстрее всего.

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

1. Запись в реплику: `DATABASE_URL` указывает на `notes-db-ro` или `notes-db-2`. Проверь `psql -c "select pg_is_in_recovery()"` через этот хост, `t` значит реплика. Исправь хост на `notes-db-rw` в `externalsecret.yaml`, закоммить, перезапусти Deployment.
2. Бэкап `failed`: `kubectl describe backup` и логи пода primary в контейнере `postgres` покажут `Access Denied` или `bucket does not exist`. Поправь `endpointURL` или ключи в `minio-creds`, создай бакет, запусти новый `Backup`. Убедись, что WAL идёт: `kubectl cnpg status` без `Not working` в блоке WAL archiving.
3. Primary удалён и не возвращается: если есть реплика, оператор повысит её сам, дождись; если реплики нет (`instances: 1`), нужен restore из бэкапа. Смотри события `kubectl -n notes get events --sort-by=.lastTimestamp`. Профилактика: `instances` не меньше 2 и рабочий бэкап.

</details>

## Вопросы с собеседований

### 1. [junior] Что такое оператор в Kubernetes и чем он отличается от Helm-чарта?

Оператор это CRD плюс контроллер, который постоянно сверяет желаемое состояние с фактическим и знает, как эксплуатировать конкретную систему. Helm один раз рисует манифесты. Оператор реагирует на события: упал primary, пора сделать бэкап, надо обновить версию.

**Что хотят услышать:** reconcile loop, CRD, эксплуатационные знания в коде, пример (CNPG, cert-manager, Prometheus Operator).

**Красный флаг:** «это такой продвинутый Helm» или «это про установку».

### 2. [middle] Прод: приложение пишет в БД, primary в CNPG умер. Что происходит и что ты делаешь?

Оператор обнаруживает потерю primary, повышает реплику с наименьшим отставанием и переключает Service `-rw`. Я смотрю `kubectl cnpg status`, роли подов, endpoints `-rw`, и что приложение переподключается. Если реплики не было, иду в восстановление из бэкапа.

**Что хотят услышать:** Service `-rw`, окно недоступности, переподключение пула, асинхронная репликация и возможная потеря последних транзакций, проверка после.

**Красный флаг:** «зайду в под и вручную сделаю pg_promote» без проверки состояния оператора.

### 3. [middle] Как в CNPG устроены бэкапы и восстановление на момент времени?

Base backup плюс непрерывная архивация WAL в объектное хранилище. Для PITR создаётся новый Cluster с `bootstrap.recovery` и `recoveryTarget.targetTime`. Восстанавливаем в новое имя, проверяем и переключаем приложение.

**Что хотят услышать:** Barman, WAL, `ScheduledBackup`, восстановление в новый кластер, проверка бэкапов (restore drill).

**Красный флаг:** «делаю pg_dump раз в сутки» как единственный вариант, или бэкапы в том же кластере и не проверены.

### 4. [junior] Через какой Service приложение должно подключаться к CNPG и почему?

К `notes-db-rw`: он всегда указывает на текущий primary. `-ro` ведёт на реплики, поэтому запись там завершится ошибкой read-only. Имена подов использовать нельзя, primary переезжает.

**Что хотят услышать:** три сервиса, назначение каждого, отличие от имени пода.

**Красный флаг:** «хожу на IP пода» или «на любой сервис, они одинаковые».

### 5. [middle] Приложение в 500, в логах «cannot execute INSERT in a read-only transaction». Твои действия?

Это запись в реплику. Проверяю, на какой хост смотрит `DATABASE_URL`, и `select pg_is_in_recovery()` через него. Возможно, недавно был failover, а клиент держит старое соединение с бывшим primary, ставшим репликой. Исправляю хост на `-rw` или перезапускаю приложение, чтобы пул переподключился.

**Что хотят услышать:** `pg_is_in_recovery`, связь с failover, пулы соединений, таймауты и retry.

**Красный флаг:** «перезагружу базу», не разобравшись.

### 6. [middle] Стоит ли держать PostgreSQL в Kubernetes?

Зависит от команды и требований. Плюсы: единый подход, GitOps, автоматизация. Минусы: своя эксплуатация хранилища, апгрейдов и бэкапов, зависимость от качества CSI и сети. Если нет людей на эксплуатацию БД, надёжнее управляемый сервис. С оператором и проверенными бэкапами вариант рабочий.

**Что хотят услышать:** взвешенный ответ с критериями (SLA, команда, стоимость, данные), не догма, упоминание управляемых сервисов.

**Красный флаг:** категоричное «никогда» или «всегда» без аргументов.

### 7. [middle] Нужно поднять новую версию PostgreSQL в CNPG с минимальным простоем. Как?

Минорное обновление: меняю `imageName`, оператор делает rolling update: сначала реплики, потом switchover primary. Для мажорного апгрейда нужен отдельный план (импорт в новый кластер или поддерживаемый in-place механизм), делаю сначала на копии из бэкапа. Перед этим свежий бэкап.

**Что хотят услышать:** rolling по репликам, switchover, свежий бэкап, репетиция на копии, различие минорных и мажорных версий.

**Красный флаг:** «просто поменяю тег и посмотрю».

### 8. [middle] Пароль БД в Vault сменили, а приложение не может подключиться. Что не так и как правильно менять пароль?

Смена в Vault не меняет пароль роли в самой PostgreSQL: ESO обновит Secret, но пользователь `notes` в БД остался со старым. Нужно синхронно сменить и роль (`ALTER ROLE` или через управление ролями оператора), и Secret, и перезапустить приложение. Проверяю `refreshInterval` ESO и статус `ExternalSecret`.

**Что хотят услышать:** источник правды один, порядок смены, ESO обновляет Secret, но не БД, перечитывание в приложении.

**Красный флаг:** «сменил в Vault, значит всё обновится».

### 9. [middle] Диск primary заполняется WAL, что делать?

Смотрю, не застрял ли архив WAL (`kubectl cnpg status`, метрики), не отвалился ли MinIO или ключи: пока архив не работает, WAL копятся на диске. Чиню архивацию, WAL уйдёт и очистится. Срочно: расширяю PVC (`storage.size`, если класс позволяет), но причину чиню всегда.

**Что хотят услышать:** связь архива WAL и диска, `kubectl cnpg status`, расширение тома, алерты на место и на возраст архивации.

**Красный флаг:** «удалю файлы WAL из pg_wal руками».

### 10. [middle] Прод отвечает 502 после failover в БД. Как разбираешься?

Иду по цепочке: логи приложения, endpoints `notes-db-rw`, роли подов, readiness-пробы. Частая причина: пул не переподключился или проба `readyz` зависит от БД и поды выпали из Service. Смотрю время сбоя, перезапускаю проблемные поды, потом чиню переподключение и таймауты.

**Что хотят услышать:** цепочка проверок, readiness, поведение пула, метрики и логи вместо догадок.

**Красный флаг:** «увеличу реплики nginx».

## Проверено на версиях

- CloudNativePG: v1.30.1
- PostgreSQL: 18.6
- Flux: v2.9.5
- External Secrets Operator: v2.11.0
- Vault: v2.1.1
- MinIO: версия не закреплена, проверь актуальную версию на странице проекта
- Версия Helm-чарта `cloudnative-pg`: проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею объяснить, чем оператор отличается от Helm-чарта
- [ ] умею установить CloudNativePG через `HelmRelease` и увидеть его CRD
- [ ] умею описать `Cluster` с паролем из Vault через ESO
- [ ] умею назвать, какой Service для записи, а какой для чтения
- [ ] умею вызвать failover и замерить окно недоступности
- [ ] умею настроить `ScheduledBackup` в S3-совместимое хранилище и восстановить в новый Cluster
- [ ] умею перенести данные `pg_dump` и `psql` и удалить старый StatefulSet
- [ ] умею диагностировать запись в реплику и упавший бэкап

**Дальше:** [Урок 9.6: прогрессивная доставка](06-progressive-delivery.md)
