---
layout: lesson
title: "Деплой «Заметок» на ВМ: домен, HTTPS, обновления по тегу"
topic: 6
lesson: "6.3"
time: "2 ч"
---

## Зачем это нужно

Пока «Заметки» живут на твоём ноутбуке, это не сервис, а учебный макет. Настоящая работа начинается, когда есть публичный адрес, валидный сертификат и выкатка, которая не требует заходить на сервер руками. На собеседовании просят описать именно этот путь: от git-тега до HTTPS, откат, что будет, если ВМ упадёт.
В этом уроке ты пройдёшь весь путь на ВМ из урока 6.2: поставишь Docker, привяжешь домен, получишь сертификат Let's Encrypt, напишешь скрипт деплоя с откатом и подключишь GitHub Actions, чтобы релиз сам выкатывался на сервер.
Шаг проекта: «Заметки» открываются по `https://notes.<твой домен>`, а публикация релиза в GitHub выкатывает новую версию на ВМ без ручных шагов.

## Что нужно знать

- [Урок 6.2: ВМ, сеть и диски в облаке](02-vm-network-storage.md) - готовая ВМ `notes-vm`, публичный IP, security group
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - `compose.yml` с `notes` и `db`, файл `.env`
- [Урок 4.6: Compose, nginx и TLS](../04-docker/06-compose-nginx-tls.md) - сервис `proxy`, `resolver 127.0.0.11`, порты 80 и 443
- [Урок 4.7: образы и реестр](../04-docker/07-images-registry.md) - образ `ghcr.io/<github-user>/notes:<semver>`
- [Урок 2.3: DNS](../02-network/03-dns.md) - A-запись, `dig`, TTL
- [Урок 2.6: TLS](../02-network/06-tls.md) - `openssl s_client`, цепочка, сроки
- [Урок 2.7: файрвол и SSH](../02-network/07-firewall.md) - вход по ключу, порты
- [Урок 3.4: качество и безопасность в CI](../03-git-ci/04-quality-security-ci.md) - секреты в CI, идея OIDC
- [Урок 3.5: релизы](../03-git-ci/05-release-flow.md) - тег `v*`, GitHub Release

## Теория

### Путь от тега до HTTPS

Весь путь выглядит так, и каждое звено ты сегодня соберёшь сам:

```text
git tag v0.4.1 -> GitHub Release -> workflow deploy.yml
   -> ssh на ВМ -> deploy.sh 0.4.1 -> docker compose pull && up -d
   -> smoke-test https://notes.<домен>/healthz -> готово (или откат)
```

Образ `ghcr.io/<github-user>/notes:0.4.1` к этому моменту уже собран workflow `image.yml` из урока 4.7. Деплой ничего не собирает, он только говорит ВМ: «запусти вот этот тег». Так сервер каждый раз запускает ровно тот артефакт, который прошёл CI, а не «то, что собралось на месте».

Правило одной версии: тег git = тег образа = `APP_VERSION` = 0.4.1. Из тега `v0.4.1` префикс `v` отрезается в скрипте, иначе образ не найдётся.

> **Проверь понимание:** почему деплой скачивает готовый образ, а не собирает его на ВМ?

<details markdown="1">
<summary>Ответ</summary>

Сборка на сервере даёт другой артефакт при каждой сборке (зависимости, время), нагружает прод и требует исходников и компиляторов на нём. Готовый образ по тегу один и тот же в CI, на стенде и в проде, а откат сводится к запуску предыдущего тега.

</details>

### DNS: домен на публичный IP

Браузеру нужно имя, а ВМ известна по IP. Связывает их A-запись (A record): `notes.example.com. 300 IN A 203.0.113.10`. Домен можно купить или взять бесплатный поддомен у DNS-хостинга. Запись создаётся у того, кто обслуживает зону: у регистратора или в облачном DNS.

Важны два числа: адрес и TTL (time to live). TTL это время в секундах, которое резолверы помнят ответ. Перед переездом сервиса его снижают до 60-300 секунд, иначе часть клиентов ещё сутки будет ходить на старый IP. Проверка всегда идёт с двух сторон: своим резолвером и публичным (`@1.1.1.1`), как в уроке 2.3.

### Let's Encrypt, ACME и certbot

Let's Encrypt выдаёт бесплатные сертификаты по протоколу ACME. Перед выдачей центр сертификации проверяет, что домен твой. Способов два:

- HTTP-01: центр открывает `http://<домен>/.well-known/acme-challenge/<токен>` на порту 80 и ждёт нужное содержимое. Просто, но нужен доступный порт 80 и нельзя выпустить wildcard (`*.example.com`).
- DNS-01: ты создаёшь TXT-запись `_acme-challenge.<домен>`. Порт 80 не нужен, wildcard возможен, но клиенту нужен API DNS-провайдера.

Клиент `certbot` в режиме webroot кладёт файл-токен в каталог, который nginx отдаёт по `/.well-known/acme-challenge/`. Сертификат живёт 90 дней, продлевает его таймер `certbot.timer`; после продления nginx нужно перечитать сертификат (deploy-hook). У Let's Encrypt есть лимиты: при отладке на боевом сервере легко упереться в блокировку на час или неделю, поэтому сначала пробуют `--dry-run`.

Курьёз, который надо знать: nginx с блоком `listen 443 ssl` не стартует, пока файла сертификата нет. Поэтому первый запуск двухэтапный: сначала только порт 80, получаем сертификат, потом добавляем 443.

> **Проверь понимание:** certbot пишет `Timeout during connect (likely firewall problem)`. Какие три места проверишь?

<details markdown="1">
<summary>Ответ</summary>

1. A-запись домена указывает на этот IP (`dig`). 2. Security group облака пускает входящий 80/tcp из интернета. 3. Порт 80 реально слушает nginx в контейнере (`sudo ss -tlnp | grep ':80'`), и ufw на ВМ его не режет. Проверка снаружи, а не с самой ВМ.

</details>

### Деплой по тегу: идемпотентность, smoke-test, откат

Деплой-скрипт должен быть идемпотентным (idempotent): повторный запуск с тем же тегом ничего не ломает и ничего лишнего не делает. `docker compose up -d` этим свойством обладает: пересоздаёт только сервисы, у которых изменилась конфигурация или образ.

После `up -d` контейнер запущен, но это не значит, что сервис работает. Поэтому есть smoke-test (дымовая проверка): короткий запрос к живому адресу, например `curl -fsS https://<домен>/healthz`. Он проходит через DNS, TLS, nginx и приложение, то есть проверяет весь путь. Не прошёл: скрипт возвращает предыдущий тег и завершается с ошибкой, чтобы CI покраснел.

Простоя нет только на уровне «мгновения»: на одной ВМ `up -d` останавливает старый контейнер и запускает новый, и несколько секунд запросы получают 502. Настоящий rolling-деплой без потери запросов требует минимум двух экземпляров за балансировщиком, это тема Kubernetes (см. [урок 5.7](../05-kubernetes/07-probes-resources-rollouts.md)).

> **Проверь понимание:** зачем скрипту помнить предыдущий тег в файле, а не брать его из git?

<details markdown="1">
<summary>Ответ</summary>

Состояние сервера это не то же самое, что состояние репозитория: на ВМ мог остаться тег после ручного отката или неудачного деплоя. Файл `.current-tag` на сервере хранит то, что реально было запущено последним успешным деплоем.

</details>

### SSH-ключ в CI и безопасность

Job деплоя заходит на ВМ по SSH. Приватный ключ хранится в GitHub Secrets (`DEPLOY_SSH_KEY`), а не в репозитории (про секреты в CI см. [урок 3.4](../03-git-ci/04-quality-security-ci.md)). Правила:

- отдельный ключ и отдельный пользователь `deploy` только под деплой, не твой личный ключ и не root;
- отпечаток хоста (`known_hosts`) тоже в секретах: иначе job примет любого, кто ответит на IP;
- environment `production` в GitHub позволяет требовать ручное подтверждение и ограничивает секреты;
- `concurrency` не даёт двум деплоям идти одновременно.

Честная оговорка: пользователь в группе `docker` фактически равен root на этой ВМ. Это осознанный компромисс учебного стенда. Ограничение SSH-ключа одной командой (`command="/opt/notes/deploy/vm/deploy.sh ..."` в `authorized_keys`) сокращает ущерб. OIDC (идея из урока 3.4) вместо долгоживущих ключей выдаёт токены для API облака, а для входа по SSH напрямую не применим.

Ещё одна ловушка: если в security group порт 22 открыт только с твоего IP, job на раннере GitHub туда не попадёт (адреса раннеров меняются). Варианты: открыть 22 для всех при отключённых паролях (урок 2.7), self-hosted раннер или bastion. Здесь мы выбираем первый и понимаем цену.

### Одна ВМ, SLA и внешний мониторинг

Теперь «Заметки» это одна ВМ: единая точка отказа (SPOF, single point of failure). ВМ упала, обслуживание провайдера, забит диск: сервис недоступен. `restart: unless-stopped` поднимет контейнеры после перезагрузки ВМ или падения процесса, но не поможет при падении самой ВМ. Долг закрывается частично в темах 5 и 9, полностью не закрывается никогда: это вопрос цены и приемлемого простоя.

Считать простой полезно в минутах. SLA 99.9% за 30 дней это 43200 минут * 0.001 = 43.2 минуты простоя. Одна неудачная выкатка с 5 минутами 502 съедает десятую часть месячного бюджета. Для 99.99% остаётся 4.3 минуты.

Проверка с самой ВМ (`curl 127.0.0.1`) не видит проблем DNS, сертификата и файрвола. Нужна внешняя проверка: бесплатный uptime-сервис или внешний blackbox (тема 8) бьёт по `https://notes.<домен>/healthz` раз в минуту и оповещает.

### Соответствие AWS

| Что делаем | Yandex Cloud / у нас | AWS |
|---|---|---|
| Виртуальная машина | Compute Cloud, `notes-vm` | EC2 |
| Домен и A-запись | Cloud DNS | Route 53 |
| Сертификат | Let's Encrypt + certbot на ВМ; Certificate Manager | ACM (только с ALB, CloudFront) |
| Правила входа 22, 80, 443 | Security group | Security group |
| Хранение SSH-ключа CI | GitHub Secrets | GitHub Secrets / Secrets Manager |
| Деплой по SSH | `deploy.sh` по ssh | SSM Run Command / CodeDeploy |
| Внешний uptime | внешняя проверка, Monitoring | Route 53 health checks, CloudWatch Synthetics |

Отличие для собеседования: сертификат ACM бесплатен, но выдаётся только для сервисов AWS (ALB, CloudFront), на ВМ его не поставишь. На EC2 ставят certbot так же, как у нас.

## Практика

Дальше `notes.example.com` и `203.0.113.10` заменяй на свои значения: домен и публичный IP ВМ из урока 6.2 (`yc compute instance get notes-vm` покажет адрес). Для трека «без облака» (Multipass-ВМ) сертификат Let's Encrypt не получится: у ВМ нет публичного адреса. Замени задание 2 на самоподписанный сертификат из урока 4.6, остальное работает так же.

### Задание 1. Docker и пользователь deploy на ВМ

**Цель:** подготовить ВМ: Docker Engine из официального apt-репозитория, отдельный пользователь `deploy` и каталог `/opt/notes`.

**Предскажи:** сработает ли `docker ps` под `deploy` сразу после `usermod -aG docker deploy` в открытой сессии? Ответ: нет, группы читаются при новом входе.

**Шаги:**

1. Подключись: `ssh yc-user@203.0.113.10`. Поставь Docker (официальный репозиторий, без `curl | bash`):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl rsync
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# репозиторий Docker для твоей версии Ubuntu
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

2. Создай пользователя и каталог:

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo install -d -o deploy -g deploy -m 755 /opt/notes
sudo install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
```

3. На ноутбуке создай отдельный ключ и положи публичную часть на ВМ:

```bash
ssh-keygen -t ed25519 -N "" -C "notes-deploy" -f ~/.ssh/notes-deploy
ssh yc-user@203.0.113.10 'sudo tee /home/deploy/.ssh/authorized_keys >/dev/null && sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys && sudo chmod 600 /home/deploy/.ssh/authorized_keys' < ~/.ssh/notes-deploy.pub
ssh -i ~/.ssh/notes-deploy deploy@203.0.113.10 'docker --version && docker compose version && docker ps'
```

**Что должно получиться:** версии Docker и Compose и пустой список контейнеров, без `permission denied`.

```text
Docker version 29.0.1, build 1a2b3c4
Docker Compose version v2.40.3
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

Номера версий у тебя будут свои.

**Объясни себе:**
- Чем плох деплой под `yc-user` или `root` вместо отдельного пользователя?
- Почему пользователя в группе `docker` можно считать администратором ВМ?

**Типичные ошибки:**
- `permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock`: пользователя нет в группе `docker` или сессия старая: `usermod -aG docker`, войти заново.
- `Permission denied (publickey).` при входе как `deploy`: неверные права на `.ssh` (нужно 700) или `authorized_keys` (600), или владелец не `deploy`: повтори `chown` и `chmod`.
- `E: Unable to locate package docker-ce`: не добавлен репозиторий или не сделан `apt-get update` после него.

### Задание 2. Домен, стек на ВМ и сертификат Let's Encrypt

**Цель:** запустить Compose-стек по тегу образа и получить HTTPS с настоящим сертификатом.

**Предскажи:** что произойдёт с контейнером `proxy`, если запустить nginx сразу с блоком `listen 443 ssl` и путём к ещё не существующему сертификату?

<details markdown="1">
<summary>Ответ</summary>

nginx не стартует: `cannot load certificate ... No such file or directory`, контейнер уходит в перезапуск (`restart: unless-stopped` будет пытаться снова и снова). Отсюда двухэтапный запуск.

</details>

**Шаги:**

1. Создай A-запись домена (тип A, имя `notes`, значение `203.0.113.10`, TTL 300) в панели DNS-хостинга и проверь её: `dig +short A notes.example.com @1.1.1.1` должен вернуть `203.0.113.10`. Пока это не так, дальше не иди: без DNS Let's Encrypt не выдаст сертификат. Пустой вывод значит, что запись не создана, создана не в той зоне или ещё не разошлась (подожди TTL); в панелях имя пишут относительно зоны (`notes`, а не `notes.example.com`).

2. В репозитории `~/notes` создай `compose.prod.yml`. Он дополняет `compose.yml` из урока 4.6: образ берётся из ghcr по тегу, конфиг nginx боевой, есть тома для сертификатов:

```yaml
# Продовое переопределение: запускается вместе с compose.yml
services:
  notes:
    image: ghcr.io/<github-user>/notes:${NOTES_TAG:?нужен NOTES_TAG}
    restart: unless-stopped
  db:
    restart: unless-stopped
  proxy:
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    # !override заменяет список томов целиком: самоподписанный ./deploy/tls на проде не нужен
    volumes: !override
      - ./deploy/nginx/compose.prod.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /var/www/certbot:/var/www/certbot:ro
```

Замени `<github-user>` на свой логин. Если пакет в ghcr приватный, сделай его публичным (Package settings, Change visibility) или выполни на ВМ `docker login ghcr.io` с токеном `read:packages`.

3. Создай `deploy/nginx/compose.prod.conf`, этап 1: только порт 80.

```nginx
# Этап 1: порт 80 (проверка ACME и редирект на HTTPS)
server {
    listen 80;
    server_name notes.example.com;

    # certbot кладёт сюда файл-токен
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}
```

4. Отправь файлы на ВМ и создай `.env` (пароль генерируется, в git его нет):

```bash
rsync -azR -e "ssh -i ~/.ssh/notes-deploy" compose.yml compose.prod.yml deploy/nginx/compose.prod.conf deploy@203.0.113.10:/opt/notes/
ssh -i ~/.ssh/notes-deploy deploy@203.0.113.10 'cd /opt/notes && PASS=$(openssl rand -hex 16) && printf "POSTGRES_PASSWORD=%s\nDATABASE_URL=postgresql://notes:%s@db:5432/notes\nAPP_VERSION=0.4.1\nNOTES_DOMAIN=notes.example.com\n" "$PASS" "$PASS" > .env && chmod 600 .env'
```

5. На ВМ (под `yc-user`) запусти стек и получи сертификат (webroot):

```bash
sudo install -d /var/www/certbot
cd /opt/notes
export COMPOSE_FILE=compose.yml:compose.prod.yml NOTES_TAG=0.4.1
docker compose up -d
sudo apt-get install -y certbot
sudo certbot certonly --webroot -w /var/www/certbot -d notes.example.com \
  --agree-tos -m you@example.com --no-eff-email \
  --deploy-hook "docker compose -f /opt/notes/compose.yml -f /opt/notes/compose.prod.yml --project-directory /opt/notes exec -T proxy nginx -s reload"
```

Отладку лучше начинать с ключа `--dry-run`, чтобы не упереться в лимиты. Если `docker` не даёт доступ, выполняй эти команды под пользователем `deploy` (`sudo -iu deploy`).

6. Допиши в `compose.prod.conf` этап 2 (блок HTTPS), снова отправь файл через `rsync` и перезапусти прокси:

```nginx
# Этап 2: HTTPS (добавляется к блоку порта 80 выше)
resolver 127.0.0.11 valid=10s;

server {
    listen 443 ssl;
    http2 on;
    server_name notes.example.com;

    ssl_certificate     /etc/letsencrypt/live/notes.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/notes.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        # переменная заставляет nginx переразрешать имя после пересоздания контейнера
        set $upstream http://notes:8080;
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }
}
```

```bash
docker compose restart proxy
curl -sS -o /dev/null -w '%{http_code}\n' https://notes.example.com/healthz
echo | openssl s_client -connect notes.example.com:443 -servername notes.example.com 2>/dev/null | openssl x509 -noout -issuer -dates
sudo certbot renew --dry-run
```

**Что должно получиться:** код 200, издатель Let's Encrypt, дата окончания через около 90 дней, тестовое продление проходит.

```text
200
issuer=C = US, O = Let's Encrypt, CN = E7
notBefore=Sep 29 10:12:01 2026 GMT
notAfter=Dec 28 10:12:00 2026 GMT
Congratulations, all simulated renewals succeeded:
  /etc/letsencrypt/live/notes.example.com/fullchain.pem (success)
```

Имя издателя (`E7`) может отличаться: центр сертификации меняет промежуточные сертификаты, это нормально.

**Объясни себе:**
- Зачем `/etc/letsencrypt` подключён в nginx только на чтение?
- Что произойдёт через 60 дней, если `deploy-hook` не сработает?
- Почему после этапа 2 хватает `restart proxy`, а `up -d` не нужен?

**Типичные ошибки:**
- `Timeout during connect (likely firewall problem)`: порт 80 закрыт в security group или ufw, либо A-запись указывает на другой IP: открой 80 (`yc vpc security-group update-rules`), проверь `dig`.
- `Invalid response from http://notes.example.com/.well-known/acme-challenge/...: 404`: nginx не отдаёт каталог webroot: проверь том `/var/www/certbot` и `location`.
- `nginx: [emerg] cannot load certificate "/etc/letsencrypt/live/notes.example.com/fullchain.pem"`: этап 2 добавлен до выпуска сертификата: вернись к этапу 1.
- `too many failed authorizations recently`: упёрся в лимит Let's Encrypt: жди указанное время, отлаживай через `--dry-run`.

### Задание 3. Скрипт деплоя с откатом

**Цель:** выкатывать версию одной командой, проверять её и откатывать при провале.

**Предскажи:** что случится с работающим сервисом, если запустить `deploy.sh 9.9.9` (такого тега в реестре нет)? Он упадёт или продолжит работать на старой версии?

<details markdown="1">
<summary>Ответ</summary>

Продолжит работать: `docker compose pull` завершится ошибкой раньше `up -d`, `set -e` остановит скрипт, а контейнеры не тронуты. Именно поэтому pull идёт отдельным шагом до пересоздания.

</details>

**Шаги:**

1. Создай `deploy/vm/deploy.sh` в репозитории:

```bash
#!/usr/bin/env bash
# Использование: deploy.sh <тег образа>, например 0.4.1
set -euo pipefail

NEW_TAG="${1:?использование: deploy.sh <тег>}"
cd /opt/notes

# .env даёт NOTES_DOMAIN и пароли, тег версии задаём поверх него
set -a; . ./.env; set +a
export COMPOSE_FILE=compose.yml:compose.prod.yml
STATE=/opt/notes/.current-tag
PREV_TAG="$(cat "$STATE" 2>/dev/null || true)"

# запускаем указанный тег и ждём успешный smoke-test
run_tag() {
  export NOTES_TAG="$1" APP_VERSION="$1"
  docker compose up -d
  for _ in $(seq 1 15); do
    if curl -fsS --max-time 3 --resolve "${NOTES_DOMAIN}:443:127.0.0.1" \
         "https://${NOTES_DOMAIN}/healthz" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# pull отдельно: если тега нет, работающие контейнеры остаются нетронутыми
NOTES_TAG="$NEW_TAG" docker compose pull notes

if run_tag "$NEW_TAG"; then
  echo "$NEW_TAG" > "$STATE"
  echo "OK: запущена версия $NEW_TAG (была: ${PREV_TAG:-нет})"
else
  echo "FAIL: версия $NEW_TAG не прошла проверку" >&2
  if [ -n "$PREV_TAG" ]; then
    echo "Откат на $PREV_TAG" >&2
    run_tag "$PREV_TAG" || echo "Откат тоже не прошёл, нужен человек" >&2
  fi
  exit 1
fi
```

2. Проверь скрипт и отправь на ВМ:

```bash
shellcheck deploy/vm/deploy.sh
chmod +x deploy/vm/deploy.sh
rsync -azR -e "ssh -i ~/.ssh/notes-deploy" deploy/vm/deploy.sh deploy@203.0.113.10:/opt/notes/
```

3. Запусти дважды подряд (идемпотентность), затем с несуществующим тегом:

```bash
ssh -i ~/.ssh/notes-deploy deploy@203.0.113.10 '/opt/notes/deploy/vm/deploy.sh 0.4.1'
ssh -i ~/.ssh/notes-deploy deploy@203.0.113.10 '/opt/notes/deploy/vm/deploy.sh 0.4.1'
ssh -i ~/.ssh/notes-deploy deploy@203.0.113.10 '/opt/notes/deploy/vm/deploy.sh 9.9.9; echo код=$?'
```

**Что должно получиться:** два успешных запуска (при втором контейнеры не пересоздаются), а на 9.9.9 ошибка pull и ненулевой код. `https://notes.example.com/healthz` при этом по-прежнему отвечает 200.

```text
OK: запущена версия 0.4.1 (была: нет)
OK: запущена версия 0.4.1 (была: 0.4.1)
Error response from daemon: manifest unknown
код=1
```

**Объясни себе:**
- Почему smoke-test идёт через `https://<домен>` (с `--resolve` на 127.0.0.1), а не в `http://notes:8080`?
- Что делает `set -a`, и почему пароль из `.env` не попадает в вывод скрипта?
- Как вручную откатиться на конкретный тег? (Подсказка: тот же скрипт.)

**Типичные ошибки:**
- `Head "https://ghcr.io/v2/<github-user>/notes/manifests/0.4.1": denied`: пакет приватный, а ВМ не авторизована: сделай пакет публичным или `docker login ghcr.io`.
- `required variable NOTES_TAG is missing a value: нужен NOTES_TAG`: `docker compose` вызван вручную без переменной: `export NOTES_TAG=$(cat /opt/notes/.current-tag)`.
- `bash: /opt/notes/deploy/vm/deploy.sh: Permission denied`: нет бита исполнения: `chmod +x` до `rsync` (ключ `-a` сохраняет права).
- `curl: (60) SSL certificate problem`: домен в `.env` не совпадает с доменом сертификата: проверь `NOTES_DOMAIN`.

### Задание 4. Деплой по релизу в GitHub Actions (шаг проекта)

**Цель:** публикация GitHub Release выкатывает версию на ВМ без ручных шагов. Это шаг сквозного проекта «Заметки»: `https://notes.<домен>` работает из интернета, деплой идёт по тегу.

**Предскажи:** почему workflow запускается по `release: published`, а не по `push` тега, если образ уже собирается по тегу?

<details markdown="1">
<summary>Ответ</summary>

Релиз это осознанное действие человека после того, как `image.yml` завершил сборку. Push тега запускает сборку образа, а деплой стартует, когда ты решил выкатить. Иначе деплой гонялся бы с ещё не готовым образом.

</details>

**Шаги:**

1. Добавь секреты и переменную в репозиторий (Settings, Secrets and variables, Actions): `DEPLOY_SSH_KEY` (содержимое `~/.ssh/notes-deploy`), `DEPLOY_KNOWN_HOSTS` (вывод команды ниже), переменная `NOTES_DOMAIN`. Создай environment `production`.

```bash
ssh-keyscan -t ed25519 notes.example.com
```

2. Открой доступ к SSH из интернета (раннеры GitHub меняют адреса), пароли уже отключены в уроке 2.7:

```bash
yc vpc security-group list
yc vpc security-group update-rules notes-sg --add-rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[0.0.0.0/0]"
```

3. Создай `.github/workflows/deploy.yml`:

{% raw %}
```yaml
name: deploy
on:
  release:
    types: [published]

permissions:
  contents: read

# два деплоя одновременно не идут, второй ждёт первого
concurrency:
  group: deploy-prod
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-24.04
    environment: production
    steps:
      - uses: actions/checkout@v7.0.1

      - name: Подготовить ssh
        env:
          SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
        run: |
          install -m 700 -d ~/.ssh
          printf '%s\n' "$SSH_KEY" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          printf '%s\n' "$KNOWN_HOSTS" > ~/.ssh/known_hosts

      - name: Выкатить тег
        env:
          DOMAIN: ${{ vars.NOTES_DOMAIN }}
          RELEASE_TAG: ${{ github.event.release.tag_name }}
        run: |
          # v0.4.1 -> 0.4.1 (тег образа без префикса v)
          VERSION="${RELEASE_TAG#v}"
          rsync -azR compose.yml compose.prod.yml deploy/nginx/compose.prod.conf deploy/vm/deploy.sh "deploy@${DOMAIN}:/opt/notes/"
          ssh "deploy@${DOMAIN}" "/opt/notes/deploy/vm/deploy.sh ${VERSION}"

      - name: Smoke-test снаружи
        env:
          DOMAIN: ${{ vars.NOTES_DOMAIN }}
        run: curl -fsS --retry 5 --retry-delay 3 "https://${DOMAIN}/healthz"
```
{% endraw %}

4. Закоммить, опубликуй релиз для тега и следи за job:

```bash
git add compose.prod.yml deploy .github/workflows/deploy.yml
git commit -m "ci: деплой на ВМ по релизу"
git push
gh release create v0.4.1 --title "0.4.1" --notes "Деплой по релизу"
gh run watch
```

Если релиз для тега `v0.4.1` уже создан в уроке 3.5, опубликуй следующий тег своей нумерации: событие `published` наступает при публикации нового релиза.

5. Подключи внешнюю проверку: в бесплатном uptime-сервисе создай HTTPS-проверку `https://notes.example.com/healthz` раз в минуту с оповещением на почту. Останови `proxy` (`docker compose stop proxy`) на 3 минуты, получи оповещение и запусти обратно (`docker compose start proxy`).

**Что должно получиться:** job `deploy` зелёный, `curl` снаружи отвечает.

```text
OK: запущена версия 0.4.1 (была: 0.4.1)
ok
```

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://notes.example.com/healthz
```

```text
200
```

**Объясни себе:**
- Что лежит в `known_hosts` и от чего это защищает?
- Почему тег берётся из `github.event.release.tag_name` через переменную окружения, а не подставляется прямо в команду?
- Какие шаги этого workflow можно безопасно повторить при сбое?

**Типичные ошибки:**
- `Permission denied (publickey).`: секрет `DEPLOY_SSH_KEY` содержит не тот ключ или обрезан перевод строки, либо публичная часть не в `authorized_keys` пользователя `deploy`: обнови секрет целиком.
- `Host key verification failed.`: `DEPLOY_KNOWN_HOSTS` пуст или для другого адреса: заново `ssh-keyscan`.
- `ssh: connect to host notes.example.com port 22: Connection timed out`: security group не пускает 22 с адресов GitHub: правило из шага 2.
- Workflow не запустился: релиз создан как черновик (draft) или файл `deploy.yml` не попал в ветку по умолчанию до публикации релиза.

## Сломай и почини

Скачай скрипт поломки, не читай его и запусти на ВМ (сценарий 1, 2 или 3):

```bash
curl -fsSL https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/6.3/break.sh -o break.sh
bash break.sh 1
```

Сценарии: 1 certbot не проходит проверку домена; 2 job деплоя падает на входе по SSH; 3 после деплоя сайт отвечает 502.

### Симптом

Опиши то, что видишь, до всяких догадок: точный текст ошибки, на каком шаге, что изменилось с прошлого раза.

- Сценарий 1: `certbot ... Timeout during connect (likely firewall problem)`.
- Сценарий 2: job `deploy` красный, шаг «Выкатить тег»: `Permission denied (publickey).`
- Сценарий 3: деплой прошёл зелёным, а `https://notes.example.com/` отвечает `502 Bad Gateway`.

### Гипотезы

Для каждого симптома выпиши минимум три версии по слоям: DNS, сеть и файрвол, процесс, конфиг, права, секреты. Порядок проверки: от дешёвых и частых к дорогим.

### Проверки

По одной проверке на гипотезу, сначала снаружи: `dig +short A <домен> @1.1.1.1`, `curl -m 5 http://<домен>/`, `ssh -v ... deploy@<домен> true`, затем на ВМ `docker compose ps` и `docker compose logs --tail 30 proxy notes`.

### Исправление

<details markdown="1">
<summary>Разбор всех сценариев</summary>

**Сценарий 1 (certbot, Timeout during connect).** Запрос Let's Encrypt не достаёт до 80/tcp. Проверка: `curl -m 5 http://notes.example.com/` снаружи (с ноутбука, не с ВМ) зависает. Причина: в security group закрыт 80 (или ufw режет). Починка: добавить правило входящего 80/tcp из `0.0.0.0/0` в security group, проверить `sudo ufw status`, повторить `certbot --dry-run`. Если `dig` показывает чужой IP, причина в DNS.

**Сценарий 2 (Permission denied (publickey)).** `ssh -v` покажет, какие ключи предлагаются и что сервер их отвергает. Причины по частоте: в секрете не тот ключ; на ВМ права `authorized_keys` не 600 или домашний каталог доступен на запись группе; пользователь заблокирован. Починка: восстановить права (`chmod 700 ~/.ssh`, `chmod 600 ~/.ssh/authorized_keys`, `chown -R deploy:deploy`), записать верный публичный ключ, перезапустить job. Менять сразу три вещи в ходе расследования нельзя: потом не поймёшь, что помогло.

**Сценарий 3 (502 после деплоя).** nginx жив, приложение нет. `docker compose ps` покажет, что `notes` перезапускается, `docker compose logs notes` даст причину: неверный `DATABASE_URL` в `.env`, несовместимая версия, приложение слушает `127.0.0.1` вместо `0.0.0.0` внутри контейнера. Быстрая починка: откат `deploy.sh <предыдущий тег>`, потом разбор без давления. Вторая причина 502: nginx кэширует IP после пересоздания контейнера, лечится `resolver` и переменной в `proxy_pass`, как в уроке 4.6.

</details>

## Вопросы с собеседований

### 1. [junior] Ты поднял сервис на ВМ, по IP открывается, по домену нет. Что проверишь?

Иду по слоям. `dig +short` двумя резолверами: записи нет или IP другой, значит DNS (и смотрю TTL, если недавно меняли). Если IP верный, `curl -v --resolve домен:443:IP`, чтобы отделить DNS от сервиса. Дальше `openssl s_client` (сертификат на это имя), потом nginx `server_name`: без совпадения имени ответит default server.

**Что хотят услышать:** порядок по слоям, два резолвера, TTL, `--resolve`, `server_name`.

**Красный флаг:** «перезагружу сервер» или «пробую все команды подряд».

### 2. [middle] certbot пишет `Timeout during connect (likely firewall problem)`. Причины?

Let's Encrypt не достучался до 80/tcp по A-записи домена. Проверяю: куда указывает A-запись, пускает ли 80 security group облака, слушает ли порт nginx, не режет ли ufw. Проверку делаю снаружи, потому что с самой ВМ всё выглядит хорошо. Отлаживаю через `--dry-run`, чтобы не упереться в лимиты.

**Что хотят услышать:** HTTP-01 идёт на порт 80, облачный файрвол отдельно от ufw, проверка снаружи, лимиты.

**Красный флаг:** «открою все порты» или «поставлю сертификат вручную».

### 3. [middle] В проде истёк сертификат Let's Encrypt, хотя стоял certbot. Как разбираешь и как не допустить повторения?

Сначала восстановить сервис: `certbot renew`, reload nginx. Потом причина: таймер `certbot.timer` выключен, продление падало (порт 80 закрыт, webroot изменился) или deploy-hook не перечитал nginx (сертификат обновился на диске, а процесс держит старый). Предотвращение: `certbot renew --dry-run` в проверках, алерт на срок сертификата за 14 дней, внешний мониторинг.

**Что хотят услышать:** deploy-hook и reload, логи `/var/log/letsencrypt`, мониторинг срока, а не только автоматизация.

**Красный флаг:** «продлю руками раз в три месяца».

### 4. [middle] Как задеплоить без простоя на одной ВМ и какие есть ограничения?

Полностью без простоя на одной ВМ не получится: `up -d` пересоздаёт контейнер, пара секунд 502. Влияние снижают быстрым стартом, healthcheck, повтором запросов на клиенте, деплоем в тихое время. Blue/green на одной ВМ возможен (два контейнера, nginx переключает upstream), но ВМ остаётся SPOF, а миграции БД надо делать обратно совместимыми. Настоящее решение: два экземпляра за балансировщиком или Kubernetes.

**Что хотят услышать:** честное «нет» с обоснованием, blue/green, совместимые миграции, SPOF.

**Красный флаг:** «у нас без простоя» без объяснения, как.

### 5. [middle] Где и как хранишь SSH-ключ для деплоя из CI? Что если он утёк?

Отдельная пара ключей и пользователь только для деплоя, приватный ключ в секретах CI с привязкой к environment, `known_hosts` закреплён. При утечке: сразу убрать публичный ключ с ВМ, выпустить новый, проверить логи входов, разобраться, как ключ оказался в логе. Улучшения: ограничить ключ одной командой, пускать только с известных адресов.

**Что хотят услышать:** отдельный пользователь, отзыв раньше расследования, ограничение по команде.

**Красный флаг:** личный ключ админа в CI или «ключ лежит в приватном репозитории».

### 6. [junior] После деплоя сервис отвечает 502. Действия?

Первое: откатить на предыдущий тег, если он известен и пользователи страдают, потом разбираться. Затем `docker compose ps`, логи `proxy` и `notes`. Если `notes` перезапускается, читаю причину в логах (конфиг, БД). Если жив, но nginx ходит на старый IP, нужен `resolver`.

**Что хотят услышать:** сначала восстановить, потом анализ; `ps` и логи; кэш IP в nginx.

**Красный флаг:** править конфиг в контейнере на живую, без отката и записи, что изменено.

### 7. [junior] SLA 99.9% это сколько простоя в месяц, и что делать, если единственная ВМ упала в 3 ночи?

За 30 дней это около 43 минут. Из одной ВМ такой SLA не построить: любая поломка, обслуживание провайдера или неудачный деплой едят бюджет. По факту: алерт из внешней проверки, перезапуск ВМ, при потере диска восстановление из снапшота и бэкапа. Системно: вторая ВМ или Managed-сервисы и runbook восстановления.

**Что хотят услышать:** арифметика, SPOF, восстановление из бэкапа, RTO и RPO как ориентир.

**Красный флаг:** «облако не падает» или отсутствие внешнего мониторинга.

### 8. [middle] Один и тот же деплой запустили дважды или два разных тега одновременно. Чем это опасно и как защищаешься?

Повтор того же тега безопасен, если деплой идемпотентный: `up -d` ничего не пересоздаёт. Опасен параллельный запуск разных тегов: гонка за состояние и `.current-tag`. Защита: `concurrency` в CI, а на ВМ блокировка `flock` в скрипте. Откат тоже идёт через тот же скрипт.

**Что хотят услышать:** идемпотентность, `concurrency`, `flock`, единая точка входа.

**Красный флаг:** «просто не запускать два раза».

### 9. [junior] Что такое smoke-test и чем он отличается от healthcheck контейнера?

Healthcheck отвечает «процесс внутри жив». Smoke-test проходит весь путь пользователя: DNS, TLS, nginx, приложение, и потому ловит то, чего контейнер не видит (просроченный сертификат, закрытый порт). Он быстрый, с таймаутом и ограниченным числом повторов.

**Что хотят услышать:** проверка снаружи через полный путь, таймаут и повторы, связь с откатом.

**Красный флаг:** «`docker ps` показал Up, значит всё хорошо».

### 10. [middle] Зачем внешний мониторинг, если на ВМ уже есть healthcheck? Что проверять?

С ВМ не видно проблем DNS, сертификата, файрвола и самой ВМ. Внешняя проверка раз в минуту `https://домен/healthz` с нескольких точек, оповещение после 2-3 неудач подряд, плюс алерт на срок сертификата. Мониторинг должен жить вне проверяемой ВМ.

**Что хотят услышать:** «снаружи», несколько точек, срок сертификата, независимость от мониторимого.

**Красный флаг:** мониторинг только на самой ВМ, которая и упала.

## Проверено на версиях

- Ubuntu на ВМ: 26.04 LTS или 24.04 LTS
- Docker Engine и Compose: версия не закреплена, проверь актуальную версию на странице проекта (нужен Compose не ниже 2.24 из-за `!override`)
- certbot: из репозитория Ubuntu, версия не закреплена, проверь актуальную версию на странице проекта
- nginx: 1.30
- PostgreSQL: 18
- actions/checkout: v7.0.1
- Образ «Заметок»: 0.4.1 (app.py v4.1)
- Yandex Cloud CLI `yc`: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею поставить Docker Engine на ВМ из официального apt-репозитория и создать отдельного пользователя для деплоя
- [ ] умею привязать домен к IP ВМ и проверить запись `dig` двумя резолверами
- [ ] умею получить сертификат Let's Encrypt через webroot и проверить его `openssl s_client`
- [ ] умею настроить автопродление и проверить его `certbot renew --dry-run` с перезагрузкой nginx
- [ ] умею написать идемпотентный `deploy.sh` со smoke-test и откатом на предыдущий тег
- [ ] умею собрать workflow, который выкатывает релиз по SSH с ключом из секретов
- [ ] умею объяснить, почему одна ВМ это SPOF, и посчитать простой для SLA 99.9%

**Дальше:** [Урок 6.4: Managed-сервисы: PostgreSQL, Kubernetes, балансировщик](04-managed-services.md)
