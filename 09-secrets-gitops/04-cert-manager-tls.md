---
layout: lesson
title: "cert-manager: TLS-сертификаты автоматически"
topic: 9
lesson: "9.4"
time: "2 ч"
---

## Зачем это нужно

Сертификат с сроком жизни, выпущенный руками, однажды истекает в пятницу вечером: браузеры показывают красную страницу, health-чеки падают, а никто не помнит, кто и как его выпускал. Это одна из самых частых причин «глупых» инцидентов в проде.
В Kubernetes эту работу делает оператор (operator): программа в кластере, которая следит за ресурсами и приводит мир к описанному состоянию. Для сертификатов такой оператор называется cert-manager.
Ты опишешь, какой сертификат нужен, а выпуск, хранение в Secret и продление cert-manager сделает сам.
Шаг проекта: Secret `notes-tls`, который в уроке 5.4 создавался командой, заменяется ресурсом Certificate; его выпускает локальный CA, а установка cert-manager и выпускающие ресурсы лежат в `notes-gitops` и ставятся через Flux.

## Что нужно знать

- [Урок 2.6: TLS и HTTPS](../02-network/06-tls.md) - цепочка доверия, SAN, срок действия, `openssl x509`
- [Урок 5.4: Ingress и Gateway API](../05-kubernetes/04-ingress-gateway.md) - Gateway `notes-gw`, listener 443 и Secret `notes-tls`
- [Урок 5.9: Helm](../05-kubernetes/09-helm.md) - чарты, values, версии чартов
- [Урок 9.3: GitOps и Flux](03-gitops-flux.md) - `HelmRelease`, `Kustomization`, `dependsOn`, репозиторий `notes-gitops`

## Теория

### Оператор и CRD: как cert-manager вообще работает

Kubernetes умеет расширяться. Ты добавляешь новый тип ресурса через CustomResourceDefinition (CRD), и `kubectl` начинает понимать `kind: Certificate` так же, как `kind: Deployment`. Сам по себе такой ресурс ничего не делает: это запись в базе кластера (etcd).
Работу выполняет контроллер (controller), процесс в поде: он в цикле сверяет желаемое состояние (то, что написано в ресурсе) с фактическим и исправляет разницу. Этот цикл называется reconcile. Пара «CRD + контроллер» и есть оператор. Ты уже видел его в Flux (9.3) и External Secrets (9.2).

cert-manager добавляет несколько CRD. Запомни четыре:

| Ресурс | Что это | Кто создаёт |
|---|---|---|
| `Issuer` / `ClusterIssuer` | Кто выпускает сертификаты: локальный CA, Let's Encrypt, Vault. `Issuer` живёт в одном namespace, `ClusterIssuer` на весь кластер | ты |
| `Certificate` | Что тебе нужно: имена, срок, в какой Secret положить результат | ты |
| `CertificateRequest` | Один запрос на подпись к издателю | cert-manager |
| `Order` и `Challenge` | Только для ACME (Let's Encrypt): заказ и проверка владения доменом | cert-manager |

Ты пишешь `Certificate`. cert-manager сам создаёт закрытый ключ, отправляет запрос издателю, получает подпись и кладёт `tls.crt`, `tls.key` (и `ca.crt`) в Secret. Незадолго до конца срока он повторяет процедуру и обновляет тот же Secret.

> **Проверь понимание:** чем `Certificate` отличается от Secret, в который он попадает, и что из них ты правишь в git?

<details markdown="1">
<summary>Ответ</summary>

`Certificate` это желание: имена, срок, издатель. Secret это результат, его создаёт и обновляет cert-manager. В git хранится только `Certificate`. Секрет с ключом в git не кладут, а вручную не правят: он перезапишется при следующем продлении.

</details>

### Issuer и цепочка для локального стенда

На домене `notes.lab` Let's Encrypt не выдаст сертификат: этого домена нет в публичном DNS, проверить владение нельзя. Поэтому в лаборатории мы строим собственный центр сертификации (Certificate Authority, CA) прямо на cert-manager. Цепочка из трёх ресурсов:

1. `ClusterIssuer selfsigned` подписывает сам себя. Он нужен только один раз, чтобы выпустить корневой сертификат.
2. `Certificate notes-ca` (флаг `isCA: true`) выпускает через `selfsigned` корневой сертификат нашего CA и кладёт его в Secret `notes-ca`.
3. `ClusterIssuer notes-ca` использует Secret `notes-ca` как подписывающий ключ. Им мы выпускаем всё остальное, включая `notes-tls`.

Это то же самое, что ты делал руками в уроке 2.6 (свой ключ, свой CA, подпись), только каждый шаг описан ресурсом, а срок и продление контролирует оператор.

Важное следствие: браузер и `curl` не доверяют нашему CA, пока ты не добавишь его корневой сертификат в свои доверенные. Для `curl` это флаг `--cacert`. В проде эту роль играет публичный CA или корпоративный, корневой сертификат которого уже раздан на все машины.

### Срок, продление и сколько им можно верить

В `Certificate` есть два поля времени. `duration` это срок жизни сертификата, `renewBefore` это за сколько до конца начинать продление. По умолчанию срок 90 дней, продление за 30 дней. Если оператор сломался, у тебя остаётся месяц, чтобы заметить, а не пятница вечером.

Ключевой факт для эксплуатации: продление обновляет Secret, но не гарантирует, что приложение подхватит новый файл. Envoy Gateway следит за Secret и перечитывает его сам. Приложение, которое читает сертификат один раз при старте (старые nginx, Java-сервисы), после продления нужно перезагружать. Проверять нужно фактически отдаваемый сертификат (`openssl s_client`), а не наличие Secret.

> **Проверь понимание:** сертификат продлён, `kubectl get certificate` показывает `READY True`, а клиенты видят истёкший. Где искать?

<details markdown="1">
<summary>Ответ</summary>

Secret обновился, но сервер отдаёт старый сертификат из памяти. Проверь `openssl s_client -connect ... | openssl x509 -noout -dates` на самом пути клиента. Затем убедись, что listener ссылается на верный Secret, и перезагрузи компонент, который не умеет перечитывать файлы.

</details>

### ACME и Let's Encrypt для реального домена

Для публичного домена используется протокол ACME (Automatic Certificate Management Environment). Издатель (Let's Encrypt) просит доказать владение доменом, и cert-manager проходит проверку сам. Два основных способа (challenge):

- **HTTP-01**: издатель заходит по `http://<домен>/.well-known/acme-challenge/<токен>`, cert-manager временно отдаёт этот токен. Нужен открытый порт 80 из интернета. Wildcard-сертификаты так не выдаются.
- **DNS-01**: cert-manager создаёт TXT-запись `_acme-challenge.<домен>` через API твоего DNS-провайдера. Порт 80 не нужен, подходит для wildcard и закрытых сервисов, но нужны права на DNS.

Издатель для боевого домена выглядит так. Мы его в лаборатории не применяем, потому что `notes.lab` недоступен снаружи; пример пригодится в облаке (тема 6) на домене `notes.<твой-домен>`:

```yaml
# Только для реального домена. В kind не применяем.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: CHANGE_ME@example.com          # сюда придут предупреждения об истечении
    privateKeySecretRef:
      name: letsencrypt-account-key       # ключ аккаунта ACME
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: notes-gw
                namespace: notes
                kind: Gateway
```

Отлаживайся на staging-адресе Let's Encrypt: у боевого жёсткие лимиты.

## Практика

Стенд: кластер kind `notes` из урока 9.3, Flux работает, репозиторий `notes-gitops` склонирован в `~/notes-gitops`. Запись `127.0.0.1 notes.lab` в `/etc/hosts` есть с урока 2.3.

### Задание 1. Ставим cert-manager через Flux

**Цель.** Установить cert-manager v1.21.2 тем же способом, что остальные контроллеры: `HelmRelease` в git.

**Предскажи:** сколько подов появится в namespace `cert-manager` и какие у них роли? Что произойдёт, если не включить установку CRD?

<details markdown="1">
<summary>Ответ</summary>

Три пода: `cert-manager` (основной контроллер), `cert-manager-cainjector` (вставляет CA в webhooks и CRD) и `cert-manager-webhook` (проверяет ресурсы при создании). Без CRD чарт поставится, но `kubectl apply` для `Certificate` даст ошибку, что такого типа ресурса нет.

</details>

**Шаги.**

1. Создай каталог и файлы (значение `crds.enabled: true` заставляет чарт ставить CRD вместе с собой):

```bash
cd ~/notes-gitops
mkdir -p infrastructure/controllers/cert-manager

cat > infrastructure/controllers/cert-manager/namespace.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
YAML

cat > infrastructure/controllers/cert-manager/helmrelease.yaml <<'YAML'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: jetstack
  namespace: cert-manager
spec:
  interval: 1h
  url: https://charts.jetstack.io
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 10m
  chart:
    spec:
      chart: cert-manager
      version: "v1.21.2"          # версия закреплена, диапазоны и latest не используем
      sourceRef:
        kind: HelmRepository
        name: jetstack
  values:
    crds:
      enabled: true               # CRD ставим и обновляем вместе с чартом
      keep: true                  # при удалении релиза CRD (и сертификаты) не сносим
YAML
```

2. Если в `infrastructure/controllers/` есть `kustomization.yaml`, добавь в `resources` строки `cert-manager/namespace.yaml` и `cert-manager/helmrelease.yaml`. Если файла нет, создай его с этими двумя записями.
3. Отправь изменения и дождись Flux:

```bash
git add infrastructure/controllers && git commit -m "feat: cert-manager v1.21.2" && git push
flux reconcile kustomization infrastructure --with-source
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=180s
kubectl -n cert-manager get pods
```

**Что должно получиться.**

```text
deployment.apps/cert-manager condition met
deployment.apps/cert-manager-cainjector condition met
deployment.apps/cert-manager-webhook condition met
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-6d8f9c7b5-x4k2p               1/1     Running   0          70s
cert-manager-cainjector-7f5c8d9b6-m8n2q    1/1     Running   0          70s
cert-manager-webhook-5b7d6c8f4-t9v3r       1/1     Running   0          70s
```

**Объясни себе.**
- Почему CRD нужно ставить раньше, чем создавать `Certificate`, и как это обеспечивает `dependsOn` из урока 9.3?
- Зачем `keep: true`? Что случится с сертификатами всего кластера, если CRD удалить?

**Типичные ошибки.**
- `no matches for kind "Certificate" in version "cert-manager.io/v1"`: CRD ещё нет. Чарт не поставился или `crds.enabled` не задан. Проверь `flux get helmrelease -n cert-manager`.
- `Internal error occurred: failed calling webhook "webhook.cert-manager.io"`: webhook ещё не готов. Подожди `Available` у `cert-manager-webhook` и повтори.

### Задание 2. Собираем локальный CA

**Цель.** Описать цепочку `selfsigned` -> `notes-ca` (сертификат) -> `notes-ca` (издатель) и убедиться, что всё Ready.

**Предскажи:** сколько `ClusterIssuer` и сколько Secret в namespace `cert-manager` ты увидишь после применения? Почему Secret с корневым сертификатом лежит именно в `cert-manager`, а не в `notes`?

<details markdown="1">
<summary>Ответ</summary>

Два `ClusterIssuer` (`selfsigned` и `notes-ca`) и Secret `notes-ca` с корневым ключом. Для `ClusterIssuer` cert-manager ищет Secret в своём «cluster resource namespace», по умолчанию это `cert-manager`. Для `Issuer` (в одном namespace) Secret лежал бы рядом с ним.

</details>

**Шаги.**

1. Создай файл конфигурации. Он попадает в слой `infrastructure/configs`, который по `dependsOn` применяется после контроллеров:

```bash
cd ~/notes-gitops
cat > infrastructure/configs/clusterissuer.yaml <<'YAML'
# 1. Самоподписанный издатель: нужен только для выпуска корня
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
# 2. Корневой сертификат нашего CA
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: notes-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: notes-lab-ca
  secretName: notes-ca
  duration: 8760h               # 1 год для учебного корня
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
# 3. Издатель, который подписывает всё остальное корнем notes-ca
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: notes-ca
spec:
  ca:
    secretName: notes-ca
YAML
```

2. Добавь `clusterissuer.yaml` в `resources` файла `infrastructure/configs/kustomization.yaml`, закоммить, запушь и посмотри статус:

```bash
git add infrastructure/configs && git commit -m "feat: локальный CA на cert-manager" && git push
flux reconcile kustomization infrastructure-config --with-source
kubectl get clusterissuer
kubectl -n cert-manager get certificate,secret notes-ca
```

**Что должно получиться.**

```text
NAME         READY   AGE
notes-ca     True    12s
selfsigned   True    14s
NAME                                   READY   SECRET     AGE
certificate.cert-manager.io/notes-ca   True    notes-ca   13s
NAME               TYPE                DATA   AGE
secret/notes-ca    kubernetes.io/tls   3      13s
```

**Объясни себе.**
- Что произойдёт, если создать `ClusterIssuer notes-ca` раньше, чем появится Secret `notes-ca`? Как это будет выглядеть в `READY`?

**Типичные ошибки.**
- `Error initializing issuer: secrets "notes-ca" not found`: издатель создан до корня или Secret в другом namespace. Проверь `kubectl describe clusterissuer notes-ca`, положи `Certificate` в `cert-manager`.
- `certificate.cert-manager.io/notes-ca   False`: смотри `kubectl -n cert-manager describe certificate notes-ca`, в Events будет причина (часто `Issuer "selfsigned" not found`).

### Задание 3. Выпускаем `notes-tls` и меняем Gateway на него

**Цель.** Заменить Secret, созданный командой в 5.4, на Certificate и убедиться, что Gateway работает без ручных шагов.

**Предскажи:** cert-manager найдёт уже существующий Secret `notes-tls`, созданный руками. Перезапишет он его или откажется? От чего это зависит?

<details markdown="1">
<summary>Ответ</summary>

Секрет, созданный вручную, cert-manager не «усыновляет» молча: он видит чужой Secret без своих аннотаций и может вести себя непредсказуемо (ошибки о несоответствии, повторные выпуски). Правильный порядок: сначала `kubectl delete secret notes-tls`, потом применять `Certificate`. Так же было с ESO в 9.2.

</details>

**Шаги.**

1. Удали старый Secret из 5.4 и опиши Certificate. Добавь его в тот же `clusterissuer.yaml` или в отдельный `certificate.yaml` в `infrastructure/configs`:

```bash
cd ~/notes-gitops
kubectl -n notes delete secret notes-tls --ignore-not-found

cat > infrastructure/configs/certificate.yaml <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: notes-tls
  namespace: notes
spec:
  secretName: notes-tls          # Gateway уже ссылается на этот Secret (listener 443)
  duration: 2160h                # 90 дней
  renewBefore: 720h              # продлевать за 30 дней до конца
  dnsNames:
    - notes.lab
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always       # при продлении генерируется новый ключ
  issuerRef:
    name: notes-ca
    kind: ClusterIssuer
YAML
```

2. Добавь `certificate.yaml` в `kustomization.yaml` этого каталога, закоммить, запушь, дождись выпуска:

```bash
git add infrastructure/configs && git commit -m "feat: Certificate notes-tls вместо ручного Secret" && git push
flux reconcile kustomization infrastructure-config --with-source
kubectl -n notes wait --for=condition=Ready certificate/notes-tls --timeout=60s
kubectl -n notes get certificate notes-tls
kubectl -n notes get secret notes-tls -o jsonpath='{.data}' | jq 'keys'
```

3. Проверь, что Gateway использует секрет, и открой сайт с доверием к нашему CA. Корневой сертификат берём прямо из Secret:

```bash
kubectl -n notes get gateway notes-gw -o jsonpath='{.spec.listeners[?(@.name=="https")].tls.certificateRefs[0].name}'; echo
kubectl -n notes get secret notes-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/notes-ca.crt
curl -sS --cacert /tmp/notes-ca.crt https://notes.lab/healthz
```

**Что должно получиться.**

```text
certificate.cert-manager.io/notes-tls condition met
NAME        READY   SECRET      AGE
notes-tls   True    notes-tls   9s
[
  "ca.crt",
  "tls.crt",
  "tls.key"
]
notes-tls
{"status":"ok"}
```

**Объясни себе.**
- Почему `curl` без `--cacert` теперь выдаёт ошибку, хотя сертификат «правильный»? Кто в этой цепочке не доверяет кому?
- Что изменилось для Gateway при замене Secret: манифест Gateway правился или нет? Почему это удобно?

**Типичные ошибки.**
- `curl: (60) SSL certificate problem: unable to get local issuer certificate`: клиент не знает корень. Добавь `--cacert /tmp/notes-ca.crt`. Не лечи флагом `-k`: он отключает проверку целиком.
- `Error from server (AlreadyExists)` или Certificate висит `Ready False` из-за старого Secret: ты забыл удалить ручной `notes-tls`. Удали и подожди пару секунд.

### Задание 4. Шаг проекта: cert-manager в `notes-gitops`

**Цель.** Закрепить всё в git, чтобы `notes-tls` выпускался и продлевался без человека, а состояние воспроизводилось из репозитория.

**Шаги.**

1. Проверь, что структура `notes-gitops` совпадает с эталоном (`cert-manager/` в `controllers`, `clusterissuer.yaml` и `certificate.yaml` в `configs`), а в `k8s/base/` из репозитория `notes` больше нет Secret `notes-tls` (для платформы он заменён Certificate):

```bash
cd ~/notes-gitops
git ls-files infrastructure | grep -E 'cert-manager|clusterissuer|certificate'
flux get kustomizations
flux get helmreleases -A
```

2. Тег состояния проекта после урока: `v0.7.0` (`git -C ~/notes tag -a v0.7.0 -m "9.4: cert-manager"`).

Эталон: [project/notes/gitops](https://github.com/distinguished-sre/devops/tree/devops/project/notes/gitops).

**Что должно получиться.**

```text
infrastructure/configs/certificate.yaml
infrastructure/configs/clusterissuer.yaml
infrastructure/controllers/cert-manager/helmrelease.yaml
infrastructure/controllers/cert-manager/namespace.yaml
NAME                    REVISION        SUSPENDED   READY   MESSAGE
infrastructure          main@sha1:...   False       True    Applied revision: main@sha1:...
infrastructure-config   main@sha1:...   False       True    Applied revision: main@sha1:...
apps                    main@sha1:...   False       True    Applied revision: main@sha1:...
```

**Объясни себе.**
- Какой долг проекта закрыт этим уроком, а какой остался (подсказка: `--cacert` на каждом клиенте)?
- Что было бы, если бы `Certificate` применился раньше cert-manager?

**Типичные ошибки.**
- `kustomize build failed: ... file not found`: ресурс не добавлен в `kustomization.yaml` или неверный путь.
- `dependency 'flux-system/infrastructure' is not ready`: контроллеры ещё не Ready; подожди или смотри `flux get hr -A`.

## Сломай и почини

Скрипт ломает стенд одним из трёх способов. Сначала запусти и не читай скрипт, потом диагностируй:

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/9.4/break.sh
bash break.sh 1     # 1, 2 или 3; починка: bash break.sh fix
```

### Симптом

Сертификат не выпускается (`READY False`), либо сайт не открывается по HTTPS, либо клиенты видят просроченный сертификат. Начни с фактов, а не с догадок.

### Гипотезы

- Издатель: его нет, он не Ready или указан не тот `kind`.
- ACME: `Challenge` в состоянии `pending`, закрыт порт 80 или не тот DNS.
- Срок: сертификат живёт часы или продление не срабатывает.
- Потребитель: Gateway ссылается на другой Secret или не перечитал новый.

### Проверки

Идём по цепочке ресурсов сверху вниз: `Certificate` -> `CertificateRequest` -> `Order` -> `Challenge`.

```bash
kubectl -n notes get certificate,certificaterequest
kubectl -n notes describe certificate notes-tls | sed -n '/Events/,$p'
kubectl get clusterissuer
kubectl get order,challenge -A
echo | openssl s_client -connect notes.lab:443 -servername notes.lab 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Правило: `describe` на самом нижнем ресурсе цепочки почти всегда содержит причину дословно.

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

**Сценарий 1. Certificate не Ready, `Issuer not found`.** В `describe certificate` видно: `Issuing certificate as Secret does not exist`, а `CertificateRequest` в состоянии `Pending` с сообщением `Referenced "ClusterIssuer" not found: clusterissuer.cert-manager.io "notes-ca-x" not found`. Причина: опечатка в `issuerRef.name` или неверный `kind` (`Issuer` вместо `ClusterIssuer`). Исправление: поправь `issuerRef` в git, дождись Flux, `kubectl get certificate` покажет `True`.

**Сценарий 2. Challenge pending.** Симптом: `kubectl get challenge -A` показывает `STATE pending`, в `describe` причина вроде `Waiting for HTTP-01 challenge propagation: failed to perform self check GET request ... connection refused`. Причина в ACME-издателе: порт 80 не доступен из интернета, HTTPRoute для challenge не создан или DNS указывает не туда. Исправление: открой 80, проверь A-запись, убедись, что `parentRefs` в `solvers` совпадает с Gateway. Для отладки используй staging Let's Encrypt, чтобы не упереться в лимиты.

**Сценарий 3. Истёкший сертификат.** `openssl x509 -noout -dates` показывает `notAfter` в прошлом или в ближайшие минуты, хотя Secret есть. Причина: очень короткий `duration` (например `1h`), а `renewBefore` не сработал, потому что оператор недоступен (скейл в 0, сломан webhook), либо клиент держит старый сертификат. Исправление: верни `duration: 2160h`, `renewBefore: 720h`, проверь `kubectl -n cert-manager get pods`, а если сертификат отдаёт старый, перезапусти потребителя.

Общий вывод: сначала `describe` нижнего ресурса цепочки, потом издатель, потом сам сервер через `openssl s_client`.

</details>

## Вопросы с собеседований

### 1. [junior] Что делает cert-manager и что такое Certificate, Issuer, Secret в этой схеме?

cert-manager это оператор, который выпускает и продлевает сертификаты внутри Kubernetes. Я описываю `Certificate` (имена, срок, издатель), а `Issuer` или `ClusterIssuer` говорит, кто подписывает. Результат cert-manager кладёт в обычный Secret, откуда его берёт Gateway или Ingress.

**Что хотят услышать:** CRD и контроллер, разделение «желание и результат», Secret как выход, автоматическое продление.

**Красный флаг:** «это утилита для certbot внутри пода» или путаница, что сертификат хранится в `Certificate`.

### 2. [middle] Сертификат истёк, хотя cert-manager стоит. Как разбираешься?

Первым делом смотрю `kubectl describe certificate` и `certificaterequest`, чтобы понять, пытался ли он продлить. Потом состояние подов cert-manager и webhook, потом `Issuer`: Ready ли он. Отдельно проверяю, что реально отдаёт сервер через `openssl s_client`, а не только Secret.

**Что хотят услышать:** порядок Certificate -> CertificateRequest -> Order -> Challenge, Events, проверка отдаваемого сертификата, различие «Secret обновлён» и «клиент видит новый».

**Красный флаг:** сразу пересоздавать Certificate или Secret, не глядя в Events.

### 3. [middle] Challenge висит в pending. Что проверяешь?

Смотрю `describe challenge`: там причина дословно. Для HTTP-01 проверяю, что порт 80 доступен снаружи, домен резолвится на нужный адрес и маршрут challenge создан. Для DNS-01 проверяю права на DNS-API и наличие TXT-записи `_acme-challenge`. Отлаживаюсь на staging.

**Что хотят услышать:** различие HTTP-01 и DNS-01, `Order` и `Challenge`, лимиты Let's Encrypt, staging.

**Красный флаг:** «удалю и создам заново несколько раз»: это быстро упирается в rate limit.

### 4. [middle] Нужен wildcard-сертификат, а порт 80 закрыт. Что делаешь?

DNS-01: cert-manager создаёт TXT-запись через API DNS-провайдера, порт 80 не нужен, wildcard выдаётся только так. Нужны минимальные права на записи DNS, токен хранится в Secret, а не в git.

**Что хотят услышать:** DNS-01, права минимального уровня, вынос токена в Vault или ESO.

**Красный флаг:** «выпущу для каждого поддомена отдельно по HTTP-01» без понимания, что это не wildcard.

### 5. [junior] Клиент пишет «unable to get local issuer certificate». Что это значит?

Сервер отдал сертификат, но клиент не доверяет тому, кто его выпустил. Сертификат может быть в порядке, просто корень нашего CA не в его хранилище. Проверяю цепочку через `openssl s_client`, добавляю корень или чиню промежуточный сертификат.

**Что хотят услышать:** цепочка доверия, корень против промежуточного, `-CAfile`, отличие от истечения срока.

**Красный флаг:** советовать `curl -k` или `verify=False` как решение.

### 6. [middle] Продление прошло, `Ready True`, а пользователи всё равно видят старый сертификат. Причины?

Приложение прочитало сертификат один раз при старте и не перечитывает. Либо listener ссылается на другой Secret. Либо перед сервисом стоит кэширующий балансировщик. Проверяю `openssl s_client` по тому пути, каким идёт клиент, и перезагружаю потребителя.

**Что хотят услышать:** «Secret обновился» не равно «сервер отдаёт новый», reloader или проверка живого эндпоинта, мониторинг реального срока.

**Красный флаг:** полагаться только на статус `READY` у Certificate.

### 7. [middle] Как поймёшь заранее, что сертификат скоро истечёт?

Настрою мониторинг двух уровней: метрика cert-manager `certmanager_certificate_expiration_timestamp_seconds` и внешняя проверка живого эндпоинта blackbox-экспортёром (`probe_ssl_earliest_cert_expiry`, урок 8.4). Алерт за 14 и за 7 дней до конца: внутренний и внешний сигналы независимы.

**Что хотят услышать:** проба снаружи, метрики, порог с запасом больше `renewBefore`, дежурный видит алерт до пользователей.

**Красный флаг:** «календарь напомнит» или отсутствие мониторинга вообще.

### 8. [junior] Чем ClusterIssuer отличается от Issuer и когда какой?

`Issuer` действует в одном namespace, `ClusterIssuer` на весь кластер. Для общего CA или Let's Encrypt удобен `ClusterIssuer`; для команды, которой нужна изоляция, `Issuer` со своими учётными данными в её namespace.

**Что хотят услышать:** область действия, где лежит Secret с ключом издателя, вопрос изоляции команд.

**Красный флаг:** путают, считают что это просто «два названия одного».

### 9. [middle] Почему ставить cert-manager через Flux, а не `helm install`, и что с CRD?

В GitOps всё, что влияет на кластер, живёт в git и воспроизводимо; ручной `helm install` создаёт drift. CRD ставим через `crds.enabled: true` и защищаем `keep: true`, чтобы удаление релиза не снесло сертификаты кластера. Порядок задаёт `dependsOn`: контроллер раньше, `ClusterIssuer` и `Certificate` позже.

**Что хотят услышать:** порядок применения, CRD и их жизненный цикл, риск удаления CRD, закрепление версии чарта.

**Красный флаг:** «CRD поставлю потом руками» без объяснения, как это воспроизвести.

### 10. [middle] Прод, HTTPS вдруг отдаёт ошибку сертификата у части пользователей. Твои действия?

Сначала выясняю масштаб: какие клиенты, какие домены, с какого момента. Проверяю `openssl s_client` с разных точек: срок, цепочка, SAN. Если истёк, смотрю продление в cert-manager и Events; если цепочка неполна, проверяю промежуточный сертификат; если у части пользователей, думаю о старых корнях или CDN. Ищу, что менялось в последнее время.

**Что хотят услышать:** послойная диагностика, сравнение путей, цепочка и SAN, связь с изменениями, коммуникация с пользователями.

**Красный флаг:** сразу перевыпускать сертификат, не установив причину.

## Проверено на версиях

- cert-manager: v1.21.2 (Helm-чарт jetstack, `crds.enabled: true`)
- Flux: v2.9.5
- Envoy Gateway: v1.9.2
- Kubernetes (kind): версия из `kind/kind.yaml` курса
- Let's Encrypt (ACME v2): показан для реального домена, в стенде не применяется; проверь актуальную версию политики сроков на странице проекта

## Итог урока: ты умеешь

- [ ] умею объяснить, чем `Certificate` отличается от Secret и кто из них пишется в git
- [ ] умею поставить cert-manager через `HelmRelease` с закреплённой версией и CRD
- [ ] умею собрать локальный CA: `selfsigned` -> `notes-ca` -> `ClusterIssuer notes-ca`
- [ ] умею выпустить `notes-tls` для Gateway и проверить его через `curl --cacert`
- [ ] умею читать `Certificate` -> `CertificateRequest` -> `Challenge` при диагностике
- [ ] умею проверить срок отдаваемого сертификата через `openssl s_client`
- [ ] умею описать HTTP-01 и DNS-01 и выбрать подходящий для wildcard

**Дальше:** [Урок 9.5: CloudNativePG: PostgreSQL-оператор](05-cnpg.md)
