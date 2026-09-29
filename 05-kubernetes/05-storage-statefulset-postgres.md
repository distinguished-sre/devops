---
layout: lesson
title: "Хранилище и StatefulSet: PostgreSQL в кластере"
topic: 5
lesson: "5.5"
time: "2 ч"
---

## Зачем это нужно

Поды в Kubernetes одноразовые: убил, создался новый, с пустой файловой системой. В уроке 5.2 «Заметки» писали в `emptyDir`, и данные пропадали вместе с подом. Для базы данных это неприемлемо: ей нужен диск, который переживает под, и стабильное имя, чтобы клиенты всегда находили её на месте.

На работе это первый вопрос к любому стейтфул-сервису в кластере: где живут данные, кто их создаёт, что будет при удалении пода, StatefulSet или всего namespace. Ошибка здесь стоит потери данных, а не просто рестарта.

Шаг проекта: в `k8s/base/40-postgres.yaml` появляются StatefulSet `postgres` (`postgres:18`), headless Service `db` и PVC на 1 ГиБ; Secret `notes-db` с паролем создан командой и в git не попадает. База доступна по адресу `db.notes.svc:5432`.

## Что нужно знать

- [Урок 4.3: тома и сети Docker](../04-docker/03-storage-networks.md) - идея тома, который живёт отдельно от контейнера
- [Урок 4.4: SQL и PostgreSQL](../04-docker/04-sql-postgres-basics.md) - `psql`, таблица `notes`
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - переменные `POSTGRES_*`, инициализация базы
- [Урок 5.2: Поды и Deployment](02-pods-deployments.md) - почему под одноразовый, `emptyDir`
- [Урок 5.3: Service и DNS кластера](03-services-dns.md) - Service, endpoints, DNS-имена `<svc>.<ns>.svc`

## Теория

### Диск в Kubernetes: PV, PVC, StorageClass

Приложение не просит у кластера конкретный диск. Оно оформляет заявку, а кластер находит или создаёт подходящий том.

- **PersistentVolume, PV** (постоянный том): кусок хранилища в кластере. Это ресурс кластера, без namespace.
- **PersistentVolumeClaim, PVC** (заявка на том): «мне нужен 1 ГиБ, чтение и запись с одного узла». Живёт в namespace, монтируется в под по имени.
- **StorageClass** (класс хранилища): рецепт, как создавать PV по заявке. Внутри указан провайдер (provisioner), политика удаления и режим привязки.

В kind по умолчанию есть StorageClass `standard` (провайдер local-path от Rancher): том создаётся как каталог на диске узла. Два свойства класса важны на практике. `reclaimPolicy: Delete` значит, что при удалении PVC удаляется и PV вместе с данными (в облаках продовые классы часто ставят `Retain`). `volumeBindingMode: WaitForFirstConsumer` значит, что том создаётся только когда появился под, который его использует, поэтому пустой PVC долго висит в `Pending`, и это нормально.

Режимы доступа (accessModes): `ReadWriteOnce` (RWO) монтируется на запись одним узлом, `ReadWriteMany` (RWX) несколькими. База почти всегда на RWO. Локальные диски узла живут только на этом узле: если узел умер, том недоступен. Поэтому в облаках диски сетевые (EBS, Yandex Network SSD), их CSI-драйвер (Container Storage Interface, единый интерфейс подключения хранилищ) отвязывает том от одного узла и привязывает к другому.

> **Проверь понимание:** PVC создан, а `kubectl get pvc` показывает `Pending` и под ещё не запущен. Это поломка?

<details>
<summary>Ответ</summary>

Не обязательно. При `WaitForFirstConsumer` том создаётся только после появления пода. Смотри `kubectl describe pvc`: событие `waiting for first consumer to be created before binding` штатное. Поломка, если под уже есть, а PVC всё ещё `Pending`: тогда ищи неверный `storageClassName` или нехватку места.

</details>

### Почему база не Deployment

Deployment создаёт взаимозаменяемые поды со случайными именами вроде `notes-6d9c-x4kq`. Для базы это плохо по трём причинам:

1. Реплики делят один PVC (если он вообще подключился), а две копии PostgreSQL на одном каталоге портят данные.
2. Имя и адрес нового пода случайные, и клиентам не за что зацепиться.
3. При обновлении Deployment сначала поднимает нового, потом убивает старого: два процесса на одном диске недопустимы.

**StatefulSet** решает это. Поды называются `postgres-0`, `postgres-1`: индекс постоянный. Для каждой реплики из шаблона `volumeClaimTemplates` создаётся собственный PVC `<шаблон>-<под>`, например `data-postgres-0`. Если под пересоздать, он получит тот же PVC и то же имя. Поды запускаются и останавливаются по порядку, а обновляются в обратном (от большего индекса к меньшему).

Важное свойство: StatefulSet **не удаляет PVC** при своём удалении или уменьшении числа реплик (`persistentVolumeClaimRetentionPolicy` по умолчанию `Retain`). Данные защищены от случайного `delete statefulset`, но не от `delete pvc` и не от удаления namespace.

> **Проверь понимание:** ты удалил под `postgres-0` командой `kubectl delete pod`. Что произойдёт с данными и с именем нового пода?

<details>
<summary>Ответ</summary>

StatefulSet-контроллер создаст под с тем же именем `postgres-0` и подключит тот же PVC `data-postgres-0`. Данные на месте, база стартует с существующего каталога (сработает восстановление после аварийного останова, crash recovery). Клиенты по имени найдут её снова.

</details>

### Headless Service и стабильное имя

Обычный ClusterIP-сервис даёт один виртуальный адрес и балансирует запросы. У StatefulSet нужен **headless Service** (`clusterIP: None`): у него нет виртуального адреса, а DNS возвращает адреса самих подов. Каждый под получает имя `postgres-0.db.notes.svc.cluster.local` (под, сервис, namespace). Поле `serviceName` в StatefulSet указывает, какой сервис отвечает за эти имена.

Для клиента с одной репликой удобнее короткое `db.notes.svc`: оно резолвится в адрес единственного пода. Когда появится реплика, приложению придётся различать primary и replica: именно этим занимаются операторы БД (CloudNativePG, обзор в [уроке 9.5](../09-secrets-gitops/05-cnpg.md)).

> **Проверь понимание:** зачем StatefulSet нужен headless Service, если можно было бы использовать обычный ClusterIP?

<details>
<summary>Ответ</summary>

Обычный сервис балансирует запросы между подами и скрывает, какой именно ответил. Для базы нужно обращаться к конкретной реплике (записывать в primary, читать с replica), а значит нужен DNS-адрес каждого пода отдельно. Headless Service даёт такие имена.

</details>

### PostgreSQL 18 и каталог данных

Образ `postgres:18` хранит данные в подкаталоге версии: `/var/lib/postgresql/18/docker`, а объявленный `VOLUME` стоит на `/var/lib/postgresql` (в образах до 17 том был на `/var/lib/postgresql/data`). Поэтому том мы монтируем в `/var/lib/postgresql`, и переменная `PGDATA` не нужна. Если смонтировать том в `/var/lib/postgresql/data`, база запустится, но данные окажутся вне тома и пропадут вместе с подом, а образ напечатает предупреждение о несовпадении каталога.

Отдельно про пароль. Образ читает `POSTGRES_PASSWORD` **только при первой инициализации пустого каталога**. Если данные уже есть, смена пароля в Secret ничего не меняет внутри базы. Это источник самой частой ошибки `password authentication failed`, её мы разберём в «Сломай и почини».

> **Проверь понимание:** ты поменял значение в Secret `notes-db` и перезапустил под. Поменяется ли пароль пользователя `notes` в базе?

<details>
<summary>Ответ</summary>

Нет. Переменная нужна только при создании кластера баз (initdb) в пустом каталоге. Пароль в существующей базе меняется командой `ALTER USER notes PASSWORD '...'`, а Secret надо привести в соответствие.

</details>

## Практика

Кластер kind `notes` из урока 5.1 должен быть запущен, namespace `notes` создан. Проверь:

```bash
kubectl config current-context
kubectl -n notes get deploy,svc
```

```text
kind-notes
NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/notes   3/3     3            3           2d

NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/notes   ClusterIP   10.96.41.207   <none>        8080/TCP   2d
```

Работать будем из `~/notes` (каталог `k8s/base/` уже есть).

### Задание 1. Secret и StatefulSet с PostgreSQL

**Цель:** запустить PostgreSQL 18 в кластере с постоянным томом и паролем из Secret.

Сначала создай Secret командой, пароль генерируется и нигде не сохраняется в файлах:

```bash
kubectl -n notes create secret generic notes-db \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 24)"
kubectl -n notes get secret notes-db
```

```text
secret/notes-db created
NAME       TYPE     DATA   AGE
notes-db   Opaque   1      1s
```

Используем `-hex`, а не `-base64`: в шестнадцатеричной строке нет символов `/`, `+`, `=`, которые в уроке 5.6 пришлось бы экранировать в `DATABASE_URL`.

Создай файл `k8s/base/40-postgres.yaml`:

```yaml
# Headless Service: даёт стабильные DNS-имена подам StatefulSet
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: notes
  labels:
    app.kubernetes.io/name: postgres
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: notes
  labels:
    app.kubernetes.io/name: postgres
spec:
  serviceName: db
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:18
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: notes
            - name: POSTGRES_USER
              value: notes
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: notes-db
                  key: POSTGRES_PASSWORD
          volumeMounts:
            # В postgres:18 данные лежат в /var/lib/postgresql/18/docker, PGDATA не нужен
            - name: data
              mountPath: /var/lib/postgresql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**Предскажи:** как будет называться PVC, который создаст StatefulSet, и в каком статусе он окажется сразу после `apply`, пока под не запущен?

<details>
<summary>Ответ</summary>

PVC `data-postgres-0` (шаблон `data` + имя пода), сначала `Pending` (режим `WaitForFirstConsumer`), после запуска пода `Bound`.

</details>

**Шаги:**

1. Проверь и примени:

```bash
kubectl apply -f k8s/base/40-postgres.yaml --dry-run=server
kubectl apply -f k8s/base/40-postgres.yaml
kubectl -n notes wait --for=condition=Ready pod/postgres-0 --timeout=180s
kubectl -n notes get statefulset,pod,pvc,svc -l app.kubernetes.io/name=postgres
kubectl -n notes get pvc
```

2. Убедись, что база отвечает:

```bash
kubectl -n notes exec postgres-0 -- pg_isready -U notes -d notes
kubectl -n notes logs postgres-0 | tail -3
```

**Что должно получиться:**

```text
NAME                        READY   AGE
statefulset.apps/postgres   1/1     40s

NAME             READY   STATUS    RESTARTS   AGE
pod/postgres-0   1/1     Running   0          40s

NAME          TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
service/db    ClusterIP   None         <none>        5432/TCP   40s

NAME                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-postgres-0         Bound    pvc-8b1a0e0d-42a3-4a7c-b6b1-5a0c3c9e2f41   1Gi        RWO            standard       40s

/var/run/postgresql:5432 - accepting connections
...
LOG:  database system is ready to accept connections
```

**Объясни себе:**

- Чем `CLUSTER-IP: None` у сервиса `db` отличается от адреса у сервиса `notes`?
- Откуда взялся PVC, если мы его нигде не описывали отдельным объектом?
- Почему пароль не лежит в YAML и не попадёт в git?

**Типичные ошибки:**

- `Error: secret "notes-db" not found` (статус пода `CreateContainerConfigError`): Secret не создан в namespace `notes`; создай командой выше и подожди, под перезапустится сам.
- `Error: Database is uninitialized and superuser password is not specified`: переменная `POSTGRES_PASSWORD` пуста; проверь ключ в Secret командой `kubectl -n notes get secret notes-db -o jsonpath='{.data}'`.
- `initdb: error: directory "/var/lib/postgresql/data" exists but is not empty`: тома с чужими данными; смонтируй том в `/var/lib/postgresql`, как в манифесте.

### Задание 2. Подключиться к базе по DNS

**Цель:** проверить, что имена `db.notes.svc` и `postgres-0.db` резолвятся, и создать таблицу `notes` по контракту курса.

**Предскажи:** какой IP вернёт DNS для имени `db.notes.svc`: виртуальный ClusterIP или адрес пода?

<details>
<summary>Ответ</summary>

Адрес пода из диапазона podCIDR, например 10.244.2.7. У headless Service виртуального адреса нет, DNS отдаёт адреса endpoints.

</details>

**Шаги:**

1. Резолвинг из временного пода:

```bash
kubectl -n notes run dnscheck --rm -it --restart=Never --image=busybox:1.37 -- \
  nslookup db.notes.svc.cluster.local
kubectl -n notes get pod postgres-0 -o wide
```

2. Создай таблицу и запиши строку через `psql` внутри пода (пароль берётся из окружения контейнера):

```bash
kubectl -n notes exec -i postgres-0 -- psql -U notes -d notes <<'SQL'
CREATE TABLE IF NOT EXISTS notes (
  id serial PRIMARY KEY,
  text text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO notes (text) VALUES ('первая заметка в кластере');
SELECT id, text FROM notes;
SQL
```

**Что должно получиться:**

```text
Name:	db.notes.svc.cluster.local
Address: 10.244.2.7

NAME         READY   STATUS    RESTARTS   AGE   IP           NODE
postgres-0   1/1     Running   0          3m    10.244.2.7   notes-worker2
...
CREATE TABLE
INSERT 0 1
 id |           text
----+---------------------------
  1 | первая заметка в кластере
(1 row)
```

**Объясни себе:**

- Совпал ли адрес из DNS с IP пода `postgres-0`? Почему?
- Почему `psql` внутри пода не спросил пароль?
- Что произойдёт с таблицей при удалении пода?

**Типичные ошибки:**

- `psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory`: сервер ещё стартует или упал; смотри `kubectl -n notes logs postgres-0`.
- `psql: error: connection to server ... failed: FATAL:  role "postgres" does not exist`: забыт ключ `-U notes`, суперпользователь в нашей базе называется `notes`.
- `nslookup: can't resolve 'db.notes.svc.cluster.local'`: неверный namespace или имя сервиса, проверь `kubectl -n notes get svc db`.

### Задание 3. Удалить под, потом попробовать удалить всё

**Цель:** отличить, что данные защищены (под, StatefulSet), а что нет (PVC, namespace).

**Предскажи:** после `delete pod`, после `delete statefulset` и после `delete pvc` в каких случаях строка про «первую заметку» останется?

<details>
<summary>Ответ</summary>

После `delete pod` останется (тот же PVC). После `delete statefulset` тоже (PVC остаётся, при новом `apply` подхватится). После `delete pvc` пропадёт: политика класса `Delete` удаляет PV и каталог.

</details>

**Шаги:**

1. Удали под и проверь данные:

```bash
kubectl -n notes delete pod postgres-0
kubectl -n notes wait --for=condition=Ready pod/postgres-0 --timeout=180s
kubectl -n notes exec postgres-0 -- psql -U notes -d notes -c 'SELECT id, text FROM notes;'
```

2. Удали StatefulSet, посмотри на PVC, верни обратно:

```bash
kubectl -n notes delete statefulset postgres
kubectl -n notes get pvc
kubectl apply -f k8s/base/40-postgres.yaml
kubectl -n notes wait --for=condition=Ready pod/postgres-0 --timeout=180s
kubectl -n notes exec postgres-0 -- psql -U notes -d notes -c 'SELECT count(*) FROM notes;'
```

3. Сделай логический бэкап на хост (команда `pg_dump`, разбор бэкапов по расписанию будет в уроке 5.8):

```bash
kubectl -n notes exec postgres-0 -- pg_dump -U notes -d notes > notes-backup.sql
wc -l notes-backup.sql
grep -c 'первая заметка' notes-backup.sql
rm notes-backup.sql
```

**Что должно получиться:**

```text
pod "postgres-0" deleted
...
 id |           text
----+---------------------------
  1 | первая заметка в кластере
(1 row)

statefulset.apps "postgres" deleted
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-postgres-0   Bound    pvc-8b1a0e0d-42a3-4a7c-b6b1-5a0c3c9e2f41   1Gi        RWO            standard       9m
...
 count
-------
     1
(1 row)

48 notes-backup.sql
1
```

**Объясни себе:**

- Почему PVC пережил удаление StatefulSet и это осознанное решение разработчиков?
- Чем `pg_dump` в файл отличается от копии каталога тома и почему для бэкапа он надёжнее?
- Что теряется, если бэкап лежит в том же кластере и на том же узле, что и база?

**Типичные ошибки:**

- `Error from server (NotFound): pods "postgres-0" not found`: `wait` вызван до того, как контроллер создал под; повтори через пару секунд.
- `pg_dump: error: connection to server on socket ... failed: FATAL:  role "postgres" does not exist`: не указан `-U notes`.
- В `notes-backup.sql` первая строка `error: ...`: бэкап пишут в stdout, поэтому не добавляй `-it` (tty портит вывод).

### Задание 4. Шаг проекта: Postgres в `k8s/base/`

**Цель:** зафиксировать состояние проекта: манифест в git, Secret вне git, адрес `db.notes.svc:5432` проверен снаружи пода `notes`.

**Предскажи:** сможет ли под `notes` из Deployment достучаться до `db.notes.svc:5432`, если приложение пока не настроено на Postgres?

<details>
<summary>Ответ</summary>

Сеть да (Service работает), но приложение всё ещё в режиме `STORE=file` и базу не использует. Переключение делаем в уроке 5.6 через ConfigMap.

</details>

**Шаги:**

1. Проверь манифест целиком и то, что в репозитории нет пароля:

```bash
cd ~/notes
kubectl apply -f k8s/base/40-postgres.yaml --dry-run=server
grep -rn 'POSTGRES_PASSWORD' k8s/ | grep -v secretKeyRef
git status --short k8s/
```

2. Проверь доступность порта из пода приложения (у образа `notes` есть `python`):

```bash
POD=$(kubectl -n notes get pod -l app.kubernetes.io/name=notes -o jsonpath='{.items[0].metadata.name}')
kubectl -n notes exec "$POD" -- python -c \
  "import socket; s=socket.create_connection(('db.notes.svc', 5432), 3); print('порт 5432 открыт')"
```

3. Зафиксируй:

```bash
git add k8s/base/40-postgres.yaml
git commit -m "k8s: PostgreSQL StatefulSet, headless Service db и PVC 1Gi"
```

**Что должно получиться:**

```text
service/db unchanged
statefulset.apps/postgres unchanged (server dry run)
```

Команда `grep` ничего не выводит (пароля в файлах нет), `git status` показывает `?? k8s/base/40-postgres.yaml`, а проверка порта печатает:

```text
порт 5432 открыт
```

Состояние проекта после урока: StatefulSet `postgres`, PVC 1 ГиБ, Service `db`, Secret `notes-db` создан командой. Приложение по-прежнему в режиме `STORE=file`. Эталон: [k8s/base/40-postgres.yaml](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/base/40-postgres.yaml).

**Объясни себе:**

- Почему Secret не в git и что из этого следует для нового кластера (долг: закроется в уроке 9.2)?
- Какой адрес будет в `DATABASE_URL` в следующем уроке?
- Что нужно сделать перед `kind delete cluster`, если данные из базы нужны?

**Типичные ошибки:**

- `error: unable to upgrade connection: container not found ("notes")`: под только что пересоздан, выбери другой командой `kubectl -n notes get pods`.
- `socket.gaierror: [Errno -2] Name or service not known`: сервис `db` не создан или в другом namespace.
- `fatal: not a git repository`: команда запущена не из `~/notes`.

## Сломай и почини

Запусти один из сценариев (скрипт не читай, диагностируй по симптомам). Для случайного используй `random`:

```bash
bash project/notes/break/5.5/break.sh random
```

Или выбери номер `1`, `2` или `3`. После каждого сценария приведи кластер в исходное состояние, как описано в исправлении.

### Симптом

Тебе дали три жалобы:

1. Под `postgres-0` не запускается, `kubectl get pod` показывает `Pending` уже пять минут.
2. Кто-то «почистил лишнее», и таблица `notes` в базе пуста, хотя под живой.
3. Под `postgres-0` в `CrashLoopBackOff`, а в логах приложения, которое подключается к базе, `password authentication failed`.

### Гипотезы

Для каждой жалобы запиши хотя бы по две версии до того, как что-то менять. Например: для первой (нет подходящего StorageClass, нет места на узле, PVC привязан к другому узлу), для второй (пересоздали PVC, пересоздали namespace, том другого пода), для третьей (пароль в Secret не совпадает с паролем в базе, неверный ключ в Secret, старый том с другим паролем).

### Проверки

```bash
kubectl -n notes describe pod postgres-0 | sed -n '/Events/,$p'
kubectl -n notes describe pvc data-postgres-0 | sed -n '/Events/,$p'
kubectl get sc,pv
kubectl -n notes logs postgres-0 --tail=20
kubectl -n notes get secret notes-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | wc -c
kubectl -n notes get pvc -o wide
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**Сценарий 1: PVC `Pending`.** В `describe pvc` событие:

```text
Warning  ProvisioningFailed  persistentvolumeclaim/data-postgres-0  storageclass.storage.k8s.io "fast-ssd" not found
```

Причина: в `volumeClaimTemplates` указан несуществующий `storageClassName`. Важно: поле `volumeClaimTemplates` у StatefulSet менять нельзя (`Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy' ... are forbidden`). Правильный путь: удалить StatefulSet (данных ещё нет), удалить зависший PVC, поправить манифест и применить заново.

```bash
kubectl -n notes delete statefulset postgres
kubectl -n notes delete pvc data-postgres-0
kubectl apply -f k8s/base/40-postgres.yaml
```

**Сценарий 2: потеря данных.** Таблица пуста, потому что PVC (или весь namespace) был удалён, а StatefulSet создал новый пустой том. Признак: у PVC свежий `AGE`, а у пода старый. Вернуть данные из тома нельзя: класс `standard` имеет `reclaimPolicy: Delete`. Остаётся бэкап: `psql < notes-backup.sql`. Профилактика: бэкапы вне кластера (урок 5.8), для продовых классов `Retain`, права на `delete pvc` только у админов, защита namespace.

```bash
kubectl -n notes exec -i postgres-0 -- psql -U notes -d notes < notes-backup.sql
```

**Сценарий 3: `password authentication failed`.** В логах:

```text
FATAL:  password authentication failed for user "notes"
```

Причина: Secret `notes-db` пересоздали с новым паролем, а том хранит базу, инициализированную со старым. Пароль читается только при первом `initdb`. Если ключ Secret назван иначе, чем `POSTGRES_PASSWORD`, под не стартует вовсе (`CreateContainerConfigError`). Лечение без потери данных: привести Secret к старому паролю или сменить пароль в базе изнутри пода (`local` подключение по сокету доверенное):

```bash
NEWPASS=$(kubectl -n notes get secret notes-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
kubectl -n notes exec -i postgres-0 -- psql -U notes -d notes \
  -c "ALTER USER notes PASSWORD '$NEWPASS';"
```

Если данных нет и не жалко, можно удалить StatefulSet и PVC: база проинициализируется заново с текущим паролем. В проде так делать нельзя.

</details>

## Вопросы с собеседований

### 1. [junior] В чём разница между Deployment и StatefulSet?

Deployment создаёт взаимозаменяемые поды со случайными именами и общим шаблоном. StatefulSet даёт подам стабильные имена `name-0`, `name-1`, свой PVC на каждую реплику из `volumeClaimTemplates`, упорядоченный запуск и обновление. Для БД, очередей и всего, где важна идентичность и диск.

**Что хотят услышать:** стабильное имя и DNS, персональный PVC, порядок, headless Service; что Deployment для stateless.

**Красный флаг:** «StatefulSet просто для баз данных» без объяснения, что именно он гарантирует.

### 2. [junior] Что такое PV, PVC и StorageClass?

PV это конкретный том, PVC заявка на него из namespace, StorageClass рецепт динамического создания PV. Разработчик пишет PVC, провайдер создаёт PV, kubelet монтирует том в под.

**Что хотят услышать:** динамический провайдер, режим привязки, `reclaimPolicy`, accessModes.

**Красный флаг:** путает PV и PVC или думает, что PVC это сам диск.

### 3. [middle] Удалили StatefulSet с базой. Что случилось с данными?

По умолчанию ничего: PVC остаются (`persistentVolumeClaimRetentionPolicy: Retain`), при повторном `apply` под получит тот же диск. Данные теряются при `delete pvc`, при удалении namespace и при `reclaimPolicy: Delete`, если PVC удалён. Я проверю `kubectl get pvc` и `kubectl get pv`, и если нужно, верну бэкап.

**Что хотят услышать:** различие политик, что namespace удаляет PVC, бэкап как единственная страховка.

**Красный флаг:** «StatefulSet защищает данные от любого удаления».

### 4. [middle] Под postgres-0 висит Pending, PVC тоже Pending. Твои действия?

Смотрю `kubectl describe pvc` и события пода. Проверяю: есть ли StorageClass и правильно ли указан `storageClassName`, есть ли провайдер (под `local-path-provisioner`), режим `WaitForFirstConsumer` (тогда PVC ждёт пода), нет ли ограничений по узлам и ресурсам, хватает ли места. Если ошибка в `volumeClaimTemplates`, StatefulSet придётся пересоздавать, править это поле на лету нельзя.

**Что хотят услышать:** `describe` и события, StorageClass, provisioner, topology; неизменяемость шаблона.

**Красный флаг:** «пересоздам кластер» вместо диагностики.

### 5. [junior] Зачем StatefulSet нужен headless Service?

Чтобы каждая реплика имела собственный DNS-адрес `pod-N.svc.ns.svc.cluster.local`, а клиент мог обратиться к конкретной реплике (primary), а не к случайной. Обычный ClusterIP скрывает, какой под ответил.

**Что хотят услышать:** `clusterIP: None`, `serviceName`, адрес пода в DNS.

**Красный флаг:** «headless это Service без портов».

### 6. [middle] Ты поменял пароль в Secret и перезапустил под Postgres, а приложение получает password authentication failed. Почему?

Образ применяет `POSTGRES_PASSWORD` только при инициализации пустого каталога. В существующей базе пароль остался старым. Я либо верну старое значение в Secret, либо выполню `ALTER USER` внутри базы, и только потом обновлю приложение.

**Что хотят услышать:** initdb, данные на PVC, порядок смены пароля, ротация без простоя.

**Красный флаг:** «перезапущу поды побольше раз» или «удалю PVC», не подумав о данных.

### 7. [middle] Диск PVC заполнился на 100%, база перешла в аварийный режим. Что делаешь?

Сначала смотрю `df -h` внутри пода и `kubectl get pvc`, чтобы понять, растут данные или WAL. Если StorageClass поддерживает расширение (`allowVolumeExpansion: true`), увеличиваю `spec.resources.requests.storage` у PVC, для StatefulSet правлю сам PVC, а не `volumeClaimTemplates`. Параллельно ищу причину роста: раздутые таблицы, застрявшие слоты репликации, архив WAL.

**Что хотят услышать:** расширение тома онлайн, ограничение шаблона, поиск причины, а не только «дай больше места», мониторинг заполнения.

**Красный флаг:** «удалю файлы в каталоге данных руками».

### 8. [middle] Как сделать бэкап PostgreSQL в Kubernetes и как убедиться, что он рабочий?

Логический: `kubectl exec ... pg_dump` или CronJob, сохраняющий дамп на другой PVC или в объектное хранилище вне кластера. Физический с WAL-архивом для восстановления на момент времени делает оператор. Рабочим бэкап считается только после проверки восстановления в отдельную базу, поэтому раз в период делаю restore drill и слежу за возрастом последнего дампа.

**Что хотят услышать:** бэкап вне кластера и вне узла, restore drill, RPO и RTO, PITR как отдельная возможность.

**Красный флаг:** «PVC уже сам является бэкапом» или «снапшот диска и достаточно, не проверяя».

### 9. [middle] Узел с postgres-0 вышел из строя. Что будет с подом и данными?

Под перейдёт в `Unknown`/`Terminating`, StatefulSet сознательно не создаёт замену, пока не убедится, что старый под действительно остановлен (гарантия «не более одного»). Если том локальный, как в kind, данные привязаны к узлу и недоступны до его возврата. Сетевой диск в облаке отвяжется и подключится на другом узле, после чего под стартует там.

**Что хотят услышать:** at-most-one, разница локального и сетевого тома, ручное вмешательство (`--force`) с пониманием риска split-brain.

**Красный флаг:** «просто сделаю `delete pod --force`» без проверки, что узел выключен.

### 10. [junior] Приложение получило ошибку connection refused к db:5432 сразу после развёртывания. Что проверишь?

Готов ли под (`kubectl get pod`, `logs`), есть ли у Service endpoints (`kubectl get endpoints db`), совпадает ли `selector` с метками пода, порт и namespace в адресе. Postgres при первом старте инициализирует базу и перезапускается, так что несколько секунд недоступен: клиент должен уметь ждать (retry) или ждать по готовности.

**Что хотят услышать:** порядок проверки от пода к Service и DNS, endpoints, ожидание готовности (пробы в уроке 5.7).

**Красный флаг:** «попробую поднять ещё реплик» или «перезапущу всё».

## Проверено на версиях

- Kubernetes: 1.37.1 (kubectl 1.37.1)
- kind: v0.33.0
- PostgreSQL: 18.6 (образ `postgres:18`)
- busybox: 1.37
- StorageClass `standard` (rancher.io/local-path), идёт в составе kind v0.33.0

## Итог урока: ты умеешь

- [ ] умею объяснить, чем PV, PVC и StorageClass отличаются и что значит `WaitForFirstConsumer`
- [ ] умею написать StatefulSet с `volumeClaimTemplates` и headless Service
- [ ] умею создать Secret командой и подключить его пароль в контейнер PostgreSQL 18
- [ ] умею проверить, что данные пережили удаление пода и StatefulSet, и назвать, что их убивает
- [ ] умею сделать `pg_dump` из пода и восстановить из дампа
- [ ] умею диагностировать `Pending` у PVC и `password authentication failed` по событиям и логам
- [ ] умею решить, когда БД в кластере оправдана, а когда нужен оператор или Managed-сервис

**Дальше:** [Урок 5.6: ConfigMap и Secret](06-config-secrets.md)
