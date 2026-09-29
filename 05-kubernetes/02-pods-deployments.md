---
layout: lesson
title: "Поды и Deployment: запускаем «Заметки»"
topic: 5
lesson: "5.2"
time: "2.5 ч"
---

## Зачем это нужно

В Compose ты говорил: «запусти этот контейнер». В Kubernetes ты говоришь: «хочу три копии приложения, всегда», и кластер сам следит, чтобы так и было. Упал контейнер, умер узел, кто-то случайно удалил под: копия вернётся без твоего участия. На работе с этого начинается любой деплой: манифест (manifest, описание объекта в YAML), `kubectl apply` и разбор статусов вроде `ImagePullBackOff` и `CrashLoopBackOff`, которые видит каждый, кто хоть раз выкатывал сервис.

Шаг проекта: в кластере kind появляется Deployment `notes` в namespace `notes`: 3 реплики образа `notes:0.4.0`, данные в `emptyDir` (после удаления пода заметки пропадают, это осознанный долг до урока 5.5), файл `k8s/base/10-deployment.yaml`.

## Что нужно знать

- [Урок 5.1: зачем Kubernetes и кластер kind](01-why-k8s-cluster.md) - у тебя есть кластер `notes`, контекст `kind-notes` и namespace `notes`.
- [Урок 4.2: Dockerfile и образ](../04-docker/02-dockerfile.md) - образ `notes`, порт 8080, пользователь uid 10001, переменные окружения.
- [Урок 4.7: образы и реестр](../04-docker/07-images-registry.md) - образ `ghcr.io/<github-user>/notes:0.4.0` и почему тег `latest` не используем.
- [Урок 4.9: диагностика Docker](../04-docker/09-docker-troubleshooting.md) - `logs`, `inspect`, `exec`, код выхода 137.
- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - что такое SIGTERM и SIGKILL, пригодится при удалении подов.

## Теория

### Под: минимальная единица запуска

Под (Pod) это обёртка вокруг одного или нескольких контейнеров, которые живут на одном узле, делят один IP-адрес и могут делить тома (volumes). Обычно в поде один контейнер: твоё приложение. Второй добавляют, когда он нужен только рядом с первым (сборщик логов, прокси). Такой контейнер называют sidecar. Контейнер, который отработал перед стартом основного и завершился (миграции, ожидание зависимости), это init-контейнер (init container).

Главное свойство: под одноразовый. Его не чинят, а заменяют. У нового пода другое имя и другой IP. Если под создан «голым», без хозяина, и умер, его никто не вернёт. Поэтому голые поды в работе не запускают: их создают через контроллеры (controller), то есть объекты, которые следят за состоянием.

Жизненный цикл пода (поле `phase`): `Pending` (принят, но ещё не запущен: ждёт узел или образ), `Running` (хотя бы один контейнер работает), `Succeeded` и `Failed` (для разовых задач), `Unknown`. Статусы в колонке `STATUS` у `kubectl get pods` богаче: `ContainerCreating`, `ImagePullBackOff`, `CrashLoopBackOff`, `Terminating`. Это уже причины, а не фазы.

> **Проверь понимание:** ты запустил под командой `kubectl run` без Deployment и удалил его. Вернётся ли он?

<details>
<summary>Ответ</summary>

Нет. У такого пода нет контроллера, который следил бы за количеством копий. Желаемое состояние «под должен существовать» нигде не записано, поэтому и возвращать нечего.

</details>

### ReplicaSet и Deployment: желаемое состояние

ReplicaSet держит заданное число одинаковых подов. Он смотрит на селектор (selector, условие по меткам) и считает, сколько подов ему подходит. Меньше нужного: создаёт. Больше: удаляет лишние. Это тот самый цикл согласования (reconcile loop) из урока 5.1: сравнить желаемое с фактическим и исправить разницу.

Deployment стоит над ReplicaSet и добавляет главное: обновления. Ты меняешь образ в манифесте, Deployment создаёт новый ReplicaSet и постепенно переводит на него поды (подробно в уроке 5.7), старый ReplicaSet остаётся для отката. Цепочка владения такая: Deployment `notes` владеет ReplicaSet `notes-<хэш>`, тот владеет подами `notes-<хэш>-<случайные символы>`. Хэш в имени это отпечаток шаблона пода: изменился шаблон, изменился хэш, появился новый ReplicaSet.

Метки (labels) это пары ключ-значение на объектах. Селектор Deployment (`spec.selector.matchLabels`) должен совпадать с метками шаблона пода (`spec.template.metadata.labels`). Если не совпадает, API отклонит манифест. Метки же связывают объекты между собой: в 5.3 по ним Service найдёт поды.

> **Проверь понимание:** ты вручную удалил ReplicaSet, которым владеет Deployment. Что произойдёт?

<details>
<summary>Ответ</summary>

Deployment заметит, что ReplicaSet для текущего шаблона нет, и создаст его заново. Поды пересоздадутся. Управлять нужно верхним объектом (Deployment), а не тем, что он создаёт.

</details>

### Манифест: из чего состоит YAML объекта

У любого объекта Kubernetes четыре верхних поля: `apiVersion` (версия API, для Deployment это `apps/v1`), `kind` (тип объекта), `metadata` (имя, namespace, метки) и `spec` (желаемое состояние). Ещё одно поле, `status`, ты не пишешь: его заполняет кластер, и там лежит факт. Разница `spec` и `status` это и есть «хочу» против «есть».

`kubectl apply -f файл` объявляет желаемое состояние: объекта нет, создаст; есть, приведёт к манифесту. Команду можно повторять сколько угодно раз (это идемпотентность, idempotency). `kubectl create -f` только создаёт и падает с ошибкой `AlreadyExists`, если объект есть. Для работы с файлами в git используют `apply`.

Перед применением полезно посмотреть, что изменится: `kubectl diff -f файл` показывает разницу с живым объектом, а `kubectl apply --dry-run=server -f файл` прогоняет манифест через валидацию API-сервера, ничего не сохраняя.

> **Проверь понимание:** чем `kubectl apply` отличается от `kubectl create`?

<details>
<summary>Ответ</summary>

`create` императивно создаёт объект и падает, если он уже есть. `apply` декларативно приводит объект к манифесту и безопасно запускается повторно, поэтому его используют в CI и при работе с файлами из git.

</details>

### Образы в kind и политика загрузки

Узлы kind это контейнеры Docker со своим containerd внутри, поэтому образы с твоего хоста они сами не видят. Есть два пути. Первый: образ лежит в публичном реестре ghcr.io (он там с урока 4.7), и узлы скачивают его сами. Второй: `kind load docker-image notes:0.4.0 --name notes` копирует локальный образ внутрь каждого узла.

Поведение при старте пода задаёт `imagePullPolicy`. `IfNotPresent`: тянуть, только если образа нет на узле. `Always`: проверять реестр каждый раз. `Never`: только локальный образ. Если поле не задано, Kubernetes выбирает сам: для тега `latest` или без тега это `Always`, для остальных `IfNotPresent`. Отсюда правило: тег `latest` не используем, иначе поведение зависит от неявных правил и невоспроизводимо. Всегда фиксированная версия.

Если образ в реестре приватный, узлу нужен доступ. Для этого создают Secret типа `docker-registry` и указывают его в `imagePullSecrets` пода. Мы этого делать не будем, потому что пакет `notes` публичный, но команду увидишь ниже, а без неё приватный образ даст `ImagePullBackOff` с текстом `unauthorized`.

> **Проверь понимание:** зачем `kind load`, если образ уже есть в локальном Docker?

<details>
<summary>Ответ</summary>

Кластер kind работает внутри своих контейнеров-узлов со своим хранилищем образов. Docker хоста для него не источник. Без `kind load` (или реестра) узел не найдёт образ и поды зависнут в `ErrImagePull`.

</details>

## Практика

Все команды выполняются из `~/notes`. Предполагается, что кластер из 5.1 запущен: `kubectl config current-context` должен вернуть `kind-notes`. Подставь свой логин GitHub вместо `<github-user>` (строчными буквами). Версии: kind v0.33.0, kubectl 1.37.1.

### Задание 1. Первый Deployment с одной репликой

**Цель:** описать приложение манифестом и получить работающий под.

**Предскажи:** сколько объектов появится после `apply` одного Deployment (не считая самого Deployment) и как будут называться поды?

<details>
<summary>Ответ</summary>

Появятся ReplicaSet (один) и под (один по числу реплик). Имя ReplicaSet: `notes-<хэш>`, имя пода: `notes-<хэш>-<5 символов>`.

</details>

**Шаги:**

1. Создай временный манифест (в проект он попадёт в задании 4 в окончательном виде):

```bash
mkdir -p ~/notes/k8s/base
cat > ~/notes/k8s/base/10-deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notes
  namespace: notes
  labels:
    app: notes
spec:
  replicas: 1
  selector:
    matchLabels:
      app: notes
  template:
    metadata:
      labels:
        app: notes
    spec:
      containers:
        - name: notes
          image: ghcr.io/<github-user>/notes:0.4.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: STORE
              value: "file"
            - name: NOTES_DATA
              value: "/data/notes.txt"
            - name: APP_VERSION
              value: "0.4.0"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
YAML
```

2. Проверь манифест сервером и примени:

```bash
kubectl apply --dry-run=server -f k8s/base/10-deployment.yaml
kubectl apply -f k8s/base/10-deployment.yaml
kubectl -n notes rollout status deploy/notes --timeout=120s
kubectl -n notes get deploy,rs,pods -o wide
```

**Что должно получиться:**

```text
deployment.apps/notes created (server dry run)
deployment.apps/notes created
deployment "notes" successfully rolled out
NAME                    READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES
deployment.apps/notes   1/1     1            1           12s   notes        ghcr.io/<github-user>/notes:0.4.0

NAME                              DESIRED   CURRENT   READY   AGE
replicaset.apps/notes-6d8c9b7f5   1         1         1       12s

NAME                        READY   STATUS    RESTARTS   AGE   IP           NODE
pod/notes-6d8c9b7f5-x2k7p   1/1     Running   0          12s   10.244.1.3   notes-worker
```

Хэш и имена у тебя будут другие.

**Объясни себе:**

- Откуда в имени пода два «хвоста» и что каждый означает?
- Почему в манифесте `emptyDir`, а не том Docker, как в Compose?
- Что такое `--dry-run=server` и чем он лучше `client`?

**Типичные ошибки:**

- `error: the namespace from the provided object does not match the namespace "default"`: неверный флаг `-n` или контекст. Убери `-n` (namespace уже в манифесте) или поправь значение.
- `Error from server (NotFound): namespaces "notes" not found`: не создан namespace из урока 5.1. Выполни `kubectl apply -f k8s/base/00-namespace.yaml`.
- `error validating data: ValidationError(Deployment.spec): missing required field "selector"`: забыт селектор или сломаны отступы в YAML. Проверь, что `selector` и `template` на одном уровне под `spec`.

### Задание 2. Заглянуть в под: логи, exec, port-forward

**Цель:** убедиться, что приложение отвечает, и научиться смотреть внутрь пода.

**Предскажи:** `port-forward` прокидывает порт с твоей машины в под. Что вернёт `curl http://127.0.0.1:8080/healthz` и пойдёт ли этот запрос через какой-либо балансировщик?

<details>
<summary>Ответ</summary>

Ответ `ok` с кодом 200. Балансировщика нет: `kubectl` открывает туннель к API-серверу, а тот к конкретному поду. Service мы ещё не создавали (урок 5.3).

</details>

**Шаги:**

```bash
kubectl -n notes logs deploy/notes --tail=5
# туннель в фоне на порт 18080, чтобы не мешать другим сервисам на 8080
kubectl -n notes port-forward deploy/notes 18080:8080 &
sleep 2
curl -sS http://127.0.0.1:18080/healthz
curl -sS -X POST -d 'первая заметка' http://127.0.0.1:18080/notes
curl -sS http://127.0.0.1:18080/notes
kill %1
# зайти в контейнер и посмотреть пользователя и файл данных
kubectl -n notes exec deploy/notes -- sh -c 'id -u; ls -l /data'
```

**Что должно получиться:**

```text
{"ts":"...","level":"info","msg":"listening","port":8080}
ok
{"id":1,"text":"первая заметка"}
[{"id":1,"text":"первая заметка",...}]
10001
-rw-r--r-- 1 10001 10001 ... notes.txt
```

**Объясни себе:**

- Почему `id -u` возвращает 10001, а не 0, и где это задано?
- Что будет с файлом `/data/notes.txt`, если удалить под?
- Почему `logs deploy/notes` работает, хотя логи хранит под?

**Типичные ошибки:**

- `error: unable to forward port because pod is not running. Current status=Pending`: под ещё не запущен. Дождись `rollout status`.
- `Unable to listen on port 18080: Listeners failed to create with the following errors: [unable to create listener: Error listen tcp4 127.0.0.1:18080: bind: address already in use]`: порт занят прошлым туннелем. Найди и останови: `pkill -f 'port-forward'`.
- `error: Internal error occurred: error executing command in container: exec: "bash": executable file not found in $PATH`: в образе `python:3.13-slim` есть `sh` и обычно `bash`, но в минимальных образах его нет. Используй `sh`.

### Задание 3. Самовосстановление и масштабирование

**Цель:** увидеть, как контроллеры возвращают желаемое состояние.

**Предскажи:** ты удалишь под, у которого `replicas: 3`. Сколько подов будет через 2 секунды и будет ли у нового то же имя?

<details>
<summary>Ответ</summary>

Снова 3 (один будет в статусе `ContainerCreating` или `Running`). Имя другое: суффикс случаен, IP тоже новый. Под одноразовый, ReplicaSet создаёт замену, а не воскрешает старый.

</details>

**Шаги:**

```bash
# масштабирование императивно (для опыта; в манифесте потом поправим)
kubectl -n notes scale deploy/notes --replicas=3
kubectl -n notes get pods -o wide
# удаляем один под и смотрим за событиями
POD=$(kubectl -n notes get pods -o name | head -1)
kubectl -n notes delete "$POD" --wait=false
kubectl -n notes get pods -w --request-timeout=10s
```

Останови `-w` по `Ctrl+C`, если он не завершился сам.

Затем посмотри, кто чем владеет:

```bash
kubectl -n notes get pod -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name
kubectl -n notes describe deploy/notes | sed -n '/Events/,$p'
```

**Что должно получиться:**

```text
NAME                    READY   STATUS              RESTARTS   AGE
notes-6d8c9b7f5-x2k7p   1/1     Terminating         0          3m
notes-6d8c9b7f5-q9m4d   0/1     ContainerCreating   0          1s
notes-6d8c9b7f5-a1b2c   1/1     Running             0          40s
notes-6d8c9b7f5-z3y4x   1/1     Running             0          40s

NAME                    OWNER
notes-6d8c9b7f5-a1b2c   notes-6d8c9b7f5
```

**Объясни себе:**

- Почему на короткое время подов «больше» трёх (один `Terminating`)?
- Что вернёт ownerReferences у пода и как это связано со сборкой мусора при удалении Deployment?
- Что произойдёт с `kubectl scale`, если ты потом применишь манифест с `replicas: 1`?

**Типичные ошибки:**

- `Error from server (NotFound): pods "notes-..." not found`: под уже заменён, имя устарело. Возьми свежий из `get pods`.
- `error: unknown flag: --replica`: опечатка, флаг называется `--replicas`.

### Задание 4. Шаг проекта: Deployment `notes` на 3 реплики

**Цель:** зафиксировать окончательный манифест в проекте и выкатить его.

**Предскажи:** что покажет `kubectl diff -f k8s/base/10-deployment.yaml`, если ты уже вручную сделал `scale --replicas=3`, а в файле стоит `replicas: 3`?

<details>
<summary>Ответ</summary>

Ничего значимого: желаемое состояние совпало с живым. Кроме `replicas` в дифф могут попасть служебные поля, например `generation`. Если в файле остаётся `replicas: 1`, дифф покажет `-  replicas: 3` и `+  replicas: 1`.

</details>

**Шаги:**

1. Обнови `k8s/base/10-deployment.yaml` целиком (три реплики, ограничение на данные `sizeLimit`):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notes
  namespace: notes
  labels:
    app: notes
spec:
  replicas: 3
  selector:
    matchLabels:
      app: notes
  template:
    metadata:
      labels:
        app: notes
    spec:
      containers:
        - name: notes
          image: ghcr.io/<github-user>/notes:0.4.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: STORE
              value: "file"
            - name: NOTES_DATA
              value: "/data/notes.txt"
            - name: APP_VERSION
              value: "0.4.0"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        # данные эфемерны: живут, пока жив под (долг, закроется в 5.5)
        - name: data
          emptyDir:
            sizeLimit: 64Mi
```

2. Посмотри дифф, примени и проверь:

```bash
kubectl diff -f k8s/base/10-deployment.yaml
kubectl apply -f k8s/base/10-deployment.yaml
kubectl -n notes rollout status deploy/notes
kubectl -n notes get deploy notes
kubectl -n notes get pods -o wide
```

3. Проверь, что у каждой реплики свои данные:

```bash
for p in $(kubectl -n notes get pods -o name); do
  kubectl -n notes exec "$p" -- sh -c 'wc -l < /data/notes.txt 2>/dev/null || echo 0'
done
```

4. Зафиксируй в git:

```bash
git add k8s/base/10-deployment.yaml
git commit -m "k8s: Deployment notes, 3 реплики, emptyDir"
```

**Что должно получиться:**

```text
deployment.apps/notes configured
deployment "notes" successfully rolled out
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
notes   3/3     3            3            9m
```

Три пода `Running` на разных workers. Счётчики строк в шаге 3 расходятся (например, 1, 0, 0): каждая реплика хранит свою заметку в своём `emptyDir`. Это главный урок задания: пока данные в поде, три копии это три разные базы, и решается это в 5.5. Эталон: [k8s/base/10-deployment.yaml](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/base/10-deployment.yaml).

**Объясни себе:**

- Почему при трёх репликах и файловом хранилище «заметки то есть, то нет» и какой объект в 5.3-5.5 это исправит?
- Что изменится в данных, если удалить один под?
- Почему нельзя просто поставить `replicas: 3` и считать приложение отказоустойчивым?

**Типичные ошибки:**

- `The Deployment "notes" is invalid: spec.selector: Invalid value: ... field is immutable`: ты изменил `matchLabels` у существующего Deployment. Селектор менять нельзя: удали Deployment (`kubectl delete -f ...`) и создай заново.
- `Error from server (BadRequest): error when creating "k8s/base/10-deployment.yaml": Deployment in version "v1" cannot be handled as a Deployment: ... unknown field`: опечатка в имени поля. Проверь его через `kubectl explain deploy.spec.template.spec.containers`.

## Сломай и почини

Скачай скрипт поломки и запусти нужный сценарий. Скрипт не читай: ломай, диагностируй, чини. Сценарии: 1, 2, 3 (или `random`).

```bash
curl -fsSLo /tmp/break52.sh https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/5.2/break.sh
bash /tmp/break52.sh 1
kubectl -n notes get pods
```

### Симптом

Ты выкатил новую версию, а `kubectl -n notes get pods` показывает поды не в `Running`. Возможные картины: `ErrImagePull` и `ImagePullBackOff`, `CrashLoopBackOff` (перезапуски растут), либо `Pending` без узла. Сервис для пользователей деградирует.

### Гипотезы

1. Образ не найден или недоступен: опечатка в теге, нет прав на приватный образ.
2. Контейнер стартует и сразу падает: неверная команда, ошибка конфигурации.
3. Под не может быть размещён: запрошено больше ресурсов, чем есть на узлах.

### Проверки

Всегда начинай с событий и с точной причины, а не с догадок:

```bash
kubectl -n notes get pods
kubectl -n notes describe pod <имя> | sed -n '/Events/,$p'
kubectl -n notes logs <имя> --previous      # логи упавшего запуска
kubectl -n notes get events --sort-by=.lastTimestamp | tail -10
kubectl describe nodes | grep -A6 'Allocated resources'
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**1. ImagePullBackOff (опечатка в теге).** В `describe` в событиях: `Failed to pull image "ghcr.io/<user>/notes:0.4.O": ... manifest unknown` или `not found`. Кластер пытается снова с нарастающей паузой, отсюда `BackOff`. Это не «упало приложение», образа просто нет. Причины бывают такие: опечатка в теге или имени, образ не опубликован, приватный реестр без `imagePullSecrets` (текст `unauthorized` или `denied`), лимит запросов реестра. Исправление: `kubectl -n notes set image deploy/notes notes=ghcr.io/<github-user>/notes:0.4.0` (и поправить файл, чтобы git совпадал с кластером). Для приватного образа:

```bash
kubectl -n notes create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<github-user> \
  --docker-password=CHANGE_ME
```

и в шаблоне пода `imagePullSecrets: [{name: ghcr-pull}]`.

**2. CrashLoopBackOff.** Статус означает: контейнер запускается, завершается с ошибкой, кластер перезапускает его с растущей паузой (10, 20, 40 секунд, потолок 5 минут). `kubectl logs` покажет уже новый пустой запуск, поэтому нужен `--previous`. В `describe` смотри `Last State: Terminated`, `Exit Code`: 1 или 2 (ошибка приложения, например неверная переменная), 127 (команда не найдена), 137 (убит, SIGKILL, часто из-за памяти). Исправление: вернуть корректные `command` и `env` в манифесте и применить его.

**3. Pending (слишком большие requests).** В `describe`: `0/3 nodes are available: 3 Insufficient cpu` или `Insufficient memory`. Планировщик (scheduler) не нашёл узел, где хватит запрошенных ресурсов; `requests` это гарантия при размещении, а не фактическое потребление. Исправление: уменьшить `resources.requests` до разумных (для «Заметок» 50m и 64Mi, подробнее в 5.7) и применить.

Общий вывод: не гадай по `STATUS`, читай `Events` и `--previous`.

</details>

После починки проверь `kubectl -n notes rollout status deploy/notes`. Чтобы вернуть образец к исходному состоянию, примени файл заново: `kubectl apply -f k8s/base/10-deployment.yaml`.

## Вопросы с собеседований

### 1. [junior] Чем отличаются Pod, ReplicaSet и Deployment?

Под это один или несколько контейнеров с общим IP на одном узле, он одноразовый. ReplicaSet держит нужное число одинаковых подов по селектору. Deployment управляет ReplicaSet и умеет обновлять и откатывать. Руками я почти всегда создаю только Deployment.

**Что хотят услышать:** цепочка Deployment, ReplicaSet, Pod; поды заменяются, а не чинятся; обновления и откат через Deployment.

**Красный флаг:** «под и контейнер это одно и то же» или «ReplicaSet я создаю вручную».

### 2. [middle] Я удалил под из Deployment. Что произойдёт и почему?

ReplicaSet увидит, что подов меньше `replicas`, и создаст новый. У нового будет другое имя и IP. Старый перейдёт в `Terminating`: контейнеру пошлют SIGTERM, через `terminationGracePeriodSeconds` (по умолчанию 30 секунд) SIGKILL. Данные в `emptyDir` удалённого пода потеряются.

**Что хотят услышать:** reconcile-цикл, желаемое против фактического, grace period, эфемерность `emptyDir`.

**Красный флаг:** «под перезапустится сам с теми же данными и IP».

### 3. [middle] Под в статусе ImagePullBackOff. Твои действия?

Начинаю с `kubectl describe pod` и читаю события: там точная ошибка. Проверяю тег и имя образа (опечатка), существует ли он в реестре, публичный ли, есть ли `imagePullSecrets`, доступна ли сеть у узла к реестру. Для kind проверяю, что образ загружен через `kind load`. Чиню `set image` или манифест.

**Что хотят услышать:** `describe` и Events, `manifest unknown` против `unauthorized`, `imagePullSecrets`, `imagePullPolicy`.

**Красный флаг:** «перезапущу под» без чтения событий.

### 4. [middle] Под в CrashLoopBackOff. Как разбираешься?

Смотрю `kubectl logs --previous`, потому что текущий запуск ещё пуст. В `describe` читаю `Exit Code` и `Reason`: 1 или 2 это ошибка приложения, 127 нет команды, 137 SIGKILL (часто OOMKilled). Проверяю переменные окружения, монтирования, зависимости (БД недоступна). Пробы могут убивать здоровое, но медленное приложение.

**Что хотят услышать:** `--previous`, коды выхода, растущая пауза, отличие падения приложения от убийства пробой.

**Красный флаг:** «увеличу `restartPolicy`» или «удалю под».

### 5. [middle] Под висит в Pending. Что проверишь?

`describe pod`, раздел Events: сообщение планировщика вроде `0/3 nodes are available: Insufficient memory`, `node(s) had untolerated taint`, `didn't match Pod's node affinity`, либо `pod has unbound immediate PersistentVolumeClaims`. Далее `describe nodes`, раздел `Allocated resources`. Лечу requests, taints и tolerations, или добавляю узлы.

**Что хотят услышать:** планировщик решает по `requests`, а не по фактической нагрузке; taints, PVC.

**Красный флаг:** «Pending значит образ скачивается».

### 6. [junior] Зачем метки и селекторы, и что будет, если селектор Deployment не совпадёт с метками шаблона?

Метки это ключи-значения на объектах, селектор выбирает по ним поды. API не примет Deployment, у которого `selector` не совпадает с метками шаблона: ошибка валидации. Тем же способом Service найдёт поды.

**Что хотят услышать:** `matchLabels`, неизменяемость селектора, связь со Service.

**Красный флаг:** «метки нужны только для красоты».

### 7. [junior] Чем `kubectl apply` отличается от `kubectl create`, и что делает `diff`?

`create` создаёт и падает, если объект есть. `apply` декларативен и повторяем: приводит объект к файлу. `kubectl diff` показывает разницу до применения, `--dry-run=server` проверяет манифест на сервере без сохранения.

**Что хотят услышать:** декларативный против императивного подхода, идемпотентность, файлы из git.

**Красный флаг:** «всё равно, `create` быстрее».

### 8. [middle] Твой сервис использует тег `latest` в образе. Чем это плохо?

Тег изменяем: сегодня и завтра под тем же именем разные образы. По умолчанию подразумевается `imagePullPolicy: Always`, и один узел может подтянуть новую версию, другой остаться на старой. Откат и разбор инцидента невоспроизводимы. Использую фиксированную версию и лучше digest.

**Что хотят услышать:** воспроизводимость, разные версии на узлах, привязка к git-тегу, digest.

**Красный флаг:** «latest это всегда последняя стабильная версия».

### 9. [middle] Мы поставили `replicas: 3`, а пользователи жалуются, что заметки то пропадают, то появляются. Что происходит?

Приложение хранит данные локально (файл или память), а не в общем хранилище. Запросы попадают на разные поды, у каждого свои данные, а при пересоздании пода они теряются. Реплики не сделали приложение отказоустойчивым: состояние надо вынести в БД или общий том. В нашем проекте это Postgres в 5.5 и 5.6.

**Что хотят услышать:** stateless против stateful, вынос состояния, `emptyDir` эфемерен.

**Красный флаг:** «увеличим реплики ещё».

### 10. [middle] Как посмотреть логи контейнера, который уже перезапустился и упал?

`kubectl logs <под> --previous` покажет логи предыдущего запуска. Если в поде несколько контейнеров, добавляю `-c <имя>`. Если под уже пересоздан, логи потеряны: их нужно собирать централизованно (тема 8).

**Что хотят услышать:** `--previous`, `-c`, ограниченное время жизни логов на узле, централизованное логирование.

**Красный флаг:** «зайду в под через `exec` и посмотрю файл».

## Проверено на версиях

- kind: v0.33.0
- kubectl: 1.37.1
- Kubernetes (образ узла `kindest/node` из 5.1): 1.37.x
- Образ приложения: `ghcr.io/<github-user>/notes:0.4.0` (app v4)
- Python в образе: 3.13 (`python:3.13-slim`)

## Итог урока: ты умеешь

- [ ] умею описать Deployment манифестом и применить его через `kubectl apply`
- [ ] умею объяснить цепочку Deployment, ReplicaSet, Pod и роль меток и селекторов
- [ ] умею смотреть логи, заходить в контейнер и открывать доступ через `port-forward`
- [ ] умею показать самовосстановление: удалить под и масштабировать через `scale`
- [ ] умею отличить `ImagePullBackOff`, `CrashLoopBackOff` и `Pending` по событиям и `--previous`
- [ ] умею загрузить локальный образ в kind и объяснить `imagePullPolicy`
- [ ] умею объяснить, почему тег `latest` не используем, а `emptyDir` эфемерен

**Дальше:** [Урок 5.3: Service и DNS кластера](03-services-dns.md)
