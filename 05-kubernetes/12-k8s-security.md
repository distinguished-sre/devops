---
layout: lesson
title: "Безопасность кластера: RBAC, NetworkPolicy, PSS"
topic: 5
lesson: "5.12"
time: "2 ч"
---

## Зачем это нужно

По умолчанию в Kubernetes любой под может обратиться к любому другому поду, запуститься от root и прочитать токен ServiceAccount с правами к API. Одна уязвимость в приложении, и атакующий получает плоскую открытую сеть и учётку внутри кластера. На работе это проверяют на аудитах и после инцидентов: «почему из пода фронтенда достучались до базы».
Три рычага закрывают основное: права на API (RBAC), сеть между подами (NetworkPolicy) и ограничения на сам под (Pod Security Standards и securityContext).
Шаг проекта: namespace `notes` получает уровень PSS `restricted`, чарт `helm/notes` версии 0.2.0 запускает приложение от uid 10001 с read-only файловой системой, отдельным ServiceAccount без токена и NetworkPolicy, а в `k8s/base/70-netpol-default-deny.yaml` появляется запрет всего трафика по умолчанию.

## Что нужно знать

- [Урок 1.3: права](../01-linux/03-users-permissions.md) - uid, gid и права на файлы: без них непонятны `runAsUser` и `fsGroup`
- [Урок 4.2: Dockerfile](../04-docker/02-dockerfile.md) - пользователь 10001 в образе «Заметок»
- [Урок 4.8: безопасность образов](../04-docker/08-image-security.md) - идея минимальных привилегий контейнера
- [Урок 5.2: Pod и Deployment](02-pods-deployments.md) - структура манифеста пода
- [Урок 5.3: Service и DNS](03-services-dns.md) - DNS кластера, порт 53, без него не разрешатся имена
- [Урок 5.4: Ingress и Gateway API](04-ingress-gateway.md) - откуда приходит трафик в `notes`
- [Урок 5.6: ConfigMap и Secret](06-config-secrets.md) - Secret это base64, поэтому доступ к нему надо ограничивать
- [Урок 5.9: Helm](09-helm.md) - чарт `helm/notes`, который мы дополняем

## Теория

### RBAC: кто что может делать с API

**RBAC (Role-Based Access Control)** отвечает на вопрос «может ли субъект (subject) выполнить глагол (verb) над ресурсом (resource)». Объекты четыре:

- **Role** - список разрешений в одном namespace: `apiGroups`, `resources`, `verbs` (`get`, `list`, `watch`, `create`, `delete`, ...);
- **ClusterRole** - то же на весь кластер (или для не-namespace ресурсов вроде узлов);
- **RoleBinding** - выдаёт роль субъекту в namespace; **ClusterRoleBinding** - на весь кластер;
- **ServiceAccount (SA)** - учётка для процесса внутри пода. Субъектом может быть ещё пользователь или группа, но пользователей Kubernetes сам не хранит: их выдаёт внешний аутентификатор (сертификат, OIDC).

Правил запрета нет: RBAC только разрешает, всё остальное отклоняется с ошибкой `forbidden`. Права складываются. Поэтому опасны `ClusterRoleBinding` на `cluster-admin` и wildcard `*` в `verbs` и `resources`.
Проверять права проще всего командой `kubectl auth can-i <глагол> <ресурс> --as=<субъект>`. Для ServiceAccount субъект пишется как `system:serviceaccount:<namespace>:<имя>`.

Каждый под получает SA (по умолчанию `default`) и токен монтируется в `/var/run/secrets/kubernetes.io/serviceaccount/`. «Заметкам» обращаться к API кластера не нужно, поэтому токен им не нужен: `automountServiceAccountToken: false`.

> **Проверь понимание:** у SA есть RoleBinding на роль `pod-reader` в namespace `dev`. Может ли он читать поды в namespace `prod`?

<details>
<summary>Ответ</summary>

Нет. RoleBinding действует только в своём namespace. Чтобы дать права в `prod`, нужен RoleBinding там (можно на ту же ClusterRole или Role с тем же содержимым). ClusterRoleBinding дал бы права везде.

</details>

### Pod Security Standards: три уровня для подов

**Pod Security Standards (PSS)** описывают три профиля:

| Профиль | Что разрешает |
|---|---|
| `privileged` | всё, без ограничений (системные компоненты) |
| `baseline` | запрещает заведомо опасное: `privileged: true`, hostNetwork, hostPath, лишние capabilities |
| `restricted` | требует лучших практик: не root, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` |

Применяет их встроенный контроллер допуска **Pod Security Admission (PSA)**. Профиль включается меткой на namespace, в трёх режимах:

- `enforce` - под, нарушающий профиль, не создаётся;
- `warn` - под создаётся, kubectl печатает предупреждение;
- `audit` - нарушение попадает в журнал аудита API-сервера.

Метки выглядят так: `pod-security.kubernetes.io/enforce: restricted`. Важная деталь: PSA проверяет только создание и изменение подов. Уже работающие поды не убиваются, проблема вскроется при следующем рестарте (например, при выкатке). Поэтому на существующем namespace сначала ставят `warn` и `audit`, чинят манифесты, и только потом `enforce`.

> **Проверь понимание:** ты включил `enforce: restricted` на namespace с работающим Postgres от root. Что произойдёт с подом сразу и что при его пересоздании?

<details>
<summary>Ответ</summary>

Сразу ничего: работающий под остаётся. При пересоздании (рестарт StatefulSet, эвакуация узла) под не пройдёт допуск: ошибка `violates PodSecurity "restricted:latest"`, а StatefulSet будет пытаться создать под снова. Именно поэтому сначала `warn`.

</details>

### securityContext: ограничения на под и контейнер

**securityContext** задаётся на уровне пода (общие для всех контейнеров: `runAsUser`, `runAsNonRoot`, `fsGroup`, `seccompProfile`) и контейнера (`readOnlyRootFilesystem`, `allowPrivilegeEscalation`, `capabilities`). Что означает каждое поле:

- `runAsNonRoot: true` и `runAsUser: 10001` - процесс не root, тот же uid, что мы задали в образе;
- `readOnlyRootFilesystem: true` - корневая ФС только для чтения: атакующий не подменит код и не положит скрипт. Куда приложению всё же писать, монтируем `emptyDir` (например, в `/tmp`);
- `allowPrivilegeEscalation: false` - процесс не получит больше прав, чем у родителя (блокирует setuid);
- `capabilities.drop: [ALL]` - убираем все Linux capabilities (привилегии root, разложенные на части);
- `seccompProfile: RuntimeDefault` - фильтр системных вызовов по умолчанию из рантайма.

Набор `runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop ALL`, `seccompProfile` ровно то, что требует `restricted`. Если что-то из этого забыть, PSA назовёт, чего именно не хватает.

> **Проверь понимание:** зачем `emptyDir` в `/tmp`, если файловая система только для чтения?

<details>
<summary>Ответ</summary>

Многие программы пишут временные файлы (Python, кэши, сокеты). На read-only корне запись падает с `Read-only file system`. `emptyDir` это отдельный записываемый том, живущий, пока жив под: ограничение остаётся на всём остальном образе.

</details>

### NetworkPolicy: сетевой фаервол между подами

**NetworkPolicy** описывает, какой трафик разрешён к подам (`ingress`) и от подов (`egress`). Ключевые правила:

- политика выбирает поды через `podSelector`; пустой `podSelector: {}` выбирает все поды namespace;
- поды, которые не выбрана ни одной политикой, открыты для всего трафика;
- как только под выбран политикой типа `Ingress`, входящим разрешено только то, что перечислено; для `Egress` то же самое исходящим;
- разрешения складываются (объединение), запретов нет;
- источники и цели задают `podSelector`, `namespaceSelector` или `ipBlock`.

Стандартный приём: **default deny** (запретить всё) плюс явные разрешения. Не забудь про DNS: после запрета egress под не сможет разрешить даже имя `db`, потому что запрос к CoreDNS (порт 53, UDP и TCP, namespace `kube-system`) тоже блокируется.

Политики применяет не API-сервер, а сетевой плагин (CNI, Container Network Interface). Если плагин их не поддерживает, манифест примется без ошибок и ничего не изменится. Поэтому политику всегда проверяют тестом: запретил и убедился, что трафик реально пропал.

> **Проверь понимание:** под выбран политикой `Ingress` с разрешением от подов `app=notes`. Может ли под с меткой `app=other` из того же namespace достучаться до него?

<details>
<summary>Ответ</summary>

Нет: как только под выбран Ingress-политикой, разрешено только перечисленное. Всё остальное отбрасывается (пакеты молча пропадают, клиент видит таймаут, а не отказ).

</details>

## Практика

Кластер kind `notes` из урока 5.1 запущен, контекст `kind-notes`, релиз `notes` из [урока 5.9](09-helm.md) работает в namespace `notes`. Версии Kubernetes и kind не закреплены курсом жёстко, проверь актуальные значения на страницах проектов.

### Задание 1. RBAC: выдай минимум и проверь

**Цель:** создать ServiceAccount, выдать ему право только читать поды в `notes` и проверить границы командой `can-i`.

**Предскажи:**

1. Сможет ли новый SA сразу после создания читать поды?
2. После выдачи роли `get pods`, сможет ли он читать секреты и удалять поды?

<details>
<summary>Ответ</summary>

1. Нет, у нового SA нет прав кроме базовых (discovery). 2. Читать поды сможет, секреты и удаление нет: RBAC разрешает только перечисленное.

</details>

**Шаги:**

1. Создай SA, Role и RoleBinding:

```bash
# ServiceAccount для «наблюдателя»
kubectl -n notes create serviceaccount viewer

# Роль: только чтение подов и их логов
kubectl -n notes create role pod-reader \
  --verb=get,list,watch --resource=pods,pods/log

# Привязка роли к SA
kubectl -n notes create rolebinding viewer-pod-reader \
  --role=pod-reader --serviceaccount=notes:viewer
```

2. Проверь права до и после границы:

```bash
SA=system:serviceaccount:notes:viewer
kubectl -n notes auth can-i list pods --as=$SA
kubectl -n notes auth can-i get secrets --as=$SA
kubectl -n notes auth can-i delete pods --as=$SA
kubectl -n default auth can-i list pods --as=$SA
```

**Что должно получиться:**

```text
yes
no
no
no
```

**Объясни себе:**

- Почему четвёртая проверка (`default`) вернул `no`, хотя роль выдана?
- Почему для `pods/log` в роли отдельная запись ресурса?
- Что опаснее: `get secrets` на весь namespace или `delete pods`? Почему?

**Типичные ошибки:**

- `Error from server (Forbidden): pods is forbidden: User "..." cannot list resource "pods"`: нет привязки или она в другом namespace: проверь `kubectl -n notes get rolebinding`.
- `error: failed to create rolebinding: ... serviceaccount must be in the format <namespace>:<name>`: в `--serviceaccount` забыт namespace: пиши `notes:viewer`.
- `auth can-i` даёт `yes` для всего: ты запустил его от своего админа без `--as`.

### Задание 2. Pod Security: warn, потом enforce

**Цель:** увидеть, что `restricted` требует от пода, и не сломать работающий namespace.

**Предскажи:** ты включаешь `warn: restricted` на `notes` с работающим релизом. Что напечатает kubectl и что случится с подами?

<details>
<summary>Ответ</summary>

kubectl напечатает предупреждения `would violate PodSecurity "restricted:latest"` со списком нарушенных полей для каждого пода. Поды продолжат работать: `warn` ничего не блокирует.

</details>

**Шаги:**

1. Включи `warn` и `audit` (не блокирующие режимы):

```bash
kubectl label namespace notes \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```

2. Проверь предупреждения без изменения кластера (`--dry-run=server` вызывает допуск на сервере):

```bash
kubectl -n notes rollout restart deployment/notes --dry-run=server
```

3. Попробуй создать заведомо плохой под, чтобы увидеть полный список нарушений:

```bash
kubectl -n notes run bad --image=nginx:1.29 --restart=Never --dry-run=server
```

**Что должно получиться:**

```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "bad" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "bad" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "bad" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "bad" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/bad created (server dry run)
```

**Объясни себе:**

- Почему под `bad` создался, несмотря на нарушения?
- Что в выводе подсказывает, какие четыре поля надо добавить?
- Какие поды в `notes` (приложение, Postgres, CronJob) придётся править до `enforce`?

**Типичные ошибки:**

- `Error from server (Forbidden): ... violates PodSecurity "restricted:latest"`: у тебя уже стоит `enforce`, а под не соответствует: добавь недостающие поля или временно верни `warn`.
- `error: ... unknown flag: --dry-run=server`: слишком старый kubectl: обнови до версии, совпадающей с кластером (отклонение не более одной минорной).

### Задание 3. NetworkPolicy: default deny и проверка, что CNI её выполняет

**Цель:** убедиться, что политики в твоём kind реально работают, и запретить весь трафик в `notes`, кроме нужного.

**Предскажи:** в namespace `notes` применена политика `default-deny` (ingress и egress для всех подов). Ответит ли приложение на `curl` из тестового пода? Разрешит ли под имя `db.notes.svc`?

<details>
<summary>Ответ</summary>

Нет на оба вопроса. Входящий трафик блокирован, а исходящий (включая DNS на порт 53) тоже: `curl` завершится по таймауту, а имя не разрешится (`Could not resolve host`).

</details>

**Шаги:**

1. Создай тестовый под вне `notes` (в `default` политик нет) и убедись, что связь есть:

```bash
kubectl -n default run nettest --image=curlimages/curl:8.14.1 --restart=Never \
  --command -- sleep 3600
kubectl -n default wait --for=condition=Ready pod/nettest --timeout=60s
kubectl -n default exec nettest -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://notes.notes.svc:8080/healthz
```

2. Файл `k8s/base/70-netpol-default-deny.yaml`: запрет всего плюс минимум разрешений (DNS, приложение к базе):

```yaml
# Запрещаем весь входящий и исходящий трафик в namespace notes
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: notes
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Разрешаем всем подам ходить в DNS кластера
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: notes
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
---
# В Postgres пускаем только приложение и бэкап
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-db-from-app
  namespace: notes
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchExpressions:
              - {key: app, operator: In, values: [notes, pg-backup]}
      ports:
        - {protocol: TCP, port: 5432}
```

Метки `app: notes` и `app: postgres` заданы в манифестах уроков 5.2 и 5.5. Если у тебя другие, подставь свои.

3. Применяй и проверь снова:

```bash
kubectl apply -f k8s/base/70-netpol-default-deny.yaml
kubectl -n default exec nettest -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://notes.notes.svc:8080/healthz
```

**Что должно получиться:** до политики код `200`, после таймаут:

```text
200
000
command terminated with exit code 28
```

Если и после политики пришло `200`, твой CNI не применяет NetworkPolicy. Запасной путь: пересоздай кластер с CNI, который их поддерживает. В `kind/kind.yaml` добавь в `networking` строку `disableDefaultCNI: true`, выполни `kind delete cluster --name notes && kind create cluster --config kind/kind.yaml`, затем поставь Calico по инструкции с сайта проекта (версия не закреплена, проверь актуальную версию на странице проекта) и повтори проверку. Учти, что все предыдущие объекты придётся применить заново.

**Объясни себе:**

- Почему таймаут, а не «connection refused»?
- Что случится с Postgres, если убрать `allow-db-from-app` и оставить `default-deny`?
- Почему `allow-dns` нужен именно как egress и на namespace `kube-system`?

**Типичные ошибки:**

- `curl: (28) Resolving timed out after 3000 milliseconds`: DNS заблокирован egress-политикой: добавь `allow-dns`.
- `error validating data: ... unknown field "namespaceSelectors"`: опечатка в имени поля: правильно `namespaceSelector`.
- Политика применилась, но трафик проходит: CNI не поддерживает NetworkPolicy, см. запасной путь выше.

### Задание 4. Шаг проекта: чарт 0.2.0 с безопасностью

**Цель:** привести чарт `helm/notes` к профилю `restricted`, отдать приложению собственный ServiceAccount без токена и разрешить только нужный входящий трафик.

**Предскажи:** после включения `enforce: restricted` и обновления чарта под будет создан без `/tmp`-тома. Что упадёт: сам под или запрос?

<details>
<summary>Ответ</summary>

Под создастся и стартует, а приложение упадёт при первой попытке записи во временный файл: `Read-only file system`. Ошибка проявится в рантайме, а не при допуске: PSA не проверяет, куда пишет процесс.

</details>

**Шаги:**

1. Обнови `k8s/base/00-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: notes
  labels:
    # Пода, нарушающего профиль restricted, в namespace не будет
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

2. Postgres от root под `restricted` не пройдёт. В `k8s/base/40-postgres.yaml` добавь в шаблон пода (образ postgres:18 запускается от uid 999):

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: postgres
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
```

Так же поправь CronJob `pg-backup` в `60-pg-backup-cronjob.yaml`: без этого следующий запуск бэкапа упрётся в `violates PodSecurity`.

3. Файл `helm/notes/templates/serviceaccount.yaml`:

{% raw %}
```yaml
# ServiceAccount приложения: токен API «Заметкам» не нужен
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "notes.fullname" . }}
automountServiceAccountToken: false
```
{% endraw %}

4. Файл `helm/notes/templates/networkpolicy.yaml`:

{% raw %}
```yaml
{{- if .Values.networkPolicy.enabled }}
# Внутрь приложения пускаем только прокси Gateway, наружу только в БД
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "notes.fullname" . }}
spec:
  podSelector:
    matchLabels:
      {{- include "notes.selectorLabels" . | nindent 6 }}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: envoy-gateway-system
      ports:
        - {protocol: TCP, port: 8080}
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - {protocol: TCP, port: 5432}
{{- end }}
```
{% endraw %}

DNS для этого пода уже разрешён политикой `allow-dns` из задания 3 (разрешения складываются).

5. В `helm/notes/templates/deployment.yaml` в шаблон пода добавь (helm-хелперы `notes.fullname` и `notes.selectorLabels` из урока 5.9):

{% raw %}
```yaml
    spec:
      serviceAccountName: {{ include "notes.fullname" . }}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: notes
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: tmp
          emptyDir: {}
```
{% endraw %}

Остальные поля контейнера (image, env, пробы) остаются как в 0.1.1. Если в твоём `deployment.yaml` уже есть `volumes` или `volumeMounts`, дописывай элементы в существующие списки, а не создавай второй ключ.

6. В `values.yaml` добавь `networkPolicy.enabled: true`, в `Chart.yaml` подними `version: 0.2.0`. Проверь и выкати:

```bash
helm lint helm/notes
helm template notes helm/notes | grep -c 'kind: NetworkPolicy'
kubectl apply -f k8s/base/00-namespace.yaml -f k8s/base/40-postgres.yaml -f k8s/base/60-pg-backup-cronjob.yaml
helm upgrade notes helm/notes -n notes --wait --timeout 3m
```

**Что должно получиться:**

```text
==> Linting helm/notes
1 chart(s) linted, 0 chart(s) failed
1
Release "notes" has been upgraded. Happy Helming!
```

7. Проверь итог: трафик через Gateway идёт, из чужого пода нет, права контейнера ограничены:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://notes.lab/healthz
kubectl -n default exec nettest -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://notes.notes.svc:8080/healthz
kubectl -n notes exec deploy/notes -- id
kubectl -n notes exec deploy/notes -- sh -c 'touch /x 2>&1; touch /tmp/x && echo tmp-ok'
```

```text
200
000
uid=10001 gid=10001
touch: /x: Read-only file system
tmp-ok
```

Закоммить: `git add k8s helm && git commit -m "5.12: PSS restricted, RBAC, NetworkPolicy, chart 0.2.0"`. Эталон: [project/notes](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Объясни себе:**

- Почему разрешён только namespace `envoy-gateway-system`, а не вся сеть?
- Зачем `automountServiceAccountToken: false` и на SA, и на поде?
- Что изменится для атакующего, получившего RCE (remote code execution, выполнение кода) в поде?

**Типичные ошибки:**

- `Error creating: pods "notes-..." is forbidden: violates PodSecurity "restricted:latest": ...`: в шаблоне не хватает одного из полей: читай список в тексте ошибки и добавь.
- `Error: UPGRADE FAILED: ... error validating "": ... unknown field "seccompProfile" in io.k8s.api.core.v1.Container`: `seccompProfile` вложен не туда: на уровне контейнера он допустим, но в чарте мы держим его в `securityContext` пода, проверь отступы.
- `PermissionError: [Errno 30] Read-only file system: '/app/...'`: приложение пишет вне `/tmp`: смонтируй `emptyDir` и туда или найди, что пишет.
- `curl: (28) Connection timed out` через `notes.lab`: политика не пускает Gateway: проверь имя namespace прокси (`kubectl get pods -A | grep envoy`).

## Сломай и почини

Запусти сценарий и почини, не читая скрипт. Сценарии 1-4 (или `random`):

```bash
bash break/5.12/break.sh 1
```

### Симптом

Сценарий 1: приложение отвечает 500 или не может подключиться к базе, в логах ошибки разрешения имён. Сценарий 2: после выката под не появляется, `rollout status` висит. Сценарий 3: под в `CrashLoopBackOff` или запросы падают ошибкой записи. Сценарий 4: команда возвращает `Forbidden`.

### Гипотезы

Для каждого симптома назови минимум две причины: что изменилось последним (`kubectl get events`, `helm history`) и на каком уровне проблема: допуск пода, сеть или права API.

### Проверки

```bash
kubectl -n notes get events --sort-by=.lastTimestamp | tail -15
kubectl -n notes describe replicaset -l app=notes | tail -15
kubectl -n notes logs deploy/notes --tail=30
kubectl -n notes get networkpolicy
kubectl auth can-i <глагол> <ресурс> --as=<субъект> -n notes
```

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

1. **NetworkPolicy блокирует DNS.** Симптом: `Temporary failure in name resolution` или `could not translate host name "db"`. Проверка: `kubectl -n notes get networkpolicy` показывает `default-deny` без `allow-dns`; из тестового пода `nslookup` виснет. Исправление: вернуть `allow-dns` (`kubectl apply -f k8s/base/70-netpol-default-deny.yaml`). Урок: egress deny без DNS ломает любое обращение по имени.
2. **`violates PodSecurity`.** Симптом: `rollout status` ждёт, подов нет. Проверка: `describe replicaset` показывает `Error creating: pods ... is forbidden: violates PodSecurity "restricted:latest"` со списком полей. Исправление: добавить недостающие поля securityContext, `helm upgrade`. Ошибка видна в ReplicaSet, а не в Deployment.
3. **`readOnlyRootFilesystem` и запись падает.** Симптом: в логах `Read-only file system`. Проверка: `kubectl exec ... -- touch /x` даёт ту же ошибку; смотрим, какой путь пишет приложение. Исправление: смонтировать `emptyDir` в этот путь (не отключать read-only).
4. **RBAC forbidden.** Симптом: `Error from server (Forbidden): ... cannot list resource "pods"`. Проверка: `kubectl auth can-i list pods --as=system:serviceaccount:notes:<sa> -n notes`, `kubectl -n notes get rolebinding -o wide`. Исправление: привязать роль нужному SA в нужном namespace, а не выдавать `cluster-admin`.

</details>

## Вопросы с собеседований

### 1. [junior] Что такое RBAC и из каких объектов он состоит?

Role описывает, какие глаголы допустимы над какими ресурсами в namespace, RoleBinding привязывает роль к пользователю, группе или ServiceAccount. ClusterRole и ClusterRoleBinding то же на весь кластер. Права только разрешаются, запретов нет.

**Что хотят услышать:** четыре объекта, принцип минимальных прав, `kubectl auth can-i`, отличие namespace от cluster.

**Красный флаг:** «RBAC это логины и пароли» или выдача `cluster-admin` «чтобы работало».

### 2. [middle] Разработчик жалуется: `cannot list resource "pods" ... forbidden`. Как разбираешься?

Смотрю точный текст: субъект, глагол, ресурс, namespace. Проверяю `kubectl auth can-i list pods --as=<субъект> -n <ns>`, потом `get rolebinding,clusterrolebinding` и роль на нужные verbs и resources. Чиню минимально: правлю роль или привязку в нужном namespace.

**Что хотят услышать:** `--as`, разница Role и ClusterRole, subject в нужном namespace, не давать wildcard.

**Красный флаг:** сразу выдаёт `cluster-admin`.

### 3. [middle] Применил NetworkPolicy, а трафик по-прежнему ходит. Почему?

Первое: CNI не поддерживает политики (манифест принимается, но не работает). Второе: под не выбран `podSelector` (метки не совпали) или политика в другом namespace. Третье: есть другая политика, которая разрешает (разрешения складываются). Проверяю тестовым `curl` изнутри и `describe networkpolicy`.

**Что хотят услышать:** CNI (Calico, Cilium), метки, аддитивность, проверка тестом, а не «применил и поверил».

**Красный флаг:** «политики всегда работают, раз kubectl не выдал ошибку».

### 4. [middle] После default deny egress сервис перестал ходить в БД по имени, а по IP ходит. В чём дело?

Заблокирован DNS: запрос к CoreDNS в `kube-system` на порт 53 (UDP и TCP) не проходит. Добавляю egress-разрешение на DNS через `namespaceSelector` на `kube-system`.

**Что хотят услышать:** порт 53, оба протокола, признак «по IP работает, по имени нет».

**Красный флаг:** отключает политику целиком вместо точечного разрешения.

### 5. [junior] Чем отличаются профили PSS privileged, baseline и restricted?

`privileged` без ограничений, `baseline` блокирует явно опасное (privileged, hostPath, hostNetwork), `restricted` требует лучших практик: не root, drop ALL, seccomp, без privilege escalation.

**Что хотят услышать:** режимы `enforce`, `warn`, `audit`, метки на namespace.

**Красный флаг:** путает PSS с PodSecurityPolicy (её убрали в 1.25).

### 6. [middle] Деплой завис: `kubectl rollout status` ждёт, подов нет. В events `violates PodSecurity`. Что делаешь?

Смотрю ошибку в `describe replicaset`: она перечисляет нарушенные поля. Добавляю в securityContext `runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`. Ослаблять метку namespace не стану без причины.

**Что хотят услышать:** ошибка в ReplicaSet, а не в Deployment; поля по списку; что PSA проверяет только создание.

**Красный флаг:** «снимаю label с namespace, чтобы деплой прошёл».

### 7. [middle] Как безопасно включить `restricted` на живом namespace?

Сначала `warn` и `audit`, смотрю нарушения на `--dry-run=server` и в аудите, исправляю манифесты (в том числе StatefulSet и CronJob), потом `enforce`. Работающие поды не убиваются, но при рестарте нарушители не поднимутся.

**Что хотят услышать:** поэтапность, что PSA действует при создании, проверка всех воркладов.

**Красный флаг:** сразу `enforce` в проде в пятницу.

### 8. [middle] Контейнер падает с `Read-only file system` после включения `readOnlyRootFilesystem`. Что делаешь?

Нахожу, куда пишет процесс (`strace`, логи, документация), и монтирую в эти пути `emptyDir`. Корень оставляю read-only, флаг не отключаю.

**Что хотят услышать:** `emptyDir` для `/tmp` и кэшей, зачем read-only.

**Красный флаг:** отключает флаг, чтобы «заработало».

### 9. [junior] Зачем `automountServiceAccountToken: false`?

Токен в поде даёт доступ к API по правам SA. Если приложение API не использует, токен только расширяет ущерб при взломе. Отключаю на SA или на поде.

**Что хотят услышать:** default SA, токен в `/var/run/secrets/...`, минимальные права.

**Красный флаг:** «токен нужен всегда для работы пода».

### 10. [middle] Из пода фронтенда достучались до базы соседнего сервиса. Как закрыть системно?

Default deny в namespace, затем явные разрешения: приложение пускают в БД только подам с нужной меткой, остальные не пускают. Разделяю по namespace, проверяю тестовым `curl` и `nc`. Добавляю RBAC минимальных прав и PSS.

**Что хотят услышать:** deny by default, разрешения по меткам, namespaceSelector, аддитивность, тест после применения.

**Красный флаг:** «поставлю пароль на базу и всё».

## Проверено на версиях

- Helm: v4 (проверь актуальную версию на странице проекта)
- Kubernetes: версия не закреплена, проверь актуальную версию на странице проекта
- kind: версия не закреплена, проверь актуальную версию на странице проекта
- Calico (запасной CNI): версия не закреплена, проверь актуальную версию на странице проекта
- Envoy Gateway: v1.9.2
- PostgreSQL: 18
- curlimages/curl: 8.14.1, busybox: 1.37

## Итог урока: ты умеешь

- [ ] умею создать ServiceAccount, Role и RoleBinding и проверить границы через `kubectl auth can-i --as`
- [ ] умею читать ошибку `forbidden` и находить, какого права не хватает
- [ ] умею включить Pod Security `restricted` поэтапно (warn, audit, enforce)
- [ ] умею настроить `securityContext`: не root, read-only корень, drop ALL, seccomp, `emptyDir` для `/tmp`
- [ ] умею написать default deny и разрешения для DNS, БД и Gateway
- [ ] умею проверить, что NetworkPolicy реально применяется CNI, а не только принята API
- [ ] умею починить `violates PodSecurity` и `Read-only file system`
- [ ] умею выпустить чарт 0.2.0 с ServiceAccount без токена и NetworkPolicy

**Дальше:** [Урок 5.13: Диагностика Kubernetes: разбор поломок](13-k8s-troubleshooting.md)
