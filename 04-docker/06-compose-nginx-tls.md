---
layout: lesson
title: "Compose: nginx и TLS перед «Заметками»"
topic: 4
lesson: "4.6"
time: "2 ч"
---

## Зачем это нужно

В уроке 4.5 стек из «Заметок» и PostgreSQL описан одним `compose.yml`, но приложение всё ещё опубликовано на `127.0.0.1:8080`, а HTTPS нет. В проде так не бывает: наружу смотрит только обратный прокси (reverse proxy), который терминирует TLS, а приложение и база доступны лишь внутри сети. Типичные аварии здесь две: после пересоздания приложения прокси отвечает 502, и база случайно опубликована на весь интернет из-за `ports: "5432:5432"`.

Шаг проекта: в `compose.yml` появляется сервис `proxy` (nginx 1.30) на портах 80 и 443, порт 8080 больше не публикуется, сертификат делает скрипт `scripts/gen-tls.sh`, логи контейнеров ротируются.

## Что нужно знать

- [Урок 4.5: Compose и PostgreSQL](05-compose-postgres.md) - `compose.yml`, сервисы `notes` и `db`, `.env`, healthcheck.
- [Урок 4.3: тома и сети Docker](03-storage-networks.md) - встроенный DNS по имени, `-p 127.0.0.1:...`.
- [Урок 2.5: nginx](../02-network/05-nginx.md) - `proxy_pass`, заголовки `X-Forwarded-*`, `nginx -t`.
- [Урок 2.6: TLS](../02-network/06-tls.md) - сертификат, SAN, `openssl s_client`, редирект 80 на 443.
- [Урок 2.3: DNS](../02-network/03-dns.md) - как имя превращается в адрес и что такое кэш.

## Теория

### Что публиковать наружу

Публикация порта (`ports`) пробрасывает порт хоста в контейнер через правила iptables, которые Docker пишет сам. Эти правила обходят ufw ([урок 2.7](../02-network/07-firewall.md)): порт, опубликованный как `"5432:5432"`, открыт всему миру, даже если ufw его закрывает. Поэтому правило одно: наружу публикуется только то, что должно быть видно клиентам. Для «Заметок» это 80 и 443 у `proxy`. Сервисы `notes` и `db` не имеют ключа `ports` вообще: друг друга они находят по имени в сети `notes-net`, и этого достаточно. Ключ `expose` ничего не публикует и служит только документацией.

Для отладки приложения без прокси публикуют порт на loopback: `127.0.0.1:8080:8080`. Такой порт виден только с самого хоста.

> **Проверь понимание:** в `compose.yml` у `db` стоит `ports: ["5432:5432"]`, а ufw закрывает 5432. Доступна ли база из интернета?

<details markdown="1">
<summary>Ответ</summary>

Да, скорее всего доступна: правила Docker в цепочке DOCKER стоят раньше правил ufw. Правильно убрать `ports` у `db` совсем или написать `127.0.0.1:5432:5432`.

</details>

### nginx в контейнере: конфиг и DNS

Официальный образ `nginx:1.30` читает `/etc/nginx/conf.d/*.conf`. Свой конфиг монтируют поверх `default.conf` только для чтения (`:ro`): тогда правка файла на хосте и `docker compose restart proxy` меняют поведение без пересборки образа. Сертификат и ключ монтируют отдельным каталогом, тоже `:ro`, и в образ они не попадают никогда.

Главная ловушка: nginx разрешает имя из `proxy_pass http://notes:8080` один раз, при старте или перечитывании конфига, и запоминает IP. Если контейнер `notes` пересоздан, у него новый IP (см. [урок 4.3](03-storage-networks.md)), а nginx продолжает стучаться по старому: клиенты получают 502. Лекарство: указать resolver Docker (`127.0.0.11`, встроенный DNS-сервер сети) с коротким временем жизни ответа и положить адрес в переменную. Когда в `proxy_pass` стоит переменная, nginx разрешает имя на каждый запрос (с кэшем `valid=10s`). Побочный эффект: при старте nginx уже не падает, если `notes` ещё не существует.

> **Проверь понимание:** почему `resolver 127.0.0.11` без переменной в `proxy_pass` не решает проблему?

<details markdown="1">
<summary>Ответ</summary>

Статическое имя в `proxy_pass` разрешается при загрузке конфига, а `resolver` для него не используется. Динамическое разрешение включается только тогда, когда адрес задан через переменную.

</details>

### TLS-терминация и самоподписанный сертификат

Терминация TLS (TLS termination) означает, что шифрованное соединение заканчивается на прокси, а до приложения трафик идёт по HTTP внутри сети Compose. Приложению сообщают схему заголовком `X-Forwarded-Proto: https`. Учебный сертификат самоподписанный (self-signed): браузер ему не доверяет, но шифрование работает так же, как с настоящим. Ключевое поле здесь SAN (Subject Alternative Name): современные клиенты сверяют имя именно с ним, а не с CN. Сертификат выпускает скрипт `scripts/gen-tls.sh`, каталог `deploy/tls` лежит в `.gitignore`: приватный ключ в git не попадает. Настоящий сертификат Let's Encrypt появится в теме 6.

> **Проверь понимание:** зачем `curl --resolve notes.lab:443:127.0.0.1` вместо правки `/etc/hosts`?

<details markdown="1">
<summary>Ответ</summary>

Флаг подставляет адрес только для одной команды: имя `notes.lab` остаётся настоящим для TLS и заголовка `Host`, а систему править не нужно.

</details>

### Логи контейнеров и их ротация

Драйвер `json-file` по умолчанию пишет stdout и stderr контейнера в файл на хосте и не ограничивает его размер. Шумный сервис за месяц забивает диск (это классическая причина «диск заполнен, а du по приложению мало»: файл лежит в `/var/lib/docker/containers`). Ограничение задают опциями `max-size` и `max-file`. Меняются они только при пересоздании контейнера.

> **Проверь понимание:** ты добавил `max-size: 10m` в `compose.yml` и сделал `docker compose restart proxy`. Ротация включилась?

<details markdown="1">
<summary>Ответ</summary>

Нет. `restart` не применяет новую конфигурацию, нужен `docker compose up -d`, который пересоздаст контейнер.

</details>

## Практика

Работай в каталоге `~/notes`, где после 4.5 есть `compose.yml`, `.env` и `Dockerfile`. Порты 80 и 443 на хосте должны быть свободны: хостовые `nginx` и `notes` остановлены в [уроке 4.1](01-containers-idea.md).

```bash
cd ~/notes
sudo ss -ltnp | grep -E ':(80|443)\s' || echo "80 и 443 свободны"
docker compose ps
```

```text
80 и 443 свободны
NAME            IMAGE       COMMAND              SERVICE   CREATED         STATUS                   PORTS
notes-db-1      postgres:18 "docker-entrypoint.s…"  db        5 minutes ago   Up 5 minutes (healthy)   5432/tcp
notes-notes-1   notes-notes "python app.py"        notes     5 minutes ago   Up 5 minutes             127.0.0.1:8080->8080/tcp
```

### Задание 1. Самоподписанный сертификат скриптом

**Цель:** получить `deploy/tls/notes.crt` и `notes.key` с SAN `notes.lab`.

**Предскажи:** если в сертификате будет только `CN=notes.lab` без SAN, примет ли его `curl` с флагом `--cacert`?

<details markdown="1">
<summary>Ответ</summary>

Нет. Современные версии OpenSSL и curl проверяют имя по SAN, поле CN игнорируется. Будет ошибка проверки имени.

</details>

**Шаги:**

1. Создай скрипт:

```bash
mkdir -p scripts
cat > scripts/gen-tls.sh <<'SCRIPT'
#!/usr/bin/env bash
# Генерация самоподписанного сертификата для notes.lab (365 дней).
set -euo pipefail

OUT="${1:-deploy/tls}"
mkdir -p "$OUT"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=notes.lab" \
  -addext "subjectAltName=DNS:notes.lab" \
  -keyout "$OUT/notes.key" -out "$OUT/notes.crt"

# ключ читает только владелец, сертификат публичный
chmod 600 "$OUT/notes.key"
chmod 644 "$OUT/notes.crt"
echo "готово: $OUT/notes.crt"
SCRIPT
chmod +x scripts/gen-tls.sh
shellcheck scripts/gen-tls.sh
```

2. Запусти и проверь SAN:

```bash
./scripts/gen-tls.sh
openssl x509 -in deploy/tls/notes.crt -noout -subject -ext subjectAltName -enddate
grep -qx 'deploy/tls/' .gitignore && echo "в .gitignore есть"
```

**Что должно получиться:**

```text
готово: deploy/tls/notes.crt
subject=CN = notes.lab
X509v3 Subject Alternative Name: 
    DNS:notes.lab
notAfter=Sep 29 10:00:00 2027 GMT
в .gitignore есть
```

Дата в `notAfter` будет через 365 дней от сегодня. Строку про `.gitignore` создал урок 3.1.

**Объясни себе:**

- Что случится, если закоммитить `notes.key`, и как узнать, что это уже произошло?
- Почему срок сертификата 365 дней, а не 10 лет?

**Типичные ошибки:**

- `-addext: unknown option` (или `req: Unrecognized flag addext`): слишком старый OpenSSL. На Ubuntu 24.04 и 26.04 флаг есть; обнови систему.
- `Can't open "deploy/tls/notes.key" for writing, Permission denied`: каталог `deploy/tls` создан раньше через `sudo` и принадлежит root. Исправление: `sudo chown -R "$USER" deploy/tls`.

### Задание 2. Конфиг nginx: редирект и динамический upstream

**Цель:** написать `deploy/nginx/compose.conf`, который переживает пересоздание `notes`.

**Предскажи:** в конфиге будет `set $upstream http://notes:8080;` и `proxy_pass $upstream;`. Изменится ли URI запроса `/notes?x=1`, который получит приложение?

<details markdown="1">
<summary>Ответ</summary>

Не изменится. Если в `proxy_pass` нет части URI, nginx передаёт исходный URI целиком, в том числе и при использовании переменной.

</details>

**Шаги:**

1. Создай файл:

```bash
mkdir -p deploy/nginx
cat > deploy/nginx/compose.conf <<'CONF'
# Внутренний DNS Docker; ответы кэшируются на 10 секунд
resolver 127.0.0.11 valid=10s;

server {
    listen 80;
    server_name notes.lab;
    # весь HTTP уходит на HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name notes.lab;

    ssl_certificate     /etc/nginx/tls/notes.crt;
    ssl_certificate_key /etc/nginx/tls/notes.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        # переменная заставляет nginx разрешать имя на каждый запрос
        set $upstream http://notes:8080;
        proxy_pass $upstream;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }
}
CONF
```

2. Проверь синтаксис одноразовым контейнером, не трогая стек:

```bash
docker run --rm \
  -v "$PWD/deploy/nginx/compose.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$PWD/deploy/tls:/etc/nginx/tls:ro" \
  nginx:1.30 nginx -t
```

**Что должно получиться:**

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

Проверка проходит, хотя сервиса `notes` в этой сети нет: как раз потому, что имя стоит в переменной.

**Объясни себе:**

- Что произойдёт при `nginx -t`, если заменить переменную на `proxy_pass http://notes:8080;`?
- Зачем `valid=10s`, а не `valid=0`?

**Типичные ошибки:**

- `nginx: [emerg] no resolver defined to resolve notes`: в `proxy_pass` переменная, а строки `resolver` нет. Добавь её на уровень `server` или выше.
- `nginx: [emerg] "server" directive is not allowed here`: файл смонтирован как `nginx.conf`, а не как `conf.d/default.conf`. В `nginx.conf` нужен контекст `http`.

### Задание 3. Сервис proxy в compose.yml

**Цель:** добавить `proxy`, убрать публикацию порта у `notes`, включить ротацию логов.

**Предскажи:** после правки `docker compose ps` покажет для `notes` порт `8080/tcp` без стрелки `->`. Что это значит для запроса `curl http://127.0.0.1:8080/healthz` с хоста?

<details markdown="1">
<summary>Ответ</summary>

Запрос завершится ошибкой `Connection refused`: порт хоста 8080 больше никем не слушается. Приложение доступно только контейнерам в сети `notes-net`.

</details>

**Шаги:**

1. Приведи `compose.yml` к такому виду (изменения относительно 4.5: блок `x-logging`, у `notes` нет `ports`, новый сервис `proxy`):

```yaml
# Общие настройки ротации логов, подключаются якорем
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  notes:
    build: .
    environment:
      STORE: postgres
      DATABASE_URL: postgresql://notes:${POSTGRES_PASSWORD}@db:5432/notes
      APP_VERSION: ${APP_VERSION:-dev}
    depends_on:
      db:
        condition: service_healthy
    logging: *logging

  db:
    image: postgres:18
    environment:
      POSTGRES_DB: notes
      POSTGRES_USER: notes
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U notes -d notes"]
      interval: 5s
      timeout: 3s
      retries: 10
    logging: *logging

  proxy:
    image: nginx:1.30
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./deploy/nginx/compose.conf:/etc/nginx/conf.d/default.conf:ro
      - ./deploy/tls:/etc/nginx/tls:ro
    depends_on:
      - notes
    logging: *logging

volumes:
  pgdata:

networks:
  default:
    name: notes-net
```

2. Проверь итоговый файл и подними стек:

{% raw %}
```bash
docker compose config --quiet && echo "compose.yml корректен"
docker compose up -d
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
```
{% endraw %}

**Что должно получиться:**

```text
compose.yml корректен
SERVICE   STATUS                    PORTS
db        Up 20 seconds (healthy)   5432/tcp
notes     Up 15 seconds             8080/tcp
proxy     Up 14 seconds             0.0.0.0:80->80/tcp, [::]:80->80/tcp, 0.0.0.0:443->443/tcp, [::]:443->443/tcp
```

Стрелка `->` есть только у `proxy`. Порты `5432/tcp` и `8080/tcp` без стрелки означают «объявлены образом, но не опубликованы».

**Объясни себе:**

- Почему `depends_on: notes` у `proxy` не гарантирует, что приложение уже принимает запросы, и почему для нашего конфига это не страшно?
- Что делает `*logging` и чем якорь лучше копирования?

**Типичные ошибки:**

- `Bind for 0.0.0.0:80 failed: port is already allocated` (или `address already in use`): порт занят хостовым nginx или другим контейнером. Найди владельца `sudo ss -ltnp | grep ':80 '` и останови его.
- `yaml: unmarshal errors: line 1: field x-logging not found`: у старой версии Compose нет расширений. Проверь `docker compose version`, нужна v2 и новее.

### Задание 4. Проверка снаружи: HTTP, HTTPS и заголовки

**Цель:** убедиться, что редирект и TLS работают, а внутренние порты закрыты.

**Предскажи:** какой код вернёт `curl -sI http://notes.lab/` и в каком заголовке будет адрес назначения?

<details markdown="1">
<summary>Ответ</summary>

Код `301 Moved Permanently`, адрес в `Location: https://notes.lab/`.

</details>

**Шаги:**

1. Все запросы с подменой адреса через `--resolve`, доверяем нашему сертификату:

```bash
R='--resolve notes.lab:80:127.0.0.1 --resolve notes.lab:443:127.0.0.1'
curl -sI $R http://notes.lab/ | head -3
curl -s $R --cacert deploy/tls/notes.crt https://notes.lab/healthz
curl -s $R --cacert deploy/tls/notes.crt -X POST -d 'через прокси' https://notes.lab/notes
curl -s $R --cacert deploy/tls/notes.crt https://notes.lab/notes
```

2. Убедись, что напрямую приложение и база недоступны:

```bash
curl -sS --max-time 3 http://127.0.0.1:8080/healthz || true
nc -zv -w 2 127.0.0.1 5432 || true
```

3. Посмотри, что видит клиент в рукопожатии:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername notes.lab 2>/dev/null \
  | grep -E 'subject=|Verify return code|Protocol'
```

**Что должно получиться:**

```text
HTTP/1.1 301 Moved Permanently
Server: nginx/1.30.0
Date: Tue, 29 Sep 2026 10:05:00 GMT
ok
```

К этим строкам добавятся ответ на `POST`, список заметок с текстом `через прокси`, затем:

```text
curl: (7) Failed to connect to 127.0.0.1 port 8080 after 0 ms: Couldn't connect to server
nc: connect to 127.0.0.1 port 5432 (tcp) failed: Connection refused
subject=CN = notes.lab
Verify return code: 18 (self-signed certificate)
Protocol  : TLSv1.3
```

Код 18 ожидаем: сертификат самоподписанный, клиент ему не доверяет без `--cacert`.

**Объясни себе:**

- Что означает `Verify return code: 18` и как он изменится, если передать `-CAfile deploy/tls/notes.crt`?
- Какой заголовок увидит приложение в `X-Forwarded-Proto`?

**Типичные ошибки:**

- `curl: (60) SSL certificate problem: self-signed certificate`: не передан `--cacert deploy/tls/notes.crt`. Не лечи флагом `-k` в скриптах: он отключает проверку целиком.
- `curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL`: nginx не поднялся. Смотри `docker compose logs proxy`.
- `curl: (60) SSL: no alternative certificate subject name matches target host name 'localhost'`: запрос без `--resolve` к имени, которого нет в SAN.

### Задание 5. Шаг проекта: полный стек и живучесть

**Цель:** зафиксировать в проекте стек proxy, notes, db и доказать, что пересоздание приложения не ломает прокси и что логи ротируются.

**Предскажи:** ты пересоздаёшь `notes` командой `docker compose up -d --force-recreate notes`. Получит ли клиент 502 в ближайшие 10 секунд и почему?

<details markdown="1">
<summary>Ответ</summary>

Возможен короткий 502 или ошибка, пока приложение стартует (секунды). Но после старта запросы пойдут на новый IP уже без перезапуска nginx: имя разрешается заново (кэш 10 секунд, затем новый запрос к DNS Docker).

</details>

**Шаги:**

1. Запомни IP приложения, пересоздай его и проверь снова:

{% raw %}
```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' notes-notes-1
docker compose up -d --force-recreate notes
sleep 12
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' notes-notes-1
curl -s --resolve notes.lab:443:127.0.0.1 --cacert deploy/tls/notes.crt https://notes.lab/notes
```
{% endraw %}

2. Проверь ротацию логов:

{% raw %}
```bash
docker inspect -f '{{.HostConfig.LogConfig}}' notes-proxy-1
```
{% endraw %}

3. Сохрани состояние проекта в git:

```bash
git add compose.yml deploy/nginx/compose.conf scripts/gen-tls.sh .gitignore
git status --short
git commit -m "compose: proxy nginx 1.30 с TLS, порт 8080 не публикуется"
```

**Что должно получиться:**

```text
172.18.0.3
172.18.0.4
через прокси
{json-file map[max-file:3 max-size:10m]}
```

IP двух вызовов отличаются (адреса у тебя могут быть другими), заметка на месте, а `git status` не показывает `deploy/tls/` и `.env`. Эталон файлов: [project/notes на GitHub](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Объясни себе:**

- Почему заметка не пропала после пересоздания `notes`, хотя контейнер новый?
- Что бы изменилось, если убрать `set $upstream` и вернуть статический `proxy_pass`?

**Типичные ошибки:**

- `Error response from daemon: No such container: notes-notes-1`: имя контейнера зависит от названия каталога проекта. Возьми точное имя из `docker compose ps`.
- `error: pathspec 'deploy/nginx/compose.conf' did not match any files`: файл не создан или ты вне `~/notes`.

## Сломай и почини

Сценарии запускает скрипт из эталона. Не читай его: смысл в диагностике. Выбери номер 1, 2 или 3 (разбор ниже, подглядывай после попытки).

```bash
cd ~/notes
bash break/4.6/break.sh 1
```

### Симптом

После запуска `docker compose up -d` сайт `https://notes.lab` не отвечает или отвечает ошибкой. Ты знаешь только это. Для каждого номера симптом свой: контейнер `proxy` постоянно перезапускается, либо клиент получает 502, либо HTTPS не поднимается.

### Гипотезы

Выпиши минимум три, прежде чем что-то менять:

1. Ошибка в конфиге nginx (имя upstream, синтаксис).
2. Приложение недоступно или сменило адрес.
3. Файлы сертификата отсутствуют или смонтированы не туда.
4. Порт занят другим процессом.

### Проверки

```bash
docker compose ps -a
docker compose logs --tail=20 proxy
docker exec notes-proxy-1 nginx -t
docker exec notes-proxy-1 ls -l /etc/nginx/tls
docker exec notes-proxy-1 getent hosts notes
```

Начинай с `ps -a` и логов `proxy`: первая же строка `[emerg]` обычно называет причину и файл.

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

**Сценарий 1. `host not found in upstream`.** В логе:

```text
nginx: [emerg] host not found in upstream "notes" in /etc/nginx/conf.d/default.conf:22
```

Статический `proxy_pass` разрешается при старте, а имя не находится: сервис назван иначе или `notes` ещё не в сети. Исправление: привести конфиг к виду из задания 2 (`resolver` и `set $upstream`) и проверить имя сервиса в `compose.yml`, затем `docker compose up -d --force-recreate proxy`.

**Сценарий 2. 502 после пересоздания notes.** `curl` возвращает `502 Bad Gateway`, а в логе `proxy`:

```text
connect() failed (113: No route to host) while connecting to upstream, upstream: "http://172.18.0.3:8080/"
```

В логе старый IP: nginx закэшировал адрес при старте. Проверка: сравни IP из лога с `docker inspect` контейнера `notes`. Исправление: переменная в `proxy_pass` вместе с `resolver 127.0.0.11 valid=10s` (постоянное решение) или `docker compose restart proxy` (временное).

**Сценарий 3. TLS-файлы не смонтированы.** Контейнер `proxy` уходит в цикл перезапусков, в логе:

```text
nginx: [emerg] cannot load certificate "/etc/nginx/tls/notes.crt": BIO_new_file() failed (SSL: error:80000002:system library::No such file or directory
```

Проверка: `docker exec` не сработает на перезапускающемся контейнере, поэтому смотри `docker compose config` (секция `volumes` у `proxy`) и `ls deploy/tls`. Причины: не запущен `gen-tls.sh` или в `volumes` путь другой. Исправление: `./scripts/gen-tls.sh` и верный том `./deploy/tls:/etc/nginx/tls:ro`, затем `docker compose up -d`.

</details>

## Вопросы с собеседований

### 1. [junior] Прод отвечает 502 за nginx в Compose, приложение только что задеплоили. Твои действия?

Смотрю `docker compose ps`, живо ли приложение и не перезапускается ли. Читаю `docker compose logs proxy`: там видно, к какому адресу nginx не смог подключиться. Сравниваю этот IP с реальным у контейнера `notes` через `docker inspect`. Если адрес старый, значит nginx кэширует IP: перезапускаю прокси и потом чиню конфиг.

**Что хотят услышать:** порядок от статуса к логам, знание про кэш DNS в nginx, `resolver 127.0.0.11` и переменную в `proxy_pass`.

**Красный флаг:** сразу «перезапущу всё» без чтения логов.

### 2. [middle] Nginx в Compose не стартует: `host not found in upstream "notes"`. Почему и как починить?

При статическом `proxy_pass` nginx разрешает имя при загрузке конфига. Имя не находится: опечатка в названии сервиса, `notes` в другой сети или ещё не создан. Проверяю имена в `compose.yml` и `getent hosts notes` внутри сети. Постоянное решение: `resolver` и переменная, чтобы старт не зависел от порядка.

**Что хотят услышать:** статическое и динамическое разрешение, встроенный DNS `127.0.0.11`, что `depends_on` не про DNS.

**Красный флаг:** «добавлю `sleep` перед стартом nginx».

### 3. [junior] Что публикуешь наружу в стеке nginx, приложение, база и почему?

Только 80 и 443 у прокси. Приложение и база общаются по имени внутри сети Compose. Для отладки публикую порт на `127.0.0.1`. Публикация обходит ufw, поэтому лишний `ports` у базы открывает её всему интернету.

**Что хотят услышать:** обход ufw через iptables Docker, `127.0.0.1:` в публикации, минимальная поверхность атаки.

**Красный флаг:** «открою 5432, чтобы удобно ходить DBeaver'ом».

### 4. [middle] Порт 5432 базы оказался доступен из интернета, хотя ufw его закрывает. Что произошло?

Docker сам пишет правила iptables для опубликованных портов, и они стоят раньше правил ufw. Ищу в `compose.yml` `ports: "5432:5432"` и убираю публикацию или привязываю к `127.0.0.1`. Проверяю снаружи `nmap` или `nc`, меняю пароль базы на случай, если её уже сканировали.

**Что хотят услышать:** цепочка DOCKER, `DOCKER-USER`, смена пароля как часть реакции.

**Красный флаг:** «ufw закрыт, значит всё закрыто».

### 5. [middle] Диск заполнился, а `du` по каталогу приложения показывает мало. Что проверишь?

Смотрю `df -h`, затем `sudo du -xh /var/lib/docker | sort -h | tail`. Часто виновата логи контейнеров `json-file` без ограничения: файлы `*-json.log`. Решение: `max-size` и `max-file` в `logging` и пересоздание контейнеров через `up -d`. Разово: `docker system df`.

**Что хотят услышать:** `/var/lib/docker/containers`, ротация, что `restart` настройки не применяет.

**Красный флаг:** `truncate` в чужом файле без понимания причины и без ротации.

### 6. [middle] Браузер ругается на сертификат на новом стенде, а `curl` без `-k` тоже падает. Как разберёшься?

Смотрю `openssl s_client -connect host:443 -servername имя` и вывод `Verify return code`. Проверяю, что имя в SAN совпадает с запрошенным, срок не истёк и цепочка полная. Для самоподписанного сертификата код 18 ожидаем, для Let's Encrypt должен быть 0.

**Что хотят услышать:** SAN вместо CN, `-servername` (SNI), проверка срока и цепочки.

**Красный флаг:** «отключу проверку сертификата в клиенте».

### 7. [junior] Чем отличаются `docker compose restart` и `docker compose up -d`, когда ты поменял `compose.yml`?

`restart` перезапускает те же контейнеры с прежней конфигурацией. `up -d` сравнивает конфиг и пересоздаёт изменившиеся сервисы. Поэтому новые порты, тома и `logging` применяются только через `up -d`. Правку смонтированного конфига nginx достаточно применить перезапуском.

**Что хотят услышать:** пересоздание контейнера, что перезапуск не читает новый compose-файл.

**Красный флаг:** «это одно и то же».

### 8. [middle] Как обновить приложение за nginx в Compose без простоя?

В одном узле Compose это ограничено: `up -d` пересоздаёт контейнер, и есть короткое окно. Уменьшаю его через healthcheck и `resolver`, чтобы прокси быстро увидел новый адрес. Настоящий rolling update и проверки готовности решаются в Kubernetes (тема 5). Второй вариант: два экземпляра приложения и выкатывать по одному.

**Что хотят услышать:** честное ограничение Compose, роль healthcheck, упоминание Kubernetes.

**Красный флаг:** «Compose умеет zero-downtime из коробки».

### 9. [middle] Приложение в логах видит IP прокси вместо IP клиента. Почему и что изменить?

Соединение к приложению идёт от контейнера `proxy`. Настоящий адрес передаётся заголовками `X-Forwarded-For` и `X-Real-IP`, а приложение или его фреймворк должно им доверять только от известного прокси. Проверяю `proxy_set_header` в конфиге и как приложение читает заголовок.

**Что хотят услышать:** `X-Forwarded-For`, доверие только своему прокси, риск подделки заголовка клиентом.

**Красный флаг:** «включу `network_mode: host` для приложения».

### 10. [junior] Клиент зашёл на `http://`, а нужен только HTTPS. Как настроишь?

Добавляю `server` на порту 80 с `return 301 https://$host$request_uri;` и `server` на 443 с сертификатом. Проверяю `curl -sI`: должен быть 301 и заголовок `Location`.

**Что хотят услышать:** `return 301` вместо `rewrite`, `$request_uri`, проверка `curl -I`, позже HSTS.

**Красный флаг:** дублирование всех `location` в обоих серверах.

## Проверено на версиях

- Docker Engine: 29.8.1 (Compose v2 из пакета `docker-compose-plugin`, версия не закреплена, проверь актуальную версию на странице проекта)
- nginx: 1.30 (образ `nginx:1.30`)
- PostgreSQL: 18 (образ `postgres:18`)
- OpenSSL: из репозитория Ubuntu, версия не закреплена, проверь актуальную версию на странице проекта
- Ubuntu: 26.04 LTS и 24.04

## Итог урока: ты умеешь

- [ ] умею выпустить самоподписанный сертификат с SAN скриптом и не коммитить ключ
- [ ] умею добавить в `compose.yml` сервис nginx с конфигом и сертификатом, смонтированными `:ro`
- [ ] умею опубликовать наружу только 80 и 443 и объяснить, почему `ports` у базы опасен
- [ ] умею настроить редирект 80 на 443 и проверить его через `curl --resolve`
- [ ] умею объяснить и починить 502 после пересоздания приложения (`resolver` и переменная)
- [ ] умею читать `[emerg]` в логах nginx и проверять конфиг через `nginx -t`
- [ ] умею включить ротацию логов `json-file` и знаю, что она применяется через `up -d`

**Дальше:** [Урок 4.7: Образы: multi-stage, теги и реестр ghcr.io](07-images-registry.md)
