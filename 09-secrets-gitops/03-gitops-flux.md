---
layout: lesson
title: "GitOps: Flux разворачивает «Заметки» из git"
topic: 9
lesson: "9.3"
time: "2.5 ч"
---

## Зачем это нужно

Пока ты катишь релизы командой `helm upgrade` со своего ноутбука, у "продакшена" есть один настоящий источник правды: твоя голова и история shell. Коллега не знает, что и когда выкатили, ручная правка через `kubectl edit` живёт до следующего деплоя, а права на кластер нужны каждому, кто выкатывает. На работе это выглядит как "у меня работает, а на проде нет" и как ночной откат "того, что кто-то поменял руками".

GitOps (git как единственный источник желаемого состояния) решает это: описание кластера лежит в репозитории, агент внутри кластера сам подтягивает его и приводит кластер в соответствие. Деплой равен merge в `main`, откат равен `git revert`.

Шаг проекта: «Заметки» разворачиваются на новом кластере `notes` не руками, а из репозитория `notes-gitops` через Flux; ручные `helm install` больше не используются.

## Что нужно знать

- [Урок 3.2: удалённые репозитории и Pull Request](../03-git-ci/02-remotes-workflow.md) - push, revert, PR в `main`
- [Урок 4.7: образы и реестр ghcr.io](../04-docker/07-images-registry.md) - образ `notes:0.7.0` и ghcr.io
- [Урок 5.1: кластер kind](../05-kubernetes/01-why-k8s-cluster.md) - `kind/kind.yaml`, контекст `kind-notes`
- [Урок 5.4: Gateway API](../05-kubernetes/04-ingress-gateway.md) - Envoy Gateway, Gateway `notes-gw`
- [Урок 5.9: Helm](../05-kubernetes/09-helm.md) - чарт `helm/notes`, values, релиз
- [Урок 9.1: Vault](01-secrets-problem-vault.md) - `scripts/seed-vault.sh`
- [Урок 9.2: Vault и External Secrets Operator](02-vault-k8s-eso.md) - `ExternalSecret`, `ClusterSecretStore`

## Теория

### Push и pull: кто стучится в кластер

В модели push (толкать) CI-пайплайн из [урока 3.3](../03-git-ci/03-actions-ci.md) после сборки сам идёт в кластер: `kubectl apply` или `helm upgrade`. Для этого у CI есть kubeconfig с высокими правами, а API-сервер должен быть доступен снаружи. Если кто-то поправил ресурс руками, пайплайн об этом не узнает до следующего запуска.

В модели pull (тянуть) агент внутри кластера сам следит за репозиторием. Доступ у него только на чтение git, наружу API-сервер открывать не нужно, а расхождение между git и кластером он замечает и исправляет постоянно. Четыре правила GitOps:

1. Желаемое состояние описано декларативно (манифесты, чарты, values).
2. Оно версионировано: история в git, кто и что изменил видно в `git log`.
3. Агент сам забирает изменения (pull), а не получает их снаружи.
4. Агент постоянно сверяет факт с описанием (reconcile) и возвращает дрейф (drift, расхождение).

> **Проверь понимание:** почему модель pull безопаснее для доступа к кластеру, чем push из CI?

<details markdown="1">
<summary>Ответ</summary>

В push у CI лежит kubeconfig с правами на изменение кластера, и утечка секрета CI даёт доступ к проду. В pull права на запись в кластер есть только у агента внутри него, а снаружи нужен лишь доступ на чтение репозитория. 

</details>

### Из чего состоит Flux

Flux v2.9.5 (Flux, CNCF graduated) - набор контроллеров (controllers), каждый следит за своими объектами (Custom Resource):

| Контроллер | Что делает | Его объекты |
|---|---|---|
| source-controller | скачивает источники и хранит артефакт | `GitRepository`, `HelmRepository`, `OCIRepository` |
| kustomize-controller | применяет манифесты из источника | `Kustomization` |
| helm-controller | ставит и обновляет Helm-релизы | `HelmRelease` |
| notification-controller | шлёт события в Slack, Telegram, webhook | `Provider`, `Alert` |

Есть ещё автоматическое обновление образов (image-reflector и image-automation): они сами коммитят новый тег в git, в курсе только обзор. Не путай два разных объекта `Kustomization`. У Flux он называется `kustomize.toolkit.fluxcd.io/v1` и означает "применить вот этот путь из git". Файл `kustomization.yaml` из [урока 5.10](../05-kubernetes/10-kustomize.md) - другое: он собирает манифесты в один набор. Первое использует второе.

Цепочка: `GitRepository` скачивает репозиторий, `Kustomization` применяет путь из него, а внутри лежат `HelmRelease`, которые helm-controller превращает в обычные релизы Helm.

> **Проверь понимание:** какой контроллер выполнит `helm upgrade`, когда ты изменишь values в `HelmRelease`, и какой заметит новый коммит в git?

<details markdown="1">
<summary>Ответ</summary>

Новый коммит заметит source-controller (он опрашивает `GitRepository` раз в `interval`). Затем kustomize-controller применит изменённый `HelmRelease`, а сам upgrade выполнит helm-controller.

</details>

### Reconcile, prune и drift

Reconcile (сверка) - это цикл: взять желаемое из git, сравнить с фактом, исправить разницу. Он идёт по таймеру `interval` и по событию. Два флага решают судьбу лишнего:

- `prune: true` - ресурс, удалённый из git, удаляется из кластера. Без него в кластере копится мусор.
- `driftDetection` у `HelmRelease` - helm-controller замечает ручные правки ресурсов релиза и откатывает их. Ресурсы из `Kustomization` откатывает kustomize-controller при каждой сверке.

Следствие: `kubectl edit` и `kubectl scale` на управляемом ресурсе бесполезны, правку затрёт следующий reconcile. Хочешь изменить прод, меняй git.

> **Проверь понимание:** что произойдёт с Deployment, если удалить его YAML из git, а `prune` выключен?

<details markdown="1">
<summary>Ответ</summary>

Ничего: Deployment останется в кластере и продолжит работать, но Flux больше им не управляет. Так и появляются "призрачные" ресурсы. С `prune: true` он был бы удалён.

</details>

### Порядок и зависимости: dependsOn

Оператор нельзя применить раньше его CRD, а `ExternalSecret` раньше External Secrets Operator. Поэтому платформа делится на три слоя, и каждый ждёт предыдущий через `dependsOn`:

1. `infrastructure` (controllers): контроллеры и операторы (Envoy Gateway, ESO, Vault).
2. `infrastructure-config` (configs): ресурсы, которые нужны CRD контроллеров (Gateway, `ClusterSecretStore`).
3. `apps`: само приложение.

`dependsOn` ждёт статуса `Ready=True` у зависимости, а не просто применения. Без него на чистом кластере apps падают с `no matches for kind` и лишь потом, через ретраи, сходятся сами.

### Структура репозитория и секреты

Репозиторий `notes-gitops` отделён от кода `notes`: код собирается CI, а желаемое состояние живёт отдельно, у него свои права и свой ритм изменений (подробности разделения: вопрос 9 ниже). Раскладка:

```text
clusters/kind/        точка входа кластера: flux-system и три Kustomization
infrastructure/
  controllers/        HelmRelease контроллеров
  configs/            Gateway, ClusterSecretStore
apps/notes/           HelmRelease приложения
```

Секретов в этом репозитории нет: пароль БД приходит из Vault через ESO ([урок 9.2](02-vault-k8s-eso.md)), в git лежит только `ExternalSecret` со ссылкой на путь. Альтернатива SOPS (шифрование файлов ключом) в курсе не используется.

### Argo CD: сравнение

Argo CD v3.5.3 решает ту же задачу центральным сервером с веб-интерфейсом и деревом ресурсов, объектом `Application` и `ApplicationSet` для многих кластеров. Flux, набор контроллеров без своего UI, ближе к Helm и Kustomize. Оба зрелые и из CNCF: Argo CD выбирают ради панели и многих команд, Flux ради лёгкой схемы. Необязательная установка Argo CD есть в конце практики.

## Практика

Все задания идут на НОВОМ кластере. Старый кластер из тем 5 и 9.1-9.2 создавался ручными командами, а мы хотим доказать, что весь стенд воспроизводится из git.

### Если у тебя 8 ГБ

Вместо `replicaCount: 3` ставь `1`, не ставь Vault через Flux (оставь только Envoy Gateway и ESO), . Кластер `notes` с одним worker: убери второй `role: worker` из `kind/kind.yaml` (копию сохрани как `kind/kind-small.yaml`). Остальное работает так же.

### Задание 1. Новый кластер и bootstrap Flux

**Цель:** поднять чистый кластер и подключить его к репозиторию `notes-gitops` командой `flux bootstrap`.

**Предскажи:** сколько подов появится в namespace `flux-system` и что Flux сам закоммитит в репозиторий?

<details markdown="1">
<summary>Ответ</summary>

Четыре пода по одному на контроллер: source, kustomize, helm, notification (image-контроллеры не входят в набор по умолчанию). В репозиторий Flux закоммитит свои манифесты в `clusters/kind/flux-system/`: `gotk-components.yaml` и `gotk-sync.yaml`.

</details>

**Шаги:**

1. Удали старый кластер и создай новый из конфигурации проекта (данные старого не нужны):

   ```bash
   kind delete cluster --name notes
   kind create cluster --config ~/notes/kind/kind.yaml
   kubectl config use-context kind-notes
   kubectl get nodes
   ```

2. Установи flux CLI v2.9.5 со сверкой SHA256 (без `curl | bash`):

   ```bash
   cd "$(mktemp -d)"   # временный каталог
   V=2.9.5
   curl -fsSLO "https://github.com/fluxcd/flux2/releases/download/v${V}/flux_${V}_linux_amd64.tar.gz"
   curl -fsSLO "https://github.com/fluxcd/flux2/releases/download/v${V}/flux_${V}_checksums.txt"
   sha256sum --ignore-missing -c "flux_${V}_checksums.txt"
   tar -xzf "flux_${V}_linux_amd64.tar.gz"
   sudo install -m 0755 flux /usr/local/bin/flux
   flux --version
   ```

   На ARM (Apple Silicon, ВМ на ARM) замени `amd64` на `arm64`.

3. Создай на GitHub пустой публичный репозиторий `notes-gitops` (без README). Создай fine-grained токен только на этот репозиторий с правами Contents: Read and write и Administration: Read and write (второе нужно, чтобы bootstrap добавил deploy key). Токен не пиши в файлы и историю:

   ```bash
   export GITHUB_USER=<твой-логин>
   read -rs GITHUB_TOKEN && export GITHUB_TOKEN   # вставь токен и Enter, он не отобразится
   flux check --pre
   ```

4. Запусти bootstrap:

   ```bash
   flux bootstrap github \
     --owner="$GITHUB_USER" \
     --repository=notes-gitops \
     --branch=main \
     --path=clusters/kind \
     --personal --private=false
   ```

5. Клонируй репозиторий и посмотри, что сделал Flux:

   ```bash
   git clone "git@github.com:${GITHUB_USER}/notes-gitops.git" ~/notes-gitops
   ls ~/notes-gitops/clusters/kind/flux-system
   kubectl get pods -n flux-system
   flux get sources git
   ```

**Что должно получиться:**

```text
NAME             REVISION              SUSPENDED  READY  MESSAGE
flux-system      main@sha1:3f9c1a2     False      True   stored artifact for revision 'main@sha1:3f9c1a2'
```

В `flux-system` четыре пода `Running`, а каталог содержит `gotk-components.yaml`, `gotk-sync.yaml`, `kustomization.yaml`.

**Объясни себе:**

- Почему Flux управляет сам собой (файлы `gotk-*` лежат в git)?

**Типичные ошибки:**

- `flux bootstrap github` падает с `failed to create repository: ... 404 Not Found`, а при готовом репозитории `could not add deploy key: 403`: у токена нет права Administration, добавь и повтори.
- `error: no context exists with the name: "kind-notes"`: кластер не создан или не тот контекст, выполни `kubectl config get-contexts`.
- `sha256sum: WARNING: 1 computed checksum did NOT match`: архив повреждён, скачай заново.

### Задание 2. Инфраструктура слоями с dependsOn

**Цель:** описать контроллеры и конфигурации платформы в git и увидеть, что порядок задан `dependsOn`.

**Предскажи:** что покажет `flux get kustomizations` сразу после пуша, если `infrastructure-config` зависит от `infrastructure`, а тот ещё ставит Envoy Gateway?

<details markdown="1">
<summary>Ответ</summary>

`infrastructure` будет `Unknown` или `Reconciling` (идёт установка чарта), а `infrastructure-config` останется с сообщением `dependency 'flux-system/infrastructure' is not ready`. Он не применяется, пока зависимость не станет `Ready`.

</details>

**Шаги:**

1. Создай структуру:

   ```bash
   cd ~/notes-gitops
   mkdir -p infrastructure/controllers infrastructure/configs apps/notes
   ```

2. Источники чартов и релизы одним файлом `infrastructure/controllers/releases.yaml`: Envoy Gateway v1.9.2, ESO v2.11.0 и Vault (standalone, файловое хранилище, как в [уроке 9.1](01-secrets-problem-vault.md)); версию чарта Vault сверь: проверь актуальную версию на странице проекта. Источники лежат в `flux-system`, релизы ставят чарты в свои namespace:

   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata: {name: envoy-gateway, namespace: flux-system}
   spec: {type: oci, interval: 1h, url: "oci://docker.io/envoyproxy"}   # чарт в OCI-реестре
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata: {name: external-secrets, namespace: flux-system}
   spec: {interval: 1h, url: "https://charts.external-secrets.io"}
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata: {name: hashicorp, namespace: flux-system}
   spec: {interval: 1h, url: "https://helm.releases.hashicorp.com"}
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata: {name: envoy-gateway, namespace: flux-system}
   spec:
     interval: 10m
     targetNamespace: envoy-gateway-system
     install: {createNamespace: true, crds: CreateReplace}
     upgrade: {crds: CreateReplace}
     chart:
       spec: {chart: gateway-helm, version: "1.9.2", sourceRef: {kind: HelmRepository, name: envoy-gateway}}
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata: {name: external-secrets, namespace: flux-system}
   spec:
     interval: 10m
     targetNamespace: external-secrets
     install: {createNamespace: true}
     chart:
       spec: {chart: external-secrets, version: "2.11.0", sourceRef: {kind: HelmRepository, name: external-secrets}}
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata: {name: vault, namespace: flux-system}
   spec:
     interval: 10m
     targetNamespace: vault
     install: {createNamespace: true}
     chart:
       spec: {chart: vault, version: "0.32.0", sourceRef: {kind: HelmRepository, name: hashicorp}}
     values:
       server: {standalone: {enabled: true}, dataStorage: {size: 1Gi}}
   ```

3. Список ресурсов слоя (`kustomization.yaml` из [урока 5.10](../05-kubernetes/10-kustomize.md)):

   ```bash
   cat > infrastructure/controllers/kustomization.yaml <<'YAML'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - releases.yaml
   YAML
   ```

4. Конфиги платформы. Namespace и Gateway берём из своего проекта как есть, `ClusterSecretStore` тоже:

   ```bash
   cat ~/notes/k8s/base/00-namespace.yaml \
       ~/notes/k8s/base/30-envoyproxy.yaml \
       ~/notes/k8s/base/31-gateway.yaml > infrastructure/configs/gateway.yaml
   cp ~/notes/k8s/platform/clustersecretstore.yaml infrastructure/configs/clustersecretstore.yaml
   cat > infrastructure/configs/kustomization.yaml <<'YAML'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - gateway.yaml
     - clustersecretstore.yaml
   YAML
   ```

   Namespace `notes` теперь создаёт Flux, а не ты.

5. Три Flux-`Kustomization` в `clusters/kind/` (у первого нет зависимостей, у остальных `dependsOn` на предыдущий):

   ```bash
   mk() {  # имя, путь, зависимость, wait
     { echo "apiVersion: kustomize.toolkit.fluxcd.io/v1"
       echo "kind: Kustomization"
       echo "metadata: {name: $1, namespace: flux-system}"
       echo "spec:"
       echo "  interval: 10m"
       echo "  path: $2"
       echo "  prune: true"
       echo "  wait: true          # Ready только когда ресурсы реально готовы"
       echo "  timeout: 10m"
       [ -n "$3" ] && printf '  dependsOn:\n    - name: %s\n' "$3"
       echo "  sourceRef: {kind: GitRepository, name: flux-system}"
     } > "clusters/kind/$1.yaml"; }
   mk infrastructure ./infrastructure/controllers ""
   mk infrastructure-config ./infrastructure/configs infrastructure
   mk apps ./apps/notes infrastructure-config
   cat clusters/kind/apps.yaml
   ```

6. Положи заглушку и запушь. `apps/notes/kustomization.yaml` пока с пустым списком ресурсов:

   ```bash
   printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' > apps/notes/kustomization.yaml
   git add -A && git commit -m "Инфраструктура платформы и слои dependsOn" && git push
   flux reconcile source git flux-system
   flux get kustomizations --watch
   ```

**Что должно получиться:** через несколько минут (на первом запуске скачиваются образы):

```text
NAME                   REVISION           SUSPENDED  READY  MESSAGE
flux-system            main@sha1:8d2e0c4  False      True   Applied revision: main@sha1:8d2e0c4
infrastructure         main@sha1:8d2e0c4  False      True   Applied revision: main@sha1:8d2e0c4
...                    (и так для infrastructure-config и apps: все READY True)
```

Затем `kubectl get gateway -n notes` показывает `notes-gw`, а под Vault `0/1`: он запечатан, это нормально.

**Объясни себе:**

- Что дал `wait: true` в `infrastructure` и почему `dependsOn` без него слабее?

**Типичные ошибки:**

- `kustomization path not found: stat /tmp/kustomization-.../infrastructure/controllers: no such file or directory`: путь в `spec.path` не совпадает с каталогом в репозитории или файлы не запушены: сверь путь и `git push`.
- `dependency 'flux-system/infrastructure' is not ready` долго висит: сама зависимость упала, смотри `flux get kustomization infrastructure` и `flux get helmreleases -A`, а не dependent.
- `no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"`: CRD Gateway API ещё не установлены, то есть `infrastructure` не готов или `dependsOn` не задан.

### Задание 3. Приложение через HelmRelease, изменение и дрейф

**Цель:** отдать «Заметки» под управление Flux, поменять реплики через git и убедиться, что ручные правки откатываются.

**Предскажи:** ты выполнишь `kubectl scale deployment notes -n notes --replicas=10`. Сколько реплик будет через пару минут и почему? А если изменить `replicaCount` в git?

<details markdown="1">
<summary>Ответ</summary>

Если включён `driftDetection`, вернётся к значению из values (три): helm-controller заметит расхождение и исправит. Через git реплики станут теми, что записаны в коммите, и в `git log` останется след, кто и когда это решил.

</details>

**Шаги:**

1. Упакуй чарт и опубликуй в OCI-реестр ghcr.io (версия чарта 0.4.0, appVersion 0.7.0):

   ```bash
   cd ~/notes
   helm package helm/notes --destination /tmp
   echo "$GITHUB_TOKEN" | helm registry login ghcr.io -u "$GITHUB_USER" --password-stdin
   helm push /tmp/notes-0.4.0.tgz "oci://ghcr.io/${GITHUB_USER}/charts"
   ```

   Токену для записи пакетов нужно право `write:packages` (для fine-grained токена GitHub Packages не подходит, используй classic PAT только с этим правом). В GitHub открой пакет `charts/notes` и сделай его публичным (Package settings, Change visibility), иначе Flux не сможет его скачать без секрета.

2. Пропиши приложение. `~/notes-gitops/apps/notes/release.yaml` (подставь свой логин вместо `<github-user>`):

   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata: {name: notes, namespace: notes}
   spec: {type: oci, interval: 10m, url: "oci://ghcr.io/<github-user>/charts"}
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata: {name: notes, namespace: notes}
   spec:
     interval: 5m
     chart:
       spec: {chart: notes, version: "0.4.0", sourceRef: {kind: HelmRepository, name: notes}}
     install: {remediation: {retries: 3}}
     upgrade: {remediation: {retries: 3}}
     driftDetection: {mode: enabled}      # откатывать ручные правки ресурсов релиза
     values:
       replicaCount: 3
       image: {repository: "ghcr.io/<github-user>/notes", tag: "0.7.0"}
       externalSecret: {enabled: true}
   ```

3. Подключи файл и запушь:

   ```bash
   cd ~/notes-gitops
   cat > apps/notes/kustomization.yaml <<'YAML'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - release.yaml
   YAML
   git add -A && git commit -m "Приложение notes через HelmRelease" && git push
   flux reconcile kustomization apps --with-source
   flux get helmreleases -n notes
   ```

4. Vault на новом кластере пуст и запечатан, а это состояние, а не конфигурация, в git его нет. Инициализируй как в 9.1 (`scripts/seed-vault.sh`), затем проверь ESO:

   ```bash
   cd ~/notes && bash scripts/seed-vault.sh
   kubectl get externalsecret -n notes
   kubectl get pods -n notes
   ```

   Секрет `notes-tls` из [урока 5.4](../05-kubernetes/04-ingress-gateway.md) создаётся командой и в git не хранится (автоматически им займётся cert-manager в уроке 9.4). Создай его командой из своей заметки 5.4, если Gateway жалуется на его отсутствие.

5. Измени реплики через git (GNU `sed`; на macOS `sed -i ''`):

   ```bash
   cd ~/notes-gitops
   sed -i 's/replicaCount: 3/replicaCount: 4/' apps/notes/release.yaml
   git commit -am "Реплик notes: 4" && git push
   flux reconcile kustomization apps --with-source
   kubectl get deployment notes -n notes
   ```

6. Теперь вмешайся руками, как в инциденте:

   ```bash
   kubectl scale deployment notes -n notes --replicas=10
   kubectl get deployment notes -n notes
   sleep 90
   kubectl get deployment notes -n notes
   ```

7. Сломай тег образа и откати через историю (`git revert`, а не правка поверх):

   ```bash
   sed -i 's/tag: "0.7.0"/tag: "9.9.9"/' apps/notes/release.yaml
   git commit -am "Плохой тег образа" && git push
   flux reconcile kustomization apps --with-source
   flux get helmreleases -n notes           # Ready=False, старые поды живы
   git revert --no-edit HEAD && git push
   flux reconcile kustomization apps --with-source
   ```

**Что должно получиться:** после шага 3 релиз `Ready`, после шага 5 в Deployment 4/4, после шага 6 сначала `10/10`, затем снова `4/4`. На шаге 7 релиз `Ready=False` (старые поды продолжают отвечать, rolling update из [урока 5.7](../05-kubernetes/07-probes-resources-rollouts.md)), после `revert` снова `Ready=True`, а в `git log` две записи.

```text
NAME        REVISION  SUSPENDED  READY  MESSAGE
notes       0.4.0     False      True   Helm install succeeded for release notes/notes.v1 with chart notes@0.4.0
```

**Объясни себе:**

- Чем `HelmRelease` отличается от ручного `helm install`, и где теперь хранится история релиза?
- Почему без `driftDetection` ручной `scale` мог бы остаться до следующего изменения values?
- Чем `git revert` лучше `push --force` на общей ветке?
- Кому в схеме GitOps остаются права на изменение кластера, а кому нет?

**Типичные ошибки:**

- `failed to get chart version for HelmChart 'notes/notes-notes': failed to fetch ... 401 Unauthorized` или `denied`: пакет в ghcr.io приватный, сделай его публичным или добавь `secretRef` с токеном.
- `ExternalSecret ... SecretSyncedError`: Vault запечатан или не засеян, вернись к шагу 4 (детали в [уроке 9.2](02-vault-k8s-eso.md)).

### Задание 4. Шаг проекта: репозиторий notes-gitops как источник правды

**Цель:** закрепить состояние проекта: деплой равен merge в `main`, ручных релизов Helm нет, эталон лежит в `~/notes/gitops/`.

**Предскажи:** что покажет `helm list -A` на кластере, где всё поставил Flux?

<details markdown="1">
<summary>Ответ</summary>

Релизы будут (`envoy-gateway`, `external-secrets`, `vault`, `notes`): helm-controller использует Helm внутри. Но их создал Flux, и у каждого есть `HelmRelease` в git.

</details>

**Шаги:**

1. Проверь, что кластер полностью собран из git:

   ```bash
   flux get all -A
   helm list -A
   ```

2. Зеркало эталона в основном репозитории (репозиторий `~/notes` остаётся единственным на курс, а `notes-gitops` служит источником для Flux):

   ```bash
   mkdir -p ~/notes/gitops
   rsync -a --exclude .git ~/notes-gitops/ ~/notes/gitops/
   cd ~/notes && git add gitops && git commit -m "gitops: зеркало репозитория notes-gitops (урок 9.3)"
   ```

**Что должно получиться:** `flux get all` без `False` в колонке READY, `helm list` показывает четыре релиза, а у каждого есть `HelmRelease` в git.

```text
NAME   NAMESPACE  REVISION  STATUS    CHART        APP VERSION
notes  notes      1         deployed  notes-0.4.0  0.7.0
```

Состояние проекта: репозиторий `notes-gitops` с каталогами `clusters/kind`, `infrastructure`, `apps/notes`, Flux v2.9.5, цепочка `dependsOn` от controllers к configs и apps. Эталон: [gitops/](https://github.com/distinguished-sre/devops/tree/devops/project/notes/gitops). Долг: сертификат `notes-tls` создан командой (закроет 9.4), Postgres пока StatefulSet (закроет 9.5).

**Объясни себе:**

- Почему деплой нового релиза теперь выглядит как PR в `notes-gitops`, а не `helm upgrade`?

**Типичные ошибки:**

### Дополнительно: Argo CD (необязательно, вне цепочки проекта)

Для сравнения поставь Argo CD v3.5.3 в отдельный namespace, открой UI через `kubectl -n argocd port-forward svc/argocd-server 8081:443` и создай `Application` на каталог `apps/notes`. Установка: `kubectl create namespace argocd`, затем `kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml`. Пароль `admin` читай из секрета `argocd-initial-admin-secret` и нигде не сохраняй. Убери эксперимент: `kubectl delete namespace argocd`.

## Сломай и почини

Скрипт ломает стенд одним из четырёх способов. Запусти из `~/notes`, не читая его:

```bash
bash break/9.3/break.sh 1     # номер от 1 до 4, или random
```

### Симптом

Ты ничего не менял в git, но после действия `flux get all -A` показывает `READY False` или изменение из git не доезжает до кластера.

### Гипотезы

Сформулируй по симптому до проверок: не может прочитать репозиторий (доступ), не находит путь (структура), не ставится чарт (values, образ, реестр), ресурс есть, но правится руками (дрейф). Подумай, какой контроллер отвечает за каждый случай.

### Проверки

```bash
flux get all -A                                   # где именно False
flux logs --level=error --since=10m               # ошибки всех контроллеров
kubectl describe gitrepository flux-system -n flux-system
kubectl describe helmrelease notes -n notes
```

### Исправление

Почини командой `bash break/9.3/fix.sh` только после собственной попытки. Разбор сценариев:

<details markdown="1">
<summary>1. GitRepository: authentication required</summary>

Симптом: `flux get sources git` показывает `False` и `authentication required`. Причина: deploy key или токен отозваны, либо репозиторий стал приватным без секрета. Исправление: `flux create secret git ...` или повторный `flux bootstrap github` (он идемпотентный и пересоздаст ключ), затем `flux reconcile source git flux-system`.

</details>

<details markdown="1">
<summary>2. HelmRelease: install retries exhausted</summary>

Симптом: `Helm install failed ... install retries exhausted`, `Ready=False`. Причина в этом сценарии: неверная версия чарта или values. Проверка: `flux logs --kind=HelmRelease --name=notes -n notes`, `helm show values` соответствующего чарта, `kubectl describe pod` (тег образа, ошибки пробы). Исправление: правка в git, затем `flux reconcile helmrelease notes -n notes --reset`, чтобы сбросить счётчик ретраев (после исчерпания он сам не пробует заново).

</details>

<details markdown="1">
<summary>3. kustomization path not found</summary>

Симптом: `kustomization path not found: stat .../apps/notes: no such file or directory`. Причина: каталог переименован или `spec.path` в `apps.yaml` указывает на несуществующий. Проверка: `git ls-tree -r main --name-only` и `kubectl get kustomization apps -n flux-system -o yaml`. Исправление: привести путь и каталог в соответствие и запушить. Зависимые Kustomization при этом остаются в `not ready`.

</details>

<details markdown="1">
<summary>4. Ручной kubectl edit затирается</summary>

Симптом: ты поправил Deployment или ConfigMap руками, и через минуты правка исчезла. Это не поломка, а штатное поведение: git главнее. Проверка: `flux events --for HelmRelease/notes -n notes` покажет `drift detected`. Исправление: вносить правку в git; если нужна временная ручная работа, `flux suspend kustomization apps`, а после `flux resume kustomization apps`.

</details>

## Вопросы с собеседований

### 1. [junior] Чем GitOps отличается от обычного CI/CD с деплоем из пайплайна?

В обычном CI/CD пайплайн толкает изменения в кластер (push). В GitOps агент внутри кластера сам тянет желаемое состояние из git (pull) и постоянно сверяет с фактом. Деплой равен merge, откат равен revert, а история в git.

**Что хотят услышать:** pull против push, у CI нет прав на кластер, постоянный reconcile и исправление дрейфа, аудит через git.

**Красный флаг:** "это когда манифесты лежат в git" без слов про агента и сверку.

### 2. [middle] Через минуту после `kubectl scale` число реплик вернулось. Что происходит и что делать?

Это reconcile: Flux сравнил кластер с git и вернул записанное. Значит, число реплик задаётся в git. Я меняю `replicaCount` в values через PR. Если нужна временная ручная правка на время инцидента, приостанавливаю `Kustomization` и обязательно возвращаю.

**Что хотят услышать:** drift detection, `flux suspend/resume`, источник правды в git, HPA как исключение (реплики под контролем автоскейлера).

**Красный флаг:** "отключу Flux совсем" или "буду править быстрее, чем он откатывает".

### 3. [middle] В git закоммитили плохое значение, `HelmRelease` в `Ready=False`. Твои действия?

Смотрю `flux get helmreleases`, `flux logs` и `kubectl describe`, определяю коммит. Восстанавливаю сервис через `git revert` плохого коммита, а не правкой поверх. Проверяю, что старые поды живы и релиз вернулся в `Ready`. Потом разбираю, почему проверка не поймала ошибку.

**Что хотят услышать:** revert, а не force-push; rolling update сохраняет старые поды; `--reset` после исчерпания ретраев; ревью и CI на PR.

**Красный флаг:** "зайду на кластер и починю руками" или `push --force` в `main`.

### 4. [middle] На чистом кластере часть приложений падает с `no matches for kind`, но через десять минут всё само проходит. Почему?

Ресурсы применялись раньше, чем контроллер установил свои CRD. Со временем ретраи сходятся. Правильно разделить на слои: контроллеры, конфиги, приложения и связать через `dependsOn` с `wait: true`.

**Что хотят услышать:** CRD и порядок, `dependsOn` ждёт `Ready`, разделение `infrastructure` и `infrastructure-config`.

**Красный флаг:** "поставлю `sleep` в скрипте" или "применю два раза".

### 5. [middle] Ты удалил файл из git, а ресурс в кластере остался. Почему и как правильно?

Скорее всего, у `Kustomization` выключен `prune`. С `prune: true` Flux удаляет то, чего больше нет в git (по инвентарю ресурсов, который он ведёт сам). Надо включить `prune` и удалить осиротевший ресурс, понимая риск: удаление PVC или БД из git удалит данные.

**Что хотят услышать:** prune и инвентарь, осторожность с данными (аннотация `kustomize.toolkit.fluxcd.io/prune: disabled` на важных ресурсах).

**Красный флаг:** "удалю руками и забуду".

### 6. [middle] Как хранить секреты при GitOps, если в git нельзя класть пароли?

Использую внешнее хранилище: Vault и External Secrets Operator, в git лежит только `ExternalSecret` со ссылкой на путь. Второй вариант: шифрование файлов (SOPS с ключом age или KMS), Flux расшифровывает при применении. Значение секрета в открытом виде в git не хранится никогда.

**Что хотят услышать:** ESO или SOPS, ротация без коммита (ESO), base64 не шифрование, доступ к ключу расшифровки только у Flux.

**Красный флаг:** "закоммичу Secret в приватный репозиторий".

### 7. [middle] Flux или Argo CD: что выберешь и почему?

Зависит от команды. Argo CD даёт веб-UI, дерево ресурсов, `ApplicationSet` для многих кластеров и удобен, когда деплоем занимаются разные команды. Flux легче, набор контроллеров без своего UI, тесно работает с Helm и Kustomize, хорош для платформенных команд. Оба зрелые, лучше выбирать по потребности в панели и по опыту команды.

**Что хотят услышать:** конкретные различия (UI, ApplicationSet, контроллеры), а не "Argo лучше".

**Красный флаг:** "не знаю, слышал только про один".

### 8. [middle] Один репозиторий для кода и манифестов или два?

Обычно два: `notes` (код, CI собирает образ) и `notes-gitops` (желаемое состояние). У них разные права, ритм изменений и история: коммиты с обновлением версии не засоряют историю кода, а доступ к манифестам можно ограничить. Для маленькой команды монорепо допустимо, но тогда путь в `Kustomization` и триггеры CI нужно настроить так, чтобы изменения манифестов не пересобирали образ.

**Что хотят услышать:** разделение ответственности, окружения через каталоги или ветки, компромисс для маленькой команды.

**Красный флаг:** "потому что так принято".

### 9. [middle] `HelmRelease` завис в `Reconciling`, потом стал `install retries exhausted`. Как диагностируешь?

Смотрю `flux logs --kind=HelmRelease`, затем `helm history` и события неймспейса. Проверяю, скачался ли чарт (`HelmRepository`, доступ к OCI), отрендерился ли (values), стартовали ли поды (образ, пробы, ресурсы). После правки в git делаю `flux reconcile helmrelease --reset`, потому что после исчерпания ретраев Flux сам не пробует заново.

**Что хотят услышать:** цепочка источник, рендер, поды, `--reset`, разница между ошибкой Flux и ошибкой приложения.

**Красный флаг:** "удалю `HelmRelease` и создам заново" без диагностики.

### 10. [middle] Как GitOps помогает восстановить кластер после катастрофы, и чего он не восстановит?

Новый кластер, `flux bootstrap` на тот же репозиторий, и всё описанное в git разворачивается само. Не восстановится состояние: содержимое БД и PVC, данные и ключи Vault, секреты, созданные вручную. Для них нужны отдельные бэкапы и restore drill.

**Что хотят услышать:** конфигурация против состояния, бэкапы данных, unseal-ключи Vault хранятся отдельно, проверенное восстановление.

**Красный флаг:** "у нас всё в git, значит, бэкапы не нужны".

## Проверено на версиях

- Flux: v2.9.5, Argo CD: v3.5.3 (только необязательный раздел)
- Envoy Gateway: v1.9.2
- External Secrets Operator: v2.11.0
- Vault: v2.1.1, чарт HashiCorp: версия не закреплена, проверь актуальную версию на странице проекта
- Helm: v4.3.0
- kind: v0.33.0
- Чарт `notes`: 0.4.0, appVersion 0.7.0

## Итог урока: ты умеешь

- [ ] умею объяснить разницу push и pull и правила GitOps
- [ ] умею установить flux CLI со сверкой SHA256 и выполнить `flux bootstrap github`
- [ ] умею разложить репозиторий на `clusters`, `infrastructure`, `apps` и связать слои через `dependsOn`
- [ ] умею описать приложение как `HelmRelease` из OCI-чарта и менять его через git
- [ ] умею показать drift и объяснить, почему ручные правки затираются
- [ ] умею откатить плохой релиз через `git revert` и сбросить ретраи `--reset`
- [ ] умею диагностировать сбой цепочкой `flux get all`, `flux logs`, `kubectl describe`

**Дальше:** [Урок 9.4: cert-manager: TLS-сертификаты автоматически](04-cert-manager-tls.md)
