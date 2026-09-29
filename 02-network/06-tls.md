---
layout: lesson
title: "TLS и HTTPS: сертификаты и цепочка доверия"
topic: 2
lesson: "2.6"
time: "2 ч"
---

## Зачем это нужно

Без TLS пароли, токены и заметки идут по сети открытым текстом, а браузер помечает сайт как небезопасный. С TLS трафик зашифрован, а клиент убеждается, что говорит именно с нужным сервером. На работе чаще всего ломается не шифрование, а сертификат: истёк срок, не то имя, не хватает промежуточного сертификата, клиент не доверяет издателю.
Ты научишься читать сертификат, проверять цепочку доверия и выпускать свой сертификат.
Шаг проекта: «Заметки» открываются по `https://notes.lab/` с самоподписанным сертификатом (SAN `notes.lab`), порт 80 редиректит на 443, включён HSTS.

## Что нужно знать

- [Урок 1.3: права](../01-linux/03-users-permissions.md) - закрытый ключ хранится с правами 600, читает его только root.
- [Урок 2.2: порты и TCP](02-ports-tcp-ssh.md) - порт 443, `ss -ltn`, `Connection refused`.
- [Урок 2.3: DNS](03-dns.md) - запись `notes.lab` в `/etc/hosts`, имя в сертификате сверяется с именем в запросе.
- [Урок 2.4: HTTP](04-http.md) - `curl -v`, `curl -i`, код 301 и заголовки ответа.
- [Урок 2.5: nginx](05-nginx.md) - `server`, `listen`, `nginx -t`, `reload`, файл `deploy/nginx/notes.conf`.

## Теория

### Что даёт TLS

TLS (Transport Layer Security) решает три задачи. Конфиденциальность: трафик зашифрован, перехватчик видит только шум. Целостность: подмену байтов по дороге заметят. Аутентификация: клиент проверяет, что сервер тот, за кого себя выдаёт. HTTPS это HTTP внутри TLS-соединения на порту 443.

Слово SSL в названиях (`ssl_certificate`, `openssl`) историческое: SSL 2.0 и 3.0 давно небезопасны и отключены. Сегодня живут TLS 1.2 и TLS 1.3.

Порядок при открытии `https://notes.lab/`: DNS (урок 2.3), TCP-соединение на 443 (урок 2.2), рукопожатие (handshake) TLS, и только потом HTTP-запрос (урок 2.4). Поэтому ошибка сертификата видна до того, как запрос вообще отправлен.

> **Проверь понимание:** на каком шаге пути запроса ты увидишь ошибку сертификата: до или после HTTP-запроса? Почему `curl` тогда не покажет код ответа?

<details>
<summary>Ответ</summary>

До. Рукопожатие TLS идёт после TCP и до HTTP. Если клиент не принял сертификат, соединение закрывается, HTTP-запрос не отправляется, и кода ответа просто нет: `curl` завершается ошибкой.

</details>

### Рукопожатие: ключи и сертификат

Упрощённо, для TLS 1.3:

1. Клиент шлёт `ClientHello`: поддерживаемые версии, шифры и имя сервера (SNI, Server Name Indication). SNI нужен, чтобы nginx на одном IP выбрал сертификат для нужного имени.
2. Сервер отвечает `ServerHello` и отдаёт сертификат.
3. Клиент проверяет сертификат (следующие разделы).
4. Стороны договариваются об общем сеансовом ключе (обмен Диффи-Хеллмана). Дальше весь трафик шифруется быстрым симметричным шифром с этим ключом.

Асимметричная криптография (пара открытый и закрытый ключ) нужна только для доказательства личности и обмена ключами: она медленная. Данные шифруются симметрично. Закрытый ключ (private key) никогда не покидает сервер. Утёк ключ: любой может выдавать себя за сервер, сертификат надо перевыпускать с новым ключом.

> **Проверь понимание:** что из пары «сертификат» и «закрытый ключ» можно безопасно отдавать всем, а что нельзя?

<details>
<summary>Ответ</summary>

Сертификат публичный: сервер отдаёт его каждому клиенту при рукопожатии. Закрытый ключ секретный: права 600, в git и в чат он не попадает.

</details>

### Что внутри сертификата

Сертификат X.509 это подписанное заявление: «этот открытый ключ принадлежит этим именам, действителен с такой даты по такую, подписал такой-то издатель». Поля, которые ты будешь читать постоянно:

- **Subject** - кому выдан. CN (Common Name) историческое поле, современные клиенты его игнорируют.
- **SAN (Subject Alternative Name)** - список имён, на которые сертификат действует. Именно по SAN клиент сверяет имя из URL. Бывает `DNS:notes.lab`, бывает `IP:192.168.1.10`. Если имени в SAN нет, будет ошибка, даже если CN верный.
- **Issuer** - кто подписал. У самоподписанного сертификата Issuer равен Subject.
- **Not Before / Not After** - срок. Публичные сертификаты живут всё короче (предельный срок сокращается, проверь актуальные правила на странице CA/Browser Forum), поэтому руками их не продлевают, а автоматизируют (в теме 9 этим занимается cert-manager).
- **Basic Constraints: CA:TRUE/FALSE** - может ли владелец сам подписывать сертификаты.

### Цепочка доверия

Клиент не может знать всех издателей. Он хранит небольшой набор корневых сертификатов (root CA), которым доверяет по умолчанию: это хранилище ОС (в Ubuntu каталог `/etc/ssl/certs/`, пакет `ca-certificates`) или встроенный список браузера. Корневые ключи хранят офлайн, а сертификаты сайтов подписывают промежуточные (intermediate CA).

Получается цепочка:

```text
root CA (в хранилище клиента, самоподписан)
  -> intermediate CA (подписан root)
       -> leaf: notes.example.com (подписан intermediate)
```

Клиент идёт снизу вверх: проверяет подпись листа (leaf) ключом промежуточного, подпись промежуточного ключом корня, и упирается в корень из своего хранилища. Дошёл: доверяет. Не дошёл: ошибка.

Практическое правило: сервер обязан отдавать лист вместе с промежуточными (файл `fullchain.pem`). Корень отдавать не нужно, он у клиента уже есть. Частая авария: настроили только лист, браузер на ноутбуке подтянул промежуточный из кэша и работает, а `curl` и мобильные клиенты падают.

> **Проверь понимание:** сертификат есть, срок не вышел, имя верное, но `curl` пишет `unable to get local issuer certificate`. Что это значит?

<details>
<summary>Ответ</summary>

Клиент не смог построить цепочку до доверенного корня. Либо сервер не отдал промежуточный сертификат, либо издатель (например, внутренний CA компании) отсутствует в хранилище клиента.

</details>

### Самоподписанный сертификат и свой CA

Самоподписанный сертификат подписан собственным ключом, и ни в чьём хранилище его нет. Для учебного стенда и внутренних сервисов это нормально, но клиент по умолчанию откажет. Есть два способа:

- сообщить клиенту сам сертификат как доверенный (`curl --cacert notes.crt`);
- завести свой мини-CA, подписать им сертификаты сервисов и раздать клиентам один корень. Так делают внутри компаний. Локальный CA для платформы мы автоматизируем в теме 9 (урок 9.4).

Ключ `curl -k` (`--insecure`) отключает проверку целиком. Это не «обойти ошибку», а отказ от аутентификации: шифрование остаётся, но говорить можно с кем угодно. В скриптах на проде `-k` красный флаг.

### HSTS и редирект на HTTPS

Пользователи набирают `notes.lab` без схемы, и браузер идёт по HTTP. Поэтому на порту 80 делают редирект 301 на `https://`. Но между первым запросом и редиректом есть окно для атаки. Заголовок `Strict-Transport-Security: max-age=31536000` (HSTS, HTTP Strict Transport Security) говорит браузеру: этот сайт год ходи только по HTTPS, даже не пробуй HTTP. Браузер принимает заголовок только по HTTPS. Осторожно: HSTS с большим `max-age` и просроченный сертификат означают, что пользователь не сможет нажать «продолжить». Сначала проверяй на маленьком значении.

> **Проверь понимание:** зачем редирект, если есть HSTS, и зачем HSTS, если есть редирект?

<details>
<summary>Ответ</summary>

Редирект нужен для первого визита и для клиентов, которые не знают про HSTS. HSTS закрывает окно атаки на последующих визитах: браузер сам переписывает адрес на https и не делает открытый запрос.

</details>

## Практика

Домен `notes.lab` должен быть в `/etc/hosts` (урок 2.3), nginx из урока 2.5 работает.

### Задание 1. Читаем сертификат живого сайта

**Цель:** увидеть цепочку доверия реального сайта и найти в сертификате имя, издателя и срок.

**Предскажи:** сколько сертификатов сервер отдаст в цепочке: один, два или три? Будет ли среди них корень?

<details>
<summary>Ответ</summary>

Обычно два или три: лист и один-два промежуточных. Корня сервер не отдаёт: он уже в хранилище клиента. Точное число зависит от сайта.

</details>

**Шаги:**

1. Сними цепочку и итог проверки:

   ```bash
   openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
     | grep -E '^( [0-9] s:|   i:|Verification|Verify return code)'
   ```

2. Достань из листа имя, издателя, срок и SAN:

   ```bash
   echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
     | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
   ```

3. Посмотри, что видит `curl` при рукопожатии:

   ```bash
   curl -sv https://example.com/ -o /dev/null 2>&1 | grep -E 'TLSv|subject|issuer|expire|SSL certificate verify'
   ```

**Что должно получиться:** значения зависят от сайта и даты, форма такая:

```text
 0 s:CN=example.com
   i:C=US, O=Example CA, CN=Example Intermediate
 1 s:C=US, O=Example CA, CN=Example Intermediate
   i:C=US, O=Example Root, CN=Example Root
Verification: OK
Verify return code: 0 (ok)
subject=CN=example.com
issuer=C=US, O=Example CA, CN=Example Intermediate
notBefore=Sep  1 00:00:00 2026 GMT
notAfter=Nov 30 23:59:59 2026 GMT
X509v3 Subject Alternative Name:
    DNS:example.com, DNS:www.example.com
```

**Объясни себе:**

- Почему `issuer` листа совпадает с `subject` следующего сертификата в цепочке?
- Зачем `-servername`? Что будет, если его опустить на сервере с несколькими сайтами?
- Сколько дней осталось до `notAfter`?

**Типичные ошибки:**

- `s_client` висит и ничего не печатает: он ждёт ввода с клавиатуры. Добавь `</dev/null` или `echo |`.
- `connect:errno=111` или `Connection timed out`: порт 443 недоступен, это вопрос TCP (урок 2.2), а не TLS.

### Задание 2. Выпускаем самоподписанный сертификат

**Цель:** создать пару ключ и сертификат для `notes.lab` с SAN и прочитать результат.

**Предскажи:** если выпустить сертификат только с `-subj "/CN=notes.lab"` без SAN, примет ли его современный клиент?

<details>
<summary>Ответ</summary>

Нет. Современные клиенты (curl с OpenSSL 3, браузеры) сверяют имя только по SAN, CN игнорируется. Поэтому SAN добавляется обязательно, флагом `-addext`.

</details>

**Шаги:**

1. Создай каталог и выпусти сертификат на 365 дней:

   ```bash
   sudo mkdir -p /etc/notes/tls
   sudo openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
     -subj "/CN=notes.lab" \
     -addext "subjectAltName=DNS:notes.lab" \
     -keyout /etc/notes/tls/notes.key \
     -out /etc/notes/tls/notes.crt
   ```

2. Выставь права: ключ читает только root (мастер-процесс nginx стартует от root и читает ключ сам):

   ```bash
   sudo chmod 600 /etc/notes/tls/notes.key
   sudo chmod 644 /etc/notes/tls/notes.crt
   ls -l /etc/notes/tls/
   ```

3. Прочитай сертификат:

   ```bash
   sudo openssl x509 -in /etc/notes/tls/notes.crt -noout -subject -issuer -dates -ext subjectAltName
   ```

4. Проверь, что ключ подходит к сертификату: хеши открытых ключей должны совпасть.

   ```bash
   sudo openssl x509 -in /etc/notes/tls/notes.crt -noout -pubkey | sha256sum
   sudo openssl pkey -in /etc/notes/tls/notes.key -pubout | sha256sum
   ```

**Что должно получиться:**

```text
-rw-r--r-- 1 root root 1119 Sep 29 10:40 notes.crt
-rw------- 1 root root 1704 Sep 29 10:40 notes.key
subject=CN=notes.lab
issuer=CN=notes.lab
notBefore=Sep 29 10:40:00 2026 GMT
notAfter=Sep 29 10:40:00 2027 GMT
X509v3 Subject Alternative Name:
    DNS:notes.lab
```

Две команды с `sha256sum` печатают одинаковый хеш. Размеры и время у тебя другие.

**Объясни себе:**

- Почему `subject` равен `issuer`? Что это говорит о доверии?
- Что случится, если положить сертификат от одного ключа и ключ от другого? (nginx не запустится: `key values mismatch`.)
- Почему `-nodes` (ключ без пароля) удобен для сервиса, который стартует сам, и чем за это платишь?

**Типичные ошибки:**

- `Can't open "/etc/notes/tls/notes.key" for writing, No such file or directory`: каталога нет: `sudo mkdir -p /etc/notes/tls`.
- `Can't open "/etc/notes/tls/notes.key" for writing, Permission denied`: запуск без `sudo`.
- `sudo: openssl: command not found`: пакет не установлен: `sudo apt install openssl`.

### Задание 3. Мини-цепочка: свой CA и сертификат от него

**Цель:** пройти цепочку доверия руками: создать корень, подписать им лист и проверить, что `openssl verify` принимает лист только вместе с корнем.

**Предскажи:** примет ли `openssl verify` лист без указания корня? А с ним?

<details>
<summary>Ответ</summary>

Без корня: нет, `unable to get local issuer certificate`, потому что издателя нет среди доверенных. С `-CAfile ca.crt`: да, `OK`.

</details>

**Шаги:**

1. Рабочий каталог (это учебные файлы, в проект они не попадут):

   ```bash
   mkdir -p ~/tls-lab && cd ~/tls-lab
   ```

2. Корневой сертификат (CA:TRUE) на 30 дней:

   ```bash
   openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
     -subj "/CN=Notes Lab Root CA" \
     -addext "basicConstraints=critical,CA:TRUE" \
     -keyout ca.key -out ca.crt
   ```

3. Запрос на подпись (CSR, Certificate Signing Request) и лист, подписанный корнем:

   ```bash
   openssl req -newkey rsa:2048 -nodes -subj "/CN=notes.lab" \
     -keyout leaf.key -out leaf.csr
   printf 'subjectAltName=DNS:notes.lab\nbasicConstraints=CA:FALSE\n' > leaf.ext
   openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -days 30 -extfile leaf.ext -out leaf.crt
   ```

4. Проверь цепочку без корня и с корнем:

   ```bash
   openssl verify leaf.crt
   openssl verify -CAfile ca.crt leaf.crt
   ```

5. Убери за собой:

   ```bash
   cd ~ && rm -rf ~/tls-lab
   ```

**Что должно получиться:**

```text
CN=notes.lab
error 20 at 0 depth lookup: unable to get local issuer certificate
error leaf.crt: verification failed
leaf.crt: OK
```

**Объясни себе:**

- Что подписывает CA: ключ листа или его сертификат? Что такое CSR и почему в нём нет закрытого ключа?
- Почему клиенту достаточно доверять одному `ca.crt`, а не каждому листу?
- Как в такой схеме выглядит ротация: что меняется у сервисов, а что у клиентов?

**Типичные ошибки:**

- `error 20 at 0 depth lookup: unable to get local issuer certificate`: не указан корень в `-CAfile` или указан не тот.
- `Can't open leaf.ext for reading, No such file or directory`: ты не в каталоге `~/tls-lab` или пропустил `printf`. Без файла расширений в листе не будет SAN.

### Задание 4. Шаг проекта: HTTPS для «Заметок»

**Цель:** привести проект к состоянию после урока 2.6: `:443` с сертификатом, редирект 80 на 443, HSTS.

**Предскажи:** после `reload` что вернёт `curl -I http://notes.lab/`: 200 или 301? А `curl https://notes.lab/` без `-k`?

<details>
<summary>Ответ</summary>

Первый вернёт 301 с заголовком `Location: https://notes.lab/`. Второй завершится ошибкой проверки: сертификат самоподписанный, `curl` ему не доверяет (`self-signed certificate`). Нужен `--cacert`.

</details>

**Шаги:**

1. Сертификат из задания 2 лежит в `/etc/notes/tls/`. Если нет, повтори его шаги.

2. Замени содержимое `~/notes/deploy/nginx/notes.conf` на такое (вместо одного `server` теперь два):

   ```nginx
   # Редирект: любой HTTP-запрос уходит на HTTPS
   server {
       listen 80;
       server_name notes.lab;
       return 301 https://$host$request_uri;
   }

   # HTTPS: nginx терминирует TLS и проксирует в приложение по HTTP
   server {
       listen 443 ssl;
       server_name notes.lab;

       ssl_certificate     /etc/notes/tls/notes.crt;
       ssl_certificate_key /etc/notes/tls/notes.key;
       ssl_protocols       TLSv1.2 TLSv1.3;

       # HSTS: браузер год ходит на этот сайт только по HTTPS
       add_header Strict-Transport-Security "max-age=31536000" always;

       access_log /var/log/nginx/notes-access.log;
       error_log  /var/log/nginx/notes-error.log;

       location / {
           proxy_pass http://127.0.0.1:8080;

           # Приложение за прокси не видит клиента, поэтому передаём явно
           proxy_set_header Host              $host;
           proxy_set_header X-Real-IP         $remote_addr;
           proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;

           proxy_connect_timeout 3s;
           proxy_read_timeout    30s;
       }
   }
   ```

3. Установи, проверь и примени:

   ```bash
   sudo cp ~/notes/deploy/nginx/notes.conf /etc/nginx/sites-available/notes
   sudo nginx -t
   sudo systemctl reload nginx
   sudo ss -ltn 'sport = :443'
   ```

4. Проверь редирект, HTTPS с доверием к своему сертификату и заголовки:

   ```bash
   curl -sI http://notes.lab/ | head -n 3
   curl -sI --cacert /etc/notes/tls/notes.crt https://notes.lab/ | grep -i -E 'HTTP|strict'
   curl -s  --cacert /etc/notes/tls/notes.crt https://notes.lab/headers
   ```

5. Убедись, что без доверия `curl` отказывает:

   ```bash
   curl -sS https://notes.lab/ -o /dev/null
   ```

6. Закоммить конфиг (если git уже подключён, урок 3.1):

   ```bash
   cd ~/notes && git add deploy/nginx/notes.conf && git commit -m "Добавлен HTTPS и редирект"
   ```

   Сертификат и ключ в git не коммить: они лежат в `/etc/notes/tls/`, вне репозитория.

**Что должно получиться:**

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
State  Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0      511          0.0.0.0:443       0.0.0.0:*
HTTP/1.1 301 Moved Permanently
Server: nginx/1.24.0 (Ubuntu)
Date: Tue, 29 Sep 2026 10:45:00 GMT
HTTP/1.1 200 OK
Strict-Transport-Security: max-age=31536000
{"Host": "notes.lab", "X-Real-Ip": "127.0.0.1", "X-Forwarded-For": "127.0.0.1", "X-Forwarded-Proto": "https", ...}
curl: (60) SSL certificate problem: self-signed certificate
```

Обрати внимание: `X-Forwarded-Proto` теперь `https`, приложение за прокси знает исходную схему. Последняя строка печатается в stderr, остальные в stdout.

**Объясни себе:**

- Почему трафик от nginx к приложению идёт по HTTP? Что защищено, а что нет? (Это терминация TLS: до приложения трафик идёт по loopback внутри одной машины.)
- Зачем `always` в `add_header`? (Без него nginx не добавит заголовок к ответам 4xx и 5xx.)
- Почему 8080 по-прежнему привязан к 127.0.0.1? (Иначе клиент обошёл бы и TLS, и nginx.)

**Типичные ошибки:**

- `nginx: [emerg] cannot load certificate "/etc/notes/tls/notes.crt": BIO_new_file() failed`: неверный путь или файла нет: проверь `ls -l /etc/notes/tls/`.
- `nginx: [emerg] SSL_CTX_use_PrivateKey("/etc/notes/tls/notes.key") failed (SSL: error:05800074:x509 certificate routines::key values mismatch)`: ключ не от этого сертификата: сверь хеши как в задании 2.
- `nginx: [emerg] no "ssl_certificate" is defined for the "listen ... ssl" directive`: забыта директива `ssl_certificate`.
- `curl: (60) SSL certificate problem: self-signed certificate`: ожидаемо без `--cacert`. Не лечи флагом `-k`.
- `curl: (7) Failed to connect to notes.lab port 443: Connection refused`: nginx не перечитал конфиг или нет `listen 443`.

## Сломай и почини

Запусти сценарий и почини по симптому. Скрипт не читай, разбор ниже:

```bash
sudo ~/notes/break/2.6/break.sh random
```

### Симптом

При обращении к `https://notes.lab/` `curl` или браузер сообщают об ошибке сертификата. Одна из трёх фраз:

```text
curl: (60) SSL certificate problem: self-signed certificate
curl: (60) SSL certificate problem: certificate has expired
curl: (60) SSL: no alternative certificate subject name matches target host name 'notes.lab'
```

### Гипотезы

- Сертификат самоподписанный, клиент ему не доверяет.
- Срок сертификата вышел (или ещё не наступил, если часы клиента сбиты).
- Имя в SAN не то, на которое ходит клиент.
- Сервер не отдаёт промежуточный сертификат.
- nginx отдаёт не тот сертификат (не тот `server`, не тот SNI).

### Проверки

Иди по слоям, не гадай:

```bash
# Что реально отдаёт сервер: имя, издатель, срок, SAN
echo | openssl s_client -connect notes.lab:443 -servername notes.lab 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# Итог проверки цепочки с нашим сертификатом как доверенным
echo | openssl s_client -connect notes.lab:443 -servername notes.lab \
  -CAfile /etc/notes/tls/notes.crt 2>/dev/null | grep 'Verify return code'

# Срок файла на диске: код 0, если сертификат ещё действует
sudo openssl x509 -in /etc/notes/tls/notes.crt -noout -checkend 0 && echo "срок в порядке"
date -u
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**1. `self-signed certificate`.** Сертификат подписан сам собой, его нет в хранилище клиента. Правильно: дать клиенту доверенный корень (`--cacert /etc/notes/tls/notes.crt` или положить его в `/usr/local/share/ca-certificates/notes.crt` и выполнить `sudo update-ca-certificates`). Для публичного сайта: сертификат от публичного CA. Не помогает и вредит: `-k`.

**2. `certificate has expired`.** В выводе `notAfter` в прошлом, `-checkend 0` возвращает ошибку. Перевыпусти сертификат командой из задания 2, затем `sudo nginx -t && sudo systemctl reload nginx`. Причина на работе: срок никто не мониторил. Алерт на срок ставят за 14-30 дней.

**3. `no alternative certificate subject name matches`.** В SAN нет `notes.lab` (или клиент ходит по IP, а в SAN только DNS). Перевыпусти сертификат с `-addext "subjectAltName=DNS:notes.lab"`. Править CN бесполезно.

После любого исправления: `sudo nginx -t && sudo systemctl reload nginx`, затем повтори проверки и `curl --cacert /etc/notes/tls/notes.crt https://notes.lab/healthz`.

</details>

Как проверить срок, не дожидаясь его конца: `openssl verify -attime` проверяет сертификат на выбранную дату. Например, на дату через 400 дней (GNU `date`):

```bash
openssl verify -attime "$(date -d '+400 days' +%s)" -CAfile /etc/notes/tls/notes.crt /etc/notes/tls/notes.crt
```

Ожидаемо: `error 10 at 0 depth lookup: certificate has expired`.

## Вопросы с собеседований

### 1. [junior] Пользователи жалуются: «в браузере предупреждение о сертификате». Что проверишь?

Открою детали сертификата в браузере или через `openssl s_client`. Смотрю три вещи: срок (`notAfter`), имя в SAN против адреса в URL, издателя и цепочку. Чаще всего это истёкший срок, не то имя или сервер не отдаёт промежуточный сертификат.

**Что хотят услышать:** `openssl s_client -servername`, `openssl x509 -noout -dates -ext subjectAltName`, порядок проверки, промежуточные сертификаты.

**Красный флаг:** «нажмите Продолжить» или «отключу проверку».

### 2. [middle] Сертификат валидный, в браузере всё открывается, а `curl` из сервиса пишет `unable to get local issuer certificate`. Что происходит?

Скорее всего сервер отдаёт только лист без промежуточного. Браузер достаёт промежуточный из кэша или по AIA (Authority Information Access), а `curl` и библиотеки нет. Проверяю `openssl s_client -showcerts`: сколько сертификатов в цепочке. Исправление: в `ssl_certificate` указать fullchain (лист плюс промежуточные).

**Что хотят услышать:** fullchain, AIA, разница браузера и клиентских библиотек, корень сервер не отдаёт.

**Красный флаг:** «добавлю `-k` в скрипт».

### 3. [junior] Чем сертификат отличается от закрытого ключа? Что делать, если ключ утёк?

Сертификат публичный: имя, открытый ключ, подпись издателя. Закрытый ключ хранится на сервере и доказывает владение сертификатом. При утечке кто угодно может выдавать себя за сервер. Перевыпускаю сертификат с новым ключом, отзываю старый, ищу причину утечки.

**Что хотят услышать:** права 600, отзыв, перевыпуск с новой парой ключей, ключ не в git.

**Красный флаг:** «поменяю сертификат, ключ оставлю прежним».

### 4. [middle] Ночью упал прод: сертификат истёк, хотя «мы его продлевали». Как искать причину и как не допустить повтора?

Сначала проверяю, что реально отдаёт сервер (`s_client`), а не что лежит на диске: nginx мог не сделать `reload` после продления. Другие причины: продлили не тот файл или не на всех узлах за балансировщиком. Профилактика: автопродление с hook на reload и мониторинг срока с алертом за 14-30 дней.

**Что хотят услышать:** разница между файлом на диске и загруженным в процесс, `reload`, алерт на срок, автоматизация.

**Красный флаг:** «поставим напоминание в календарь».

### 5. [middle] Клиент ходит на сервис по IP и получает ошибку имени, хотя сертификат «от нашего CA». В чём дело?

В SAN только DNS-имена, IP там нет, поэтому проверка имени не проходит. Решение: ходить по имени или выпустить сертификат с `IP:...` в SAN. Править CN не поможет.

**Что хотят услышать:** SAN против CN, типы SAN (DNS, IP), обращаться по имени.

**Красный флаг:** «поправлю Common Name».

### 6. [middle] На nginx включены редирект и HSTS на год. Что случится, если сертификат просрочится?

Браузеры с HSTS не дадут пользователю нажать «продолжить»: сайт недоступен, пока сертификат не заменят. Поэтому большой `max-age` включают, когда продление автоматизировано и под мониторингом, а начинают с небольшого значения.

**Что хотят услышать:** HSTS убирает возможность обойти ошибку, постепенное повышение `max-age`, мониторинг срока.

**Красный флаг:** «HSTS всегда ставим на максимум и забываем».

### 7. [middle] `nginx -t` проходит, `reload` не ругается, а клиенты видят старый сертификат. Что проверишь?

Возможно, отвечает не тот `server` (другой `server_name` или `default_server` на 443), в `ssl_certificate` другой файл или перед nginx стоит балансировщик со своим сертификатом. Смотрю `nginx -T | grep -n ssl_certificate`, `s_client -servername` и что стоит перед nginx.

**Что хотят услышать:** `nginx -T`, SNI и `default_server`, слой перед nginx, проверка того, что реально отдаётся.

**Красный флаг:** «перезагрузим сервер».

### 8. [middle] Для внутреннего сервиса сделали самоподписанный сертификат, и коллеги жмут «продолжить». Как исправить по-взрослому?

Завожу внутренний CA и раздаю его корень в хранилища клиентов (`update-ca-certificates`, политики, базовый образ). Сертификаты сервисов подписывает CA, и они доверенные без исключений. Самоподписанные листья на каждом сервисе не масштабируются и приучают игнорировать предупреждения.

**Что хотят услышать:** внутренний CA, раздача корня, ротация, автоматизация (ACME, cert-manager), сравнение с публичным CA.

**Красный флаг:** «пусть добавят исключение в браузере».

### 9. [junior] `openssl s_client` без `-servername` показывает не тот сертификат, что браузер. Почему?

Клиент не передал SNI, и сервер отдал сертификат по умолчанию (первый или `default_server`). Браузер SNI передаёт всегда. Поэтому в диагностике `s_client` всегда с `-servername`.

**Что хотят услышать:** SNI передаётся до шифрования, выбор `server` в nginx по имени, сертификат по умолчанию.

**Красный флаг:** «значит, у браузера кэш».

### 10. [middle] `nginx -t` падает с `key values mismatch` после продления. Что случилось и как проверить заранее?

Новый сертификат положили к старому ключу. Сравниваю хеши открытых ключей: `openssl x509 -noout -pubkey | sha256sum` и `openssl pkey -pubout | sha256sum`. Делаю это до `reload`, вместе с `nginx -t`.

**Что хотят услышать:** сравнение открытых ключей, проверка до применения, `reload` только после `nginx -t`.

**Красный флаг:** «сравню файлы на глаз».

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- OpenSSL: версия из репозитория Ubuntu не закреплена, проверь актуальную версию на странице проекта (в примерах вывода 3.x)
- nginx: версия из репозитория Ubuntu не закреплена, проверь актуальную версию на странице проекта (в примерах вывода 1.24.0 из Ubuntu 24.04)
- curl: версия из репозитория Ubuntu (в примерах 8.14.1)
- Python: 3.13

## Итог урока: ты умеешь

- [ ] умею объяснить, что защищает TLS и на каком шаге пути запроса происходит рукопожатие
- [ ] умею прочитать сертификат: subject, issuer, срок, SAN
- [ ] умею проверить цепочку доверия и объяснить `unable to get local issuer certificate`
- [ ] умею выпустить самоподписанный сертификат с SAN и свой мини-CA
- [ ] умею настроить в nginx `listen 443 ssl`, редирект 80 на 443 и HSTS
- [ ] умею отличить `self-signed`, `expired` и `no alternative certificate subject name` и починить каждую ошибку
- [ ] умею проверить, что ключ подходит к сертификату, и не отключать проверку через `-k`

**Дальше:** [Урок 2.7: Файрвол и защита SSH](07-firewall.md)
