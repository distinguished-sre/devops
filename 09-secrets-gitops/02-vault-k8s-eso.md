---
layout: lesson
title: "Секреты в Kubernetes: Vault и External Secrets Operator"
topic: 9
lesson: "9.2"
time: "2 ч"
---

## Зачем это нужно

В уроке 5.6 пароль БД жил в Secret, созданном командой, а в Secret значения лежат в base64, то есть почти открытым текстом. Стоит положить такой манифест в git, и пароль утёк навсегда. В Vault пароль уже лежит (урок 9.1), но под Vault не ходит: ему нужен обычный Kubernetes Secret.

На работе эту связку делает External Secrets Operator (ESO): оператор с доступом к Vault сам создаёт и обновляет Secret из внешнего хранилища. В git остаётся только описание «откуда взять», а не сам пароль. Ту же схему используют с AWS Secrets Manager, Yandex Lockbox и другими хранилищами.

Шаг проекта: ESO ставится в кластер, в Helm-чарте «Заметок» появляется `ExternalSecret notes-db` (chart 0.4.0), ручной Secret удаляется, пароль БД в git и в манифестах платформы больше не хранится.

## Что нужно знать

- [Урок 9.1: проблема секретов и Vault](01-secrets-problem-vault.md) - Vault в кластере, `secret/notes/db`, политика `notes-read`, Kubernetes auth
- [Урок 5.6: ConfigMap и Secret](../05-kubernetes/06-config-secrets.md) - Secret `notes-db`, `envFrom`, почему base64 не шифрование
- [Урок 5.9: Helm](../05-kubernetes/09-helm.md) - чарт `helm/notes`, `values.yaml`, `helm upgrade`
- [Урок 5.12: безопасность Kubernetes](../05-kubernetes/12-k8s-security.md) - ServiceAccount и RBAC
- [Урок 5.13: диагностика Kubernetes](../05-kubernetes/13-k8s-troubleshooting.md) - `describe`, события, логи контроллеров
- [Урок 5.5: StatefulSet с PostgreSQL](../05-kubernetes/05-storage-statefulset-postgres.md) - пароль в БД задаётся при первой инициализации тома

## Теория

### Как ESO доставляет секрет

ESO это оператор (operator): контроллер, который следит за своими ресурсами (CRD, Custom Resource Definition) и приводит кластер в описанное состояние. Ресурсов два основных:

- **`ClusterSecretStore`** (или `SecretStore` в одном namespace) описывает подключение: адрес Vault, путь движка, способ входа. Один на кластер, его ведёт платформа.
- **`ExternalSecret`** лежит рядом с приложением и говорит: «возьми `secret/notes/db` из этого хранилища и собери из него Secret с именем `notes-db`».

Цепочка такая: контроллер ESO читает `ExternalSecret`, идёт по описанию из `ClusterSecretStore` в Vault, забирает значения и создаёт обычный Secret. Приложение про Vault ничего не знает: `envFrom: secretRef: notes-db` работает как раньше. Это главное достоинство подхода и причина, по которой в курсе выбран именно он, а не sidecar-инжектор из 9.1.

Второе достоинство: `refreshInterval`. Оператор периодически перечитывает Vault и обновляет Secret. Поменял пароль в Vault, через час (или через минуту, если интервал короче) Secret в кластере другой.

> **Проверь понимание:** пароль сменили в Vault. Увидит ли уже работающий под новое значение из `envFrom`?

<details markdown="1">
<summary>Ответ</summary>

Нет. Переменные окружения из `envFrom` читаются один раз при старте контейнера. ESO обновит Secret, но процесс в поде продолжит жить со старым значением до перезапуска пода. Поэтому после ротации нужен `kubectl rollout restart` или контроллер вроде Reloader, который перезапускает поды при изменении Secret.

</details>

### Kubernetes auth: как ESO входит в Vault без пароля

ESO тоже нужно чем-то доказать Vault, кто он. Вспомни «проблему нулевого секрета» из 9.1: пароля для доступа к паролям быть не должно. Решение это метод `kubernetes`:

1. ESO просит у API-сервера короткоживущий токен ServiceAccount (ServiceAccount, SA), указанный в `ClusterSecretStore`.
2. Отдаёт токен в Vault на `auth/kubernetes/login`, называя роль (`role`) `notes`.
3. Vault сам идёт в API-сервер (TokenReview) и проверяет, что токен настоящий и что SA с таким именем и в таком namespace.
4. Роль `notes` в Vault привязана к конкретному SA `notes` в namespace `notes` и к политике `notes-read`. Если всё совпало, Vault выдаёт свой токен с правами только на `secret/data/notes/*`.

Итого доступ выдаётся не по знанию пароля, а по «личности» ServiceAccount. Любое несовпадение (другое имя SA, другой namespace, нет роли) даёт `permission denied`, и на этом строятся сценарии «Сломай и почини».

> **Проверь понимание:** ты создал SA `notes` в namespace `default` и указал его в `ClusterSecretStore`. Роль в Vault привязана к SA `notes` в namespace `notes`. Что получишь?

<details markdown="1">
<summary>Ответ</summary>

Vault отклонит вход: `namespace not authorized`, ExternalSecret получит статус `SecretSyncedError`. Имя SA совпало, но «личность» это пара имя + namespace.

</details>

### Из чего собирается Secret

`ExternalSecret` умеет не только копировать ключи. В Vault лежат `username`, `password`, `database`, а приложению нужна одна строка `DATABASE_URL` (контракт приложения из 4.4). Для этого есть шаблон (`target.template`): ESO подставляет значения из Vault в Go-шаблон. Пароль из `openssl rand -base64 24` может содержать `+`, `/` и `=`, а в URL они ломают разбор, поэтому пароль пропускают через функцию `urlquery`.

Поле `creationPolicy: Owner` означает, что ESO владеет Secret: создаёт его, обновляет и удаляет вместе с `ExternalSecret`. Отсюда типичная ловушка: если Secret с таким именем уже создан вручную, ESO с политикой `Owner` не сможет его присвоить и будет ругаться. Ручной Secret надо удалить до применения `ExternalSecret`.

Ещё одна ловушка касается самого чарта. Helm тоже использует двойные фигурные скобки, поэтому шаблон ESO внутри Helm-шаблона нужно экранировать. Как именно, увидишь в задании 4.

> **Проверь понимание:** что будет с Secret `notes-db`, если удалить `ExternalSecret notes-db` при `creationPolicy: Owner`?

<details markdown="1">
<summary>Ответ</summary>

Secret удалится вместе с ним, поды при следующем создании упадут с `CreateContainerConfigError`. Поэтому удалять `ExternalSecret` на живом приложении нельзя, а в GitOps (тема 9.3) это делается осознанно.

</details>

### Что происходит при недоступном Vault

Vault упал или запечатан (sealed), а ESO не может достучаться. Важный факт: уже созданный Secret остаётся на месте. Поды продолжают работать, новые поды тоже стартуют, пока Secret существует. Страдает только синхронизация: `ExternalSecret` получает `SecretSyncedError`, обновления не приходят. Это отличает ESO от Vault Agent Injector, где недоступный Vault означает, что новый под не стартует вовсе. Если же Secret ещё не создавался (первый деплой на чистом кластере), под без Secret не запустится.

## Практика

Ожидается стенд после урока 9.1: кластер `kind-notes`, Vault распечатан (unseal) в namespace `vault`, `secret/notes/db` заполнен, релиз `notes` стоит в namespace `notes`, Secret `notes-db` создан вручную (5.6). Проверь исходное состояние:

```bash
kubectl config use-context kind-notes
kubectl -n vault get pods
kubectl -n notes get secret notes-db
```

```text
NAME      READY   STATUS    RESTARTS   AGE
vault-0   1/1     Running   0          2d
NAME       TYPE     DATA   AGE
notes-db   Opaque   2      6d
```

Если `vault-0` показывает `0/1`, Vault запечатан: распечатай его командами из 9.1 (`scripts/seed-vault.sh` идемпотентный).

### Задание 1. Установить External Secrets Operator

**Цель:** поставить ESO v2.11.0 через Helm и убедиться, что появились его CRD и поды.

**Предскажи:** сколько подов появится в namespace `external-secrets` и какие ресурсы (`kubectl api-resources`) с группой `external-secrets.io` добавятся?

<details markdown="1">
<summary>Ответ</summary>

Три пода: сам контроллер, `cert-controller` (управляет сертификатом вебхука) и `webhook` (проверяет ресурсы при создании). Появятся CRD `externalsecrets`, `secretstores`, `clustersecretstores` и другие.

</details>

**Шаги:**

1. Добавь репозиторий чартов и установи версию 2.11.0, закреплённую явно:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --version 2.11.0 \
  --namespace external-secrets --create-namespace \
  --wait --timeout 3m
```

2. Проверь поды и CRD:

```bash
kubectl -n external-secrets get pods
kubectl api-resources --api-group=external-secrets.io -o name | head -5
```

**Что должно получиться:**

```text
NAME                                                READY   STATUS    RESTARTS   AGE
external-secrets-6c8f9d7b5-kq2xw                    1/1     Running   0          58s
external-secrets-cert-controller-7d9c4f6b8-p4tzn    1/1     Running   0          58s
external-secrets-webhook-5b7f8c9d64-m9vh2           1/1     Running   0          58s
acraccesstokens.generators.external-secrets.io
clusterexternalsecrets.external-secrets.io
clustergenerators.generators.external-secrets.io
clustersecretstores.external-secrets.io
externalsecrets.external-secrets.io
```

**Объясни себе:**
- Зачем оператору отдельный вебхук и что случится с созданием `ExternalSecret`, если под вебхука не запущен?
- Почему CRD ставятся вместе с оператором, а не вместе с приложением?

**Типичные ошибки:**
- `Error: INSTALLATION FAILED: cannot re-use a name that is still in use`: релиз `external-secrets` уже есть, посмотри `helm list -A` и используй `helm upgrade`.
- `Internal error occurred: failed calling webhook "validate.externalsecret.external-secrets.io"`: под вебхука ещё не готов, подожди `Running 1/1` и повтори `kubectl apply`.
- `Error: no cached repo found`: не выполнен `helm repo update`.

### Задание 2. Подключить Vault: ClusterSecretStore

**Цель:** описать подключение к Vault с входом по Kubernetes auth и добиться статуса `Ready`.

**Предскажи:** какие три вещи в Vault должны существовать, чтобы вход прошёл? Подсказка: вспомни 9.1.

<details markdown="1">
<summary>Ответ</summary>

Включённый метод `auth/kubernetes`, роль `notes`, привязанная к SA `notes` в namespace `notes`, и политика `notes-read` на роли. Всё это создал `scripts/seed-vault.sh`. Кроме Vault нужен сам SA `notes` в кластере.

</details>

**Шаги:**

1. Проверь роль в Vault (root-токен лежит вне репозитория, в `~/.notes-secrets/`):

```bash
ROOT_TOKEN=$(jq -r .root_token ~/.notes-secrets/vault-init.json)
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
  vault read auth/kubernetes/role/notes
```

2. Убедись, что ServiceAccount существует (создай, если нет; команда идемпотентна):

```bash
kubectl -n notes create serviceaccount notes --dry-run=client -o yaml | kubectl apply -f -
```

3. Создай `k8s/platform/clustersecretstore.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      # Адрес Vault внутри кластера (сервис из урока 9.1)
      server: "http://vault.vault.svc:8200"
      # Движок kv-v2 смонтирован в secret/
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          # Путь, под которым включён метод kubernetes
          mountPath: "kubernetes"
          role: "notes"
          # ESO запросит токен именно для этого SA
          serviceAccountRef:
            name: notes
            namespace: notes
```

4. Примени и проверь статус:

```bash
kubectl apply -f k8s/platform/clustersecretstore.yaml
kubectl get clustersecretstore vault-backend
```

**Что должно получиться:**

```text
Key                              Value
---                              -----
alias_name_source                serviceaccount_uid
bound_service_account_names      [notes]
bound_service_account_namespaces [notes]
policies                         [notes-read]
token_ttl                        1h
```

```text
NAME            AGE   STATUS   CAPABILITIES   READY
vault-backend   6s    Valid    ReadWrite      True
```

**Объясни себе:**
- Почему `bound_service_account_namespaces` нужно ограничивать конкретным namespace, а не `*`?
- Почему в `ClusterSecretStore` нет ни пароля, ни токена Vault?

**Типичные ошибки:**
- `no matches for kind "ClusterSecretStore" in version "external-secrets.io/v1"`: CRD не установлены (задание 1) или установлена старая версия ESO.
- `STATUS InvalidProviderConfig`, в событии `unable to log in with Kubernetes auth: ... Errors: * invalid role name "notes"`: в Vault нет роли, перезапусти `scripts/seed-vault.sh`.
- `Vault is sealed`: распечатай Vault (урок 9.1).

### Задание 3. Ротация: как обновление доходит до Secret

**Цель:** на демонстрационном секрете увидеть `refreshInterval` и то, что под сам не обновляется. Боевой пароль БД пока не трогаем.

**Предскажи:** ты меняешь значение в Vault. Через сколько Secret обновится при `refreshInterval: 1m` и изменится ли значение в уже запущенном поде?

<details markdown="1">
<summary>Ответ</summary>

Secret обновится не позже чем через минуту. Переменная окружения в запущенном поде не изменится до его перезапуска (см. вопрос в теории). Если Secret смонтирован файлом (volume), файл обновится сам примерно за минуту, но приложение должно перечитать его.

</details>

**Шаги:**

1. Положи демо-секрет и создай `ExternalSecret`:

```bash
ROOT_TOKEN=$(jq -r .root_token ~/.notes-secrets/vault-init.json)
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
  vault kv put secret/notes/demo token=first

kubectl apply -f - <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo
  namespace: notes
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: demo
  dataFrom:
    - extract:
        key: notes/demo
YAML
```

2. Проверь синхронизацию и значение:

```bash
kubectl -n notes get externalsecret demo
kubectl -n notes get secret demo -o jsonpath='{.data.token}' | base64 -d; echo
```

3. Смени значение в Vault, подожди минуту и прочитай Secret снова:

```bash
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
  vault kv put secret/notes/demo token=second
sleep 70
kubectl -n notes get secret demo -o jsonpath='{.data.token}' | base64 -d; echo
```

4. Убери демо за собой:

```bash
kubectl -n notes delete externalsecret demo
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
  vault kv metadata delete secret/notes/demo
```

**Что должно получиться:**

```text
NAME   STORETYPE            STORE           REFRESH INTERVAL   STATUS         READY
demo   ClusterSecretStore   vault-backend   1m                 SecretSynced   True
first
second
```

После шага 4 Secret `demo` тоже исчезает: им владел ESO.

**Объясни себе:**
- Как ускорить синхронизацию, не дожидаясь интервала? (Подсказка: `kubectl annotate externalsecret demo force-sync=$(date +%s) --overwrite`.)
- Какой `refreshInterval` разумен для пароля БД и почему не `1s`?

**Типичные ошибки:**
- `Error from server (NotFound): secrets "demo" not found` сразу после `apply`: синхронизация ещё не прошла, подожди 5-10 секунд.
- `Code: 404. Errors: * secret not found`: в Vault нет пути `secret/notes/demo`, проверь шаг 1 (в `key` пишется `notes/demo` без `secret/` и без `data/`).

### Задание 4. Шаг проекта: ExternalSecret в чарте, пароль из Vault

**Цель:** заменить ручной Secret `notes-db` на Secret от ESO и убрать пароль из git. Chart 0.4.0.

**Предскажи:** если применить `ExternalSecret notes-db`, пока ручной Secret с таким же именем существует, что скажет ESO? И почему нельзя просто взять новый пароль из Vault, не трогая PostgreSQL?

<details markdown="1">
<summary>Ответ</summary>

ESO не сможет стать владельцем чужого Secret: статус `SecretSyncedError`, Secret не перезаписан. Поэтому ручной Secret сначала удаляют. Про PostgreSQL: пароль пользователя `notes` записан в самой БД при инициализации тома (5.5). Изменение Secret его не меняет, значит, пароль в БД надо привести в соответствие с Vault, иначе приложение получит `password authentication failed`.

</details>

**Шаги:**

1. Добавь в `helm/notes/values.yaml` блок (значения по умолчанию, ESO выключен):

```yaml
existingSecret: notes-db

externalSecret:
  # Включает ExternalSecret вместо ручного Secret
  enabled: false
  store: vault-backend
  # Путь в kv-v2 без префикса secret/
  remoteKey: notes/db
```

Если ключ `existingSecret` уже есть в файле, второй раз его не добавляй.

2. Создай `helm/notes/templates/externalsecret.yaml`. Внутри шаблона живут два уровня двойных фигурных скобок: внешний для Helm, внутренний для ESO. Внутренний оборачивают в строковый литерал, чтобы Helm вывел его как есть:

{% raw %}
```yaml
{{- if .Values.externalSecret.enabled }}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Values.existingSecret }}
  labels:
    app.kubernetes.io/name: notes
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: {{ .Values.externalSecret.store }}
    kind: ClusterSecretStore
  target:
    name: {{ .Values.existingSecret }}
    creationPolicy: Owner
    template:
      data:
        # Строка подключения для приложения (контракт 4.4)
        DATABASE_URL: 'postgresql://{{ "{{ .username }}" }}:{{ "{{ .password | urlquery }}" }}@db:5432/{{ "{{ .database }}" }}'
        # Тот же пароль нужен StatefulSet postgres (5.5)
        POSTGRES_PASSWORD: '{{ "{{ .password }}" }}'
  dataFrom:
    - extract:
        key: {{ .Values.externalSecret.remoteKey }}
{{- end }}
```
{% endraw %}

3. Подними версию чарта и проверь рендер, ничего не применяя:

```bash
sed -i 's/^version: .*/version: 0.4.0/' helm/notes/Chart.yaml   # macOS: sed -i ''
helm lint helm/notes
helm template notes helm/notes --set externalSecret.enabled=true \
  | grep -A3 'DATABASE_URL'
```

4. Приведи пароль в PostgreSQL в соответствие с Vault (Vault источник правды):

```bash
ROOT_TOKEN=$(jq -r .root_token ~/.notes-secrets/vault-init.json)
PW=$(kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
  vault kv get -field=password secret/notes/db)
printf "ALTER USER notes PASSWORD '%s';\n" "$PW" \
  | kubectl -n notes exec -i postgres-0 -- psql -U notes -d notes
unset PW ROOT_TOKEN
```

5. Удали ручной Secret и обнови релиз:

```bash
kubectl -n notes delete secret notes-db
helm upgrade notes helm/notes --namespace notes --set externalSecret.enabled=true
kubectl -n notes get externalsecret notes-db
```

6. Убедись, что приложение подхватило Secret. Поды пересоздаются, чтобы прочитать новое значение:

```bash
kubectl -n notes rollout restart deployment/notes
kubectl -n notes rollout status deployment/notes
curl -s -o /dev/null -w '%{http_code}\n' https://notes.lab/readyz --cacert <(kubectl -n notes get secret notes-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)
```

7. Закрой хвосты в git: пароля нет в манифестах, а `.env` помечен как локальный:

```bash
grep -rn 'kind: Secret' k8s/ helm/ || echo "Secret-манифестов с паролем нет"
sed -i '1i # Только для локальной отладки в compose. На платформе пароль лежит в Vault (урок 9.2).' .env.example
git add k8s/platform helm/notes .env.example
git commit -m "9.2: пароль БД из Vault через External Secrets Operator (chart 0.4.0)"
```

**Что должно получиться:**

{% raw %}
```text
        DATABASE_URL: 'postgresql://{{ .username }}:{{ .password | urlquery }}@db:5432/{{ .database }}'
```
{% endraw %}

```text
NAME       STORETYPE            STORE           REFRESH INTERVAL   STATUS         READY
notes-db   ClusterSecretStore   vault-backend   1h                 SecretSynced   True
```

```text
deployment "notes" successfully rolled out
200
Secret-манифестов с паролем нет
```

Строка с шаблоном `username` в выводе `helm template` нужна как есть: значит, Helm не съел внутренний шаблон и ESO получит его целиком.

**Объясни себе:**
- Почему у ключа `POSTGRES_PASSWORD` в шаблоне тот же пароль, что и в `DATABASE_URL`?
- Где теперь хранится пароль и кто из людей и систем может его прочитать? Сравни с ситуацией до урока.
- Что мешает удалить `.env` из compose совсем? Почему для платформы долг закрыт, а для локальной отладки остаётся пометка?

**Типичные ошибки:**
- `Error: UPGRADE FAILED: ... Secret "notes-db" ... invalid ownership metadata`: ручной Secret не удалён или пересоздан, повтори `kubectl delete secret notes-db`.
- `FATAL: password authentication failed for user "notes"` в логах приложения: пропущен шаг 4, пароль в БД не совпал с Vault.
- `could not parse ... invalid port number in URL` или `invalid URL`: в пароле есть `/` или `+`, а шаблон без `| urlquery`.
- `error calling urlquery`/`function "urlqery" not defined`: опечатка в имени функции, ошибка видна в `kubectl describe externalsecret notes-db`.
- `helm template` ничего не выводит: забыл `--set externalSecret.enabled=true`, по умолчанию блок отключён.

## Сломай и почини

Запусти сценарий и не подсматривай в скрипт. Номер выбери сам или возьми `random`:

```bash
bash ~/notes/break/9.2/break.sh random
```

### Симптом

Что-то одно из списка (какое именно, тебе неизвестно):

1. `kubectl -n notes get externalsecret notes-db` показывает `SecretSyncedError`, Secret не обновляется.
2. После правки описания ESO по-прежнему не может войти в Vault, хотя роль и политика на месте.
3. Vault недоступен: ExternalSecret красный, но приложение отвечает.

### Гипотезы

- Роль в Vault не существует или названа иначе, чем в `ClusterSecretStore`.
- ServiceAccount из `ClusterSecretStore` не тот, что в `bound_service_account_*` роли: другое имя или другой namespace.
- Политика роли не разрешает чтение пути `secret/data/notes/*`.
- Vault запечатан, под не работает или Service без endpoints.
- Сломан сам оператор: поды `external-secrets` не запущены.

### Проверки

Иди от статуса к причине, не гадай:

```bash
kubectl -n notes describe externalsecret notes-db | tail -15
kubectl describe clustersecretstore vault-backend | tail -10
kubectl -n external-secrets logs deploy/external-secrets --tail=20
kubectl -n vault get pods,endpoints vault
```

Сообщение из `describe` содержит текст ответа Vault, и по нему сразу видно слой: 400 (роль или привязка), 403 (политика), `connection refused` или `no such host` (сеть и сам Vault), `Vault is sealed` (печать).

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

**1. `permission denied` / `invalid role name "notes"`.** Сообщение вида `Code: 400. Errors: * invalid role name "notes"` говорит: роли нет или в `ClusterSecretStore` другое имя. Сверь `role` в хранилище с `vault list auth/kubernetes/role`. Если роли нет, запусти `scripts/seed-vault.sh`. Ответ `Code: 403 ... permission denied` уже после успешного входа означает, что политика роли не покрывает путь: проверь `vault policy read notes-read`, путь должен быть `secret/data/notes/*` (у kv-v2 в пути политики есть `data/`).

**2. SA не в том namespace.** Сообщение `service account name not authorized` или `namespace not authorized` при существующей роли. Сравни `serviceAccountRef` в хранилище с `bound_service_account_names` и `bound_service_account_namespaces` в роли. Исправь `serviceAccountRef` (или привязку роли) и примени. ExternalSecret перечитает хранилище сам, ускорить можно аннотацией `force-sync`.

**3. Vault недоступен.** В сообщении `dial tcp ...: connect: connection refused` или `Vault is sealed`. Проверь `kubectl -n vault get pods,endpoints`: под не запущен, Vault запечатан (unseal по 9.1) или Service без endpoints. Приложение при этом работает: Secret уже создан и остаётся в кластере. Симптом опасен тем, что о проблеме ты узнаешь только по алерту на статус ExternalSecret, а не по падению сервиса, и при первом деплое на чистом кластере под без Secret не стартует.

Общий вывод: у ESO нет «магии», вся диагностика в `kubectl describe externalsecret` и логах контроллера. Читай текст ошибки Vault целиком.

</details>

## Вопросы с собеседований

### 1. [middle] ExternalSecret в статусе SecretSyncedError. Как диагностируешь?

Сначала `kubectl describe externalsecret`: в событиях полный текст ответа Vault. Дальше по коду: 400 это роль или привязка SA, 403 политика, `connection refused` сеть или Vault, `sealed` печать. Потом смотрю логи контроллера ESO и состояние `ClusterSecretStore`. Приложение обычно не затронуто, пока Secret уже создан.

**Что хотят услышать:** порядок от статуса к слою, знание, что Secret остаётся, проверка роли и SA в Vault.

**Красный флаг:** «пересоздам ESO» без чтения сообщения об ошибке.

### 2. [middle] В Vault поменяли пароль, а приложение продолжает использовать старый. Почему и что делать?

ESO обновит Secret в пределах `refreshInterval`, но переменные `envFrom` читаются при старте контейнера, значит, под надо перезапустить. Ускорить синхронизацию можно аннотацией `force-sync`, перезапустить `rollout restart` или поставить Reloader. Отдельно проверяю, сменился ли пароль в самой БД: секрет и БД должны меняться согласованно.

**Что хотят услышать:** env читаются один раз, `refreshInterval`, Reloader, согласованность с БД.

**Красный флаг:** «ESO сам перезапускает поды».

### 3. [middle] Vault лёг ночью. Что произойдёт с приложениями, которые берут секреты через ESO?

Уже работающие и новые поды продолжат жить, пока Secret существует: он лежит в кластере. Синхронизация остановится, ExternalSecret покраснеет, обновления и ротация не дойдут. Проблема возникнет при первом деплое на чистом кластере или при удалении Secret. Поэтому нужен алерт на статус ExternalSecret и мониторинг самого Vault.

**Что хотят услышать:** разница с sidecar-инжектором, что Secret остаётся, алерт на `SecretSyncedError`, риск чистого кластера.

**Красный флаг:** «все поды упадут» или «ничего страшного, никто не заметит».

### 4. [junior] Почему нельзя хранить Secret Kubernetes в git, даже если он в base64?

Base64 это кодировка, а не шифрование: `base64 -d` возвращает пароль за секунду. Пароль в git останется в истории навсегда и доступен всем с доступом к репозиторию. Нужен либо внешний менеджер секретов (Vault + ESO), либо шифрование перед коммитом (SOPS, Sealed Secrets).

**Что хотят услышать:** история git, base64 не защита, три варианта решения.

**Красный флаг:** «в приватном репозитории можно».

### 5. [middle] Ты применил ExternalSecret, а ESO пишет, что не может создать Secret. В кластере уже есть Secret с тем же именем, созданный вручную. Что делаешь?

ESO с `creationPolicy: Owner` не берёт чужой ресурс. Удаляю ручной Secret (предварительно сохранив, откуда брался пароль) и даю ESO создать свой. Проверяю, что значение совпадает с ожидаемым приложением, и что пароль в БД тоже согласован. Для миграции без простоя иногда используют `creationPolicy: Merge`, но это исключение.

**Что хотят услышать:** политики `Owner`, `Merge`, `Orphan`, порядок миграции, риск простоя.

**Красный флаг:** правит ручной Secret руками, чтобы ESO «подхватил».

### 6. [middle] Как ESO входит в Vault и почему для этого не нужен пароль?

По Kubernetes auth: ESO получает токен ServiceAccount, Vault проверяет его у API-сервера (TokenReview) и сверяет пару «имя SA + namespace» с ролью. Совпало, выдаёт короткоживущий токен с политикой роли. Секрет для входа не хранится нигде, подтверждается сама «личность» рабочей нагрузки.

**Что хотят услышать:** TokenReview, привязка роли к SA и namespace, минимальная политика, TTL токена.

**Красный флаг:** «ESO хранит root-токен Vault в Secret».

### 7. [middle] Пароль в Vault сменили, ExternalSecret синхронизировался, а приложение получает `password authentication failed`. В чём дело?

Пароль пользователя хранится в самой БД, и обновление Secret его не меняет. Значит, Vault и БД разошлись. Смотрю, кто менял значение, приводим БД в соответствие (`ALTER USER`) или откатываем значение в Vault (kv-v2 хранит версии). Правильный процесс: менять пароль в БД и в Vault в одном сценарии, а лучше перейти на динамические секреты.

**Что хотят услышать:** источник правды один, версии kv-v2, динамические секреты БД как решение.

**Красный флаг:** «перезапущу поды, пока не заработает».

### 8. [junior] Чем ClusterSecretStore отличается от SecretStore?

`SecretStore` действует в одном namespace, а `ClusterSecretStore` доступен из любого namespace кластера. Платформенная команда ведёт один общий `ClusterSecretStore`, а команды приложений создают только свои `ExternalSecret`. Если хранилище кластерное, нужно ограничить, кто может на него ссылаться.

**Что хотят услышать:** область действия, разделение ответственности, вопрос изоляции.

**Красный флаг:** «одно и то же».

### 9. [middle] Чем ESO лучше или хуже Vault Agent Injector, когда что выбираешь?

ESO создаёт обычный Secret: приложение не меняется, поды не зависят от Vault при старте, зато секрет лежит в etcd кластера. Injector кладёт секрет файлом в память пода, поддерживает динамические секреты и обновление без пересоздания, но требует sidecar и Vault при каждом старте. Для обычных статических паролей я беру ESO, для динамических учётных данных и строгих требований к хранению в etcd Injector или CSI.

**Что хотят услышать:** плюсы и минусы обоих, вопрос etcd и шифрования, критерии выбора.

**Красный флаг:** «Injector устарел» или «ESO безопаснее всегда».

### 10. [middle] Ты заметил, что пароль БД попал в git-историю. Что делаешь, по шагам?

Считаю пароль скомпрометированным: меняю в БД и Vault, перевыкатываю, проверяю логи доступа. Чистка истории (`git filter-repo`) не заменяет смены пароля, так как копии уже могли разойтись. Затем закрываю причину: секрет в Vault, ExternalSecret в чарте, сканер секретов в CI.

**Что хотят услышать:** ротация прежде чистки истории, аудит доступа, профилактика.

**Красный флаг:** «удалю коммит и продолжу».

## Проверено на версиях

- External Secrets Operator: v2.11.0 (Helm-чарт 2.11.0)
- HashiCorp Vault: v2.1.1 (чарт HashiCorp, standalone)
- Helm: v4.3.0
- kind: v0.33.0
- kubectl: 1.37.1
- Kubernetes: 1.36.x / 1.37.x
- PostgreSQL: 18

## Итог урока: ты умеешь

- [ ] умею объяснить, как ESO доставляет секрет из Vault в Kubernetes Secret
- [ ] умею установить ESO конкретной версии через Helm и проверить CRD и поды
- [ ] умею описать `ClusterSecretStore` с Kubernetes auth и добиться `Ready`
- [ ] умею собрать `ExternalSecret` с шаблоном `DATABASE_URL` и экранировать его внутри Helm-шаблона
- [ ] умею мигрировать ручной Secret на ESO, не сломав пароль в БД
- [ ] умею читать причину `SecretSyncedError` и отличать роль, привязку SA, политику и недоступность Vault
- [ ] умею объяснить, что происходит с приложением при недоступном Vault и почему после ротации нужен перезапуск

**Дальше:** [Урок 9.3: GitOps: Flux разворачивает «Заметки» из git](03-gitops-flux.md)
