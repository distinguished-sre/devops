---
layout: lesson
title: "Compose: «Заметки» и PostgreSQL"
topic: 4
lesson: "4.5"
time: "2.5 ч"
---

## Зачем это нужно

В уроке 4.4 ты поднимал PostgreSQL и «Заметки» двумя длинными командами `docker run`: сеть, том, переменные, порядок запуска, всё в голове или в истории shell. Через неделю ты не вспомнишь ни флагов, ни порядка. На работе такой стенд описывают одним файлом `compose.yml` (Docker Compose), кладут в git, и любой коллега поднимает его одной командой.

Compose решает и вторую проблему: контейнер БД «запущен» не значит «готов принимать запросы». Без проверки готовности приложение стартует раньше базы и падает.

Шаг проекта: «Заметки» и PostgreSQL описаны в `compose.yml`, пароль лежит в `.env` (вне git), приложение стартует только после того, как БД прошла healthcheck.

## Что нужно знать

- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - что делает `docker compose stop` (SIGTERM, потом SIGKILL).
- [Урок 2.1: адреса и порты](../02-network/01-addresses-routes.md) - чем `127.0.0.1:8080` отличается от `0.0.0.0:8080`.
- [Урок 3.1: git](../03-git-ci/01-git-basics.md) - `.gitignore`, коммит.
- [Урок 4.2: Dockerfile](02-dockerfile.md) - образ «Заметок» собирается из `Dockerfile` в корне репозитория.
- [Урок 4.3: тома и сети](03-storage-networks.md) - именованный том, пользовательская сеть с DNS по имени.
- [Урок 4.4: SQL и PostgreSQL](04-sql-postgres-basics.md) - `STORE=postgres`, `DATABASE_URL`, `/readyz`, `psql`.

## Теория

### Что такое Compose и что в нём описывается

Docker Compose (далее просто Compose) читает файл `compose.yml` и приводит Docker к описанному состоянию: создаёт сеть, тома, контейнеры. Это декларативный подход: ты описываешь, что должно быть, а не последовательность команд. Повторный `docker compose up -d` не перезапускает всё подряд, а пересоздаёт только то, что изменилось в описании.

У файла три главных секции верхнего уровня:

- `services` - контейнеры (у нас `notes` и `db`). Имя сервиса становится DNS-именем в сети.
- `volumes` - именованные тома (named volume), которыми управляет Docker.
- `networks` - сети. Если ничего не описать, Compose создаст сеть по умолчанию (default), и все сервисы окажутся в ней.

Ключа `version:` в файле нет: современный Compose его игнорирует и ругается на него. Команда всегда `docker compose` (через пробел, это плагин Docker); старый `docker-compose` через дефис не используется.

Проект (project) в терминах Compose это набор ресурсов под одним именем. Имя по умолчанию равно имени каталога, то есть `notes`. Отсюда имена вида `notes-db-1` (контейнер) и `notes_pgdata` (том). Сеть мы назовём явно: `notes-net`, потому что позже к ней подключится мониторинг (урок 8.2).

> **Проверь понимание:** ты запустил `docker compose up -d` в каталоге `~/notes`, потом переименовал каталог в `~/notes2` и снова запустил `up -d`. Что произойдёт?

<details markdown="1">
<summary>Ответ</summary>

Имя проекта возьмётся из нового имени каталога (`notes2`), и Compose создаст второй, параллельный набор контейнеров и томов (`notes2-db-1`, `notes2_pgdata`). Старый стенд останется работать. Чтобы имя не зависело от каталога, задают `name:` в файле или флаг `-p`.

</details>

### Готовность не равна запуску: healthcheck и depends_on

Контейнер `db` переходит в состояние `running` через долю секунды после старта, но PostgreSQL при первом запуске ещё инициализирует каталог данных и несколько секунд не принимает соединения. Приложение, которое пришло в этот момент, получает `connection refused` и падает.

Простой `depends_on: [db]` гарантирует только порядок запуска контейнеров, но не готовность. Правильная связка из двух частей:

1. `healthcheck` у `db`: команда, которую Docker периодически выполняет внутри контейнера. Код выхода 0 значит «здоров». Для PostgreSQL это `pg_isready -U notes -d notes`: утилита спрашивает сервер, готов ли он принимать соединения.
2. `depends_on` с `condition: service_healthy` у `notes`: Compose не запустит приложение, пока БД не станет `healthy`.

У healthcheck четыре параметра: `interval` (как часто проверять), `timeout` (сколько ждать ответа), `retries` (сколько неудач подряд до статуса `unhealthy`), `start_period` (время на старт, в течение которого неудачи не считаются).

Это защита только на старте. Если БД упадёт позже, `depends_on` ничего не сделает: приложение должно само переживать потерю соединения (у нас `/readyz` покажет 503, и оркестратор снимет трафик, подробнее в уроке 5.7).

> **Проверь понимание:** `db` стал `healthy`, потом упал и перезапустился. Перезапустит ли Compose `notes` из-за `depends_on`?

<details markdown="1">
<summary>Ответ</summary>

Нет. `depends_on` работает только при запуске стека (`up`). Дальше каждый контейнер живёт по своей политике `restart`. Соединение с БД приложение должно восстанавливать само; в нашем `app.py` соединение открывается на каждый запрос, поэтому после возврата БД заметки снова работают без перезапуска.

</details>

### Переменные и секреты: .env и подстановка

Compose автоматически читает файл `.env` рядом с `compose.yml` и подставляет значения в конструкции `${ИМЯ}` внутри самого `compose.yml`. Так пароль не пишется в файл, который лежит в git:

```yaml
environment:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
```

Полезные формы: `${VAR:-значение}` (значение по умолчанию, если переменная не задана или пуста) и `${VAR:?сообщение}` (остановиться с ошибкой, если не задана). Если переменной нет вовсе, Compose молча подставит пустую строку и напишет предупреждение `variable is not set. Defaulting to a blank string.`; PostgreSQL с пустым паролем откажется стартовать.

В git попадает `.env.example` с заглушкой `CHANGE_ME`, а настоящий `.env` внесён в `.gitignore`. Это компромисс, а не решение: пароль всё равно лежит открытым текстом на диске. Нормальное хранение секретов разберём в теме 9 (урок 9.1); здесь долг фиксируется явно.

Важная ловушка: `POSTGRES_PASSWORD` образ `postgres` читает только при инициализации пустого каталога данных. Если том уже содержит базу, смена пароля в `.env` ничего не меняет (см. «Сломай и почини»).

> **Проверь понимание:** пароль в `DATABASE_URL` и в `POSTGRES_PASSWORD` должен совпадать. Почему для генерации пароля удобнее `openssl rand -hex 16`, чем `openssl rand -base64 16`?

<details markdown="1">
<summary>Ответ</summary>

Пароль вставляется в URL. Символы `/`, `+`, `=` из base64 в URL имеют особый смысл и сломают разбор строки подключения (нужно кодировать процентами). Hex состоит только из `0-9a-f` и безопасен в URL.

</details>

### Жизненный цикл и данные

Основные команды:

| Команда | Что делает |
|---|---|
| `docker compose up -d` | создать и запустить недостающее, пересоздать изменившееся |
| `docker compose ps` | состояние сервисов и healthcheck |
| `docker compose exec db psql ...` | команда внутри работающего контейнера |
| `docker compose down` | удалить контейнеры и сеть, тома остаются |
| `docker compose down -v` | то же плюс удалить тома: данные пропадают |
| `docker compose config` | итоговый файл после подстановки |

Том `pgdata` живёт отдельно от контейнера, поэтому пересоздание `db` данные не трогает.

Образ `postgres:18` хранит данные в `/var/lib/postgresql` (в версии 17 и старше это был `/var/lib/postgresql/data`). Том монтируется в родительский каталог: так работает и апгрейд между мажорными версиями через `pg_upgrade`. Монтировать том по старому пути `.../data` в версии 18 нельзя: данные окажутся в анонимном томе и потеряются при пересоздании.

Порты: `db` не публикуется наружу вообще: приложение достаёт её по имени `db` внутри сети `notes-net`. Приложение публикуется как `127.0.0.1:8080:8080`: только с этой машины. Запись `8080:8080` без адреса откроет порт на всех интерфейсах (Docker при этом обходит правила ufw, см. урок 2.7).

> **Проверь понимание:** зачем `db` без секции `ports`, если ты хочешь смотреть в неё `psql` с хоста?

<details markdown="1">
<summary>Ответ</summary>

Порт наружу не нужен: `docker compose exec db psql ...` заходит внутрь контейнера. Публикация 5432 открывает БД всем, кто достанет до хоста, и конфликтует с локальным PostgreSQL.

</details>

## Практика

Стартовое состояние: репозиторий `~/notes` из урока 4.4 (app v4, `Dockerfile`, `requirements.txt`, `db/schema.sql`). Сначала убери стенд из `docker run`, иначе имена и порты будут заняты:

```bash
cd ~/notes
# имена контейнеров из урока 4.4; если у тебя другие, посмотри docker ps -a
docker rm -f notes-db notes-app 2>/dev/null
# ручная сеть из 4.3: Compose создаст свою с тем же именем и будет её вести сам
docker network rm notes-net 2>/dev/null
docker ps -a
```

### Задание 1. База в Compose и healthcheck

**Цель:** описать `db` в `compose.yml`, вынести пароль в `.env`, увидеть переход `starting` -> `healthy`.

**Предскажи:** сколько секунд `db` будет в статусе `starting` при первом запуске: 0, около 5-10 или больше минуты? И изменится ли это при втором запуске?

<details markdown="1">
<summary>Ответ</summary>

Около 5-10 секунд: при первом запуске PostgreSQL инициализирует каталог данных. При втором (том уже с данными) готовность приходит быстрее, за 2-3 секунды.

</details>

**Шаги:**

1. Создай `.env.example` и `.env`, закрой `.env` от git:

```bash
cat > .env.example <<'EOT'
POSTGRES_PASSWORD=CHANGE_ME
DATABASE_URL=postgresql://notes:CHANGE_ME@db:5432/notes
APP_VERSION=
EOT

# генерируем пароль и подставляем вместо CHANGE_ME (без sed -i, поэтому одинаково на Linux и macOS)
PW=$(openssl rand -hex 16)
sed "s/CHANGE_ME/${PW}/g" .env.example > .env
chmod 600 .env

echo ".env" >> .gitignore
git check-ignore -v .env
```

2. Создай `compose.yml` с одним сервисом:

```yaml
services:
  db:
    image: postgres:18
    environment:
      POSTGRES_DB: notes
      POSTGRES_USER: notes
      # значение берётся из .env, в самом файле пароля нет
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      # postgres:18 хранит данные в /var/lib/postgresql (не в .../data)
      - pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U notes -d notes"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s
    restart: unless-stopped

volumes:
  pgdata:

networks:
  default:
    # явное имя сети: к ней позже подключится мониторинг
    name: notes-net
```

3. Запусти и следи за статусом:

```bash
docker compose up -d
docker compose ps
sleep 8
docker compose ps
```

**Что должно получиться:**

```text
.gitignore:1:.env	.env
NAME          IMAGE         COMMAND                  SERVICE   CREATED         STATUS                            PORTS
notes-db-1    postgres:18   "docker-entrypoint.s…"   db        3 seconds ago   Up 2 seconds (health: starting)   5432/tcp

NAME          IMAGE         COMMAND                  SERVICE   CREATED         STATUS                    PORTS
notes-db-1    postgres:18   "docker-entrypoint.s…"   db        11 seconds ago  Up 10 seconds (healthy)   5432/tcp
```

Номер строки в `.gitignore` у тебя может быть другим. `5432/tcp` без стрелки `->` означает: порт объявлен образом, но на хост не опубликован.

**Объясни себе:**

- Почему в `compose.yml` нет ни одного настоящего пароля, а контейнер всё же его получил?
- Что делает `start_period` и что было бы без него на медленном диске?

**Типичные ошибки:**

- `yaml: line 9: found character that cannot start any token`: в отступах табуляция, нужны пробелы.
- `WARN[0000] The "POSTGRES_PASSWORD" variable is not set. Defaulting to a blank string.`: `.env` лежит не рядом с `compose.yml` или запуск не из каталога проекта. Сделай `pwd` и `ls -a`.
- `Error response from daemon: network notes-net was found but has incorrect label com.docker.compose.network`: сеть осталась от ручного `docker network create` в уроке 4.3. Удали её командой `docker network rm notes-net` и повтори `up`.

### Задание 2. Добавляем приложение и порядок старта

**Цель:** подключить `notes`, дождаться БД через `service_healthy`, записать и прочитать заметку.

**Предскажи:** что покажет `docker compose ps` сразу после `up -d`, пока `db` ещё `starting`: будет ли `notes` в списке и в каком состоянии? Что произойдёт с `depends_on` без `condition`?

<details markdown="1">
<summary>Ответ</summary>

С `condition: service_healthy` Compose сам подождёт `db` и только потом создаст `notes`; команда `up -d` вернётся, когда `db` станет healthy. Без `condition` (простой список) `notes` создастся сразу после `db`, и приложение может получить `connection refused` (см. «Сломай и почини», сценарий 2).

</details>

**Шаги:**

1. Добавь сервис `notes` в `compose.yml` первым в секции `services` (`db`, `volumes` и `networks` остаются как в задании 1):

```yaml
services:
  notes:
    # образ собирается из Dockerfile в корне репозитория (урок 4.2)
    build: .
    environment:
      STORE: postgres
      DATABASE_URL: ${DATABASE_URL}
      APP_VERSION: ${APP_VERSION:-dev}
    ports:
      # только с этой машины; наружу порт не открыт
      - "127.0.0.1:8080:8080"
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  db:
    # ... без изменений
```

2. Собери образ (в нём теперь нужен `psycopg` из `requirements.txt`) и запусти:

```bash
docker compose up -d --build
docker compose ps
```

3. Проверь приложение и БД:

```bash
curl -s -i http://127.0.0.1:8080/readyz | head -n 1
curl -s -X POST http://127.0.0.1:8080/notes -d '{"text":"первая заметка из compose"}'
echo
curl -s http://127.0.0.1:8080/notes
echo
docker compose exec db psql -U notes -d notes -c 'select id, text from notes order by id'
```

**Что должно получиться:**

```text
NAME           IMAGE         COMMAND                  SERVICE   CREATED          STATUS                    PORTS
notes-db-1     postgres:18   "docker-entrypoint.s…"   db        20 seconds ago   Up 19 seconds (healthy)   5432/tcp
notes-notes-1  notes-notes   "python app.py"          notes     9 seconds ago    Up 8 seconds              127.0.0.1:8080->8080/tcp

HTTP/1.1 200 OK
{"id":1}
[{"id":1,"text":"первая заметка из compose","created_at":"2026-09-29T10:00:00+00:00"}]
 id |             text
----+-------------------------------
  1 | первая заметка из compose
(1 row)
```

Время в `created_at` у тебя будет своё. Приложение видит БД по имени `db`: это DNS Docker в сети `notes-net`, тот же механизм, что в уроке 4.3.

**Объясни себе:**

- Почему в `DATABASE_URL` хост `db`, а не `localhost` и не `127.0.0.1`?

**Типичные ошибки:**

- `psycopg.OperationalError: connection failed: connection to server at "127.0.0.1", port 5432 failed: Connection refused`: в `DATABASE_URL` вместо `db` стоит `localhost`. Внутри контейнера `localhost` это сам контейнер.
- `ModuleNotFoundError: No module named 'psycopg'` в логах `notes`: образ собран до появления `requirements.txt`. Запусти `docker compose up -d --build`.
- `Bind for 127.0.0.1:8080 failed: port is already allocated`: порт занят старым контейнером или хост-сервисом из урока 4.1. Найди владельца: `sudo ss -ltnp | grep 8080`.

### Задание 3. Жизненный цикл: где живут данные

**Цель:** увидеть на практике разницу `down` и `down -v`, поведение приложения при остановленной БД.

**Предскажи:** после `docker compose down` и нового `up -d` заметка останется? А после `down -v`? Что вернёт `/readyz`, если остановить только `db`?

<details markdown="1">
<summary>Ответ</summary>

После `down` заметка останется: том `pgdata` не удалялся. После `down -v` том удалён, база создаётся заново пустой, `GET /notes` вернёт `[]`. Если остановить `db`, `/readyz` вернёт 503 (приложение не достаёт БД), а `/healthz` продолжит отвечать 200: процесс жив, но не готов.

</details>

**Шаги:**

```bash
# 1. пересоздаём контейнеры, том остаётся
docker compose down
docker volume ls | grep pgdata
docker compose up -d
curl -s http://127.0.0.1:8080/notes
echo

# 2. останавливаем только БД
docker compose stop db
curl -s -o /dev/null -w "readyz=%{http_code}\n" http://127.0.0.1:8080/readyz
curl -s -o /dev/null -w "healthz=%{http_code}\n" http://127.0.0.1:8080/healthz
docker compose start db
sleep 6
curl -s -o /dev/null -w "readyz=%{http_code}\n" http://127.0.0.1:8080/readyz

# 3. сносим вместе с данными
docker compose down -v
docker compose up -d
curl -s http://127.0.0.1:8080/notes
echo
```

**Что должно получиться:**

```text
local     notes_pgdata
[{"id":1,"text":"первая заметка из compose","created_at":"2026-09-29T10:00:00+00:00"}]
readyz=503
healthz=200
readyz=200
[]
```

Строка `[]` в конце означает, что данные удалены `down -v`. Первая команда `curl` после `up -d` может вернуть ошибку соединения, если приложение ещё стартует: подожди секунду и повтори.

**Объясни себе:**

- Почему `/healthz` остался 200, а `/readyz` стал 503? Какую из двух проб надо использовать для перезапуска, а какую для снятия трафика?

**Типичные ошибки:**

- `no configuration file provided: not found`: ты не в каталоге с `compose.yml`. Перейди в `~/notes` или укажи файл флагом `-f`.
- `dependency failed to start: container notes-db-1 is unhealthy`: `db` не прошла healthcheck за отведённые попытки. Смотри `docker compose logs db`.

### Задание 4. Шаг проекта: стенд «Заметки» в git

**Цель:** зафиксировать в репозитории `compose.yml` и `.env.example`, убедиться, что пароль не попал в историю.

**Предскажи:** что покажет `git status` после `git add compose.yml .env.example .gitignore`: попадёт ли в список `.env`? А что покажет `docker compose config` про пароль?

<details markdown="1">
<summary>Ответ</summary>

`.env` в список не попадёт (он в `.gitignore`). `docker compose config` печатает итоговый файл уже с подставленным паролем: это удобно для отладки, но вывод нельзя вставлять в тикеты и чаты.

</details>

**Шаги:**

```bash
docker compose config --quiet && echo "compose.yml корректен"

git add compose.yml .env.example .gitignore
git status --short
git ls-files | grep -c '^.env$' || true

git commit -m "Compose: Заметки и PostgreSQL, пароль в .env"
```

**Что должно получиться:**

```text
compose.yml корректен
A  .env.example
M  .gitignore
A  compose.yml
0
```

Состояние проекта после урока: `compose.yml` (сервисы `notes` и `db`), `.env.example`, `.env` в `.gitignore`, сеть `notes-net`, том `pgdata`, приложение на `127.0.0.1:8080`, БД только внутри сети. Открытый долг: пароль лежит в `.env` открытым текстом, для платформы он закроется в уроке 9.2. Сверить себя можно с [эталоном](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Объясни себе:**

- Если `.env` случайно попал в коммит, достаточно ли `git rm`? Что делать с уже утёкшим паролем?

**Типичные ошибки:**

- `The following paths are ignored by one of your .gitignore files: .env`: ты пытаешься добавить `.env` через `git add .env`. Так и задумано, не используй `-f`.
- Пароль в `DATABASE_URL` не совпадает с `POSTGRES_PASSWORD`: приложение получит `password authentication failed`. Генерируй оба значения одной подстановкой, как в задании 1.

## Сломай и почини

Скачай скрипт поломки и запусти нужный сценарий. Читать скрипт не нужно: цель в том, чтобы найти причину по симптомам. Перед этим закоммить рабочее состояние (задание 4), тогда откат это `git checkout -- .` плюс `docker compose down`.

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/4.5/break.sh
bash break.sh 1     # номер сценария 1, 2 или 3
```

Сценарии: 1 - старый том со старым паролем, 2 - приложение стартует раньше БД, 3 - порт 5432 занят. Для каждого пройди четыре шага: симптом, гипотезы, проверки, исправление. Начни с сценария 1.

### Симптом

Сценарий 1: ты сменил `POSTGRES_PASSWORD` в `.env`, выполнил `docker compose up -d`, но `notes` не подключается, `/readyz` отдаёт 503. Сценарий 2: после `down -v` и `up -d` приложение сразу падает и уходит в перезапуски. Сценарий 3: `up -d` не запускает `db`.

### Гипотезы

Запиши до проверок, что может быть причиной: неверный пароль, БД не готова, БД не та, сеть или DNS, порт занят.

### Проверки

```bash
docker compose ps -a
docker compose logs --tail=30 notes
docker compose logs --tail=30 db
docker compose config | grep -E 'PASSWORD|DATABASE_URL'
sudo ss -ltnp | grep 5432
```


### Исправление

<details markdown="1">
<summary>Разбор всех сценариев</summary>

**Сценарий 1. Старый том со старым паролем.** Симптом в логах `notes`:

```text
psycopg.OperationalError: connection failed: connection to server at "172.19.0.2", port 5432 failed: FATAL:  password authentication failed for user "notes"
```

В логах `db` при перезапуске нет инициализации, зато есть строка `PostgreSQL Database directory appears to contain a database; Skipping initialization`. Причина: образ `postgres` применяет `POSTGRES_PASSWORD` только при создании пустого каталога данных. Том `pgdata` уже содержит базу со старым паролем, новое значение из `.env` игнорируется. Исправление зависит от ценности данных. Данные не нужны (учебный стенд): `docker compose down -v && docker compose up -d`. Данные нужны: верни старый пароль в `.env` или смени его внутри базы:

```bash
docker compose exec db psql -U notes -d notes -c "ALTER USER notes PASSWORD 'новый_пароль'"
```

и синхронизируй `.env`.

**Сценарий 2. Приложение раньше БД.** В `depends_on` пропало `condition: service_healthy` (остался просто порядок запуска). Симптом в логах `notes`:

```text
psycopg.OperationalError: connection failed: connection to server at "172.19.0.2", port 5432 failed: Connection refused
```

или `the database system is starting up`. Причина: контейнер `db` запущен, PostgreSQL ещё нет. Исправление: вернуть

```yaml
depends_on:
  db:
    condition: service_healthy
```

Проверка: `docker compose down && docker compose up -d`, `notes` создаётся после `healthy`. 
**Сценарий 3. Порт 5432 занят.** В `db` появилась публикация `5432:5432`, а на хосте уже слушает локальный PostgreSQL. Ошибка при `up`:

```text
Error response from daemon: driver failed programming external connectivity on endpoint notes-db-1: Bind for 0.0.0.0:5432 failed: port is already allocated
```

(в новых версиях Docker формулировка может быть `failed to bind host port ... address already in use`). Найди владельца: `sudo ss -ltnp | grep 5432`. Исправление: убрать `ports` у `db` (приложению порт наружу не нужен) либо публиковать на другой порт `127.0.0.1:15432:5432`. Остановка чужого сервиса ради этого не нужна.

</details>

## Вопросы с собеседований

### 1. [junior] Приложение в Compose падает при старте с connection refused к базе, хотя `depends_on: db` указан. Почему и как чинишь?

`depends_on` без условия гарантирует только порядок запуска контейнеров. Контейнер БД уже `running`, а PostgreSQL ещё инициализируется. Я добавляю healthcheck на `db` (`pg_isready`) и `depends_on` с `condition: service_healthy`. Дополнительно приложение должно уметь повторять подключение.

**Что хотят услышать:** разница «запущен» и «готов», `service_healthy`, ретраи в приложении, проба на уровне протокола (`pg_isready`), а не «контейнер жив».

**Красный флаг:** «поставлю `sleep 30` в entrypoint».

### 2. [junior] Ты сменил пароль в `.env` и перезапустил стек, а приложение пишет `password authentication failed`. Что происходит?

Образ PostgreSQL берёт `POSTGRES_PASSWORD` только при инициализации пустого каталога. Том уже с данными, поэтому старый пароль остался. Если данные не нужны, `down -v` и заново. Если нужны, `ALTER USER` внутри базы и синхронизация `.env`.

**Что хотят услышать:** инициализация только на пустом томе, лог «Skipping initialization», осторожность с `-v` на данных, смена пароля именно в БД.

**Красный флаг:** «пересоздам контейнер», не понимая, что дело в томе.

### 3. [junior] Чем `docker compose down` отличается от `down -v` и когда второе опасно?

`down` удаляет контейнеры и сеть, тома остаются, данные целы. `down -v` удаляет ещё и именованные тома, то есть саму базу. Опасно везде, где данные не восстановить: на общем стенде, на проде, если нет свежего бэкапа.

**Что хотят услышать:** том живёт независимо от контейнера, `-v` необратим, бэкап перед деструктивными операциями.

**Красный флаг:** «`down -v` на всякий случай, чтобы чище».

### 4. [junior] Почему у `db` в Compose обычно нет `ports`, а у приложения порт публикуют как `127.0.0.1:8080:8080`?

Сервисы одной сети общаются по имени сервиса без публикации портов. Порт на хост нужен только тем, к кому ходят снаружи, и лучше привязать его к loopback: запись `8080:8080` откроет порт на всех интерфейсах. К тому же Docker публикует порты в обход ufw. Публикация 5432 открывает БД сети и конфликтует с локальным PostgreSQL.

**Что хотят услышать:** DNS по имени в сети, минимальная поверхность, loopback, Docker и файрвол.

**Красный флаг:** «открою 5432 наружу, чтобы удобно было подключаться DBeaver'ом» без ограничений.

### 5. [middle] Коллега закоммитил `.env` с паролем БД в репозиторий. Твои действия?

Считаю пароль скомпрометированным: сначала меняю его в БД (`ALTER USER`) и во всех местах использования. Потом убираю файл из индекса (`git rm --cached .env`), добавляю в `.gitignore`. Историю чищу (`git filter-repo`) только если репозиторий приватный и это согласовано, но смена пароля важнее, чем чистка. Если репозиторий публичный или есть форки, файл уже считается утёкшим. Потом добавляю сканер секретов в CI (урок 3.4).

**Что хотят услышать:** ротация первична, история git не удаляет утечку, сканер в CI, `.env.example`.

**Красный флаг:** «удалю файл новым коммитом, и всё».

### 6. [middle] После `docker compose up -d` контейнер `db` в статусе `unhealthy`. Как разбираешься?

Смотрю `docker compose logs db`: причина обычно там (пустой пароль, неверный путь тома, нехватка диска). Потом проверяю сам healthcheck вручную: `docker compose exec db pg_isready -U notes -d notes` и его вывод в `docker inspect`. Проверяю, что параметры проверки не слишком жёсткие: `start_period`, `retries`, `interval`. Отдельно смотрю, нет ли пустой переменной из-за неверного `.env`.

**Что хотят услышать:** логи первыми, ручной запуск проверки, `docker inspect` (State.Health), предупреждение `variable is not set`.

**Красный флаг:** «перезапущу и посмотрю, помогло ли».

### 7. [junior] Приложение внутри контейнера не может подключиться к `localhost:5432`, а с хоста `psql -h localhost` работает. Почему?

`localhost` внутри контейнера это сам контейнер, а не хост и не соседний сервис. В сети Compose БД доступна по имени сервиса: `db:5432`. То, что с хоста работает, значит, что порт где-то опубликован на хост, что как раз обычно нежелательно.

**Что хотят услышать:** у каждого контейнера свой сетевой namespace, DNS по имени сервиса, хост `db`.

**Красный флаг:** «пропишу IP контейнера в конфиг» (IP меняется при пересоздании).

### 8. [middle] После обновления образа PostgreSQL с 17 на 18 в Compose база оказалась пустой. Что могло пойти не так?

В 17 том монтировали в `/var/lib/postgresql/data`, в 18 каталог данных стал внутри `/var/lib/postgresql` (с подкаталогом версии). Если оставить старый путь монтирования, новый образ запишет данные в анонимный том поверх, и после пересоздания они пропадут. К тому же мажорная версия PostgreSQL не читает каталог предыдущей: нужен `pg_upgrade` или дамп и восстановление.

**Что хотят услышать:** несовместимость мажоров, `pg_dump`/`pg_restore`, проверка пути тома по документации образа, бэкап до апгрейда.

**Красный флаг:** «просто поменяю тег образа».

### 9. [middle] Ты изменил одну переменную в `.env` и хочешь применить её. Что перезапустится и как проверить заранее?

`docker compose up -d` пересоздаст только сервисы, у которых изменилась итоговая конфигурация. Проверяю заранее: `docker compose config` показывает итог подстановки, `docker compose up -d --dry-run` перечисляет планируемые действия. Если поменялся пароль `db`, помню про проблему тома (вопрос 2).

**Что хотят услышать:** декларативность, пересоздание по diff конфигурации, `config`, `--dry-run`, осторожность с секретами в выводе.

**Красный флаг:** «делаю `down` и `up` всегда, на всякий случай».

### 10. [middle] `/readyz` приложения отдаёт 503, а `/healthz` 200. Кого и как перезапускать, и что бы ты изменил в стенде?

Процесс жив, но не готов: не видит БД. Перезапускать приложение бессмысленно, надо смотреть БД и сеть (`docker compose ps`, логи `db`, `pg_isready`). Liveness-проба не должна зависеть от внешних систем, иначе временный сбой БД вызовет лавину перезапусков; readiness должна, и по ней снимают трафик.

**Что хотят услышать:** разделение liveness и readiness, каскадные рестарты, диагностика по слоям (приложение, сеть, БД).

**Красный флаг:** «сделаю одну проверку `/health`, которая ходит во всё».

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- PostgreSQL (образ): `postgres:18`
- Python (образ приложения): `python:3.13-slim`
- Docker Engine и Docker Compose: версия не закреплена, проверь актуальную версию на странице проекта
- psycopg: версия закреплена в `requirements.txt` эталона

## Итог урока: ты умеешь

- [ ] умею описать стенд из двух сервисов в `compose.yml` без ключа `version:`
- [ ] умею настроить healthcheck `pg_isready` и `depends_on` с `condition: service_healthy`
- [ ] умею вынести пароль в `.env`, держать `.env.example` в git и проверить `git check-ignore`
- [ ] умею отличать `down` от `down -v` и объяснить, где живут данные PostgreSQL
- [ ] умею объяснить, почему смена `POSTGRES_PASSWORD` не действует на существующем томе, и починить
- [ ] умею диагностировать `connection refused`, `password authentication failed` и `port is already allocated` в Compose-стенде
- [ ] умею публиковать порт только на loopback и не открывать БД наружу

**Дальше:** [Урок 4.6: Compose: nginx и TLS перед «Заметками»](06-compose-nginx-tls.md)
