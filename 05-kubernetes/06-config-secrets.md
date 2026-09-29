---
layout: lesson
title: "ConfigMap и Secret"
topic: 5
lesson: "5.6"
time: "1.5 ч"
---

## Зачем это нужно

Образ `notes:0.4.0` один, а окружений несколько: локально, в dev, в проде. Отличаются адрес БД, уровень логов, пароль. Если зашить это в образ, придётся собирать новый образ на каждое изменение, а пароль окажется в реестре. Kubernetes отделяет конфигурацию от образа: обычные настройки лежат в ConfigMap, чувствительные в Secret.

На работе с этим сталкиваются каждый день: под не стартует из-за пропавшего ключа, конфиг поменяли, а приложение работает по-старому, пароль случайно попал в git. Отдельная ловушка: Secret выглядит зашифрованным, но это всего лишь base64.

Шаг проекта: «Заметки» переходят с файла на PostgreSQL (`STORE=postgres`); настройки берутся из ConfigMap `notes-config`, строка подключения из Secret `notes-db`.

## Что нужно знать

- [Урок 5.2: поды и Deployment](02-pods-deployments.md) - мы правим `10-deployment.yaml`, поэтому нужно понимать шаблон пода и `rollout`
- [Урок 5.3: Service и DNS кластера](03-services-dns.md) - адрес БД `db` это DNS-имя Service внутри namespace
- [Урок 5.5: хранилище и StatefulSet](05-storage-statefulset-postgres.md) - PostgreSQL уже работает в кластере, Secret `notes-db` с паролем уже создан
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - там пароль жил в `.env`, теперь его место занимает Secret
- [Урок 4.2: Dockerfile](../04-docker/02-dockerfile.md) - переменные окружения приложения и почему образ не должен содержать конфигурацию

## Теория

### ConfigMap: настройки отдельно от образа

ConfigMap (карта конфигурации) это объект с парами «ключ: значение». Размер до 1 МиБ. Он лежит в namespace, и любой под этого namespace может его подключить. Есть три способа использовать его:

1. Все ключи как переменные окружения: `envFrom` с `configMapRef`.
2. Один ключ как одна переменная: `env` с `valueFrom.configMapKeyRef`.
3. Как файлы: ConfigMap монтируется томом, каждый ключ становится файлом в каталоге.

Переменные окружения проще всего: приложение читает `os.environ`, как мы делали в `app.py` (`STORE`, `HOST`, `PORT`, `LOG_LEVEL`). Файлы удобны, когда приложение ждёт конфигурационный файл целиком (например `nginx.conf`).

Главное различие в обновлении. Переменные окружения фиксируются в момент старта контейнера и потом не меняются. Файлы из тома kubelet (агент на узле) обновляет сам, обычно в пределах минуты, но приложение должно перечитать файл. Поэтому «поменял ConfigMap, а под работает по-старому» это нормальное поведение, а не баг.

> **Проверь понимание:** ты изменил значение `LOG_LEVEL` в ConfigMap, подключённом через `envFrom`. Поды работают. Какой уровень логов у них?

<details>
<summary>Ответ</summary>

Прежний. Переменные окружения читаются при старте контейнера. Чтобы применить новое значение, поды нужно пересоздать: `kubectl rollout restart deployment/notes`.

</details>

### Secret: тот же ConfigMap, но с оговорками

Secret устроен как ConfigMap, но предназначен для паролей, токенов и ключей. Значения в поле `data` хранятся в base64. Это кодирование (encoding), а не шифрование (encryption): декодируется одной командой без всякого ключа. Настоящей защиты у Secret по умолчанию три:

- отдельные права RBAC: можно разрешить читать ConfigMap и запретить Secret (тема 5.12);
- значение не показывается в `kubectl describe`;
- kubelet держит Secret в tmpfs (оперативная память), а не на диске узла.

Но в etcd (хранилище состояния кластера) Secret по умолчанию лежит без шифрования, а `kubectl get secret -o yaml` любому, у кого есть доступ, отдаёт значение. Шифрование etcd (encryption at rest) настраивается на стороне администраторов кластера, в managed-кластерах обычно включено.

Есть удобное поле `stringData`: в манифесте можно писать значение обычным текстом, кластер сам сложит его в `data` в base64. Читать обратно оно не будет: в `get` вернётся только `data`.

Из этого следует главное правило: манифест с настоящим паролем в git не кладут, даже в base64. В этом уроке Secret создаётся командой, и это осознанный долг проекта. Он закроется в [уроке 9.2](../09-secrets-gitops/02-vault-k8s-eso.md).

> **Проверь понимание:** коллега прислал в чат `cGFzc3dvcmQ=` и говорит, что это надёжно зашифровано. Что ты ответишь?

<details>
<summary>Ответ</summary>

Это base64: `echo cGFzc3dvcmQ= | base64 -d` даёт `password`. Никакого ключа не нужно, поэтому это не шифрование. Base64 нужен, чтобы в YAML помещались произвольные байты.

</details>

### Как конфигурация доходит до контейнера

Kubelet собирает окружение контейнера перед запуском. Если ссылка ведёт на несуществующий ConfigMap, Secret или ключ, контейнер даже не создаётся: под получает статус `CreateContainerConfigError`. Это отличается от `CrashLoopBackOff`: там контейнер стартовал и упал, здесь стартовать не смог. Причину пишет `kubectl describe pod` в событиях, например `couldn't find key DATABASE_URL in Secret notes/notes-db`.

Ссылку можно объявить необязательной: `optional: true`. Тогда отсутствие объекта не блокирует запуск, но приложение получит пустую конфигурацию, и ошибка проявится позже и в другом месте. Для строки подключения к БД `optional` не ставят.

Обновление конфигурации выстраивают так: правишь ConfigMap или Secret, применяешь, затем `kubectl rollout restart` (создаёт новые поды тем же rolling update из [урока 5.2](02-pods-deployments.md)). Helm-чарты делают это автоматически через аннотацию с хэшем ConfigMap: изменился хэш, изменился шаблон пода, начался rollout (урок 5.9).

Если ConfigMap или Secret помечен `immutable: true`, его содержимое менять нельзя, только удалить и создать заново. Это защищает от случайной правки и снижает нагрузку на API-сервер. Обновления при этом делают через новое имя (`notes-config-v2`) и смену ссылки в Deployment, что заодно запускает rollout.

> **Проверь понимание:** под в статусе `CreateContainerConfigError`. Ты смотришь `kubectl logs`, и там пусто. Почему?

<details>
<summary>Ответ</summary>

Контейнер ни разу не запускался, поэтому логов нет. Причину нужно искать в `kubectl describe pod` (раздел Events) или в `kubectl get events`.

</details>

## Практика

Убедись, что кластер и namespace на месте:

```bash
kubectl config use-context kind-notes
kubectl -n notes get pods
```

Ожидается, что `postgres-0` в статусе `Running`. Учебные объекты этого урока называются `demo-*` и в конце удаляются.

### Задание 1. ConfigMap как переменные и как файлы

**Цель:** увидеть на практике, чем отличается обновление env-переменной от обновления файла.

**Предскажи:** ты подключишь один и тот же ConfigMap двумя способами и потом поменяешь в нём значение. Что изменится в поде: переменная, файл, оба или ничего?

<details>
<summary>Ответ</summary>

Файл изменится (не сразу, kubelet синхронизирует тома периодически, до минуты-полутора). Переменная останется прежней до пересоздания пода.

</details>

**Шаги:**

1. Создай ConfigMap из литералов и посмотри его:

```bash
kubectl -n notes create configmap demo-config \
  --from-literal=LOG_LEVEL=info \
  --from-literal=GREETING=hello
kubectl -n notes get configmap demo-config -o yaml
```

2. Создай под, который получает ConfigMap обоими способами. Сохрани как `demo-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod
  namespace: notes
spec:
  containers:
    - name: demo
      image: python:3.13-slim
      command: ["sleep", "3600"]
      # Способ 1: все ключи как переменные окружения
      envFrom:
        - configMapRef:
            name: demo-config
      # Способ 2: ключи как файлы в каталоге
      volumeMounts:
        - name: cfg
          mountPath: /etc/demo
  volumes:
    - name: cfg
      configMap:
        name: demo-config
```

3. Запусти и проверь оба способа:

```bash
kubectl apply -f demo-pod.yaml
kubectl -n notes wait --for=condition=Ready pod/demo-pod --timeout=90s
kubectl -n notes exec demo-pod -- sh -c 'echo "env: $LOG_LEVEL"; echo -n "file: "; cat /etc/demo/LOG_LEVEL; echo'
```

4. Поменяй значение и подожди минуту-две:

```bash
kubectl -n notes patch configmap demo-config --type merge -p '{"data":{"LOG_LEVEL":"debug"}}'
sleep 90
kubectl -n notes exec demo-pod -- sh -c 'echo "env: $LOG_LEVEL"; echo -n "file: "; cat /etc/demo/LOG_LEVEL; echo'
```

**Что должно получиться:**

```text
env: info
file: info
```

и после правки:

```text
env: info
file: debug
```

**Объясни себе:**

- Почему файл обновился, а переменная нет?

**Типичные ошибки:**

- `Error from server (AlreadyExists): configmaps "demo-config" already exists`: объект уже есть, удали `kubectl -n notes delete configmap demo-config` или используй `apply`.
- Файл не обновился через 10 секунд: kubelet синхронизирует тома с задержкой, подожди до двух минут. Ещё причина: если монтировать ключ через `subPath`, файл не обновляется вообще.

### Задание 2. Secret: base64 это не шифрование

**Цель:** создать Secret, прочитать его обратно и убедиться, что защиты нет.

**Предскажи:** что покажет `kubectl get secret -o yaml` для значения, которое ты задал как `CHANGE_ME`: сам текст, случайную строку или что-то, что нельзя расшифровать без ключа?

<details>
<summary>Ответ</summary>

Строку в base64 (`Q0hBTkdFX01F`), которая декодируется без всякого ключа.

</details>

**Шаги:**

1. Создай Secret командой, значение не остаётся в файле:

```bash
kubectl -n notes create secret generic demo-secret \
  --from-literal=API_TOKEN=CHANGE_ME
kubectl -n notes get secret demo-secret -o yaml
kubectl -n notes describe secret demo-secret
```

2. Достань значение и декодируй:

```bash
kubectl -n notes get secret demo-secret -o jsonpath='{.data.API_TOKEN}'; echo
kubectl -n notes get secret demo-secret -o jsonpath='{.data.API_TOKEN}' | base64 -d; echo
```

3. Сравни с `stringData` (значение обычным текстом, кластер сам кодирует):

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret-2
  namespace: notes
type: Opaque
stringData:
  API_TOKEN: CHANGE_ME
YAML
kubectl -n notes get secret demo-secret-2 -o jsonpath='{.data.API_TOKEN}'; echo
```

**Что должно получиться:**

```text
Q0hBTkdFX01F
CHANGE_ME
Q0hBTkdFX01F
```

`describe` покажет только размеры значений (`API_TOKEN:  9 bytes`), не сами значения.

**Объясни себе:**

- Кто в кластере может выполнить шаг 2 и почему это важно для RBAC?
- Чем `stringData` удобнее `data`, и почему оба варианта не подходят для git?

**Типичные ошибки:**

- `base64: invalid input`: в команду попал лишний символ, например перевод строки при копировании. Используй `jsonpath` и pipe, как выше.
- `error: failed to create secret secrets "demo-secret" already exists`: Secret уже создан, удали его или используй `--dry-run=client -o yaml | kubectl apply -f -`.

### Задание 3. Шаг проекта: «Заметки» работают на PostgreSQL

**Цель:** вынести конфигурацию `notes` в ConfigMap и Secret, переключить приложение на PostgreSQL и проверить, что заметки лежат в БД, а не в поде.

**Предскажи:** после переключения на `STORE=postgres` ты создашь заметку и удалишь все поды `notes`. Останется ли заметка?

<details>
<summary>Ответ</summary>

Да. Данные теперь хранятся в PostgreSQL на PVC, а не в `emptyDir` пода.

</details>

**Шаги:**

1. Создай `k8s/base/50-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: notes-config
  namespace: notes
  labels:
    app.kubernetes.io/name: notes
data:
  # Хранилище: PostgreSQL вместо файла
  STORE: postgres
  # В контейнере слушаем все интерфейсы, порт всегда 8080
  HOST: 0.0.0.0
  PORT: "8080"
  LOG_LEVEL: info
  APP_VERSION: 0.4.0
```

Значение `PORT` в кавычках: в ConfigMap значения только строки, число без кавычек YAML превратит в int, и API отклонит манифест.

2. Дополни Secret `notes-db` ключом `DATABASE_URL`. Пароль уже задан в [уроке 5.5](05-storage-statefulset-postgres.md) и записан в базу, поэтому берём именно его: смена пароля в Secret не меняет пароль внутри уже созданной БД.

```bash
# Достаём пароль из существующего Secret (в историю shell он не попадает)
PGPASS=$(kubectl -n notes get secret notes-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
# Пересоздаём Secret с двумя ключами и применяем поверх
kubectl -n notes create secret generic notes-db \
  --from-literal=POSTGRES_PASSWORD="$PGPASS" \
  --from-literal=DATABASE_URL="postgresql://notes:${PGPASS}@db:5432/notes" \
  --dry-run=client -o yaml | kubectl apply -f -
unset PGPASS
kubectl -n notes get secret notes-db -o jsonpath='{.data}' | jq 'keys'
```

Манифест этого Secret в репозиторий не кладём. Адрес `db` короткий: под и БД в одном namespace, DNS из [урока 5.3](03-services-dns.md).

3. Замени `k8s/base/10-deployment.yaml` целиком. Изменились три вещи: добавлен `envFrom`, пропали прямые `env`-значения, `STORE` теперь берётся из ConfigMap. Подставь свой GitHub-пользователь вместо `<github-user>`:

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
  template:
    metadata:
      labels:
        app.kubernetes.io/name: notes
    spec:
      containers:
        - name: notes
          image: ghcr.io/<github-user>/notes:0.4.0
          ports:
            - containerPort: 8080
          # Все ключи ConfigMap и Secret становятся переменными окружения
          envFrom:
            - configMapRef:
                name: notes-config
            - secretRef:
                name: notes-db
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
```

4. Примени и дождись выкатки:

```bash
kubectl apply -f ~/notes/k8s/base/50-configmap.yaml
kubectl apply -f ~/notes/k8s/base/10-deployment.yaml
kubectl -n notes rollout status deployment/notes
kubectl -n notes exec deploy/notes -- printenv STORE LOG_LEVEL
```

5. Создай заметку, пересоздай поды и прочитай заметку снова:

```bash
kubectl -n notes port-forward svc/notes 8080:8080 &
sleep 2
curl -s -X POST localhost:8080/notes -d '{"text":"first in postgres"}'; echo
kubectl -n notes delete pod -l app.kubernetes.io/name=notes
kubectl -n notes rollout status deployment/notes
kubectl -n notes port-forward svc/notes 8080:8080 &
sleep 2
curl -s localhost:8080/notes; echo
```

6. Проверь, что конфигурация env не обновляется сама, и примени её перезапуском:

```bash
kubectl -n notes patch configmap notes-config --type merge -p '{"data":{"LOG_LEVEL":"debug"}}'
kubectl -n notes exec deploy/notes -- printenv LOG_LEVEL
kubectl -n notes rollout restart deployment/notes
kubectl -n notes rollout status deployment/notes
kubectl -n notes exec deploy/notes -- printenv LOG_LEVEL
```

7. Верни `LOG_LEVEL: info` (`kubectl apply -f ~/notes/k8s/base/50-configmap.yaml`, затем `rollout restart`) и останови port-forward: `kill %1 %2`.

**Что должно получиться:**

```text
["DATABASE_URL","POSTGRES_PASSWORD"]
deployment "notes" successfully rolled out
postgres
info
{"id":1}
[{"id":1,"text":"first in postgres","created_at":"2026-09-29T10:00:00+00:00"}]
info
debug
```

Эталон: [`project/notes/k8s/base/`](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/base). После этого шага долг проекта: Secret хранится в кластере как base64 и вне git, закроется в [уроке 9.2](../09-secrets-gitops/02-vault-k8s-eso.md).

**Объясни себе:**

- Почему шаг 6 показал старое значение сразу после `patch`?
- Что будет, если пересоздать Secret `notes-db` с другим `POSTGRES_PASSWORD`, а БД не трогать?
- `envFrom` со `secretRef` отдаёт приложению и `POSTGRES_PASSWORD` тоже. Чем это плохо и как сузить (подсказка: `valueFrom.secretKeyRef`)?

**Типичные ошибки:**

- `Error: couldn't find key DATABASE_URL in Secret notes/notes-db`: Secret есть, но без ключа `DATABASE_URL`. Повтори шаг 2.
- `psycopg.OperationalError: connection failed: FATAL:  password authentication failed for user "notes"`: в `DATABASE_URL` не тот пароль, что внутри БД. Возьми пароль из `POSTGRES_PASSWORD` (шаг 2), а не придумывай новый.
- Пароль содержит `/`, `@` или `+`: такой символ ломает разбор URL. Генерируй пароли `openssl rand -hex 16`: только буквы и цифры.

## Сломай и почини

Запусти скрипт поломки. Читать его не нужно: цель в том, чтобы найти причину по симптомам.

```bash
bash ~/notes/break/5.6/break.sh random
```

### Симптом

После скрипта «Заметки» ведут себя неправильно. Ты не знаешь, какая из трёх поломок выбрана. Начни с `kubectl -n notes get pods` и с ответа на вопрос: поды вообще запущены?

### Гипотезы

1. Под не стартует: ссылка на ключ или объект конфигурации указывает в пустоту.
2. Под запущен, но приложение не может работать с БД: адрес или пароль в `DATABASE_URL` неверны.
3. Конфигурацию поменяли, а поды работают по-старому.

### Проверки

```bash
kubectl -n notes get pods
kubectl -n notes describe pod -l app.kubernetes.io/name=notes | grep -A8 Events
kubectl -n notes logs deploy/notes --tail=20
kubectl -n notes get secret notes-db -o jsonpath='{.data.DATABASE_URL}' | base64 -d; echo
kubectl -n notes get configmap notes-config -o yaml
kubectl -n notes exec deploy/notes -- printenv | sort | grep -E 'STORE|LOG_LEVEL|DATABASE_URL'
```

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**Сценарий 1: `CreateContainerConfigError`.**

`get pods` показывает `CreateContainerConfigError`, `logs` пусты (контейнера не было). В `describe` в событиях:

```text
Error: couldn't find key DATABASE_URL in Secret notes/notes-db
```

В Secret нет ключа. Пересоздай Secret с обоими ключами (шаг 2 задания 4). Под перезапускать не нужно: kubelet повторяет попытку сам, но чтобы ускорить, можно `kubectl -n notes rollout restart deployment/notes`.

**Сценарий 2: неверный `DATABASE_URL`.**

Поды `Running`, потому что проб ещё нет (они появятся в [уроке 5.7](07-probes-resources-rollouts.md)), но `POST /notes` отвечает 500. В логах ошибка подключения: `could not translate host name "db1" to address` (ошибочное имя хоста) или `password authentication failed for user "notes"` (неверный пароль). Сравни `DATABASE_URL` с паролем в `POSTGRES_PASSWORD` и с именем Service `db`. Исправь Secret и перезапусти поды: env читается только при старте.

**Сценарий 3: ConfigMap изменён, поды не перезапущены.**

Ты видишь, что в ConfigMap `LOG_LEVEL: debug`, а `printenv` в поде показывает `info`. Ничего не сломано, так работают env. Выполни `kubectl -n notes rollout restart deployment/notes`. Урок запомнить: после любой правки ConfigMap или Secret, подключённых через env, нужен рестарт.

</details>

## Вопросы с собеседований

### 1. [junior] Чем ConfigMap отличается от Secret и когда что использовать?

ConfigMap для обычных настроек: уровень логов, адреса, флаги. Secret для паролей, токенов, ключей. Устроены почти одинаково, но Secret можно отдельно ограничить правами RBAC, он не печатается в `describe` и хранится на узле в памяти. Значения в Secret это base64, а не шифрование.

**Что хотят услышать:** оба объекта namespaced, лимит 1 МиБ, три способа подключения, что Secret защищён только RBAC и, при настройке, шифрованием etcd.

**Красный флаг:** «Secret зашифрован» или «в ConfigMap можно класть пароли, они же внутри кластера».

### 2. [junior] Твой коллега говорит: «Я закодировал пароль в base64, можно коммитить в git». Что скажешь?

Нельзя. Base64 декодируется за секунду без ключа, значит пароль в репозитории раскрыт всем, у кого есть доступ к репозиторию, и остаётся в истории даже после удаления файла. Пароль нужно считать скомпрометированным и сменить. Секреты хранят вне git или шифруют специальными инструментами.

**Что хотят услышать:** base64 не шифрование, ротация пароля, чистка истории не спасает, варианты: Sealed Secrets, SOPS, External Secrets с Vault.

**Красный флаг:** «ничего страшного, репозиторий приватный».

### 3. [junior] Как передать ConfigMap приложению: переменными или файлом?

Переменными, если приложение читает окружение, а настроек немного. Файлом, если приложению нужен конфигурационный файл целиком, или значение должно обновляться без перезапуска. Учитываю, что env читаются при старте, а файл kubelet обновляет сам, но приложение должно его перечитать.

**Что хотят услышать:** `envFrom` против `volumeMounts`, обновление файла с задержкой, `subPath` не обновляется.

**Красный флаг:** уверенность, что env подхватят изменение сами.

### 4. [junior] Что означает `envFrom` и чем отличается от `env` с `valueFrom`?

`envFrom` импортирует все ключи ConfigMap или Secret как переменные. `env` с `valueFrom` берёт один конкретный ключ и позволяет задать другое имя переменной. Первый короче, второй точнее и не тянет лишнего.

**Что хотят услышать:** `configMapKeyRef`, `secretKeyRef`, при `envFrom` в приложение попадают все ключи Secret, включая ненужные.

**Красный флаг:** не различает и не знает про лишние ключи.

### 5. [middle] Ты поменял ConfigMap, а приложение работает по-старому. Твои действия?

Проверю, как подключён ConfigMap. Если через env, значение фиксируется при старте: делаю `kubectl rollout restart deployment/x` и сверяю `printenv` в новом поде. Если через том, жду синхронизации kubelet и проверяю, перечитывает ли приложение файл. Если `subPath`, файл вообще не обновится, нужен рестарт.

**Что хотят услышать:** различие env и volume, `rollout restart`, хэш конфигурации в аннотации шаблона (Helm checksum), immutable с версионированием имени.

**Красный флаг:** «удалю поды руками» без понимания причины, или «перезапущу узел».

### 6. [middle] Под в статусе `CreateContainerConfigError`. Что делаешь?

Смотрю `kubectl describe pod`, раздел Events: там точная причина, например `couldn't find key DATABASE_URL in Secret`. Логов нет, контейнер не создавался. Проверяю, что Secret или ConfigMap существует в том же namespace, что в нём есть нужный ключ и что имя в Deployment без опечаток. Исправляю объект, kubelet повторит запуск.

**Что хотят услышать:** отличие от `CrashLoopBackOff`, `describe` и события, namespace как частая ловушка.

**Красный флаг:** начинает с `kubectl logs` и не понимает, почему они пусты.

### 7. [middle] Как ты организуешь хранение секретов, если работаешь по GitOps и всё лежит в git?

Секреты в открытом виде в git не нужны. Варианты: External Secrets Operator берёт значения из Vault или облачного хранилища и создаёт Secret в кластере; Sealed Secrets и SOPS хранят в git зашифрованный манифест. Я предпочитаю ESO: в git только ссылка на секрет, ротация происходит в хранилище.

**Что хотят услышать:** ESO, Vault, SOPS с age или KMS, Sealed Secrets, ротация и аудит, отсутствие секретов в истории git.

**Красный флаг:** «храню в приватном репозитории в base64».

### 8. [middle] Как ограничить, кто может читать Secret в кластере?

Через RBAC: даю Role только на нужные ресурсы, не включаю `secrets`, особенно глаголы `get`, `list`, `watch`. Учитываю, что доступ к созданию подов в namespace тоже фактически даёт доступ к Secret через монтирование. На уровне кластера включаю шифрование etcd и ограничиваю доступ к самому etcd.

**Что хотят услышать:** `kubectl auth can-i get secrets`, что `list` тоже раскрывает значения, права на создание подов как обход, encryption at rest.

**Красный флаг:** «Secret по умолчанию виден только своему приложению».

### 9. [middle] Пароль БД в Secret сменили на новый, поды перезапущены, а приложение получает `password authentication failed`. Почему?

Пароль в Secret и пароль внутри PostgreSQL разные вещи. Переменная `POSTGRES_PASSWORD` влияет на БД только при первой инициализации каталога данных. Раз данные уже есть на PVC, пароль пользователя нужно менять командой `ALTER USER notes PASSWORD ...` внутри БД, а затем менять Secret и перезапускать приложение.

**Что хотят услышать:** порядок ротации, инициализация только на пустом томе, рестарт приложения, пароль без спецсимволов для URL или кодирование.

**Красный флаг:** «пересоздам поды, и БД подхватит».

### 10. [middle] Зачем `immutable: true` у ConfigMap и как с ним обновлять конфигурацию?

Иммутабельность защищает от случайной правки, которая мгновенно отразится на всех подах, и снижает нагрузку на API-сервер, потому что kubelet перестаёт следить за объектом. Для изменения создаю новый объект с новым именем, например `notes-config-v2`, и меняю ссылку в Deployment, это запускает controlled rollout с возможностью откатить.

**Что хотят услышать:** версионирование имён, откат через `rollout undo`, автоматизация через Helm или Kustomize (`configMapGenerator` с хэшем в имени).

**Красный флаг:** думает, что immutable можно отредактировать через `kubectl edit`.

## Проверено на версиях

- kind: v0.33.0
- Kubernetes: 1.36.x (образ узла `kindest/node` из `kind/kind.yaml`)
- kubectl: 1.37.1
- PostgreSQL: 18 (образ `postgres:18`)
- Python: 3.13 (образ `python:3.13-slim`)
- приложение «Заметки»: v4, образ `notes:0.4.0`

## Итог урока: ты умеешь

- [ ] умею создать ConfigMap из литералов и манифеста и подключить его переменными и файлами
- [ ] умею создать Secret командой и прочитать значение через `jsonpath` и `base64 -d`
- [ ] умею объяснить, почему base64 не шифрование и что реально защищает Secret
- [ ] умею отличить `CreateContainerConfigError` от `CrashLoopBackOff` и найти причину через `describe`
- [ ] умею применить изменённую конфигурацию через `rollout restart`
- [ ] умею настроить Deployment на `envFrom` из ConfigMap и Secret
- [ ] умею назвать варианты хранения секретов вне git

**Дальше:** [Урок 5.7: Пробы, ресурсы и обновление без простоя](07-probes-resources-rollouts.md)
