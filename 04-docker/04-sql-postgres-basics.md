---
layout: lesson
title: "SQL и PostgreSQL: запросы, индексы, EXPLAIN"
topic: 4
lesson: "4.4"
time: "2 ч"
---

## Зачем это нужно

Файл с заметками хорош, пока заметок сто и писатель один. Когда сервис живёт в нескольких копиях, нужна база данных (database): она держит параллельные записи, транзакции и индексы. На работе ты будешь постоянно слышать «база тормозит», и половина таких случаев лечится одним индексом, который видно в плане запроса.
В этом уроке ты поднимаешь PostgreSQL 18 в контейнере, учишься читать и писать SQL, ломаешь скорость запроса и лечишь её индексом, а потом переводишь «Заметки» на хранение в БД.

Шаг проекта: «Заметки» переезжают с файла на PostgreSQL (`STORE=postgres`), `/readyz` проверяет базу, появляется демонстрационный `/slowsql`.

## Что нужно знать

- [Урок 4.2: Dockerfile](02-dockerfile.md) - соберёшь образ `notes:0.4.0` с новой зависимостью
- [Урок 4.3: тома и сети Docker](03-storage-networks.md) - база живёт в томе и в сети `notes-net`, обращаться будем по имени контейнера
- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - `docker stop` шлёт SIGTERM, и это важно для базы
- [Урок 2.2: порты и TCP](../02-network/02-ports-tcp-ssh.md) - что значит `connection refused`

## Теория

### Реляционная база и SQL за пять минут

Реляционная база (relational database) хранит данные в таблицах (tables): строки это записи, столбцы (columns) это поля с типами. SQL (Structured Query Language) это язык запросов, он описывает, что получить, а не как. PostgreSQL это сервер: он слушает порт 5432, проверяет пароль и выполняет запросы клиентов (`psql`, наше приложение).

Четыре основные операции (CRUD):

```sql
-- создать запись
INSERT INTO notes (text) VALUES ('купить молоко');
-- прочитать записи
SELECT id, text FROM notes WHERE id > 10 ORDER BY id LIMIT 5;
-- изменить
UPDATE notes SET text = 'купить кефир' WHERE id = 1;
-- удалить
DELETE FROM notes WHERE id = 1;
```

Забытый `WHERE` в `UPDATE` или `DELETE` затрагивает все строки таблицы. Поэтому на проде такие команды сначала пишут как `SELECT`, проверяют число строк и только потом заменяют глагол.

> **Проверь понимание:** что сделает `DELETE FROM notes;` без `WHERE`?

<details>
<summary>Ответ</summary>

Удалит все строки таблицы (сама таблица останется). В `psql` без явной транзакции команда применяется сразу, отката не будет. Защита: `BEGIN;` перед опасной командой и проверка `SELECT count(*)`, восстановление из бэкапа.

</details>

### Типы, ограничения и схема

Схема (schema) это описание таблиц. Для «Заметок» она зафиксирована в контракте курса:

```sql
CREATE TABLE IF NOT EXISTS notes (
    id         serial PRIMARY KEY,
    text       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

`serial` это автоинкремент: база сама выдаёт `id`. `PRIMARY KEY` значит «уникально и не пусто», и под него база автоматически строит индекс. `NOT NULL` запрещает пустое значение, `DEFAULT now()` подставляет текущее время. `timestamptz` хранит момент времени вместе с часовым поясом (timestamp with time zone): для серверных данных используй его, а не `timestamp` без пояса.

Ограничения (constraints) защищают данные лучше, чем код приложения: приложений может быть несколько, а база одна.

> **Проверь понимание:** зачем `NOT NULL`, если приложение и так не отправляет пустой текст?

<details>
<summary>Ответ</summary>

Потому что в базу пишет не только твоё приложение: миграции, скрипты, ручные правки через `psql`. Ограничение в БД работает для всех клиентов и не зависит от багов конкретного кода.

</details>

### JOIN и агрегаты

Данные обычно лежат в нескольких связанных таблицах. `JOIN` склеивает строки по ключу: `INNER JOIN` оставляет только пары с совпадением, `LEFT JOIN` оставляет все строки левой таблицы, а недостающее справа заполняет `NULL`. Агрегаты (`count`, `sum`, `max`) со `GROUP BY` сворачивают строки в группы.

```sql
-- сколько постов у каждого автора, включая авторов без постов
SELECT a.name, count(p.id) AS posts
FROM authors a
LEFT JOIN posts p ON p.author_id = a.id
GROUP BY a.name
ORDER BY posts DESC;
```

Заметь `count(p.id)`, а не `count(*)`: `count(*)` посчитал бы и строку-пустышку от `LEFT JOIN`, и у автора без постов получилась бы единица.

> **Проверь понимание:** чем `LEFT JOIN` отличается от `INNER JOIN` в этом запросе?

<details>
<summary>Ответ</summary>

`INNER JOIN` потерял бы авторов без постов, а `LEFT JOIN` покажет их с нулём. Для отчётов вида «у кого ничего нет» нужен именно `LEFT JOIN`.

</details>

### Транзакции и ACID

Транзакция (transaction) это группа команд «всё или ничего»: `BEGIN` ... `COMMIT` применяет всё, `ROLLBACK` откатывает всё. Классический пример: перевод денег это два `UPDATE`, и упасть между ними нельзя. ACID (atomicity, consistency, isolation, durability) означает: атомарность, целостность, изоляцию параллельных транзакций и сохранность после `COMMIT` даже при сбое питания (благодаря журналу WAL, write-ahead log).

Каждая отдельная команда без `BEGIN` это своя маленькая транзакция с автоматическим `COMMIT`. Длинная забытая транзакция опасна: она держит блокировки и не даёт очистке (vacuum) убирать старые версии строк.

> **Проверь понимание:** что будет с изменениями, если клиент упал после `BEGIN` и нескольких `UPDATE`, но до `COMMIT`?

<details>
<summary>Ответ</summary>

Сервер увидит разрыв соединения и откатит транзакцию: изменения не сохранятся. Именно поэтому `COMMIT` это момент, после которого данные считаются надёжными.

</details>

### Индексы и EXPLAIN

Без индекса (index) база при фильтре по столбцу читает всю таблицу построчно: последовательное сканирование (Seq Scan). Индекс это отсортированная структура (по умолчанию B-tree), которая находит нужные строки за логарифмическое время: Index Scan. Цена индекса: место на диске и замедление `INSERT` и `UPDATE`, потому что индекс тоже надо обновлять. Поэтому индекс создают под реальные запросы, а не «на всякий случай».

`EXPLAIN` показывает план запроса (query plan): как база собирается его выполнить. `EXPLAIN ANALYZE` ещё и выполняет запрос, показывая реальное время и число строк. Внимание: `EXPLAIN ANALYZE` на `UPDATE` или `DELETE` действительно изменит данные, оборачивай его в `BEGIN` ... `ROLLBACK`.

Как читать: смотри тип узла (`Seq Scan` или `Index Scan`), `rows` (оценка и факт) и `Execution Time`. Большая разница между оценкой и фактом значит, что статистика устарела: помогает `ANALYZE таблица`.

> **Проверь понимание:** запрос `WHERE created_at > ...` тормозит на таблице в миллион строк. Что проверишь первым?

<details>
<summary>Ответ</summary>

`EXPLAIN ANALYZE` этого запроса: если там `Seq Scan` и большой `Execution Time`, а фильтр отбирает малую долю строк, нужен индекс по `created_at`. Если фильтр отбирает половину таблицы, индекс не поможет, планировщик сам выберет Seq Scan.

</details>

### PostgreSQL в контейнере

Образ `postgres:18` при первом старте (пустой каталог данных) читает переменные `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, создаёт кластер и базу. Данные лежат в `/var/lib/postgresql` (в 18-м образе каталог данных внутри версионный подкаталог), поэтому том монтируют именно на `/var/lib/postgresql`. Важный подводный камень: переменные читаются только при инициализации. Если том уже содержит данные, смена `POSTGRES_PASSWORD` ничего не изменит, пароль останется старым (об этом сценарий в «Сломай и почини»).

> **Проверь понимание:** ты изменил `POSTGRES_PASSWORD` в команде `docker run` и перезапустил контейнер с тем же томом. Какой пароль действует?

<details>
<summary>Ответ</summary>

Старый: пароль записан в данных кластера при первой инициализации, переменная больше не читается. Чтобы сменить пароль, нужен `ALTER USER notes PASSWORD '...'` или новый пустой том (данные потеряются).

</details>

## Практика

### Задание 1. Поднимаем PostgreSQL 18 и заходим в psql

**Цель:** запустить базу в сети `notes-net` с томом и выполнить первый запрос.

**Предскажи:** после `docker run` с `-d` сервер стартует несколько секунд. Что увидит `psql`, если подключиться мгновенно? А что покажет `\dt` в свежей базе `notes`?

<details>
<summary>Ответ</summary>

Сразу после старта может быть `server closed the connection unexpectedly` или отказ подключения: сервер ещё инициализируется (временный сервер на init-фазе). `\dt` покажет `Did not find any relations`, таблиц ещё нет.

</details>

**Шаги:**

1. Сгенерируй пароль и сохрани в переменную оболочки (в примерах ниже он подставляется как `$PGPASS`, в git его не кладём):

```bash
export PGPASS="$(openssl rand -base64 24 | tr -d '/+=')"
```

2. Запусти контейнер. Порт наружу не публикуем: приложение обратится по имени `db` внутри сети.

```bash
docker run -d --name db --network notes-net --network-alias db \
  -e POSTGRES_USER=notes -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=notes \
  -v notes-pgdata:/var/lib/postgresql \
  postgres:18
```

3. Дождись готовности и зайди в `psql` внутри контейнера:

```bash
until docker exec db pg_isready -U notes -d notes; do sleep 1; done
docker exec -it db psql -U notes -d notes
```

4. Внутри `psql` выполни:

```sql
SELECT version();
\dt
\q
```

**Что должно получиться:**

```text
/var/run/postgresql:5432 - accepting connections
```

и после `SELECT version();` строка вида `PostgreSQL 18.x on x86_64-pc-linux-gnu ...` (номер минорной версии может отличаться).

**Объясни себе:**

- Почему том смонтирован на `/var/lib/postgresql`, а не на `/var/lib/postgresql/data`?
- Почему мы не публикуем порт 5432 на хост и как приложение найдёт базу?

**Типичные ошибки:**

- `docker: Error response from daemon: Conflict. The container name "/db" is already in use`: старый контейнер с таким именем, убери `docker rm -f db`.
- `psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory`: сервер ещё не поднялся или контейнер упал, смотри `docker logs db`.
- `Bind for 0.0.0.0:5432 failed: port is already allocated`: появляется, если ты добавил `-p 5432:5432`, а порт занят хостовым PostgreSQL или другим контейнером. Нам порт наружу не нужен.

### Задание 2. SELECT, INSERT, JOIN и транзакция

**Цель:** набить руку на SQL в отдельной учебной базе `lab`, не трогая рабочую `notes`.

**Предскажи:** у автора без постов `LEFT JOIN` вернёт `count(p.id)` равный чему? А `count(*)`?

<details>
<summary>Ответ</summary>

`count(p.id)` даст 0 (`NULL` не считаются), `count(*)` даст 1 (строка-результат существует, хоть справа пусто).

</details>

**Шаги:**

1. Создай базу и таблицы (приглашение `psql` показано в блоке, команды вводи без него):

```bash
docker exec db createdb -U notes lab
docker exec -i db psql -U notes -d lab <<'SQL'
CREATE TABLE authors (id serial PRIMARY KEY, name text NOT NULL UNIQUE);
CREATE TABLE posts (
  id serial PRIMARY KEY,
  author_id int NOT NULL REFERENCES authors(id),
  title text NOT NULL
);
INSERT INTO authors (name) VALUES ('anna'), ('boris'), ('vera');
INSERT INTO posts (author_id, title) VALUES (1, 'про nginx'), (1, 'про TLS'), (2, 'про Docker');
SQL
```

2. Запрос с `LEFT JOIN`:

```bash
docker exec -i db psql -U notes -d lab <<'SQL'
SELECT a.name, count(p.id) AS posts
FROM authors a LEFT JOIN posts p ON p.author_id = a.id
GROUP BY a.name ORDER BY posts DESC, a.name;
SQL
```

3. Транзакция с откатом и нарушением ограничения:

```bash
docker exec -i db psql -U notes -d lab <<'SQL'
BEGIN;
DELETE FROM posts;
SELECT count(*) AS after_delete FROM posts;
ROLLBACK;
SELECT count(*) AS after_rollback FROM posts;
INSERT INTO posts (author_id, title) VALUES (99, 'нет такого автора');
SQL
```

**Что должно получиться:**

```text
 name  | posts 
-------+-------
 anna  |     2
 boris |     1
 vera  |     0
(3 rows)

 after_delete 
--------------
            0
(1 row)

ROLLBACK
 after_rollback 
----------------
              3
(1 row)

ERROR:  insert or update on table "posts" violates foreign key constraint "posts_author_id_fkey"
DETAIL:  Key (author_id)=(99) is not present in table "authors".
```

**Объясни себе:**

- Почему `vera` осталась в результате, и что изменится при `INNER JOIN`?
- Что доказал `after_rollback`?
- Какую защиту дал `REFERENCES` и зачем она, если приложение «и так» передаёт верный `author_id`?

**Типичные ошибки:**

- `ERROR:  relation "authors" does not exist`: ты подключился не к той базе (нет `-d lab`) или таблицы не создались.
- `ERROR:  column "a.name" must appear in the GROUP BY clause or be used in an aggregate function`: в `SELECT` есть столбец, которого нет в `GROUP BY`: добавь его или оберни в агрегат.
- `ERROR:  duplicate key value violates unique constraint "authors_name_key"`: повторно выполнил вставку авторов, `UNIQUE` сработал: это норма.

### Задание 3. Медленный запрос, EXPLAIN и индекс

**Цель:** воспроизвести «база тормозит», увидеть `Seq Scan` в плане и вылечить его индексом.

**Предскажи:** в таблице 1 000 000 строк, и мы ищем одну по точному значению `text`. Какой узел плана будет до индекса и какой после? Во сколько раз ускорится: в 2, в 100 или в 10000?

<details>
<summary>Ответ</summary>

До индекса `Seq Scan` (читает всю таблицу, десятки-сотни миллисекунд), после `Index Scan` или `Bitmap Index Scan` (доли миллисекунды). Ускорение порядка сотен и тысяч раз, точные цифры зависят от машины.

</details>

**Шаги:**

1. Наполни таблицу миллионом строк в учебной базе `lab` (данные псевдослучайные, но воспроизводимые):

```bash
docker exec -i db psql -U notes -d lab <<'SQL'
CREATE TABLE big_notes (
  id serial PRIMARY KEY,
  text text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO big_notes (text, created_at)
SELECT 'заметка ' || g, now() - (g || ' seconds')::interval
FROM generate_series(1, 1000000) AS g;
ANALYZE big_notes;
SQL
```

2. Запрос без индекса:

```bash
docker exec -i db psql -U notes -d lab -c \
  "EXPLAIN ANALYZE SELECT * FROM big_notes WHERE text = 'заметка 777777';"
```

3. Создай индекс и повтори запрос:

```bash
docker exec -i db psql -U notes -d lab -c \
  "CREATE INDEX big_notes_text_idx ON big_notes (text);"
docker exec -i db psql -U notes -d lab -c \
  "EXPLAIN ANALYZE SELECT * FROM big_notes WHERE text = 'заметка 777777';"
```


**Что должно получиться (цифры будут другими, важны узлы плана):**

```text
 Gather  (cost=1000.00..15000.00 rows=1 width=37) (actual time=40.000..90.000 rows=1 loops=1)
   Workers Planned: 2
   ->  Parallel Seq Scan on big_notes  (cost=0.00..14000.00 rows=1 width=37)
         Filter: (text = 'заметка 777777'::text)
         Rows Removed by Filter: 333333
 Execution Time: 92.000 ms
```

и после индекса:

```text
 Index Scan using big_notes_text_idx on big_notes  (cost=0.42..8.44 rows=1 width=37) (actual time=0.030..0.031 rows=1 loops=1)
   Index Cond: (text = 'заметка 777777'::text)
 Execution Time: 0.060 ms
```

**Объясни себе:**

- Что значит `Rows Removed by Filter` и почему это признак проблемы?
- Индекс занял место на диске. Что ещё стало дороже, и когда индекс не стоит создавать?
- Почему запрос `WHERE text LIKE '%777'` индекс не использует?

**Типичные ошибки:**

- `ERROR:  relation "big_notes" does not exist`: работаешь в базе `notes`, а не `lab`.
- Планировщик выбрал `Seq Scan` даже после индекса: не выполнен `ANALYZE` (устаревшая статистика) либо запрос отбирает большую долю таблицы.
- `ERROR:  canceling statement due to statement timeout`: на очень слабой ВМ генерация миллиона строк не уложилась в лимит, уменьши до 300000 в `generate_series`.

### Задание 4. Шаг проекта: «Заметки» переезжают на PostgreSQL

**Цель:** приложение v4 хранит заметки в базе, `/readyz` проверяет БД, `/slowsql` показывает влияние медленного запроса.

**Предскажи:** запустишь новое приложение с `STORE=postgres`, но раньше базы. Что покажет `docker logs`, и что вернёт `/readyz`? А если приложение стартует раньше готовности БД, оно должно упасть или ждать?

<details>
<summary>Ответ</summary>

Соединение с БД не установится (`connection refused` либо `could not translate host name "db"`), а `/readyz` вернёт 503: процесс жив (`/healthz` 200), но обслуживать запросы не может. Это ровно разница liveness и readiness. Приложение не падает: соединение открывается на каждый запрос, поэтому как только база поднимется, `/readyz` станет 200 (упадёт или не упадёт при старте решает версия кода, наша версия не падает).

</details>

**Шаги:**

1. Перейди в репозиторий и создай `db/schema.sql` (схема из теории, применяется приложением при старте и доступна вручную):

```bash
cd ~/notes
mkdir -p db
cat > db/schema.sql <<'SQL'
-- схема хранилища "Заметок"; повторный запуск безопасен
CREATE TABLE IF NOT EXISTS notes (
    id         serial PRIMARY KEY,
    text       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
SQL
```

2. Добавь зависимость. Версию закрепи по `pip index versions psycopg` (проверь актуальную версию на странице проекта), ниже диапазон мажорной ветки 3:

```bash
echo 'psycopg[binary]>=3.2,<4' > requirements.txt
```

3. Внеси в `app.py` слой хранилища. Существующие эндпоинты остаются, меняется выбор хранилища по `STORE`. Добавь (или замени соответствующие места файла):

```python
import os
import psycopg

STORE = os.environ.get("STORE", "file")
DATABASE_URL = os.environ.get("DATABASE_URL", "")

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS notes (
    id         serial PRIMARY KEY,
    text       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
)
"""


def pg_connect():
    # Соединение на каждый запрос: просто, но без пула и с лишней задержкой.
    # Компромисс осознанный, пул появится, когда нагрузка это оправдает.
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def pg_init():
    with pg_connect() as conn:
        conn.execute(SCHEMA_SQL)


def pg_list():
    with pg_connect() as conn:
        rows = conn.execute(
            "SELECT id, text, created_at FROM notes ORDER BY id"
        ).fetchall()
    return [
        {"id": r[0], "text": r[1], "created_at": r[2].isoformat()} for r in rows
    ]


def pg_add(text):
    with pg_connect() as conn:
        # параметры передаются отдельно от SQL: защита от SQL-инъекций
        return conn.execute(
            "INSERT INTO notes (text) VALUES (%s) RETURNING id", (text,)
        ).fetchone()[0]


def pg_ready():
    try:
        with pg_connect() as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error:
        return False


def pg_sleep(sec):
    with pg_connect() as conn:
        conn.execute("SELECT pg_sleep(%s)", (sec,))
```

В обработчике `GET /readyz` при `STORE=postgres` возвращай 200 `ready`, если `pg_ready()`, иначе 503 `not ready`. `GET /notes` и `POST /notes` при `STORE=postgres` вызывают `pg_list()` и `pg_add()`. Эндпоинт `GET /slowsql?sec=N` (демонстрационный, в реальном сервисе его бы не было): целое `N` от 0 до 30 (иначе 400), вызывает `pg_sleep(N)` и отвечает 200 `slept N`; при `STORE=file` отвечает 501 `{"error":"postgres only"}`. В `main` при `STORE=postgres` вызывай `pg_init()` в `try` и пиши предупреждение в лог при ошибке, а не падай: `/readyz` сообщит о проблеме. Полный файл версии v4: [project/notes/app.py](https://github.com/distinguished-sre/devops/tree/devops/project/notes/app.py).

4. Обнови `Dockerfile` не нужно: он из урока 4.2 уже копирует `requirements.txt` первым слоем и ставит зависимости. Пересобери образ:

```bash
docker build -t notes:0.4.0 .
```

5. Запусти приложение в `notes-net` (пароль из переменной `PGPASS`, порт публикуем только на localhost):

```bash
docker rm -f notes 2>/dev/null
docker run -d --name notes --network notes-net -p 127.0.0.1:8080:8080 \
  -e STORE=postgres -e APP_VERSION=0.4.0 \
  -e DATABASE_URL="postgresql://notes:${PGPASS}@db:5432/notes" \
  notes:0.4.0
```

6. Проверь всю цепочку, включая переживание пересоздания базы:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
curl -s -X POST -d '{"text":"первая заметка в PostgreSQL"}' http://127.0.0.1:8080/notes
curl -s http://127.0.0.1:8080/notes
docker rm -f db
docker run -d --name db --network notes-net --network-alias db \
  -e POSTGRES_USER=notes -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=notes \
  -v notes-pgdata:/var/lib/postgresql postgres:18
until docker exec db pg_isready -U notes -d notes; do sleep 1; done
curl -s http://127.0.0.1:8080/notes
curl -s -w ' %{http_code}\n' 'http://127.0.0.1:8080/slowsql?sec=2'
```

**Что должно получиться:**

```text
200
{"id":1}
[{"id":1,"text":"первая заметка в PostgreSQL","created_at":"2026-09-29T10:00:00+00:00"}]
/var/run/postgresql:5432 - accepting connections
[{"id":1,"text":"первая заметка в PostgreSQL","created_at":"2026-09-29T10:00:00+00:00"}]
slept 2 200
```

Время в `created_at` у тебя будет своё. Заметка пережила удаление контейнера `db`, потому что данные лежат в томе `notes-pgdata`.

Состояние проекта после урока: `app.py` версии v4, `requirements.txt`, `db/schema.sql`, образ `notes:0.4.0`, PostgreSQL 18 в сети `notes-net` (5432 внутри сети), долг: пароль базы передаётся переменной окружения (закроется в теме 9).

Зафиксируй в git:

```bash
git add app.py requirements.txt db/schema.sql
git commit -m "Хранилище PostgreSQL: STORE=postgres, readyz по БД, slowsql"
```

**Объясни себе:**

- Почему `/readyz` теперь проверяет базу, а `/healthz` нет? Что произойдёт с трафиком, если БД недоступна, а мы проверяли бы её в liveness?
- Зачем параметры передаются как `(text,)`, а не подстановкой строки в SQL?

**Типичные ошибки:**

- `psycopg.OperationalError: connection failed: connection to server at "172.18.0.2", port 5432 failed: FATAL:  password authentication failed for user "notes"`: пароль в `DATABASE_URL` не совпадает с тем, что записан в томе при инициализации: проверь `PGPASS` (в новом окне терминала переменная пропала) или смени пароль через `ALTER USER`.
- `psycopg.OperationalError: [Errno -2] Name or service not known` (либо `could not translate host name "db" to address`): контейнеры не в одной пользовательской сети или база не запущена, проверь `docker network inspect notes-net`.
- `ModuleNotFoundError: No module named 'psycopg'`: образ собран до правки `requirements.txt`, пересобери `docker build`.
- `psycopg.errors.UndefinedTable: relation "notes" does not exist`: `pg_init()` не отработал, примени схему вручную: `docker exec -i db psql -U notes -d notes < db/schema.sql`.

## Сломай и почини

Запусти сценарий сломанной среды (скрипт не читай, диагностируй как настоящий инцидент):

```bash
bash ~/notes/break/4.4/break.sh random
```

Сценарии урока: неверный пароль, приложение раньше базы, медленный `/slowsql` без индекса и занятый порт 5432.

### Симптом

Приложение отвечает 5xx на `/notes`, `/readyz` возвращает 503, либо `curl 'http://127.0.0.1:8080/slowsql?sec=1'` работает, но запросы к базе заметно тормозят, либо `docker run` не стартует с ошибкой порта.

### Гипотезы

Запиши до проверок, что вероятнее всего:

1. Неверные учётные данные (пароль в `DATABASE_URL` и в томе не совпадают).
2. База недоступна из сети: не запущена, не в той сети, ещё не поднялась.
3. Запрос без индекса читает всю таблицу.
4. Порт занят другим процессом.

### Проверки

{% raw %}
```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker logs --tail 30 notes
docker logs --tail 30 db
docker exec notes python -c "import socket; print(socket.gethostbyname('db'))"
docker exec db pg_isready -U notes -d notes
sudo ss -ltnp | grep ':5432'
```
{% endraw %}

Для медленных запросов: `EXPLAIN ANALYZE` подозрительного запроса и поиск `Seq Scan` с большим `Rows Removed by Filter`.

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

1. `FATAL:  password authentication failed for user "notes"`: пароль в `DATABASE_URL` не тот, что записан в томе. Проверка: `docker exec -it db psql -U notes -d notes` изнутри контейнера работает (по сокету пароль не спрашивают), значит база жива, дело в пароле клиента. Исправление: привести `DATABASE_URL` к паролю тома либо `ALTER USER notes PASSWORD '<новый>';` и обновить переменную приложения. Вспомни: смена `POSTGRES_PASSWORD` на живом томе не действует.
2. `connection refused` или `Name or service not known` при старте: приложение поднято раньше базы или в другой сети. Исправление: запустить `db`, дождаться `pg_isready`, убедиться, что оба контейнера в `notes-net`. Наше приложение открывает соединение на каждый запрос, поэтому `/readyz` сам перейдёт в 200. Как гарантировать порядок запуска декларативно, разберём в [уроке 4.5](05-compose-postgres.md).
3. Тормозит запрос: `EXPLAIN ANALYZE` показал `Seq Scan`. Исправление: `CREATE INDEX` под фильтр (в проде `CREATE INDEX CONCURRENTLY`, чтобы не блокировать записи), затем повторный `EXPLAIN ANALYZE`: должен появиться `Index Scan`.
4. `Bind for 0.0.0.0:5432 failed: port is already allocated`: на хосте уже слушает PostgreSQL или другой контейнер. Найти: `sudo ss -ltnp | grep ':5432'`. Исправление: остановить лишний процесс либо не публиковать порт вовсе (приложению он не нужен), либо опубликовать на другой: `-p 127.0.0.1:5433:5432`.

</details>

## Вопросы с собеседований

### 1. [junior] Приложение пишет «connection refused» к базе, а база в соседнем контейнере. С чего начнёшь?

Проверю, что контейнер базы запущен и здоров (`docker ps`, `pg_isready`), потом что оба в одной пользовательской сети и имя резолвится. Дальше порт: слушает ли база 5432 на нужном интерфейсе. Логи `docker logs` обоих контейнеров.

**Что хотят услышать:** последовательность: жива ли база, сеть, DNS по имени, порт, логи; знание, что `localhost` внутри контейнера это он сам.

**Красный флаг:** «перезапущу всё и посмотрю», или публикация порта 5432 на весь интернет ради связи контейнеров.

### 2. [junior] Что такое индекс и когда он вредит?

Индекс это отдельная структура (B-tree), ускоряющая поиск по столбцу. Вредит тем, что занимает место и замедляет запись: каждый `INSERT` и `UPDATE` обновляет и индексы. На маленьких таблицах и на столбцах с низкой избирательностью пользы нет.

**Что хотят услышать:** цена записи, избирательность (selectivity), индекс под конкретный запрос, проверка через `EXPLAIN`.

**Красный флаг:** «индекс нужно ставить на все столбцы, чтобы быстро было».

### 3. [middle] Запрос внезапно стал медленным на проде. Твои действия?

Сначала выясню, что именно медленно: `pg_stat_activity` для активных запросов, потом `EXPLAIN (ANALYZE, BUFFERS)` подозрительного. Ищу `Seq Scan`, расхождение оценки и факта, блокировки. Если статистика устарела, делаю `ANALYZE`. Индекс на проде создаю через `CREATE INDEX CONCURRENTLY`.

**Что хотят услышать:** измерять до правки, `pg_stat_activity`, план запроса, блокировки, `CONCURRENTLY`, что менялось (релиз, рост данных).

**Красный флаг:** «увеличу CPU и память», не глядя в план.

### 4. [middle] EXPLAIN и EXPLAIN ANALYZE: в чём разница и какая ловушка?

`EXPLAIN` показывает план без выполнения, только оценки. `EXPLAIN ANALYZE` выполняет запрос и показывает факт. Ловушка: на `UPDATE` и `DELETE` он реально меняет данные, поэтому его оборачивают в `BEGIN` и `ROLLBACK`.

**Что хотят услышать:** побочные эффекты, сравнение оценки и факта, `BUFFERS`.

**Красный флаг:** запускал `EXPLAIN ANALYZE DELETE` на проде «посмотреть».

### 5. [junior] Забыли WHERE в UPDATE на проде. Что делать?

Не паниковать и не писать ещё команд. Если транзакция ещё открыта, сделать `ROLLBACK`. Если уже `COMMIT`, восстанавливать: point-in-time recovery из бэкапа и WAL либо точечно из бэкапной копии. Потом разбор: `BEGIN` для ручных правок, роли с урезанными правами, ревью.

**Что хотят услышать:** откат, бэкапы и PITR, что нельзя дописывать «исправления» вслепую, профилактика.

**Красный флаг:** «сделаю обратный UPDATE по памяти».

### 6. [middle] Контейнер PostgreSQL перезапустили, а пароль в приложении не подошёл. Как так?

Я поменял `POSTGRES_PASSWORD`, но том с данными уже был инициализирован: переменные читаются только при первом старте. Действует старый пароль, записанный в кластер. Исправление: `ALTER USER` внутри базы и синхронизация секрета приложения.

**Что хотят услышать:** инициализация только на пустом томе, `ALTER USER`, секрет в одном источнике правды.

**Красный флаг:** «удалю том и создам заново» без вопроса, есть ли там данные.

### 7. [middle] Диск сервера с PostgreSQL заполняется, а таблицы небольшие. Куда смотреть?

Размер каталога данных и WAL, число незавершённых репликационных слотов, раздувание таблиц (bloat) от мёртвых строк, которые не убирает vacuum из-за долгой транзакции, логи. Проверяю `pg_stat_activity` на старые транзакции и `pg_database_size`.

**Что хотят услышать:** WAL и слоты репликации, bloat и vacuum, долгие транзакции, логи.

**Красный флаг:** «удалю файлы из каталога данных руками».

### 8. [middle] Сервис под нагрузкой упёрся в `too many connections`. Причина и лечение?

Каждое соединение это отдельный процесс PostgreSQL, лимит `max_connections` конечен. Если приложение открывает соединение на каждый запрос (как наши «Заметки»), при росте трафика лимит кончается. Лечение: пул соединений в приложении или PgBouncer, ограничение числа воркеров, а не слепое повышение `max_connections`.

**Что хотят услышать:** процесс на соединение, пулинг, PgBouncer, поиск утечек соединений.

**Красный флаг:** «поставлю `max_connections` в 10000».

### 9. [middle] Проба `/readyz` проверяет базу. База легла на минуту. Что произойдёт и правильно ли это?

Проба перестанет проходить, оркестратор снимет поды с трафика (readiness), но не перезапустит их. Это правильно: перезапуск приложения базу не вылечит. Liveness базу проверять не должна, иначе получим каскад перезапусков.

**Что хотят услышать:** разница liveness и readiness, каскадные отказы, что делает балансировщик.

**Красный флаг:** «проверку базы надо в liveness, чтобы всё перезапускалось».

### 10. [junior] Как безопасно передать в запрос значение от пользователя?

Только параметрами драйвера (`%s` с отдельным кортежем значений), не склейкой строк. Тогда данные не становятся частью SQL, и SQL-инъекция невозможна.

**Что хотят услышать:** параметризованные запросы, пример инъекции с `' OR 1=1`, экранирование не своими руками.

**Красный флаг:** «экранирую кавычки регуляркой».

## Проверено на версиях

- PostgreSQL: 18 (образ `postgres:18`)
- psycopg: 3.x, версию закрепи в `requirements.txt` по актуальному релизу (проверь актуальную версию на странице проекта)
- Docker Engine: версия из урока 4.1
- Python: 3.13 (образ `python:3.13-slim`)
- Ubuntu: 26.04 LTS и 24.04

## Итог урока: ты умеешь

- [ ] умею запустить PostgreSQL 18 в контейнере с томом и зайти в `psql`
- [ ] умею писать `SELECT`, `INSERT`, `UPDATE`, `DELETE` с `WHERE` и безопасно проверять опасные команды
- [ ] умею объединять таблицы через `JOIN` и считать агрегаты с `GROUP BY`
- [ ] умею использовать транзакцию с `ROLLBACK` и объяснять ACID
- [ ] умею читать `EXPLAIN ANALYZE`, находить `Seq Scan` и лечить его индексом
- [ ] умею передавать параметры запроса без риска SQL-инъекции
- [ ] умею подключить приложение к базе по имени в сети `notes-net` и проверить `/readyz`
- [ ] умею диагностировать `password authentication failed` и `connection refused` к базе

**Дальше:** [Урок 4.5: Compose: «Заметки» и PostgreSQL](05-compose-postgres.md)
