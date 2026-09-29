---
layout: lesson
title: "Проблема секретов и HashiCorp Vault"
topic: 9
lesson: "9.1"
time: "2 ч"
---

## Зачем это нужно

Пароль от базы в `.env`, токен в истории git, ключ в переменных окружения контейнера: так секреты утекают чаще всего, и никакой хакер для этого не нужен. На работе тебя спросят, где хранятся секреты, кто к ним ходил и что делать при утечке. Хранилище секретов (secrets manager) отвечает на все три вопроса: отдаёт секрет по политике, шифрует его на диске и ведёт аудит.

В этом уроке ты найдёшь утечки руками, поработаешь с Vault в трёх режимах (dev, с диском и запечатыванием, в кластере) и поймёшь, чем он лучше `.env`.

Шаг проекта: в кластере `kind-notes` появляется Vault (namespace `vault`) со скриптом `scripts/seed-vault.sh`, в нём лежит `secret/notes/db`, пока секрет кладётся вручную.

## Что нужно знать

- [Урок 3.4: качество и безопасность в CI](../03-git-ci/04-quality-security-ci.md) - сканеры секретов и почему `.env` нельзя в git
- [Урок 4.2: Dockerfile](../04-docker/02-dockerfile.md) - слои образа, `docker run -e`, `docker exec`
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - откуда взялся пароль БД в `.env`
- [Урок 5.1: зачем Kubernetes, кластер kind](../05-kubernetes/01-why-k8s-cluster.md) - кластер `kind-notes`
- [Урок 5.6: ConfigMap и Secret](../05-kubernetes/06-config-secrets.md) - почему Secret это всего лишь base64
- [Урок 5.9: Helm](../05-kubernetes/09-helm.md) - установка чарта из репозитория

## Теория

### Где секреты утекают

Секрет (secret) это всё, что даёт доступ: пароль, токен, приватный ключ, строка подключения. Утекают они в предсказуемых местах:

| Место | Как утекает |
|---|---|
| git | `.env` или `config.yaml` закоммитили; удаление файла не стирает его из истории |
| образ Docker | `COPY .env` или `ARG PASSWORD`: значение остаётся в слоях, `docker history` его покажет |
| переменные окружения | видны в `docker inspect`, в `/proc/<pid>/environ`, в дампах падений, иногда в логах |
| чат и тикеты | «скинь пароль от прода в личку» живёт в поиске мессенджера годами |
| история shell | `mysql -pПароль` или `export TOKEN=...` лежит в `~/.bash_history` |
| Kubernetes Secret | только base64, читает любой, у кого есть `get secret` (урок 5.6) |

Общий принцип: секрет нельзя ни «спрятать получше», ни «не показывать». Нужно, чтобы он выдавался тому, кому положено, на время, с записью в журнал, а при утечке отзывался за минуты.

> **Проверь понимание:** ты удалил `.env` из репозитория коммитом `remove secrets`. Секрет безопасен?

<details>
<summary>Ответ</summary>

Нет. Файл остался в истории, любой клон репозитория содержит его. Правильно: считать секрет скомпрометированным, сменить его (ротация, rotation) и только потом чистить историю. Ротация обязательна, чистка истории нет.

</details>

### Что такое Vault

HashiCorp Vault (хранилище секретов) это сервис с HTTP API. Приложение приходит с токеном, Vault проверяет политику и отдаёт секрет. Что он даёт сверх «надёжной папки»:

- шифрование при хранении: на диске лежит шифротекст, ключ шифрования в открытом виде не хранится;
- политики (policies) на языке HCL: кто и к какому пути ходит, на чтение или запись;
- аудит (audit device): каждый запрос пишется в журнал;
- аренда (lease) и TTL: токен и динамические секреты живут ограниченное время;
- динамические секреты (dynamic secrets): Vault сам создаёт временного пользователя БД и удаляет его по истечении TTL. Красть постоянный пароль нечего (в этом уроке только идея, практика в [уроке 9.2](02-vault-k8s-eso.md)).

Версия курса Vault v2.1.1 распространяется по лицензии BSL (Business Source License, не открытая). Открытая альтернатива: OpenBao v2.7.0, форк с той же архитектурой, команды `bao` совпадают с `vault`. Для учебы и внутреннего использования разницы нет, для продукта, который продаёшь, стоит читать лицензию.

### Seal и unseal

После запуска Vault запечатан (sealed): данные на диске есть, но расшифровать их нечем. Ключ шифрования данных защищён мастер-ключом, а мастер-ключ при `vault operator init` разрезается по алгоритму Шамира на N долей (key shares); для распечатывания (unseal) нужно собрать K из них (threshold). Прод-классика 5 из 3: ни один админ в одиночку не откроет хранилище.

Следствия, о которые все спотыкаются:

- перезапуск пода или сервера снова запечатывает Vault, и пока его не распечатали, все клиенты получают `Vault is sealed`;
- потерял больше N-K долей: данные не расшифровать никак, даже владельцу. Бэкап хранилища бесполезен без ключей;
- при `init` выдаётся ещё root-токен (root token): всемогущий, его используют для начальной настройки и потом отзывают.

В облаке ручной unseal заменяют auto-unseal через облачный KMS: мастер-ключ хранит KMS, Vault распечатывается сам при старте. Для учебного стенда мы используем 1 долю из 1, для прода такой вариант недопустим.

### KV v2, политики и токены

Движок секретов (secrets engine) определяет, что лежит по пути. `kv` версии 2 хранит пары ключ-значение с историей версий. Важная деталь: CLI пишет `secret/notes/db`, а в политике и API путь превращается в `secret/data/notes/db` (данные) и `secret/metadata/notes/db` (метаданные и список). Забыл `data` в политике: получишь `permission denied` при том, что политика «вроде правильная».

Политика по умолчанию запрещает всё. Пример политики `notes-read`, которую мы используем в проекте:

```hcl
# Чтение только секретов приложения, ничего больше
path "secret/data/notes/*" {
  capabilities = ["read"]
}
# Список ключей внутри каталога
path "secret/metadata/notes/*" {
  capabilities = ["read", "list"]
}
```

Токен (token) привязан к политикам и TTL. Правило: root-токен не хранят и не используют в работе, для людей и приложений выпускают токены с узкими политиками.

> **Проверь понимание:** политика разрешает `read` на `secret/notes/*`, а `vault kv get secret/notes/db` отвечает `permission denied`. Почему?

<details>
<summary>Ответ</summary>

В KV v2 путь данных `secret/data/notes/db`. Политику надо писать с `data` в середине.

</details>

### Другие подходы

SOPS с age шифрует значения в YAML, файл коммитят в git; Sealed Secrets расшифровывает только контроллер своего кластера; облачные менеджеры (AWS Secrets Manager, Yandex Lockbox) привязаны к облаку. У первых двух нет аудита и динамических секретов, зато нет и отдельного сервиса. Vault оправдан, когда нужны аудит, политики и динамические секреты и есть кому его эксплуатировать: он сам становится критичным сервисом.

## Практика

Нужны Docker (урок 4.2), `jq` и `git`. Работаешь в отдельных каталогах `~/leak-lab` и `~/vault-lab`, репозиторий `~/notes` пока не трогаем.

### Задание 1. Найди утечки руками

**Цель:** увидеть, где на самом деле лежит секрет, который «спрятан в переменную».

**Предскажи:** запустишь контейнер с `-e DB_PASSWORD=...` и потом удалишь `.env` из git. Найдёшь ли ты пароль (а) в `docker inspect`, (б) в `docker history` образа, (в) в `git log` после удаления файла?

<details>
<summary>Ответ</summary>

(а) да, в поле `Env`. (в) да, в истории. (б) зависит от образа: если пароль передан только через `-e`, в слоях его нет; если он попал в `ENV`, `ARG` или `COPY`, то есть.

</details>

**Шаги:**

1. Контейнер с секретом в переменной:

```bash
docker run -d --name leak-demo -e DB_PASSWORD=CHANGE_ME_1 postgres:18-alpine sleep 600
docker inspect leak-demo | grep DB_PASSWORD
docker exec leak-demo cat /proc/1/environ | tr '\0' '\n' | grep DB_PASSWORD
```

2. Секрет в git, который «удалили»:

```bash
mkdir -p ~/leak-lab && cd ~/leak-lab && git init -q -b main
echo 'DB_PASSWORD=CHANGE_ME_2' > .env
git add .env && git -c user.name=t -c user.email=t@t commit -qm "add env"
git rm -q .env && git -c user.name=t -c user.email=t@t commit -qm "remove secrets"
ls -a
git log --oneline -S CHANGE_ME_2
git show HEAD~1:.env
```

**Что должно получиться:**

```text
            "DB_PASSWORD=CHANGE_ME_1",
DB_PASSWORD=CHANGE_ME_1
.  ..  .git
a1b2c3d add env
DB_PASSWORD=CHANGE_ME_2
```

Хеш коммита у тебя будет другой. Главное: во всех случаях значение читается открытым текстом.

**Объясни себе:**
- Почему `ls -a` пуст, а `git show HEAD~1:.env` выдаёт пароль?
- Кто на хосте может прочитать `/proc/<pid>/environ` чужого процесса?
- Что нужно сделать с `CHANGE_ME_2`, кроме чистки истории?

**Типичные ошибки:**
- `fatal: path '.env' does not exist in 'HEAD~1'`: коммитов меньше двух или файл назван иначе: проверь `git log --oneline`.
- `Error response from daemon: Conflict. The container name "/leak-demo" is already in use`: контейнер остался с прошлого раза: `docker rm -f leak-demo`.

Прибери за собой: `docker rm -f leak-demo; rm -rf ~/leak-lab`.

### Задание 2. Vault в dev-режиме: секрет, политика, отказ

**Цель:** освоить `kv put/get` и увидеть, как политика ограничивает токен.

**Предскажи:** токен с политикой `notes-read` попробует прочитать `secret/notes/db` и `secret/billing/card`, а потом записать в `secret/notes/db`. Какие из трёх операций пройдут?

<details>
<summary>Ответ</summary>

Пройдёт только чтение `secret/notes/db`. Чужой путь не описан в политике, а запись не входит в `capabilities`.

</details>

**Шаги:**

1. Dev-режим: Vault сразу распечатан, хранит данные в памяти, токен известен. Только для 30-секундной демонстрации.

```bash
docker run -d --name vault-dev --cap-add=IPC_LOCK -p 127.0.0.1:8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=CHANGE_ME_dev hashicorp/vault:2.1.1
# Удобный псевдоним: vault внутри контейнера с адресом и токеном
alias v='docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=CHANGE_ME_dev vault-dev vault'
v status
```

2. Положи и прочитай секрет, перезапиши и посмотри историю версий:

```bash
v kv put -mount=secret notes/db username=notes password=CHANGE_ME_pw database=notes
v kv get -mount=secret notes/db
v kv put -mount=secret notes/db username=notes password=CHANGE_ME_pw2 database=notes
v kv get -mount=secret -version=1 -field=password notes/db
v kv put -mount=secret billing/card key=CHANGE_ME_card
```

3. Политика и токен с ней:

```bash
docker exec -i vault-dev sh -c 'cat > /tmp/notes-read.hcl' <<'HCL'
path "secret/data/notes/*" {
  capabilities = ["read"]
}
path "secret/metadata/notes/*" {
  capabilities = ["read", "list"]
}
HCL
v policy write notes-read /tmp/notes-read.hcl
NT=$(v token create -policy=notes-read -ttl=1h -field=token)
alias vn='docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=$NT vault-dev vault'
vn kv get -mount=secret -field=password notes/db
vn kv get -mount=secret billing/card
vn kv put -mount=secret notes/db password=hack
```

**Что должно получиться:**

```text
Initialized     true
Sealed          false
Version         2.1.1
...
CHANGE_ME_pw
...
Error reading secret/data/billing/card: Error making API request.
...
Code: 403. Errors:

* 1 error occurred:
	* permission denied
```

`-version=1` возвращает старое значение `CHANGE_ME_pw`, обычный `kv get` покажет `CHANGE_ME_pw2`. Отказ (403) появится дважды: на чужом пути и на записи.

**Объясни себе:**
- Почему в политике `secret/data/...`, а в команде `notes/db`?
- Что даёт TTL токена в 1 час, если токен утёк?
- Чем `kv get` отличается от чтения Kubernetes Secret?

**Типичные ошибки:**
- `Error checking seal status: Get "https://127.0.0.1:8200/v1/sys/seal-status": http: server gave HTTP response to HTTPS client`: не задан `VAULT_ADDR=http://...`: добавь переменную.
- `Code: 403 ... permission denied` на своём же пути: в политике забыли `data`: смотри теорию.
- `bind: address already in use`: порт 8200 занят: `docker rm -f vault-dev`.

### Задание 3. Как в проде: диск, unseal, перезапуск, аудит

**Цель:** пройти жизненный цикл `init`, `unseal`, рестарт, `sealed`, и найти чтение секрета в аудите.

**Предскажи:** после `docker restart` что покажет `vault status` и получится ли прочитать секрет? Останутся ли данные на диске?

<details>
<summary>Ответ</summary>

`Sealed true`, чтение вернёт `Vault is sealed`. Данные на диске целы, но зашифрованы: нужно снова ввести три доли ключа.

</details>

**Шаги:**

1. Останови dev и подготовь конфигурацию с файловым хранилищем (file storage):

```bash
docker rm -f vault-dev
mkdir -p ~/vault-lab/config && cd ~/vault-lab
cat > config/vault.hcl <<'HCL'
# Данные на диске, в томе
storage "file" {
  path = "/vault/file"
}
# TLS отключён только для учебного стенда на localhost
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
api_addr      = "http://127.0.0.1:8200"
disable_mlock = true
HCL
docker run -d --name vault-prod -p 127.0.0.1:8200:8200 \
  -v vault-data:/vault/file -v "$PWD/config:/vault/config:ro" \
  hashicorp/vault:2.1.1 server
alias v='docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault-prod vault'
v status
```

2. Инициализация 5 из 3 и распечатывание. Ключи сохраняем в файл с правами 600 вне любого репозитория:

```bash
v operator init -key-shares=5 -key-threshold=3 -format=json > ~/vault-lab/init.json
chmod 600 ~/vault-lab/init.json
for i in 0 1 2; do v operator unseal "$(jq -r ".unseal_keys_b64[$i]" ~/vault-lab/init.json)" >/dev/null; done
v status | grep -E 'Sealed|Total Shares|Threshold'
```

3. Включи аудит, положи секрет, прочитай его и найди запись в журнале:

```bash
ROOT=$(jq -r .root_token ~/vault-lab/init.json)
va() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT" vault-prod vault "$@"; }
va audit enable file file_path=/vault/logs/audit.log
va secrets enable -path=secret kv-v2
va kv put -mount=secret notes/db password=CHANGE_ME_pw
va kv get -mount=secret notes/db >/dev/null
docker exec vault-prod grep -c 'secret/data/notes/db' /vault/logs/audit.log
docker exec vault-prod tail -n 1 /vault/logs/audit.log | jq '{type, path: .request.path, op: .request.operation, pw: .response.data}'
```

4. Перезапусти и убедись, что Vault запечатан:

```bash
docker restart vault-prod && sleep 3
v status | grep Sealed
va kv get -mount=secret notes/db
```

**Что должно получиться:**

```text
Sealed          false
Total Shares    5
Threshold       3
...
4
{
  "type": "response",
  "path": "secret/data/notes/db",
  "op": "read",
  "pw": { "data": { "password": "hmac-sha256:..." } }
}
...
Sealed          true
Error reading secret/data/notes/db: ... Vault is sealed
```

Число совпадений может отличаться. Значение пароля в аудите хеширует HMAC: в журнале видно, кто и что читал, но не сам секрет.

**Объясни себе:**
- Почему после рестарта данные целы, а прочитать их нельзя?
- Что произойдёт, если потеряешь три из пяти долей ключа?
- Почему root-токен из `init.json` нужно отозвать, когда настроишь нормальные токены?

**Типичные ошибки:**
- `Error initializing: ... Vault is already initialized`: том `vault-data` уже с данными: `docker rm -f vault-prod && docker volume rm vault-data` и заново (потеряешь всё, это учебный стенд).
- `Error enabling audit device: ... permission denied`: команда выполнена без `VAULT_TOKEN`: используй функцию `va`.
- `Error unsealing: ... invalid key`: перепутан индекс: индексы массива с 0 до 4.

Прибери: `docker rm -f vault-prod; docker volume rm vault-data`. Файл `init.json` удали после урока: `shred -u ~/vault-lab/init.json 2>/dev/null || rm -P ~/vault-lab/init.json`.

### Задание 4. Проект «Заметки»: Vault в кластере и `seed-vault.sh`

**Цель:** поднять Vault в кластере `kind-notes`, инициализировать его скриптом и положить `secret/notes/db`.

**Предскажи:** после `helm install` под `vault-0` будет `Running`, но не `Ready`. Почему?

<details>
<summary>Ответ</summary>

Readiness-проба Vault считает готовым только распечатанный сервер. Пока не выполнен `unseal`, под `0/1 Running`. Это нормально.

</details>

**Шаги:**

1. Убедись, что кластер жив: `kubectl config use-context kind-notes && kubectl get nodes`.
2. Установи Vault: режим standalone с файловым хранилищем на PVC (том) 1 ГБ, образ закреплён:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm install vault hashicorp/vault -n vault --create-namespace \
  --set server.image.tag=2.1.1 \
  --set server.dataStorage.size=1Gi \
  --set injector.enabled=false
kubectl -n vault get pods
```

3. Создай скрипт `~/notes/scripts/seed-vault.sh` целиком и сделай его исполняемым (`chmod +x`):

```bash
#!/usr/bin/env bash
# Инициализация Vault в кластере kind-notes. Идемпотентен: можно запускать повторно.
set -euo pipefail

NS=vault
POD=vault-0
INIT_DIR="$HOME/.notes-secrets"
INIT_FILE="$INIT_DIR/vault-init.json"

# Команда vault внутри пода; токен передаём через env, а не через историю shell
vcmd() {
  kubectl -n "$NS" exec -i "$POD" -- env VAULT_TOKEN="${ROOT:-}" vault "$@"
}

kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$POD" --timeout=180s
mkdir -p "$INIT_DIR" && chmod 700 "$INIT_DIR"

# 1. init: 1 ключ из 1 только для учебного стенда (в проде: 5 ключей, порог 3)
status=$(vcmd status -format=json || true)
if [ "$(echo "$status" | jq -r .initialized)" != "true" ]; then
  vcmd operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  echo "init выполнен, ключи в $INIT_FILE (вне репозитория)"
fi

# 2. unseal
if [ "$(vcmd status -format=json | jq -r .sealed || true)" != "false" ]; then
  vcmd operator unseal "$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")" > /dev/null
fi
ROOT=$(jq -r .root_token "$INIT_FILE")

# 3. движок kv-v2 по пути secret/
vcmd secrets list -format=json | jq -e '."secret/"' > /dev/null \
  || vcmd secrets enable -path=secret kv-v2

# 4. политика notes-read
vcmd policy write notes-read - <<'HCL'
path "secret/data/notes/*" {
  capabilities = ["read"]
}
path "secret/metadata/notes/*" {
  capabilities = ["read", "list"]
}
HCL

# 5. Kubernetes auth и роль notes (ns notes, ServiceAccount notes)
vcmd auth list -format=json | jq -e '."kubernetes/"' > /dev/null \
  || vcmd auth enable kubernetes
kubectl -n "$NS" exec -i "$POD" -- env VAULT_TOKEN="$ROOT" sh -c \
  'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"' > /dev/null
vcmd write auth/kubernetes/role/notes \
  bound_service_account_names=notes \
  bound_service_account_namespaces=notes \
  policies=notes-read ttl=1h > /dev/null

# 6. секрет БД: генерируем пароль, если секрета ещё нет
if ! vcmd kv get -mount=secret notes/db > /dev/null 2>&1; then
  PASS=$(openssl rand -base64 24)
  vcmd kv put -mount=secret notes/db username=notes password="$PASS" database=notes > /dev/null
  echo "секрет secret/notes/db создан"
fi
echo "готово: vault.vault.svc:8200"
```

4. Запусти и проверь:

```bash
~/notes/scripts/seed-vault.sh
kubectl -n vault get pods
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$(jq -r .root_token ~/.notes-secrets/vault-init.json)" \
  vault kv get -mount=secret -field=username notes/db
~/notes/scripts/seed-vault.sh   # повторный запуск ничего не ломает
```

5. Проверь, что ключи вне репозитория, и зафиксируй скрипт в git:

```bash
cd ~/notes && git status --short
stat -c '%a %n' ~/.notes-secrets/vault-init.json    # на macOS: stat -f '%Lp %N'
git add scripts/seed-vault.sh && git commit -m "Vault в кластере и seed-vault.sh"
```

Эталон: [scripts/seed-vault.sh](https://github.com/distinguished-sre/devops/tree/devops/project/notes/scripts/seed-vault.sh).

**Что должно получиться:**

```text
NAME      READY   STATUS    RESTARTS   AGE
vault-0   1/1     Running   0          2m
notes
готово: vault.vault.svc:8200
600 /home/user/.notes-secrets/vault-init.json
```

При первом запуске перед «готово» будут строки `init выполнен ...` и `секрет secret/notes/db создан`, при втором их нет. `git status` не показывает ничего из `~/.notes-secrets`.

**Объясни себе:**
- Почему ключи и root-токен лежат в `~/.notes-secrets/`, а не в `~/notes`?
- Чем проект нарушает принципы урока (подсказка: роль долга «секрет пока вручную в Vault»)?
- Что произойдёт с Vault после `kind delete cluster` и после `docker restart notes-control-plane`?

**Типичные ошибки:**
- `Error from server (BadRequest): pod vault-0 does not have a host assigned`: под ещё не запущен: скрипт ждёт 180 секунд, подожди или проверь `kubectl -n vault describe pod vault-0`.
- `Error: INSTALLATION FAILED: cannot re-use a name that is still in use`: Vault уже установлен: `helm -n vault list`, и переходи к скрипту.
- `jq: error (at <stdin>:0): Cannot index number with string "initialized"`: `vault status` ответил не JSON (под не готов к запросам): подожди и запусти скрипт снова.
- `Error making API request ... Code: 403 ... permission denied` при `kv get`: не передан `VAULT_TOKEN`: используй команду из шага 4 целиком.

## Сломай и почини

Запусти сценарий и не читай скрипт:

```bash
bash ~/notes/break/9.1/break.sh random
```

Сценарии 1, 2 и 3 выбираются случайно (можно `break.sh 1` и т.д.).

### Симптом

Запиши, что видишь: код ответа, текст ошибки, состояние пода Vault.

### Гипотезы

Составь две-три до запуска проверок: запечатан ли Vault, есть ли ключи, что могло попасть в историю и файлы.

### Проверки

```bash
kubectl -n vault get pods
kubectl -n vault exec vault-0 -- vault status
ls -l ~/.notes-secrets/
history | grep -i token
```

### Исправление

<details>
<summary>Разбор трёх сценариев</summary>

**1. `Vault is sealed` после рестарта.** `vault status` показывает `Sealed true`, под `0/1 Running`. Причина: рестарт запечатывает хранилище. Исправление: запустить `~/notes/scripts/seed-vault.sh` (он распечатает Vault ключом из `~/.notes-secrets/vault-init.json`) или выполнить `vault operator unseal <ключ>` вручную нужное число раз. Профилактика: auto-unseal через KMS и алерт на `vault_core_unsealed == 0`.

**2. Потеряны unseal-ключи.** `unseal` невозможен, данные зашифрованы. Исправление: если хватает долей по порогу, распечатать ими. Если нет, данные не восстановить, ни бэкап, ни поддержка не помогут. Действия: поднять Vault заново (`init`), заново загрузить секреты из источников (менеджер, владельцы систем), всё, что лежало в утерянном Vault, считать потерянным и перевыпустить. Профилактика: доли разным людям, копия в сейфе, учения по unseal.

**3. Root-токен в истории shell.** В `history` или логах виден `hvs.`-токен. Исправление: отозвать его (`vault token revoke <токен>`), создать нужные токены с узкими политиками, очистить историю (`history -c`) и не использовать root после начальной настройки. Аварийный новый root можно получить через `vault operator generate-root` (нужен кворум долей).

</details>

## Вопросы с собеседований

### 1. [junior] Где ты хранишь секреты приложения и где хранить нельзя?

Нельзя в git, в образе, в чате, в открытом виде в переменных, доступных всем. Храню в менеджере секретов (Vault, облачный аналог) и выдаю приложению при старте с ограниченными правами. Если что-то попало в git, считаю секрет скомпрометированным и меняю.

**Что хотят услышать:** список мест утечки, идея «выдаётся, а не лежит», ротация после утечки.

**Красный флаг:** «зашифрую base64» или «удалю коммит и всё».

### 2. [middle] Пароль БД закоммитили в публичный репозиторий полчаса назад. Твои действия?

Сначала ротирую пароль в БД и во всех потребителях: секрет считаю известным. Потом смотрю логи БД и аудит на использование за этот период. Только затем чищу историю (`git filter-repo`) и закрываю причину: pre-commit и сканер секретов в CI (урок 3.4). Уведомляю ответственного по безопасности.

**Что хотят услышать:** ротация раньше чистки, проверка использования, профилактика.

**Красный флаг:** «сделаю `git push --force` и никто не увидит».

### 3. [junior] Что значит, что Vault запечатан (sealed)?

Данные на диске зашифрованы, а ключ расшифровки не в памяти: Vault не может ни прочитать, ни отдать их. Распечатывается вводом K долей мастер-ключа из N. Запечатывается при каждом запуске.

**Что хотят услышать:** алгоритм Шамира, 5 из 3, auto-unseal через KMS.

**Красный флаг:** «запечатан значит выключен» или «это пароль администратора».

### 4. [middle] После обновления ноды Vault недоступен, приложения получают ошибку. Что делаешь?

Смотрю `vault status`: скорее всего `Sealed true`, потому что под пересоздан. Распечатываю кворумом ключей, проверяю `Ready` и что клиенты восстановились. Затем разбираюсь, почему нет auto-unseal, и добавляю алерт на запечатанность, чтобы не узнавать от пользователей.

**Что хотят услышать:** проверка статуса, ключи у нескольких людей, auto-unseal, мониторинг.

**Красный флаг:** «пересоздам Vault» (потеряет данные).

### 5. [middle] Потеряли все unseal-ключи. Что делать?

Данные не восстановить: без ключей мастер-ключ недоступен, а обхода нет по дизайну. Поднимаю новый Vault, восстанавливаю секреты из первоисточников (владельцы систем, менеджер паролей), перевыпускаю то, что нельзя восстановить. Разбор: доли у разных людей, копии в сейфе, учения.

**Что хотят услышать:** честное «нельзя», план восстановления, профилактика.

**Красный флаг:** «свяжусь с поддержкой HashiCorp, они расшифруют».

### 6. [middle] `vault kv get secret/notes/db` возвращает `permission denied`, хотя политика разрешает read на `secret/notes/*`. Причина?

В KV v2 путь данных `secret/data/notes/*`, а для `list` и метаданных `secret/metadata/...`. Проверяю `vault policy read`, `vault token lookup` (какие политики у токена) и точный путь в ошибке.

**Что хотят услышать:** различие путей v1 и v2, диагностика по ошибке и токену.

**Красный флаг:** «выдам root, чтобы заработало».

### 7. [junior] Чем dev-режим Vault отличается от боевого и почему в прод нельзя?

В dev-режиме Vault распечатан, хранит всё в памяти, токен известен, TLS нет. После рестарта данные пропадают, любой с токеном имеет полный доступ. Годится для демо на 30 секунд.

**Что хотят услышать:** память, известный root, нет TLS и persistence.

**Красный флаг:** «просто включён флаг для скорости, потом можно оставить».

### 8. [middle] Нужно, чтобы утечка пароля БД из приложения не давала долгий доступ. Как?

Динамические секреты: Vault создаёт пользователя БД с TTL, скажем час, и удаляет его по истечении. Утекший пароль скоро перестаёт работать, а в аудите видно, кому выдан. Дополнительно короткие токены и узкие политики.

**Что хотят услышать:** database secrets engine, lease, TTL, отзыв.

**Красный флаг:** «будем менять пароль раз в год».

### 9. [middle] Vault, SOPS или Sealed Secrets для команды из трёх человек и одного кластера?

Для такого размера SOPS или Sealed Secrets: секрет зашифрован в git, отдельного критичного сервиса нет. Vault беру, когда нужны аудит, политики, динамические секреты и есть команда на эксплуатацию.

**Что хотят услышать:** ограничения каждого, цена эксплуатации Vault, критерии выбора.

**Красный флаг:** «Vault всегда лучше, ставим везде».

### 10. [middle] Расследуешь инцидент: кто прочитал секрет `secret/notes/db` вчера в 14:00? Где смотришь?

В аудит-логе (audit device): там запись каждого запроса с путём, операцией, временем, токеном и IP. Значения секретов в нём хешированы. Ищу по пути и времени, потом по токену выясняю, кому он выдан.

**Что хотят услышать:** audit device включён заранее, HMAC значений, отправка в SIEM.

**Красный флаг:** «в Vault нет логов, спрошу у команды».

## Проверено на версиях

- HashiCorp Vault: v2.1.1 (образ `hashicorp/vault:2.1.1`, лицензия BSL)
- OpenBao: v2.7.0 (открытая альтернатива, команды `bao` совпадают с `vault`)
- Helm-чарт `hashicorp/vault`: версия не закреплена, проверь актуальную версию на странице проекта
- PostgreSQL (пример утечки): 18-alpine
- kind, kubectl, Helm: версии из [урока 5.1](../05-kubernetes/01-why-k8s-cluster.md) и [урока 5.9](../05-kubernetes/09-helm.md)

## Итог урока: ты умеешь

- [ ] умею находить, где секрет утекает: git, `docker inspect`, `/proc`, история shell
- [ ] умею объяснить, почему удаление файла из git не отзывает секрет, и что делать при утечке
- [ ] умею запустить Vault, положить и прочитать секрет через KV v2 и посмотреть версии
- [ ] умею написать политику HCL с путями `data` и `metadata` и проверить отказ
- [ ] умею пройти `init`, `unseal`, рестарт и объяснить, почему Vault снова запечатан
- [ ] умею включить аудит и найти в нём чтение секрета
- [ ] умею поднять Vault в кластере скриптом и держать ключи вне репозитория
- [ ] умею выбрать между Vault, SOPS и Sealed Secrets по задаче

**Дальше:** [Урок 9.2: Секреты в Kubernetes: Vault и External Secrets Operator](02-vault-k8s-eso.md)
