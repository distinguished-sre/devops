---
layout: lesson
title: "Платформа целиком: разбор и слабые места"
topic: 9
lesson: "9.7"
time: "2 ч"
---

## Зачем это нужно

К этому моменту у «Заметок» есть Vault, Flux, cert-manager, оператор PostgreSQL, canary-релизы и мониторинг. Каждый кусок ты собирал отдельно. На собеседовании и на дежурстве спрашивают другое: как это работает вместе, что будет, если кластер пропадёт, и какие дыры остались. Кто не может нарисовать цепочку целиком и назвать свои долги, тот платформу не понимает, а только повторяет команды.

В этом уроке ты нарисуешь всю цепочку от коммита до алерта, докажешь, что кластер восстанавливается из git за измеренное время, закроешь одну дыру admission-политикой (admission policy) и честно перечислишь то, что осталось.

Шаг проекта: в «Заметках» появляются `docs/architecture.md` с диаграммой и долгами, `docs/threat-model.md` и политика `vap-no-latest-tag.yaml`.

## Что нужно знать

- [Урок 3.3: CI](../03-git-ci/03-actions-ci.md) - откуда берётся образ и тег
- [Урок 5.4: Gateway API](../05-kubernetes/04-ingress-gateway.md) - как трафик попадает в кластер
- [Урок 8.5: алерты](../08-observability/05-alertmanager.md) - чем заканчивается цепочка
- [Урок 9.1: Vault](01-secrets-problem-vault.md) - `seed-vault.sh`, unseal-ключи вне репозитория
- [Урок 9.2: ESO](02-vault-k8s-eso.md) - как секрет попадает в под
- [Урок 9.3: Flux](03-gitops-flux.md) - `dependsOn` и bootstrap
- [Урок 9.5: CloudNativePG](05-cnpg.md) - где лежат данные
- [Урок 9.6: Argo Rollouts](06-progressive-delivery.md) - как релиз откатывается сам

## Теория

### Вся цепочка на одной схеме

Схема нужна не для красоты. По ней ты отвечаешь на вопрос «где может сломаться и кто это заметит». У «Заметок» цепочка такая:

```text
разработчик
   |  git push / PR
   v
GitHub (код app + gitops-репозиторий)
   |  CI: тесты, линтер, сборка образа, Trivy
   v
реестр образов ghcr.io  (notes:0.7.1, тег неизменяемый)
   |
   |   Flux (source, kustomize, helm controllers) тянет из git
   v
кластер kind "notes"
   |-- controllers: Envoy Gateway, ESO, Vault, cert-manager, CNPG, Argo Rollouts
   |-- configs:     Gateway, ClusterSecretStore, ClusterIssuer, политики
   |-- apps:        HelmRelease notes, Cluster notes-db, ExternalSecret
   v
пользователь -> Gateway 443 (TLS от cert-manager) -> Rollout notes -> notes-db-rw

Vault --(ESO)--> Secret notes-db --> под
Prometheus/Loki/Tempo <-- метрики, логи, трейсы из подов
Prometheus --> Alertmanager --> дежурный
Prometheus --> AnalysisTemplate --> Argo Rollouts (откат canary)
```

Главное свойство: изменения идут в одну сторону, из git в кластер (pull, кластер сам забирает состояние). Исключение одно: секреты и данные. Их в git нет, и это сознательно. Из этого вытекает всё остальное в уроке: чтобы восстановить кластер, нужны git, Vault и бэкап данных. Без любого из трёх ты восстановишь только часть.

> **Проверь понимание:** назови три вещи, которых нет в git, но без которых платформа не поднимется.

<details>
<summary>Ответ</summary>

Значения секретов в Vault, unseal-ключи и root-токен Vault (лежат в `~/.notes-secrets/`), данные PostgreSQL (в PVC и в бэкапах MinIO). Ещё токен для `flux bootstrap`, но его можно выпустить заново.

</details>

### Порядок восстановления и dependsOn

Когда кластер создан заново, Flux применяет всё сразу, но зависимости обязаны сходиться в правильном порядке. В `clusters/kind/` три Kustomization: `infrastructure` (контроллеры), `infrastructure-config` (ресурсы, которым нужны CRD контроллеров), `apps` (приложение). Связаны они через `dependsOn`.

Почему нельзя положить всё в одну Kustomization? Ресурс `ClusterIssuer` нельзя применить, пока cert-manager не установил CRD. Kubernetes ответит `no matches for kind "ClusterIssuer"`. Flux повторит попытку, но приложение, зависящее от сертификата, уже могло стартовать в неправильном порядке. `dependsOn` даёт гарантию: следующая ступень ждёт, пока предыдущая станет Ready.

Есть и третий слой зависимостей, который `dependsOn` не видит: данные. ExternalSecret ссылается на Vault, а Vault после нового bootstrap пуст и запечатан (sealed). Значит, после создания кластера человек должен один раз выполнить `seed-vault.sh`. Это ручной шаг, и он входит в «время восстановления».

### Admission-политика: запретить проблему на входе

Admission controller (контроллер допуска) проверяет объект в момент, когда его создают или меняют, до записи в etcd. Так можно сказать «нет» ещё до того, как под запустится. В Kubernetes есть встроенный механизм: ValidatingAdmissionPolicy (VAP), правило пишется на языке CEL (Common Expression Language), устанавливать ничего не нужно.

Политика состоит из двух объектов: сама политика (что проверять и какое выражение считается нарушением) и привязка ValidatingAdmissionPolicyBinding (к каким namespace применять и что делать: отказать или только предупредить).

Kyverno и OPA Gatekeeper делают то же самое мощнее: умеют менять объекты (mutate), генерировать ресурсы, проверять подписи образов. Ценой становится ещё один компонент кластера, который сам может стать точкой отказа. Для одного простого правила встроенной VAP достаточно. В уроке Kyverno не ставим, только знаем, где он нужен.

### Цепочка поставки: что защищает образ

Supply chain (цепочка поставки) - всё, что происходит от коммита до запущенного контейнера. Атаковать можно любое звено: подменить зависимость, отравить CI, перезаписать тег в реестре. Три инструмента закрывают разные звенья, и в курсе они только обзорные.

- Trivy (уже в CI, [урок 3.3](../03-git-ci/03-actions-ci.md)) ищет известные уязвимости в образе и конфигах.
- SBOM (Software Bill of Materials, перечень компонентов образа) отвечает на вопрос «где у нас библиотека X», когда выходит новая CVE.
- cosign подписывает образ ключом или через OIDC-идентичность CI (keyless). Проверка подписи при деплое гарантирует, что в кластер попал образ, собранный вашим CI, а не подложенный.

Проверка подписи в кластере делается admission-контроллером, например Kyverno с правилом `verifyImages`. Встроенная VAP подписи проверять не умеет. Поэтому в нашей платформе подписи нет, и это записано в долги.

### Threat model: STRIDE за пять минут

Threat model (модель угроз) - список того, что может пойти не так по злому умыслу, и что с этим сделано. STRIDE это шесть категорий: Spoofing (подмена личности), Tampering (порча данных), Repudiation (отказ от авторства), Information disclosure (утечка), Denial of service (отказ в обслуживании), Elevation of privilege (повышение прав). Идёшь по компонентам схемы и для каждой категории спрашиваешь «может ли случиться здесь». Результат: таблица «угроза, что закрыто, что осталось».

Модель угроз не даёт нулевого риска. Она нужна, чтобы остаточный риск был выбран осознанно и записан, а не обнаружен во время инцидента.

> **Проверь понимание:** чем остаточный риск отличается от долга?

<details>
<summary>Ответ</summary>

Остаточный риск принят осознанно и записан вместе с причиной («MinIO без репликации, для учебного стенда допустимо»). Долг - то, что нужно закрыть до прода, и у него есть способ закрытия. На практике одна запись часто содержит оба: что не закрыто и что надо сделать в проде.

</details>

## Практика

### Задание 1. Нарисуй платформу и найди точки отказа

**Цель:** получить `docs/architecture.md` с диаграммой и списком точек отказа.

**Предскажи:** сколько компонентов из схемы выше можно потерять, не потеряв данные, если всё описано в git?

<details>
<summary>Ответ</summary>

Почти все: контроллеры, конфиги, само приложение пересоздаются из git. Данные теряются только там, где есть состояние: PVC Vault, PVC PostgreSQL, MinIO. Это и есть «точки потери данных».

</details>

**Шаги:**

1. Создай файл документа.
2. Перерисуй схему из теории своими словами, добавь порты и namespace.
3. Отдельным списком выпиши, где хранится состояние.

```bash
cd ~/notes
mkdir -p docs
cat > docs/architecture.md <<'EOF'
# Архитектура платформы «Заметки»

## Цепочка

git -> CI (тесты, Trivy, сборка) -> ghcr.io/<github-user>/notes:0.7.1
git (notes-gitops) -> Flux -> кластер kind "notes" (контекст kind-notes)

Порядок в кластере (dependsOn):
1. infrastructure        контроллеры: Envoy Gateway, ESO, Vault, cert-manager, CNPG, Argo Rollouts
2. infrastructure-config Gateway, ClusterSecretStore, ClusterIssuer, политики
3. apps                  HelmRelease notes, Cluster notes-db, ExternalSecret

Трафик: клиент -> Gateway :443 (notes.lab, cert-manager) -> Rollout notes :8080 -> notes-db-rw :5432
Секрет: Vault secret/notes/db -> ESO -> Secret notes-db -> под
Наблюдаемость: метрики Prometheus, логи Loki, трейсы Tempo, алерты Alertmanager

## Где живёт состояние (нет в git)

| Что | Где | Как восстановить |
|---|---|---|
| Секреты | PVC Vault, ns vault | seed-vault.sh, ключи в ~/.notes-secrets/ |
| Данные БД | PVC CNPG, бэкапы в MinIO | восстановление из бэкапа (урок 10.3) |
| Бэкапы | PVC MinIO | нет копии, см. долги |

## Долги

(заполнится в задании 5)
EOF
wc -l docs/architecture.md
```

**Что должно получиться:**

```text
32 docs/architecture.md
```

Число строк может отличаться на несколько, главное, что файл создан и раздел «Долги» на месте.

**Объясни себе:**

- Почему у секретов и данных разный способ восстановления, хотя оба не в git?
- Какая ступень `dependsOn` отвечает за появление CRD?

**Типичные ошибки:**

- `bash: docs/architecture.md: No such file or directory`: не создан каталог `docs`. Сначала `mkdir -p docs`.
- Диаграмма съезжает при просмотре на сайте: обёрнута не в блок `text`. Оберни в тройные кавычки с языком `text`.

### Задание 2. День разрушения: восстанавливаем кластер из git

**Цель:** удалить кластер и поднять его заново из git и Vault, замерив время.

**Предскажи:** после `kind delete cluster` и повторного bootstrap приложение поднимется само? Что придётся сделать руками?

<details>
<summary>Ответ</summary>

Всё описанное в git поднимется само, порядок задаст `dependsOn`. Руками нужно: создать кластер, выполнить `flux bootstrap`, запустить `seed-vault.sh` (Vault пуст). Данные PostgreSQL в новом кластере пусты: восстановление из бэкапа отдельный шаг (урок 10.3).

</details>

**Шаги:**

1. Убедись, что unseal-ключи на месте: без них старый Vault не нужен, но проверить полезно.
2. Удали кластер и создай заново, замеряя время.
3. Выполни bootstrap и seed.

```bash
# Токен для Flux (только в переменной окружения, значение не печатай)
source ~/.notes-secrets/github.env   # экспортирует GITHUB_TOKEN и GITHUB_USER
ls -l ~/.notes-secrets/vault-init.json

# Замер начинается здесь
START=$(date +%s)

kind delete cluster --name notes
kind create cluster --config kind/kind.yaml

flux bootstrap github \
  --owner="$GITHUB_USER" \
  --repository=notes-gitops \
  --branch=main \
  --path=clusters/kind \
  --personal

# Ждём, пока все ступени станут Ready
kubectl -n flux-system wait kustomization/infrastructure --for=condition=Ready --timeout=15m
```

Когда контроллеры готовы, Vault нужно инициализировать заново, потому что его PVC создан в новом кластере.

```bash
kubectl -n vault wait pod/vault-0 --for=condition=Initialized --timeout=5m
bash scripts/seed-vault.sh

kubectl -n flux-system wait kustomization/apps --for=condition=Ready --timeout=15m
END=$(date +%s)
echo "Восстановление заняло $(( (END - START) / 60 )) мин"
```

Проверка результата:

```bash
flux get kustomizations
kubectl -n notes get pods
curl -sk --resolve notes.lab:443:127.0.0.1 https://notes.lab/health
```

**Что должно получиться:**

```text
NAME                    REVISION        SUSPENDED       READY   MESSAGE
apps                    main@sha1:3f2a1c9   False       True    Applied revision: main@sha1:3f2a1c9
flux-system             main@sha1:3f2a1c9   False       True    Applied revision: main@sha1:3f2a1c9
infrastructure          main@sha1:3f2a1c9   False       True    Applied revision: main@sha1:3f2a1c9
infrastructure-config   main@sha1:3f2a1c9   False       True    Applied revision: main@sha1:3f2a1c9
NAME                     READY   STATUS    RESTARTS   AGE
notes-6d8f7c9b5-x2k4q    1/1     Running   0          2m
notes-db-1               1/1     Running   0          4m
{"status":"ok"}
Восстановление заняло 17 мин
```

Время у тебя будет своё: от 12 до 25 минут, зависит от скорости сети (скачиваются образы). Запиши своё число в `docs/architecture.md`: это твой измеренный RTO (Recovery Time Objective, целевое время восстановления) для учебного стенда. Как оформлять RTO и RPO, разбираем в [уроке 10.3](../10-capstone/03-backup-dr-capacity.md).

**Объясни себе:**

- Что из 17 минут заняло ожидание, а что ручные действия? Что можно автоматизировать?
- Почему данные в таблице `notes` пусты после восстановления и что должно их вернуть?
- Что было бы, если бы `seed-vault.sh` не был идемпотентным?

**Типичные ошибки:**

- `✗ failed to clone repository: authentication required`: токен не экспортирован или без прав `repo`. Проверь `echo ${GITHUB_TOKEN:+задан}` и права токена.
- `ERROR: failed to create cluster: node(s) already exist for a cluster with the name "notes"`: старый кластер не удалён. Выполни `kind delete cluster --name notes`.
- `Error from server (NotFound): pods "vault-0" not found`: контроллеры ещё не применились. Подожди `infrastructure` Ready и повтори.

### Задание 3. Политика: запретить latest

**Цель:** запретить в namespace `notes` образы с тегом `latest` и без тега, доставив политику через git.

**Предскажи:** попытка создать под с `image: nginx:latest` вернёт ошибку от API или под создастся и упадёт позже?

<details>
<summary>Ответ</summary>

Ошибку вернёт сам API-сервер сразу, под даже не будет записан в etcd. Это отличие admission от проверок в CI: политика работает на любом пути в кластер, в том числе для ручного `kubectl run`.

</details>

**Шаги:**

1. Добавь файл политики в репозиторий `notes-gitops` (эталон лежит в `project/notes/gitops/`).
2. Подключи его в `kustomization.yaml` каталога `configs`.
3. Запушь и дождись применения Flux.

```yaml
# gitops/infrastructure/configs/policies/vap-no-latest-tag.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: no-latest-tag
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    # Образ должен иметь digest или явный тег, и тег не latest
    - expression: >-
        object.spec.containers.all(c,
          c.image.contains('@') ||
          (c.image.contains(':') && !c.image.endsWith(':latest')))
      message: "Образ без тега или с тегом latest запрещён: укажи semver-тег или digest"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: no-latest-tag
spec:
  policyName: no-latest-tag
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: notes
```

```bash
cd ~/notes-gitops
mkdir -p infrastructure/configs/policies
# (сохрани YAML выше в infrastructure/configs/policies/vap-no-latest-tag.yaml)
# В kustomization.yaml каталога configs добавь строку ресурса:
#   - policies/vap-no-latest-tag.yaml
git add infrastructure/configs
git commit -m "Запретить образы latest в namespace notes"
git push
flux reconcile kustomization infrastructure-config --with-source

kubectl -n notes run bad --image=nginx:latest
kubectl -n notes run ok --image=nginx:1.29.0
kubectl -n notes delete pod ok
```

**Что должно получиться:**

```text
The pods "bad" is invalid: : ValidatingAdmissionPolicy 'no-latest-tag' with binding 'no-latest-tag' denied request: Образ без тега или с тегом latest запрещён: укажи semver-тег или digest
pod/ok created
pod "ok" deleted
```

**Объясни себе:**

- Почему политика привязана только к namespace `notes`, а не ко всему кластеру?
- Что произойдёт с системными подами (`kube-system`), если снять фильтр namespace? Что значит `failurePolicy: Fail`?
- Что политика не ловит? Подумай про образ вида `localhost:5000/notes` без тега.

**Типичные ошибки:**

- `no matches for kind "ValidatingAdmissionPolicy" in version "admissionregistration.k8s.io/v1"`: кластер старше 1.30, VAP там ещё бета. Используй актуальный kind-образ из `kind/kind.yaml`.
- `ValidatingAdmissionPolicy 'no-latest-tag' ... expression ... undeclared reference`: опечатка в CEL. Смотри `kubectl get validatingadmissionpolicy no-latest-tag -o yaml`, поле `status.typeChecking`.
- Политика создана, но `nginx:latest` проходит: у namespace нет метки или `validationActions` равно `Warn`. Проверь `kubectl get ns notes --show-labels` и `kubectl get validatingadmissionpolicybinding no-latest-tag -o yaml`.

### Задание 4. Threat model «Заметок»

**Цель:** составить `docs/threat-model.md` из восьми угроз по STRIDE.

**Предскажи:** какая категория STRIDE закрыта у нас лучше всего, а какая хуже?

<details>
<summary>Ответ</summary>

Лучше всего закрыта утечка секретов (Information disclosure): их нет в git, доступ по политике Vault. Хуже всего Repudiation (аудит): включён ли аудит Vault и kube-apiserver, мы не настраивали, это долг.

</details>

**Шаги:** создай файл, для каждой угрозы заполни «что закрыто» и «что осталось».

```bash
cat > docs/threat-model.md <<'EOF'
# Модель угроз «Заметок» (STRIDE)

| N | Категория | Угроза | Что закрыто | Что осталось |
|---|---|---|---|---|
| 1 | Spoofing | Чужой под читает секрет из Vault | Kubernetes auth: роль notes привязана к ns notes и SA notes | Роль без ограничения по TTL токена |
| 2 | Spoofing | Подмена образа в реестре | Тег semver, Trivy в CI | Нет подписи cosign и проверки при деплое |
| 3 | Tampering | Ручная правка кластера в обход git | Flux откатывает дрейф за интервал reconcile | У людей есть kubectl edit с админскими правами |
| 4 | Repudiation | Неясно, кто выполнил действие | История git, PR-ревью | Нет аудит-лога Vault и apiserver |
| 5 | Info disclosure | Пароль БД в git или образе | Vault + ESO, .env только в dev | Секрет в Secret Kubernetes лежит в etcd без шифрования |
| 6 | Info disclosure | Перехват трафика | TLS на входе от cert-manager | Внутри кластера трафик без mTLS |
| 7 | Denial of service | Шквал запросов или ошибочный релиз | Лимиты ресурсов, canary с авто-откатом | Нет rate limit на Gateway |
| 8 | Elevation of privilege | Контейнер с root или latest-образ | Uid 10001 в образе, VAP против latest | Нет Pod Security Standards restricted и NetworkPolicy по умолчанию |
EOF
grep -c '^| [0-9]' docs/threat-model.md
```

**Что должно получиться:**

```text
8
```

**Объясни себе:**

- Какие строки ты закроешь до прода первыми и почему именно их?
- Чем отличается пункт 4 от пункта 3: где нужна техника, а где процесс?

**Типичные ошибки:**

- `grep: docs/threat-model.md: No such file or directory`: файл создан не из корня репозитория. Перейди в `~/notes`.
- Таблица не рендерится на сайте: нет пустой строки перед таблицей или лишний `|` в тексте ячейки. Экранируй как `\|`.

### Задание 5. Шаг проекта: карта долгов

**Цель:** дописать в `docs/architecture.md` раздел «Долги» и зафиксировать состояние.

**Предскажи:** сколько долгов у тебя получится и сколько из них связано с данными, а не с кодом?

<details>
<summary>Ответ</summary>

Обычно 8-10 долгов, и заметная часть касается данных и восстановления: бэкапы в одном месте, нет проверенного restore, Vault в одном экземпляре. Код приложения в списке редко главный.

</details>

**Шаги:**

1. Замени заглушку в разделе «Долги».
2. Для каждого долга запиши, как закрыть его в проде.
3. Закоммить в репозиторий `~/notes`.

```bash
cd ~/notes
python3 - <<'EOF'
# Заменяем заглушку на список долгов
p = "docs/architecture.md"
s = open(p, encoding="utf-8").read()
debts = """| Долг | Как закрыть в проде |
|---|---|
| Vault в одном экземпляре, 1 ключ из 1 | HA (Raft, 3 узла), Shamir 5 из 3, auto-unseal через облачный KMS |
| MinIO без репликации, бэкапы в одном месте | Объектное хранилище облака, копия в другом регионе |
| Нет подписи образов | cosign keyless в CI, проверка через Kyverno verifyImages |
| Нет SBOM и provenance | Генерация SBOM в CI, хранение рядом с образом |
| Один кластер и одна зона | Второй кластер, GitOps-восстановление, Velero для PVC |
| Нет аудит-логов Vault и apiserver | Включить audit device и audit policy, отправка в Loki |
| Нет Pod Security Standards и NetworkPolicy по умолчанию | Метка restricted на namespace, default-deny |
| Секреты в etcd без шифрования | Encryption at rest, KMS-провайдер |
| RTO измерен один раз в kind | Регулярный restore drill по расписанию (урок 10.3) |
"""
s = s.replace("(заполнится в задании 5)", debts)
open(p, "w", encoding="utf-8").write(s)
EOF
grep -c '^| ' docs/architecture.md
git add docs gitops 2>/dev/null
git commit -m "Платформа целиком: architecture, threat model, политика latest"
git tag v0.7.1-review 2>/dev/null || true
git log --oneline -1
```

**Что должно получиться:**

```text
15
7a3c2d1 Платформа целиком: architecture, threat model, политика latest
```

Хэш у тебя будет другой. Число строк таблиц зависит от того, что ты написал сам.

**Объясни себе:**

- Какой долг самый дорогой, если его не закрыть: потеря данных или взлом? Почему?
- Чем Velero и GitOps-восстановление различаются по тому, что они возвращают?

**Типичные ошибки:**

- `nothing to commit, working tree clean`: файлы уже закоммичены или правка не сохранилась. Проверь `git status` и содержимое файла.
- `fatal: pathspec 'gitops' did not match any files`: в `~/notes` нет каталога `gitops`, зеркало лежит в репозитории `notes-gitops`. Команда с `2>/dev/null` это пропустит, но политику закоммить в её репозитории.

## Сломай и почини

Запусти один из сценариев и почини без подсказок. Сначала запусти команду, потом иди по шагам ниже.

```bash
bash project/notes/break/9.7/break.sh 1   # сценарии 1, 2, 3
```

### Симптом

После пересоздания кластера `flux get kustomizations` показывает, что часть ступеней не Ready, приложение не поднялось, а страница `https://notes.lab` не отвечает. В разных сценариях причина разная, а картина сверху похожая.

### Гипотезы

- Порядок применения нарушен: приложение стартует раньше, чем готовы контроллеры (`dependsOn`).
- Vault пуст или запечатан: ExternalSecret не может выдать Secret.
- CRD ещё нет, когда применяется ресурс этого типа.
- Образ или Git недоступны (сеть, токен).

### Проверки

```bash
flux get kustomizations
kubectl -n flux-system describe kustomization apps | tail -20
kubectl -n notes get externalsecret,secret
kubectl get crd | grep -E 'cert-manager|external-secrets|postgresql'
kubectl -n vault exec vault-0 -- vault status
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**Сценарий 1: неверный `dependsOn`.** В `apps.yaml` зависимость указывает на несуществующую ступень или отсутствует. Симптом: `dependency 'flux-system/infrastructure-configs' not found` в статусе Kustomization. Найди опечатку в имени `dependsOn`, поправь в git (не руками в кластере), запушь и выполни `flux reconcile kustomization apps --with-source`. Правильная цепочка: `infrastructure` -> `infrastructure-config` -> `apps`.

**Сценарий 2: забытый секрет в Vault.** Vault поднялся, но `seed-vault.sh` не запускали. Симптом: `SecretSyncedError`, в описании `secret does not exist`, под `notes` в `CreateContainerConfigError`. Запусти `bash scripts/seed-vault.sh`, затем `kubectl -n notes annotate externalsecret notes-db force-sync=$(date +%s) --overwrite`. Урок: восстановление из git не восстанавливает содержимое Vault, это должен быть отдельный шаг в чек-листе.

**Сценарий 3: порядок CRD.** Ресурс `ClusterIssuer` лежит в ступени `infrastructure` вместе с cert-manager. Симптом: `no matches for kind "ClusterIssuer" in version "cert-manager.io/v1"`, ступень не Ready. Вынеси ресурс в `infrastructure/configs/` (она зависит от контроллеров) и запушь. Тот же приём для `ClusterSecretStore` и `Cluster` CNPG: ресурс на основе CRD живёт строго после установки оператора.

Общая мораль: `dependsOn` описывает порядок ступеней, но не содержимое Vault и не наличие CRD внутри одной ступени.

</details>

## Вопросы с собеседований

### 1. [middle] У тебя погиб кластер целиком. Как восстановишь платформу?

Создаю кластер по коду, запускаю `flux bootstrap` на тот же репозиторий, Flux применяет ступени по `dependsOn`. Потом поднимаю Vault: unseal или init и seed секретов. Данные БД возвращаю из бэкапа, а не из git. Замеряю время и сверяю с RTO.

**Что хотят услышать:** git даёт конфигурацию, но не секреты и не данные; порядок; время восстановления известно из учений, а не выдумано.

**Красный флаг:** «всё в git, поэтому всё вернётся само» или «у нас снапшот кластера, поднимем его».

### 2. [middle] Flux применил всё, но под не стартует, в ExternalSecret `SecretSyncedError`. Что делаешь?

Смотрю `describe externalsecret`, текст ошибки. Проверяю, что Vault доступен и распечатан, что путь секрета существует, что роль Kubernetes auth соответствует namespace и ServiceAccount. Если Vault пуст после пересоздания, запускаю seed.

**Что хотят услышать:** идут по цепочке снизу вверх: под, Secret, ExternalSecret, ClusterSecretStore, Vault.

**Красный флаг:** пересоздаёт под или вручную создаёт Secret в обход ESO.

### 3. [junior] Что такое admission controller и чем он отличается от проверки в CI?

Это проверка объекта при записи в API до сохранения в etcd. CI проверяет только то, что прошло через CI, а admission ловит и ручной `kubectl`, и любой другой путь в кластер.

**Что хотят услышать:** «на входе в API», Validating и Mutating, пример с запретом `latest` или root.

**Красный флаг:** путает admission с RBAC или с NetworkPolicy.

### 4. [middle] Тебя просят запретить образы `latest`. Как сделаешь и что политика не поймает?

Встроенная ValidatingAdmissionPolicy с выражением CEL на подах и привязкой к namespace. Не поймает образ без тега, если выражение проверяет только слово `latest`, и образы, у которых тег указывает на разные сборки (тег изменяемый). Надёжнее digest.

**Что хотят услышать:** неявный latest, mutable tag, digest, режим `Warn` перед `Deny`.

**Красный флаг:** «я поставлю Kyverno» без объяснения, зачем нужен именно он для такой простой задачи.

### 5. [middle] В чём разница между Velero и GitOps для восстановления?

GitOps возвращает описание (манифесты) из git, но не данные и не секреты. Velero делает бэкап объектов и снимки томов, то есть возвращает и состояние. Для stateless-приложений хватает GitOps, для PVC нужны бэкапы данных.

**Что хотят услышать:** «описание против состояния», БД восстанавливается собственными средствами (CNPG backup, PITR).

**Красный флаг:** считает, что одно заменяет другое во всех случаях.

### 6. [middle] Prod отвечает 502 после релиза через Argo Rollouts. Действия?

Смотрю `kubectl argo rollouts get rollout`, не идёт ли canary. Если анализ показывает рост ошибок, останавливаю или откатываю (`abort`). Проверяю логи подов новой версии и метрики ошибок. Митигация первой, разбор потом.

**Что хотят услышать:** сначала откат, потом причина; стабильная версия остаётся в работе, сверка с алертом и метриками.

**Красный флаг:** правит манифест в кластере руками, а git оставляет прежним.

### 7. [junior] Кто-то поменял число реплик через `kubectl scale`, а через минуту оно вернулось. Почему?

Flux сравнивает состояние кластера с git на каждом интервале reconcile и возвращает то, что описано в репозитории. Менять надо через коммит.

**Что хотят услышать:** pull-модель, drift, правка через git и PR; для срочного случая `flux suspend` как исключение с последующим возвратом.

**Красный флаг:** отключает Flux навсегда, «чтобы не мешал».

### 8. [middle] Ты строишь threat model для сервиса. С чего начнёшь и как поймёшь, что закончил?

Рисую схему потоков данных и границы доверия, иду по каждому компоненту и категории STRIDE. Для каждой угрозы записываю, что закрыто и что нет. Заканчиваю, когда остаточные риски названы, приоритизированы и у каждого есть владелец.

**Что хотят услышать:** начало со схемы, STRIDE как чек-лист, приоритет по ущербу, список остаточных рисков.

**Красный флаг:** перечисляет инструменты безопасности вместо угроз.

### 9. [middle] Как доказать, что платформа надёжна, а не просто «работает»?

Замерами: время восстановления из учений, результаты restore drill, SLO с error budget, тесты откатов и failover. Слова «работает» без проверок не доказательство.

**Что хотят услышать:** регулярные учения, метрики, а не разовая проверка; знает, что ни разу не проверенный бэкап не бэкап.

**Красный флаг:** «мы давно не падали».

### 10. [middle] Vault запечатан после перезапуска пода. Что происходит и что делаешь?

Vault хранит данные зашифрованными, ключ расшифровки на диске не лежит. После рестарта его надо распечатать (unseal). Пока он запечатан, ESO не читает секреты, но уже созданные Secret в кластере продолжают работать. Проверяю `vault status`, распечатываю ключами из безопасного хранилища.

**Что хотят услышать:** unseal-ключи вне git, в проде auto-unseal через KMS, существующие Secret не пропадают, новые под не получат секрет.

**Красный флаг:** предлагает хранить unseal-ключи в git, чтобы не потерять.

## Проверено на версиях

- Flux: v2.9.5
- External Secrets Operator: v2.11.0
- Vault: v2.1.1
- cert-manager: v1.21.2
- CloudNativePG: v1.30.1
- Argo Rollouts: v1.10.0
- Envoy Gateway: v1.9.2
- ValidatingAdmissionPolicy: встроена в Kubernetes с версии 1.30 (GA)
- kind: версия не закреплена, проверь актуальную версию на странице проекта
- Kyverno и cosign: версия не закреплена, проверь актуальную версию на странице проекта (в уроке только обзор)

## Итог урока: ты умеешь

- [ ] умею нарисовать цепочку от коммита до алерта и назвать, где хранится состояние
- [ ] умею восстановить кластер из git и Vault и назвать измеренное время
- [ ] умею объяснить порядок `dependsOn` и найти ошибку в нём
- [ ] умею написать ValidatingAdmissionPolicy на CEL и проверить её отказ
- [ ] умею объяснить, зачем нужны SBOM, подпись cosign и проверка при деплое
- [ ] умею составить threat model по STRIDE с остаточными рисками
- [ ] умею вести список долгов и предложить, как закрыть каждый в проде

**Дальше:** [Тема 10: Итоговый практикум](../10-capstone/index.md)
