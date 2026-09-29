---
layout: lesson
title: "Dockerfile: собираем образ «Заметок»"
topic: 4
lesson: "4.2"
time: "2 ч"
---

## Зачем это нужно

На сервере «Заметки» работали как systemd-сервис: код в `/opt/notes/`, данные в `/var/lib/notes/`, свой пользователь. Чтобы запустить то же самое на другой машине, нужно повторить десяток шагов руками. Образ (image) собирает всё это один раз по рецепту, `Dockerfile`, и запускается одинаково везде: на ноутбуке, в CI, в Kubernetes.

На работе Dockerfile ревьюят так же, как код: медленная сборка, образ на гигабайт и сервис под root это три самые частые претензии. Этот урок про то, как их не получить.

Шаг проекта: в `~/notes` появляются `Dockerfile`, `.dockerignore` и образ `notes:0.3.0`, приложение слушает `0.0.0.0:8080` внутри контейнера и работает под uid 10001.

## Что нужно знать

- [Урок 4.1: контейнеры](01-containers-idea.md) - контейнер это процесс с изоляцией, Docker Engine установлен, порты 80/443/8080 на хосте свободны
- [Урок 1.3: пользователи и права](../01-linux/03-users-permissions.md) - что такое uid, владелец каталога и почему сервис не должен быть root
- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - SIGTERM против SIGKILL, PID 1
- [Урок 3.5: релизы](../03-git-ci/05-release-flow.md) - semver и git-теги: версия образа совпадёт с тегом

## Теория

### Образ, слои и кэш

Образ (image) это неизменяемый набор слоёв (layers) плюс метаданные: команда запуска, переменные, пользователь. Каждая инструкция `RUN`, `COPY`, `ADD` создаёт новый слой с разницей файлов. Остальные (`ENV`, `CMD`, `USER`, `EXPOSE`) меняют только метаданные.

Сборщик (BuildKit) кэширует слои. Слой берётся из кэша, если не изменилась ни сама инструкция, ни содержимое файлов, которые она копирует, ни все слои выше. Стоит инвалидировать один слой, и всё, что ниже, пересобирается. Отсюда главное правило порядка: то, что меняется редко (зависимости), выше; то, что меняется часто (твой код), ниже.

```dockerfile
COPY requirements.txt .        # меняется раз в неделю
RUN pip install -r requirements.txt
COPY app.py .                  # меняется каждый коммит
```

> **Проверь понимание:** ты поменял одну строку в `app.py`. Какие слои этого фрагмента пересоберутся, если сначала идёт `COPY . .`, а потом `RUN pip install`?

<details markdown="1">
<summary>Ответ</summary>

Все: `COPY . .` видит изменившийся файл, слой инвалидируется, а `pip install` ниже него тоже пересоберётся и заново скачает зависимости. Если сначала копировать только `requirements.txt`, то установка зависимостей останется в кэше.

</details>

### Контекст сборки и .dockerignore

`docker build .` отправляет демону весь каталог `.` (контекст сборки, build context). `COPY` видит только его: файл вне контекста скопировать нельзя. Файл `.dockerignore` исключает из контекста лишнее: `.git`, `.env`, каталоги с данными. Это ускоряет сборку и не даёт секретам попасть в слой: удалить файл в следующем слое не выйдет, он останется в предыдущем и его увидит любой, у кого есть образ.

> **Проверь понимание:** `.env` с паролем скопирован в образ, а следующей строкой `RUN rm .env`. Пароль исчез?

<details markdown="1">
<summary>Ответ</summary>

Нет. Слой с `COPY` неизменяем, `rm` только добавляет слой, где файла нет. Достать пароль можно из предыдущего слоя (`docker history`, `docker save`). Поэтому `.env` в `.dockerignore`, а секреты передают при запуске.

</details>

### CMD, ENTRYPOINT и форма записи

`CMD` задаёт команду по умолчанию, её можно заменить при `docker run образ другая-команда`. `ENTRYPOINT` задаёт программу, к которой команда из `CMD` или из `docker run` добавляется аргументами. Для приложения обычно хватает одного `CMD`.

У обеих инструкций две формы:

- exec-форма `CMD ["python", "app.py"]`: процесс запускается напрямую и получает PID 1;
- shell-форма `CMD python app.py`: запускается `/bin/sh -c "python app.py"`, PID 1 это shell.

`docker stop` шлёт SIGTERM процессу с PID 1 и через 10 секунд SIGKILL. Shell не передаёт сигнал дочернему процессу, поэтому приложение SIGTERM не видит и убивается принудительно. В [уроке 1.4](../01-linux/04-processes-signals.md) ты видел, чем это плохо: не сброшены буферы, оборваны запросы.

> **Проверь понимание:** почему при shell-форме `docker stop` всегда занимает около 10 секунд?

<details markdown="1">
<summary>Ответ</summary>

SIGTERM получает `sh`, который его игнорирует как PID 1 без обработчика. Приложение не завершается, Docker ждёт таймаут 10 секунд и шлёт SIGKILL.

</details>

### Не root и HEALTHCHECK

Процесс в контейнере по умолчанию работает от root (uid 0). Это тот же root ядра хоста, ограниченный namespaces и capabilities, но при ошибке конфигурации побег из контейнера даёт root на хосте. Поэтому в образе создают обычного пользователя и переключаются на него инструкцией `USER`. Для «Заметок» договорено: uid и gid 10001.

`HEALTHCHECK` это команда, которую Docker периодически запускает внутри контейнера: код выхода 0 значит `healthy`, 1 значит `unhealthy`. В slim-образе нет `curl`, поэтому проверку пишут на Python из стандартной библиотеки.

## Практика

Все задания идут в `~/notes` (репозиторий проекта, приложение v3). Docker Engine из урока 4.1 работает, `docker run hello-world` проходит.

### Задание 1. Первый Dockerfile

**Цель:** собрать образ «Заметок» и запустить его.

**Предскажи:** приложение на хосте по умолчанию слушает `127.0.0.1`. Откроется ли оно с хоста, если запустить контейнер с `-p 8080:8080` и не менять `HOST`? Ответ проверь в шаге 5.

<details markdown="1">
<summary>Ответ</summary>

Не откроется. Для контейнера `127.0.0.1` это его собственная петля (loopback), а проброшенный порт приходит на другой адрес контейнера. Слушать нужно `0.0.0.0`.

</details>

**Шаги:**

1. Проверь, что каталог на месте, и подготовь `requirements.txt`. У «Заметок» v3 внешних зависимостей нет, но файл нужен, чтобы порядок слоёв был правильным уже сейчас (в уроке 4.4 появится `psycopg`):

   ```bash
   cd ~/notes
   ls app.py
   echo "# зависимости приложения (пока только стандартная библиотека)" > requirements.txt
   ```

2. Создай `.dockerignore`:

   ```bash
   cat > .dockerignore <<'IGN'
   .git
   .github
   k8s
   helm
   infra
   monitoring
   docs
   versions
   break
   .env
   __pycache__
   *.md
   IGN
   ```

3. Создай `Dockerfile`:

   ```dockerfile
   # База закреплена по минорной версии, latest не используем
   FROM python:3.13-slim

   WORKDIR /app

   # Сначала зависимости: этот слой меняется редко и живёт в кэше
   COPY requirements.txt .
   RUN pip install --no-cache-dir -r requirements.txt

   # Потом код: меняется часто, пересобирается только он
   COPY app.py .

   # Конфигурация по умолчанию: слушаем все интерфейсы контейнера
   ENV HOST=0.0.0.0 PORT=8080 NOTES_DATA=/data/notes.txt

   # Документация для человека, порт не публикует
   EXPOSE 8080

   CMD ["python", "app.py"]
   ```

4. Собери образ:

   ```bash
   docker build -t notes:0.3.0 .
   docker image ls notes
   ```

5. Запусти и проверь с хоста:

   ```bash
   docker run -d --name notes -p 8080:8080 notes:0.3.0
   curl -s localhost:8080/healthz; echo
   curl -s -X POST localhost:8080/notes -d '{"text":"из контейнера"}'; echo
   ```

**Что должно получиться:**

```text
REPOSITORY   TAG     IMAGE ID       CREATED          SIZE
notes        0.3.0   3f1c9a7b2d10   10 seconds ago   130MB
ok
{"id":1}
```

Размер и ID у тебя будут другими, порядок 120-140 МБ.

**Объясни себе:**

- Почему `EXPOSE 8080` не заменяет `-p 8080:8080`?
- Что произойдёт с заметкой после `docker rm -f notes`? (Подсказка: `/data` пока не смонтирован, это тема урока 4.3.)

**Типичные ошибки:**

- `failed to compute cache key: "/requirements.txt": not found`: файла нет в контексте сборки или он исключён в `.dockerignore`. Проверь `ls` и содержимое `.dockerignore`.
- `docker: Error response from daemon: Conflict. The container name "/notes" is already in use`: старый контейнер с таким именем. `docker rm -f notes`.
- `Bind for 0.0.0.0:8080 failed: port is already allocated`: порт занят. Хостовый `notes.service` должен быть остановлен в 4.1: `sudo systemctl disable --now notes`.

### Задание 2. Кэш слоёв и docker history

**Цель:** увидеть, как порядок инструкций определяет скорость пересборки.

**Предскажи:** ты добавишь комментарий в `app.py` и пересоберёшь. Сколько шагов будет `CACHED`, а сколько выполнится заново?

<details markdown="1">
<summary>Ответ</summary>

Всё до `COPY app.py` берётся из кэша (`FROM`, `WORKDIR`, `COPY requirements.txt`, `RUN pip`). Заново выполнится только `COPY app.py .`, остальные инструкции ниже меняют лишь метаданные и пересоздаются мгновенно.

</details>

**Шаги:**

1. Пересобери без изменений и отметь `CACHED`:

   ```bash
   docker build -t notes:0.3.0 . 2>&1 | grep -E 'CACHED|DONE|=> \['
   ```

2. Измени код и собери снова:

   ```bash
   echo "# правка для проверки кэша" >> app.py
   docker build -t notes:0.3.0 . 2>&1 | grep -E 'CACHED|=> \['
   ```

3. Убери правку: `sed -i '$ d' app.py` (на macOS `sed -i '' '$ d' app.py`).
4. Посмотри слои образа:

   ```bash
   docker history notes:0.3.0
   ```

**Что должно получиться:**

```text
 => CACHED [2/5] WORKDIR /app
 => CACHED [3/5] COPY requirements.txt .
 => CACHED [4/5] RUN pip install --no-cache-dir -r requirements.txt
 => [5/5] COPY app.py .
```

В `docker history` самые тяжёлые строки это слои базового образа, твой `COPY app.py` занимает килобайты.

**Объясни себе:**

- Что было бы, если бы `COPY . .` стоял выше `pip install`?
- Почему `ENV`, `EXPOSE` и `CMD` в `docker history` весят 0 байт?

**Типичные ошибки:**

- Кэш не срабатывает вообще: в `COPY . .` попал изменчивый файл (лог, `__pycache__`). Добавь его в `.dockerignore`.
- В выводе нет слова `CACHED`: BuildKit пишет прогресс в терминал в виде анимации. Добавь `--progress=plain`.

### Задание 3. Не root: USER и владелец /data

**Цель:** запустить сервис под uid 10001 и получить каталог данных, доступный этому пользователю.

**Предскажи:** сейчас `docker exec notes id` покажет `uid=0(root)`. А сможет ли приложение писать в `/data`, если добавить только `USER 10001:10001`, но не создать каталог?

<details markdown="1">
<summary>Ответ</summary>

Нет. `/data` не существует, а создать каталог в `/` обычный пользователь не может. Каталог нужно создать и сменить владельца до `USER`, пока ты ещё root.

</details>

**Шаги:**

1. Проверь текущего пользователя:

   ```bash
   docker exec notes id
   ```

2. Дополни `Dockerfile`: после `COPY app.py .` и перед `ENV` добавь пользователя и каталог данных, а перед `CMD` переключись на него:

   ```dockerfile
   # Системный пользователь без пароля и оболочки, uid/gid как договорено в курсе
   RUN groupadd --system --gid 10001 notes \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin notes \
    && mkdir /data && chown 10001:10001 /data

   USER 10001:10001
   ```

3. Добавь `HEALTHCHECK` перед `CMD` (Python-однострочник, `curl` в slim нет):

   ```dockerfile
   HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
     CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz')"
   ```

4. Пересобери и перезапусти:

   ```bash
   docker build -t notes:0.3.0 .
   docker rm -f notes
   docker run -d --name notes -p 8080:8080 notes:0.3.0
   docker exec notes id
   curl -s -X POST localhost:8080/notes -d '{"text":"под uid 10001"}'; echo
   docker exec notes ls -ld /data
   ```

5. Подожди 15 секунд и посмотри статус:

   {% raw %}
   ```bash
   docker ps --format 'table {{.Names}}\t{{.Status}}'
   ```
   {% endraw %}

**Что должно получиться:**

```text
uid=10001(notes) gid=10001(notes) groups=10001(notes)
{"id":1}
drwxr-xr-x 2 notes notes 4096 Sep 29 10:00 /data
NAMES   STATUS
notes   Up 20 seconds (healthy)
```

**Объясни себе:**

- Почему `USER` стоит после `RUN mkdir`, а не до?
- Чем `HEALTHCHECK` полезнее, чем «контейнер в статусе Up»?

**Типичные ошибки:**

- `PermissionError: [Errno 13] Permission denied: '/data'`: каталог принадлежит root или `USER` стоит раньше `chown`. Поменяй порядок.
- Статус `Up ... (unhealthy)`: проверка не проходит, чаще всего приложение слушает не тот порт. {% raw %}`docker inspect --format '{{json .State.Health}}' notes`{% endraw %} покажет вывод последних проб.
- `useradd: UID 10001 is not unique`: такой uid уже есть в базовом образе. Выбери другой или удали конфликт, но договорённость курса это 10001.

### Задание 4. Сигналы: exec-форма против shell-формы

**Цель:** измерить, как форма `CMD` влияет на остановку.

**Предскажи:** сколько секунд займёт `docker stop` при exec-форме, а сколько при shell-форме?

<details markdown="1">
<summary>Ответ</summary>

Exec-форма: около секунды или меньше, если приложение обрабатывает SIGTERM. Shell-форма: около 10 секунд, затем SIGKILL. Если приложение SIGTERM не обрабатывает даже в exec-форме, оно тоже проживёт таймаут: у PID 1 нет обработчика по умолчанию. Сервер «Заметок» обрабатывает SIGTERM (это сделано в теме 1).

</details>

**Шаги:**

1. Замерь остановку текущего контейнера:

   ```bash
   time docker stop notes
   ```

2. Временно собери вариант с shell-формой (образ с другим тегом, чтобы не трогать основной):

   ```bash
   sed 's|^CMD \["python", "app.py"\]|CMD python app.py|' Dockerfile > /tmp/Dockerfile.shell
   docker build -f /tmp/Dockerfile.shell -t notes:shell .
   docker run -d --name notes-shell notes:shell
   docker exec notes-shell ps -o pid,args
   time docker stop notes-shell
   ```

3. Убери за собой:

   ```bash
   docker rm notes notes-shell
   docker image rm notes:shell
   rm /tmp/Dockerfile.shell
   ```

**Что должно получиться:**

```text
notes

real    0m0.5s
```

для exec-формы и для shell-формы `PID 1` это `/bin/sh -c python app.py`, а `real` около `0m10.2s`. Если `ps` в образе отсутствует, ту же информацию даёт `docker top notes-shell`.

**Объясни себе:**

- Что именно получил процесс с PID 1 в shell-форме и почему приложение об этом не узнало?
- К чему приводит SIGKILL при остановке в Kubernetes (шаг ко второй теме курса, подробнее в [уроке 5.7](../05-kubernetes/07-probes-resources-rollouts.md))?

**Типичные ошибки:**

- `OCI runtime exec failed: exec: "ps": executable file not found in $PATH`: в slim-образе нет `ps`. Используй `docker top <контейнер>`.
- `sed: -e expression #1, char ...: unterminated s command`: неэкранированные скобки или кавычки. Скопируй команду точно.

### Задание 5. Шаг проекта: образ notes:0.3.0 и тег v0.3.0

**Цель:** зафиксировать Dockerfile в репозитории и выпустить версию 0.3.0.

**Шаги:**

1. Финальный `Dockerfile` должен выглядеть так:

   ```dockerfile
   FROM python:3.13-slim

   WORKDIR /app

   COPY requirements.txt .
   RUN pip install --no-cache-dir -r requirements.txt

   COPY app.py .

   # Пользователь и каталог данных создаются до USER
   RUN groupadd --system --gid 10001 notes \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin notes \
    && mkdir /data && chown 10001:10001 /data

   ENV HOST=0.0.0.0 PORT=8080 NOTES_DATA=/data/notes.txt

   USER 10001:10001

   EXPOSE 8080

   HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
     CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz')"

   CMD ["python", "app.py"]
   ```

   Эталон проекта: [project/notes/Dockerfile](https://github.com/distinguished-sre/devops/tree/devops/project/notes/Dockerfile).

2. Собери, проверь и посмотри размер:

   ```bash
   docker build -t notes:0.3.0 .
   docker run --rm -d --name notes -p 8080:8080 notes:0.3.0
   sleep 3; curl -s localhost:8080/; docker stop notes
   docker image ls notes:0.3.0
   ```

3. Закоммить и поставь тег, как в [уроке 3.5](../03-git-ci/05-release-flow.md):

   ```bash
   git switch -c feat/dockerfile
   git add Dockerfile .dockerignore requirements.txt
   git commit -m "Добавить Dockerfile и .dockerignore"
   git switch main && git merge --no-ff feat/dockerfile
   git tag -a v0.3.0 -m "Образ notes:0.3.0"
   git push origin main v0.3.0
   ```

**Что должно получиться:**

```text
Notes service v3
notes
REPOSITORY   TAG     IMAGE ID       CREATED          SIZE
notes        0.3.0   3f1c9a7b2d10   40 seconds ago   130MB
```

**Объясни себе:**

- Почему версия образа `0.3.0` совпадает с git-тегом `v0.3.0`?
- Что в проекте пока не решено? (Данные лежат в анонимном томе и пропадут вместе с контейнером: это делает урок 4.3.)

**Типичные ошибки:**

- `error: pathspec 'main' did not match any file(s) known to git`: ветка называется иначе. `git branch --show-current`.
- `! [rejected] main -> main (protected branch hook declined)`: main защищена, как настроено в 3.2. Открой PR из `feat/dockerfile` и поставь тег после слияния.
- `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`: демон не запущен или нет прав. `sudo systemctl start docker`, проверь группу `docker`.

## Сломай и почини

Запусти сценарий (не читай скрипт, иначе пропадёт смысл упражнения). Он готовит сломанную сборку или контейнер:

```bash
bash project/notes/break/4.2/break.sh 1
```

Сценарии 1, 2 и 3 идут по порядку, `random` выбирает любой.

### Симптом

Одно из трёх:

- сборка падает с `COPY failed` или `not found` на строке с `COPY`;
- контейнер `Up`, `docker logs` показывает, что сервер запущен, а `curl localhost:8080` с хоста возвращает `Connection reset by peer` или `Empty reply from server`;
- контейнер стартует и сразу падает, в логах `Permission denied` при записи в `/data`.

### Гипотезы

Для каждого симптома запиши по две гипотезы и одну проверку, которая их различает. Например, для второго: слушает `127.0.0.1` внутри контейнера, либо порт не опубликован через `-p`.

### Проверки

```bash
docker build --progress=plain -t notes:test . 2>&1 | tail -20   # какой шаг упал
docker port notes                                                # опубликован ли порт
docker exec notes env | grep -E 'HOST|PORT'                      # какой адрес слушаем
docker exec notes id                                             # под кем работаем
docker exec notes ls -ld /data                                   # владелец каталога
docker logs notes                                                # что говорит приложение
```

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

**1. `COPY failed: file not found in build context` или `"/app.py": not found`.** Причина: файл лежит вне контекста либо перечислен в `.dockerignore` (например, туда попало `*.py` или `app.py`). Проверка: `cat .dockerignore` и `ls`. Исправление: убрать файл из `.dockerignore`, собрать снова.

**2. Контейнер работает, с хоста не открывается.** Причина: `HOST` не равен `0.0.0.0` (в `ENV` пропущен или переопределён `-e HOST=127.0.0.1`), приложение слушает только петлю контейнера. Проверка: `docker exec notes env | grep HOST`. Исправление: `ENV HOST=0.0.0.0` в Dockerfile, пересборка, перезапуск. Порт `EXPOSE` тут ни при чём.

**3. `PermissionError: [Errno 13] Permission denied: '/data'`.** Причина: каталог создан от root после `USER` или смонтирован том с владельцем root. Проверка: `docker exec notes ls -ld /data`. Исправление: `mkdir` и `chown 10001:10001` до `USER`; для тома, смонтированного снаружи, сменить владельца тома (подробно в [уроке 4.3](03-storage-networks.md)).

</details>

## Вопросы с собеседований

### 1. [junior] Чем CMD отличается от ENTRYPOINT?

`ENTRYPOINT` это программа, которая запускается всегда, `CMD` это аргументы по умолчанию к ней или команда по умолчанию, если `ENTRYPOINT` нет. `docker run образ команда` заменяет `CMD`, а `ENTRYPOINT` заменяется только флагом `--entrypoint`. Для обычного приложения хватает `CMD`, `ENTRYPOINT` берут для образов-утилит.

**Что хотят услышать:** что `CMD` перезаписывается аргументами `docker run`, `ENTRYPOINT` нет; комбинация «ENTRYPOINT плюс CMD как аргументы по умолчанию».

**Красный флаг:** «это одно и то же, просто два способа».

### 2. [middle] `docker stop` висит 10 секунд, потом контейнер убивается. Почему и как чинить?

Скорее всего, приложение не получает SIGTERM: `CMD` в shell-форме, PID 1 это `/bin/sh`, он сигнал не пробрасывает. Перехожу на exec-форму `CMD ["python","app.py"]`. Если приложение всё равно не реагирует, проверяю обработчик SIGTERM в коде: у PID 1 нет обработчиков по умолчанию.

**Что хотят услышать:** exec против shell, PID 1, таймаут 10 секунд и SIGKILL, `--init` или `tini` как запасной вариант, `exec` в entrypoint-скриптах.

**Красный флаг:** «увеличу таймаут `-t 60`» без поиска причины.

### 3. [middle] Сборка занимает 5 минут после любой правки одной строки кода. Что смотришь?

Порядок слоёв: скорее всего, `COPY . .` стоит до установки зависимостей, и каждый коммит перекачивает пакеты. Разделяю: сначала `COPY requirements.txt` и `RUN pip install`, потом код. Смотрю `--progress=plain`, что помечено `CACHED`, и проверяю `.dockerignore`: изменчивые файлы в контексте тоже ломают кэш.

**Что хотят услышать:** правило «редко меняющееся выше», инвалидация всех слоёв ниже изменённого, `.dockerignore`, cache mount для pip как продвинутая мера.

**Красный флаг:** «добавлю `--no-cache`, чтобы было надёжнее».

### 4. [junior] Зачем нужен `.dockerignore`?

Он исключает файлы из контекста сборки. Это ускоряет `docker build` (не гоняется `.git` и данные), стабильнее кэш и главное не даёт секретам вроде `.env` попасть в слои образа.

**Что хотят услышать:** контекст сборки отправляется демону целиком, `.git` и `.env`, влияние на кэш `COPY . .`.

**Красный флаг:** «чтобы образ был меньше» и ничего про секреты.

### 5. [middle] В образ случайно попал пароль. Ты удалил его следующей командой `RUN rm`. Что не так?

Файл остаётся в предыдущем слое, образ это набор слоёв. Любой, кто получил образ, достанет секрет через `docker save` или `docker history`. Пароль нужно считать скомпрометированным и сменить, образ пересобрать без него, а в будущем передавать секреты при запуске, а не в сборке.

**Что хотят услышать:** слои неизменяемы, ротация секрета, `.dockerignore`, BuildKit secret mounts, ошибка `ARG` для секретов (виден в history).

**Красный флаг:** «удалю образ локально, и всё» без ротации.

### 6. [junior] Почему контейнер не стоит запускать от root?

Root в контейнере это uid 0 хоста, ограниченный namespaces и capabilities. Уязвимость приложения или ошибка конфигурации (смонтированный docker.sock, `--privileged`) даёт атакующему root на хосте. Поэтому в образе `USER` с непривилегированным uid, а каталоги данных отдают этому uid.

**Что хотят услышать:** минимальные права, `USER 10001`, `chown` до `USER`, дальше `--cap-drop`, `--read-only`, `runAsNonRoot` в Kubernetes.

**Красный флаг:** «в контейнере всё равно изолировано, root там безопасен».

### 7. [middle] Контейнер запущен, `docker logs` чистые, а с хоста порт не открывается. Твои шаги?

Проверяю `docker port` и `docker ps`: опубликован ли порт (`-p`). Потом `docker exec ... env` и логи: на каком адресе слушает приложение. Слушает `127.0.0.1` внутри контейнера, нужно `0.0.0.0`. Дальше firewall хоста и занятость порта.

**Что хотят услышать:** loopback контейнера отличается от хоста, `EXPOSE` не публикует, `ss -tlnp` внутри и снаружи.

**Красный флаг:** «пересоздам контейнер, вдруг поможет».

### 8. [middle] В контейнере `Permission denied` при записи в каталог данных. Причины?

Приложение работает под uid 10001, а владелец каталога root: либо `mkdir` создан после `USER`, либо смонтирован том или bind mount с другим владельцем. Смотрю `docker exec id` и `ls -ld`. Чиню: `chown` в Dockerfile до `USER` либо владелец тома на хосте.

**Что хотят услышать:** сверка uid процесса и владельца каталога, различие между слоем образа и монтируемым томом, `fsGroup` в Kubernetes.

**Красный флаг:** `chmod 777` или запуск от root ради «починки».

### 9. [junior] Чем плох тег `latest`?

Это обычный тег без гарантий, он указывает на последний выпущенный образ, и завтра тот же тег даст другой код. Сборка и откат становятся невоспроизводимы. В проде используют конкретную версию, а для полной неизменности digest.

**Что хотят услышать:** воспроизводимость, откат на предыдущую версию, тег совпадает с semver, digest `@sha256:...` как неизменяемая ссылка.

**Красный флаг:** «latest это всегда самая свежая и безопасная версия».

### 10. [middle] Как уменьшить образ?

Взять slim или distroless базу, не ставить лишнего, `--no-cache-dir` для pip, `.dockerignore`, объединять `RUN` с очисткой в одном слое, multi-stage сборка. Размер смотрю через `docker history`, чтобы найти тяжёлые слои. Multi-stage разберём в [уроке 4.7](07-images-registry.md).

**Что хотят услышать:** удаление в том же слое, где создано, multi-stage, выбор базы с оглядкой на совместимость (musl у Alpine), проверка через `docker history`.

**Красный флаг:** «просто удалю файлы в конце Dockerfile».

## Проверено на версиях

- Ubuntu: 24.04 LTS и 26.04 LTS
- Docker Engine: версия не закреплена, проверь актуальную версию на странице проекта
- BuildKit: входит в Docker Engine, включён по умолчанию
- Базовый образ: `python:3.13-slim`
- Приложение «Заметки»: v3, образ `notes:0.3.0`

## Итог урока: ты умеешь

- [ ] умею написать Dockerfile для Python-сервиса с закреплённой базой и exec-формой `CMD`
- [ ] умею расположить слои так, чтобы правка кода не пересобирала зависимости, и доказать это по `CACHED`
- [ ] умею исключить лишнее и секреты из контекста через `.dockerignore`
- [ ] умею запустить сервис под uid 10001 и выдать ему доступ к каталогу данных
- [ ] умею замерить `docker stop` и объяснить разницу exec- и shell-формы
- [ ] умею добавить `HEALTHCHECK` на стандартной библиотеке Python и прочитать статус в `docker ps`
- [ ] умею диагностировать три поломки: `COPY failed`, недоступный порт, `Permission denied` в `/data`

**Дальше:** [Урок 4.3: Тома и сети Docker](03-storage-networks.md)
