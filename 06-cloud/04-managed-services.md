---
layout: lesson
title: "Managed-сервисы: PostgreSQL, Kubernetes, балансировщик"
topic: 6
lesson: "6.4"
time: "2 ч"
---

## Зачем это нужно

На ВМ из прошлого урока PostgreSQL живёт в контейнере рядом с приложением. Если ВМ умрёт, диск потеряется или ты забудешь про бэкап, «Заметки» потеряют данные. На работе почти всегда спрашивают одно и то же: что мы делаем сами, что отдаём провайдеру, и сколько это стоит в деньгах и в ночных дежурствах.
Managed-сервис (управляемый сервис) снимает часть эксплуатации: патчи, бэкапы, failover. Но подключение, права, схема, миграции и проверка восстановления остаются на тебе.

Шаг проекта: «Заметки» переезжают на Managed PostgreSQL, `DATABASE_URL` получает `sslmode=verify-full`, из `compose.prod.yml` уходит сервис `db`; Managed Kubernetes и балансировщик разбираешь по спецификации и цене, ничего не создавая.

## Что нужно знать

- [Урок 4.4: SQL и PostgreSQL](../04-docker/04-sql-postgres-basics.md) - `psql`, таблицы, `SELECT`, `pg_dump`
- [Урок 4.5: Compose, «Заметки» и PostgreSQL](../04-docker/05-compose-postgres.md) - `DATABASE_URL`, сервис `db`, `.env`
- [Урок 6.2: ВМ, сеть и диски](02-vm-network-storage.md) - сеть, подсеть, security group, `yc`
- [Урок 6.3: деплой на ВМ](03-deploy-notes-vm.md) - `compose.prod.yml`, `deploy.sh`, домен и HTTPS
- [Урок 5.4: Ingress и Gateway API](../05-kubernetes/04-ingress-gateway.md) - вход в кластер, пригодится для сравнения с балансировщиком

## Теория

### Что именно продаёт Managed-сервис

Managed PostgreSQL (управляемая PostgreSQL) это обычный PostgreSQL, вокруг которого провайдер сделал автоматику. Что берёт на себя провайдер:

- установка и минорные обновления (patching);
- автоматические бэкапы и непрерывный архив журнала WAL, на котором работает PITR (point-in-time recovery, восстановление на момент времени);
- HA (high availability): вторая реплика в другой зоне и автоматический failover (переключение) при падении мастера;
- мониторинг «железа», метрики, алерты на диск;
- масштабирование: сменить размер хоста, расширить диск.

Что остаётся тебе (это модель разделённой ответственности из [урока 6.1](01-cloud-models-aws-mapping.md)):

- сеть: кто и откуда может подключиться;
- пользователи, пароли, права, схема БД, индексы, миграции;
- медленные запросы и число соединений;
- проверка, что бэкап реально восстанавливается;
- расходы и удаление ненужных кластеров.

Суперпользователя (`postgres`) у тебя нет: расширения, настройки и `pg_hba.conf` меняются только через API и консоль провайдера. Это цена за автоматику.

> **Проверь понимание:** ты включил HA-кластер из двух хостов. Кто-то выполнил `DROP TABLE notes`. Спасёт ли реплика?

<details>
<summary>Ответ</summary>

Нет. Реплика получает те же изменения, и `DROP TABLE` применится на ней тоже. HA защищает от падения хоста, а не от человеческой ошибки. От ошибки спасает PITR или бэкап: восстанавливаешь кластер на момент за минуту до `DROP`.

</details>

### Подключение: TLS, приватная сеть, порт

Managed-кластер живёт в сети провайдера. Два способа доступа:

1. Приватный: у хоста нет публичного адреса, подключаются только ВМ из той же сети (VPC) по внутреннему адресу и FQDN. Так делают в проде.
2. Публичный: у хоста есть публичный IP. Удобно для разбора, но опасно: пароль остаётся единственной защитой.

Доступ ограничивает security group (группа безопасности, набор правил файрвола из [урока 6.2](02-vm-network-storage.md)): разреши входящий TCP на порт БД только из security group ВМ, а не из `0.0.0.0/0`.

Шифрование: провайдер выдаёт сертификат хоста, подписанный своим корневым центром (CA, certificate authority). Режимы `sslmode` в libpq (клиентская библиотека PostgreSQL):

| `sslmode` | Шифрует | Проверяет, что сервер тот |
|---|---|---|
| `disable` | нет | нет |
| `require` | да | нет (подмена возможна) |
| `verify-ca` | да | сертификат выдан доверенным CA |
| `verify-full` | да | CA и имя хоста совпадают с сертификатом |

Для прода нужен `verify-full` и файл корневого CA провайдера (`sslrootcert`). Порт в Yandex Managed PostgreSQL 6432: перед базой стоит менеджер соединений (connection pooler, Odyssey), аналог pgbouncer. Он держит небольшой пул соединений к базе и раздаёт их клиентам, поэтому приложение без своего пула («Заметки» открывают соединение на каждый запрос) обходится дешевле.

> **Проверь понимание:** чем `verify-full` защищает лучше, чем `require`?

<details>
<summary>Ответ</summary>

`require` шифрует канал, но принимает любой сертификат. Атакующий на пути (MITM) подставит свой сертификат, и ты отдашь ему пароль. `verify-full` проверяет цепочку до доверенного CA и то, что имя в сертификате совпадает с хостом, к которому ты подключался.

</details>

### HA, реплики, RPO и RTO

- Реплика для HA стоит в другой зоне доступности (AZ, availability zone). При падении мастера провайдер повышает реплику, FQDN кластера остаётся, соединения обрываются на десятки секунд.
- Read replica (реплика для чтения) отдаёт `SELECT` и снимает нагрузку с мастера, но отстаёт (replication lag), поэтому читать с неё только что записанное нельзя.
- RPO (recovery point objective): сколько данных ты готов потерять. RTO (recovery time objective): за какое время нужно вернуться. Глубже про них в [уроке 6.5](05-cloud-ops-cost.md). Для managed RPO определяется WAL-архивом (минуты), RTO зависит от размера базы.
- PITR восстанавливает не в тот же кластер, а в новый. Приложение потом переключают на новый адрес.

### Managed Kubernetes и балансировщик (обзор)

Managed Kubernetes (Yandex Managed Service for Kubernetes, AWS EKS): провайдер запускает и обновляет control plane (управляющую часть: API-сервер, etcd, планировщик). Ты платишь за control plane отдельно (зональный мастер дешевле региональной HA-версии) и за группы узлов (node group), то есть обычные ВМ, на которых работают твои pod'ы. Провайдер обновляет control plane, а версию узлов и приложения обновляешь ты. Для одного приложения вроде «Заметок» это дорого и избыточно: минимальный кластер это мастер плюс пара узлов. Он оправдан, когда сервисов много и нужна платформа.

Балансировщик (load balancer) распределяет входящий трафик по бэкендам и проверяет их здоровье:

- L4 (Network Load Balancer): работает с TCP/UDP, не смотрит внутрь HTTP, очень быстрый. Подходит для БД и любого TCP.
- L7 (Application Load Balancer, ALB): понимает HTTP, маршрутизирует по хосту и пути, завершает TLS, умеет редиректы и заголовки. Это аналог nginx или Gateway из [урока 5.4](../05-kubernetes/04-ingress-gateway.md), но управляемый.

Ещё два сервиса каталога, знать по названию: CDN (сеть доставки контента, кэш статики ближе к пользователю) и Cloud Functions (функции по событию, платишь за выполнение). «Заметкам» не нужны.

Квоты (quotas): у каждого облака есть лимиты на число ВМ, дисков, IP и кластеров на каталог. Упрёшься в них ночью, когда нужно быстро расширить кластер, поэтому проверяй заранее.

### Соответствие AWS

| Что | Yandex Cloud | AWS |
|---|---|---|
| Managed PostgreSQL | Managed Service for PostgreSQL | RDS for PostgreSQL / Aurora PostgreSQL |
| Managed Kubernetes | Managed Service for Kubernetes | EKS |
| Балансировщик L4 | Network Load Balancer | NLB |
| Балансировщик L7 | Application Load Balancer | ALB |
| CDN | Cloud CDN | CloudFront |
| Функции | Cloud Functions | Lambda |
| Пул соединений | Odyssey в кластере (порт 6432) | RDS Proxy |
| Фильтр доступа | Security group | Security group |
| Корневой CA | `CA.pem` из хранилища Yandex | `global-bundle.pem` для RDS |
| Восстановление | из бэкапа или PITR в новый кластер | restore to point in time в новый инстанс |

## Практика

Нужны: облако Yandex Cloud из [урока 6.1](01-cloud-models-aws-mapping.md), ВМ `notes-vm` с работающими «Заметками» из [урока 6.3](03-deploy-notes-vm.md), настроенный `yc`. Managed PostgreSQL платный даже минимальный (небольшие деньги в час, но не ноль): кластер удалишь в конце урока. Если облака нет, задания 1-4 читаются как разбор по выводам, а письменная часть задания 5 выполняется целиком.

### Задание 1. Кластер Managed PostgreSQL

**Цель:** создать минимальный кластер в той же сети, что и ВМ, и закрыть доступ security group.

**Предскажи:** после команды `create` можно сразу подключаться?

<details>
<summary>Ответ</summary>

Нет. Команда запускает долгую операцию: создание хоста и диска занимает минуты. Пока статус не `RUNNING`, подключаться нельзя.

</details>

**Шаги:**

1. Возьми имена сети, подсети и зоны из урока 6.2 (в примере сеть `notes-net`, подсеть `notes-subnet-a`, зона `ru-central1-a`; подставь свои). Пароль сгенерируй и держи в переменной сессии:

```bash
# Пароль только в переменной текущей сессии, в файл не пишем
export PGPASS_NOTES="$(openssl rand -base64 24 | tr -d '=+/')"

# Минимальный кластер: один хост, диск 10 ГБ, без публичного адреса
yc managed-postgresql cluster create \
  --name notes-pg \
  --environment production \
  --network-name notes-net \
  --postgresql-version 18 \
  --resource-preset s2.micro \
  --disk-type network-ssd --disk-size 10 \
  --host zone-id=ru-central1-a,subnet-name=notes-subnet-a \
  --user name=notes,password="$PGPASS_NOTES" \
  --database name=notes,owner=notes
```

Пресет и версию проверь в списках провайдера: `yc managed-postgresql resource-preset list` и `yc managed-postgresql cluster list-versions`. Если версии 18 нет, выбери самую новую и запомни номер.

2. Дождись статуса и посмотри хост:

```bash
# Ждём RUNNING
yc managed-postgresql cluster get notes-pg | grep -E '^(name|status|health)'
yc managed-postgresql hosts list --cluster-name notes-pg
```

3. Создай отдельную security group для БД: входящий TCP 6432 только из группы ВМ, и привяжи её к кластеру.

```bash
# id группы ВМ (имя из урока 6.2, подставь своё)
VM_SG=$(yc vpc security-group get notes-vm-sg --format json | jq -r .id)

yc vpc security-group create --name notes-pg-sg --network-name notes-net \
  --rule "direction=ingress,port=6432,protocol=tcp,security-group-id=$VM_SG"

# Привязываем группу к кластеру
PG_SG=$(yc vpc security-group get notes-pg-sg --format json | jq -r .id)
yc managed-postgresql cluster update notes-pg --security-group-ids "$PG_SG"
```

**Что должно получиться:**

```text
name: notes-pg
status: RUNNING
health: ALIVE
```

Идентификаторы и FQDN у тебя будут другими. FQDN хоста понадобится дальше как `PGHOST_NOTES`.

**Объясни себе:**

- Почему у хоста нет публичного адреса и как к нему всё равно попадёт ВМ?
- Почему правило ссылается на security group ВМ, а не на IP ВМ?
- Что сломается, если создать кластер в другой сети?

**Типичные ошибки:**

- `ERROR: rpc error: code = ResourceExhausted desc = Quota limit ... exceeded`: превышена квота (кластеры или ядра): освободи ресурсы или запроси увеличение в консоли.
- `ERROR: rpc error: code = InvalidArgument desc = ... password ...`: пароль не подошёл по требованиям (длина): сгенерируй заново, `tr -d '=+/'` убирает символы, ломающие URL.
- `ERROR: rpc error: code = NotFound desc = Subnet ... not found`: имя подсети не то или она в другой зоне: сверься с `yc vpc subnet list`.

### Задание 2. Подключение с ВМ по TLS

**Цель:** зайти в БД с `notes-vm` через `psql` с `sslmode=verify-full`.

**Предскажи:** что произойдёт при `sslmode=verify-full` без корневого сертификата? А если подключаться по IP хоста, а не по FQDN?

<details>
<summary>Ответ</summary>

Без сертификата: `root certificate file "..." does not exist`. По IP: проверка имени провалится, потому что в сертификате записан FQDN, а не адрес.

</details>

**Шаги:**

1. Зайди на ВМ и поставь клиент:

```bash
ssh ubuntu@notes.<твой-домен>

sudo apt-get update && sudo apt-get install -y postgresql-client
psql --version
```

2. Скачай корневой сертификат Yandex в каталог конфига «Заметок». Сертификат публичный, права 644 подходят (про права см. [урок 1.3](../01-linux/03-users-permissions.md)):

```bash
sudo mkdir -p /etc/notes/tls
sudo curl -fsSL -o /etc/notes/tls/yc-ca.pem https://storage.yandexcloud.net/cloud-certs/CA.pem
sudo chmod 644 /etc/notes/tls/yc-ca.pem
# Проверка, что это сертификат, а не HTML со страницей ошибки
openssl x509 -in /etc/notes/tls/yc-ca.pem -noout -subject -enddate
```

3. Подключись (пароль введёшь по запросу; FQDN возьми из `hosts list`):

```bash
export PGHOST_NOTES=rc1a-xxxxxxxxxxxxxxxx.mdb.yandexcloud.net

psql "host=$PGHOST_NOTES port=6432 dbname=notes user=notes sslmode=verify-full sslrootcert=/etc/notes/tls/yc-ca.pem" \
  -c "SELECT version();" \
  -c "SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid();"
```

**Что должно получиться:**

```text
subject=CN = Yandex Cloud CA
notAfter=Jun 20 12:00:00 2033 GMT
```

```text
                             version
----------------------------------------------------------------
 PostgreSQL 18.x on x86_64-pc-linux-gnu, compiled by gcc ...
```

```text
 ssl | version
-----+---------
 t   | TLSv1.3
```

Даты и патч-версия будут другими. Важно: `ssl = t` и нет предупреждений.

**Объясни себе:**

- Что проверяет `verify-full` кроме шифрования?
- Почему `sslrootcert` указывает на файл на ВМ, а не на сервер БД?
- Зачем порт 6432, а не 5432?

**Типичные ошибки:**

- `psql: error: connection to server at "rc1a-....mdb.yandexcloud.net" (10.128.0.23), port 6432 failed: root certificate file "/root/.postgresql/root.crt" does not exist`: при `verify-full` не задан `sslrootcert`: добавь параметр или положи файл в `~/.postgresql/root.crt`.
- `psql: error: connection to server ... failed: SSL error: certificate verify failed`: скачан не тот файл (например, HTML): проверь `openssl x509 -in ... -noout -subject`.
- `psql: error: connection to server ... port 6432 failed: timeout expired`: security group не пускает или другая сеть: см. раздел «Сломай и почини».

### Задание 3. Перенос данных из контейнера в Managed PostgreSQL

**Цель:** перенести таблицу `notes` из compose-БД на ВМ в Managed PostgreSQL и сверить данные.

**Предскажи:** новая заметка через приложение после переноса получит корректный `id`, если дамп сделан полным `pg_dump`? А если просто выгрузить строки с явными `id`?

<details>
<summary>Ответ</summary>

С полным `pg_dump` да: он переносит и значение последовательности (sequence) через `setval`. Выгрузка строк оставит последовательность на 1, и первый `INSERT` упадёт с `duplicate key value violates unique constraint "notes_pkey"`.

</details>

**Шаги:**

1. На ВМ останови приложение и прокси, чтобы данные не менялись (короткое окно простоя; перенос без простоя делают логической репликацией, это отдельная тема). Запомни число заметок:

```bash
cd /opt/notes
sudo docker compose -f compose.yml -f compose.prod.yml stop notes proxy

sudo docker compose -f compose.yml -f compose.prod.yml exec -T db \
  psql -U notes -d notes -Atc "SELECT count(*), max(id) FROM notes;"
```

2. Сними дамп из контейнера. `--no-owner --no-acl` убирают привязку к ролям, которых нет в managed-кластере:

```bash
sudo docker compose -f compose.yml -f compose.prod.yml exec -T db \
  pg_dump -U notes -d notes --no-owner --no-acl > /tmp/notes.sql
ls -l /tmp/notes.sql
grep -c setval /tmp/notes.sql
```

3. Загрузи дамп в Managed PostgreSQL. `ON_ERROR_STOP` остановит загрузку на первой ошибке, `--single-transaction` откатит всё при сбое:

```bash
export PGPASSWORD="<пароль из задания 1>"
psql "host=$PGHOST_NOTES port=6432 dbname=notes user=notes sslmode=verify-full sslrootcert=/etc/notes/tls/yc-ca.pem" \
  -v ON_ERROR_STOP=1 --single-transaction -f /tmp/notes.sql
```

4. Сверь количество, максимальный `id` и последовательность:

```bash
psql "host=$PGHOST_NOTES port=6432 dbname=notes user=notes sslmode=verify-full sslrootcert=/etc/notes/tls/yc-ca.pem" \
  -Atc "SELECT count(*), max(id) FROM notes;" \
  -Atc "SELECT last_value FROM notes_id_seq;"
```

5. Удали дамп, в нём данные: `shred -u /tmp/notes.sql`.

**Что должно получиться:**

```text
42|42
42
```

Первое число совпадает с записанным в шаге 1, `last_value` не меньше `max(id)`. Твои числа будут другими.

**Объясни себе:**

- Зачем дамп с `--no-owner`, если владелец в новой БД тот же `notes`?
- Зачем `--single-transaction`?
- Что будет с записями, сделанными между дампом и переключением?

**Типичные ошибки:**

- `ERROR:  permission denied to create extension "..."`: в дампе есть расширение, которое без суперпользователя не создать: включи его в настройках кластера или убери из дампа, если оно не нужно.
- `ERROR:  role "postgres" does not exist`: в дампе `ALTER ... OWNER TO postgres`: сделай дамп с `--no-owner`.
- `pg_dump: error: aborting because of server version mismatch`: клиент старше сервера: запускай `pg_dump` внутри контейнера `postgres:18`, как в шаге 2.

### Задание 4. Восстановление из бэкапа в новый кластер

**Цель:** убедиться, что восстановление managed-сервиса создаёт новый кластер, и замерить время.

**Предскажи:** сколько кластеров будет после восстановления и куда указывает старый `DATABASE_URL`?

<details>
<summary>Ответ</summary>

Два: старый остаётся, появляется новый со своим FQDN. Старый `DATABASE_URL` по-прежнему указывает на старый кластер, пока не сменишь хост.

</details>

**Шаги:**

1. Создай бэкап вручную и посмотри список. Для PITR к `restore` добавляют `--time` (например, `2026-09-29T12:00:00Z`, момент между бэкапом и последним WAL):

```bash
yc managed-postgresql cluster backup notes-pg
BACKUP_ID=$(yc managed-postgresql cluster list-backups notes-pg --format json | jq -r '.[0].id')

yc managed-postgresql cluster restore \
  --backup-id "$BACKUP_ID" --name notes-pg-restore --environment production \
  --network-name notes-net --host zone-id=ru-central1-a,subnet-name=notes-subnet-a \
  --resource-preset s2.micro --disk-type network-ssd --disk-size 10
```

2. Замерь время до `RUNNING`, сверь `count(*)` через `psql` как в задании 2 и сразу удали кластер, чтобы не платить: `yc managed-postgresql cluster delete notes-pg-restore`. Если квота или бюджет не позволяют, письменно опиши, что пришлось бы поменять после восстановления (`DATABASE_URL`, security group, пользователи).

**Что должно получиться:**

```text
done (11m42s)
name: notes-pg-restore
status: RUNNING
```

Время у тебя будет другим, но это минуты, а не секунды.

**Объясни себе:**

- Что не переносится вместе с данными и что надо повторить вручную?
- Сколько данных потеряешь (RPO), если авария случилась через 3 минуты после последнего бэкапа при включённом WAL-архиве?

**Типичные ошибки:**

- `ERROR: rpc error: code = InvalidArgument desc = ... recovery time ... is out of range`: `--time` вне окна PITR: возьми момент между временем бэкапа и текущим.
- `ERROR: rpc error: code = ResourceExhausted desc = Quota limit ... exceeded`: нет квоты на второй кластер: удали лишнее или запроси увеличение.

### Задание 5. Шаг проекта: «Заметки» на Managed PostgreSQL

**Цель:** переключить продовые «Заметки» на Managed PostgreSQL, убрать `db` из `compose.prod.yml`, зафиксировать в репозитории и письменно разобрать, что ты больше не делаешь сам.

**Предскажи:** приложение читает `DATABASE_URL` из `.env`. Хватит поменять только эту строку?

<details>
<summary>Ответ</summary>

Нет. Контейнер должен видеть файл корневого сертификата, иначе `verify-full` в libpq (внутри `psycopg`) упадёт. Файл монтируют в контейнер, путь указывают в `sslrootcert`.

</details>

**Шаги:**

1. В репозитории `~/notes` измени `compose.prod.yml` (остальное содержимое из урока 6.3 не трогаем). Сервис `db` остаётся в `compose.yml` для локальной разработки, а на проде его отключает профиль. Сервис `notes` получает сертификат:

```yaml
services:
  notes:
    # Сертификат провайдера только для чтения; путь совпадает с sslrootcert в DATABASE_URL
    volumes:
      - /etc/notes/tls/yc-ca.pem:/certs/yc-ca.pem:ro
    # Ждать локальную БД больше не нужно
    depends_on: !reset []

  db:
    # На проде не запускается: сервис включается только профилем local
    profiles: ["local"]
```

Проверка без запуска контейнеров: `docker compose -f compose.yml -f compose.prod.yml config --services` не должна показывать `db`.

2. На ВМ поправь `/opt/notes/.env` (владелец root, `sudo chmod 640`). Пароль пока остаётся в файле: это осознанный долг до темы секретов. Пример с заглушкой:

```bash
# /opt/notes/.env: CHANGE_ME замени на пароль из задания 1
DATABASE_URL=postgresql://notes:CHANGE_ME@rc1a-xxxxxxxxxxxxxxxx.mdb.yandexcloud.net:6432/notes?sslmode=verify-full&sslrootcert=/certs/yc-ca.pem
```

3. Запусти и проверь:

```bash
cd /opt/notes
sudo docker compose -f compose.yml -f compose.prod.yml config --services
sudo docker compose -f compose.yml -f compose.prod.yml up -d
sudo docker compose -f compose.yml -f compose.prod.yml ps

curl -fsS https://notes.<твой-домен>/readyz
curl -fsS -X POST https://notes.<твой-домен>/notes -H 'Content-Type: application/json' -d '{"text":"после переезда в managed"}'
curl -fsS https://notes.<твой-домен>/notes | tail -c 200
```

4. Убедись, что заметка видна и в managed-БД (`psql` из задания 2, `SELECT count(*) FROM notes;`). Старую БД останови, а её том оставь на несколько дней как страховку:

```bash
sudo docker compose -f compose.yml -f compose.prod.yml --profile local stop db
```

5. Зафиксируй изменение в `~/notes` (`.env` в git не попадает, он в `.gitignore` с урока 4.5). Версия приложения не меняется: `app.py` остаётся 0.4.1:

```bash
cd ~/notes
git add compose.prod.yml
git commit -m "prod: Managed PostgreSQL, db только для профиля local"
git push
```

6. Письменно (в тетради или `README.md`) ответь: что ты больше не делаешь сам, а что осталось тебе. Образец:

| Больше не делаю | Осталось мне |
|---|---|
| патчи и обновления PostgreSQL | схема и миграции |
| настройка бэкапов и WAL-архива | проверка, что бэкап восстанавливается |
| failover на реплику | сеть, security group, TLS на клиенте |
| диск и его расширение | пароли и их хранение (пока в `.env`) |
| мониторинг «железа» БД | медленные запросы, число соединений |

**Что должно получиться:**

```text
notes
proxy
```

```text
ready
```

```text
NAME            IMAGE                             STATUS
notes-notes-1   ghcr.io/<github-user>/notes:...   Up 20 seconds
notes-proxy-1   nginx:1.30                        Up 20 seconds
```

Сервиса `db` нет, заметка после `POST` видна при повторном `GET` и в `psql` к managed-кластеру.

**Объясни себе:**

- Почему `db` не удалён из `compose.yml`, а спрятан профилем?
- Где сейчас лежит пароль БД и почему это долг?
- Как быстро откатиться на старую БД, если что-то пошло не так?

**Типичные ошибки:**

- `psycopg.OperationalError: connection failed: connection to server at "10.128.0.23", port 6432 failed: FATAL:  no pg_hba.conf entry for host "10.128.0.5", user "notes", database "notes", no encryption`: клиент пришёл без TLS, в `DATABASE_URL` нет `sslmode`: добавь `sslmode=verify-full`.
- `psycopg.OperationalError: ... root certificate file "/certs/yc-ca.pem" does not exist`: сертификат не смонтирован: проверь `volumes` и путь на ВМ.
- `service "notes" depends on undefined service "db": invalid compose project`: `depends_on` не сброшен: добавь `depends_on: !reset []` (нужен современный Compose v2).

## Сломай и почини

Запусти в каталоге `~/notes` на своей машине (скрипт лежит в эталонном репозитории курса; читать его до починки не нужно):

```bash
bash break/6.4/break.sh random
```

Скрипт выберет одну из трёх поломок подключения «Заметок» к Managed PostgreSQL. Починив, проверь, что `/readyz` отвечает `ready`. Скрипт `bash break/6.4/fix.sh` запускай, только если застрял.

### Симптом

После изменения приложение отвечает 503 на `/readyz`, заметки не читаются и не пишутся. Первое, что смотришь:

```bash
sudo docker compose -f compose.yml -f compose.prod.yml logs --tail=20 notes
```

### Гипотезы

Прежде чем что-либо менять, пройди список:

1. Клиент пришёл без TLS или с неверным режимом (в тексте `pg_hba.conf`, `SSL`).
2. До БД не доходит трафик: security group, сеть, порт или FQDN (`timeout expired`).
3. Соединение есть, но запись падает на уровне данных: дубликат ключа, сломана последовательность.

### Проверки

Одна проверка на одну гипотезу, только чтение:

```bash
# Гипотеза 1: какой sslmode в строке подключения (пароль скрыт)
sudo grep -o 'DATABASE_URL=.*' /opt/notes/.env | sed 's#://[^@]*@#://***@#'

# Гипотеза 2: доходит ли TCP до порта и что разрешает группа кластера
timeout 5 bash -c "</dev/tcp/$PGHOST_NOTES/6432" && echo open || echo closed
yc vpc security-group get notes-pg-sg

# Гипотеза 3: последовательность против данных
psql "host=$PGHOST_NOTES port=6432 dbname=notes user=notes sslmode=verify-full sslrootcert=/etc/notes/tls/yc-ca.pem" \
  -Atc "SELECT max(id) FROM notes;" -Atc "SELECT last_value FROM notes_id_seq;"
```

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**Сценарий 1. `no pg_hba.conf entry ... no encryption` или `SSL is required`.**
Причина: в `DATABASE_URL` нет `sslmode` или стоит `disable`. Managed-кластер принимает только TLS, правила для нешифрованных соединений в его `pg_hba.conf` нет.
Починка: добавить `?sslmode=verify-full&sslrootcert=/certs/yc-ca.pem` и выполнить `docker compose ... up -d` (переменные окружения подхватываются при пересоздании контейнера, `restart` не поможет).
Вывод: сервер ответил текстом ошибки, значит сеть в порядке.

**Сценарий 2. `timeout expired`.**
Причина: в security group кластера нет правила для группы ВМ на 6432 или группа не привязана к кластеру. Пакеты молча отбрасываются, поэтому ответа нет вообще.
Починка: добавить правило ingress TCP 6432 из группы ВМ и привязать группу (команды из задания 1, шаг 3).
Вывод: таймаут означает файрвол или маршрут; `refused` означает, что хост достигнут, но порт никто не слушает; ошибка аутентификации означает, что сеть уже в порядке.

**Сценарий 3. `duplicate key value violates unique constraint "notes_pkey"` после миграции.**
Причина: строки загружены с явными `id`, последовательность осталась ниже `max(id)`.
Починка:

```sql
-- Двигаем последовательность к максимальному id
SELECT setval(pg_get_serial_sequence('notes', 'id'), (SELECT max(id) FROM notes));
```

Вывод: полный `pg_dump` переносит `setval`, самодельные выгрузки нет. После любой миграции данных сверяй последовательности.

</details>

## Вопросы с собеседований

### 1. [middle] Прод отвечает 502, в логах приложения `connection timed out` к БД. Твои действия?

Сначала смотрю, что менялось: деплой, правка security group, обновление кластера. С хоста приложения проверяю порт БД (`nc` или `/dev/tcp`), потом статус кластера в консоли и метрики (CPU, диск, соединения). Порт закрыт: ищу правила security group и маршрут. Порт открыт, но БД не отвечает: смотрю нагрузку и число соединений.

**Что хотят услышать:** порядок от дешёвого к дорогому: что менялось, сеть, статус сервиса, нагрузка; разницу между timeout (файрвол), refused и auth failed.

**Красный флаг:** «перезапущу приложение» без диагностики; «перезагружу БД».

### 2. [middle] `psql` говорит `no pg_hba.conf entry for host ..., no encryption`. Что это и как чинить?

Клиент подключился без TLS, а managed-кластер принимает только шифрованные соединения. Значит сеть и порт в порядке. Добавляю `sslmode=verify-full` и путь к корневому сертификату провайдера.

**Что хотят услышать:** что такое `pg_hba.conf` и что на managed его не правят; разница режимов `sslmode`; почему именно `verify-full`.

**Красный флаг:** «открою доступ всем» или «поставлю `sslmode=disable`».

### 3. [middle] После переезда БД приложение падает на записи: `duplicate key value violates unique constraint`. Причина?

Данные перенесли выгрузкой строк, а последовательность (sequence) не продвинули, и она выдаёт уже занятые `id`. Смотрю `max(id)` и `last_value`, выравниваю через `setval`. В следующий раз делаю полный `pg_dump`.

**Что хотят услышать:** связь `serial` и sequence; `setval` и `pg_get_serial_sequence`; сверка после миграции.

**Красный флаг:** «уберу уникальность» или «пересоздам таблицу».

### 4. [middle] Ночью упал мастер managed PostgreSQL. Что произойдёт и что делаешь ты?

При включённом HA провайдер повысит реплику, FQDN остаётся, соединения обрываются на десятки секунд. Приложение должно переподключаться (retry) и не держать мёртвые соединения. Я проверяю, что сервис восстановился, что реплика создана заново, разбираю причину.

**Что хотят услышать:** HA и failover, обрыв соединений, переподключение в клиенте, RPO около нуля при синхронной репликации и небольшой при асинхронной.

**Красный флаг:** «ничего, облако само»; «вручную переключу DNS».

### 5. [middle] В 14:07 кто-то выполнил `DELETE FROM notes` без `WHERE`. Реплика есть. Как восстановиться?

Реплика повторила удаление и не поможет. Делаю PITR в новый кластер на 14:06, сверяю данные, потом либо переключаю приложение, либо переношу нужные строки в боевой кластер. Старый не трогаю до сверки.

**Что хотят услышать:** HA это не бэкап; PITR идёт в новый кластер; RPO и RTO; проверка перед переключением; разбор причины (права, процесс).

**Красный флаг:** «откачу с реплики»; «поставлю самый свежий бэкап», потеряв данные после него.

### 6. [middle] Приложение открывает соединение на каждый запрос, БД отвечает `too many connections`. Что делать?

Быстро: пул соединений на стороне сервиса (в Yandex порт 6432) или pgbouncer. Постоянно: пул в самом приложении и лимиты соединений. Отдельно проверяю утечки соединений и долгие транзакции в `pg_stat_activity`.

**Что хотят услышать:** connection pooling, режим transaction, цену соединения в PostgreSQL (процесс на соединение), диагностику через `pg_stat_activity`.

**Красный флаг:** «просто подниму `max_connections`».

### 7. [middle] Как перенести БД на managed с минимальным простоем?

Простой вариант: короткое окно, остановка записи, `pg_dump`, загрузка, переключение. Для большой БД: логическая репликация (publication и subscription) или сервис миграции провайдера: синхронизируем, сверяем данные, на секунды останавливаем запись, догоняем и переключаем `DATABASE_URL`. Обязательно проверяю последовательности и держу план отката.

**Что хотят услышать:** дамп против логической репликации, сверка данных, откат, последовательности, заморозка записи.

**Красный флаг:** «остановим сайт на ночь» без плана отката; «скопируем файлы данных».

### 8. [junior] Managed или self-hosted PostgreSQL: как выбираешь?

Смотрю на команду и требования. Нет людей, которые умеют восстанавливать и обновлять PostgreSQL, и нет особых расширений: беру managed, плачу деньгами и экономлю часы и риск. Self-hosted, если нужен контроль, особые расширения или требования по размещению данных.

**Что хотят услышать:** сравнение по стоимости, эксплуатации и контролю; SLA провайдера; нет суперпользователя; переносимость через дамп.

**Красный флаг:** «managed всегда дорого и плохо» или «managed решает все проблемы».

### 9. [junior] Чем L4-балансировщик отличается от L7 и что выберешь для веб-приложения?

L4 работает с TCP/UDP и не видит HTTP. L7 понимает хост и путь, завершает TLS, делает редиректы и проверки по HTTP. Для веб-приложения с несколькими маршрутами беру L7, для БД, очередей и произвольного TCP L4.

**Что хотят услышать:** что умеет L7 (завершение TLS, маршрутизация), что клиентский IP за L7 приходит в `X-Forwarded-For`.

**Красный флаг:** не знает, где завершается TLS; путает балансировщик с DNS.

### 10. [middle] Тебе предлагают Managed Kubernetes для одного небольшого сервиса. Согласишься?

Скорее нет. За control plane платим отдельно, нужно минимум несколько узлов, плюс эксплуатация кластера: версии, сеть, безопасность. Одному сервису хватит ВМ с compose или PaaS. Kubernetes оправдан, когда сервисов много и нужны единые практики деплоя и автоскейлинг.

**Что хотят услышать:** стоимость control plane и узлов; что провайдер обновляет control plane, а узлы и приложения нет; критерии выбора и альтернативы.

**Красный флаг:** «Kubernetes везде, потому что все так делают».

## Проверено на версиях

- PostgreSQL: 18 (Managed и клиент `psql`; список версий провайдера проверь в консоли)
- Yandex Cloud CLI (`yc`): версия не закреплена, проверь актуальную версию на странице проекта
- Ubuntu на ВМ: 26.04 LTS или 24.04
- nginx: 1.30 (контейнер `proxy` из урока 4.6)
- Docker Compose: плагин `docker compose` из урока 4.1 (тег `!reset` требует современного Compose v2)
- «Заметки»: 0.4.1 (`app.py` v4)

## Итог урока: ты умеешь

- [ ] умею объяснить, что Managed PostgreSQL делает за тебя и что остаётся тебе
- [ ] умею создать минимальный кластер и ограничить доступ security group
- [ ] умею подключиться по TLS с `sslmode=verify-full` и корневым сертификатом провайдера
- [ ] умею перенести БД полным `pg_dump` и сверить строки и последовательности
- [ ] умею объяснить разницу между HA, репликой и бэкапом и почему PITR создаёт новый кластер
- [ ] умею по тексту ошибки отличить проблему TLS, сети и данных
- [ ] умею оценить, нужен ли Managed Kubernetes, и выбрать между L4 и L7

**Дальше:** [Урок 6.5: Эксплуатация в облаке: бэкапы, стоимость, надёжность, удаление](05-cloud-ops-cost.md)
