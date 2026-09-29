---
layout: lesson
title: "Kustomize: окружения без шаблонов"
topic: 5
lesson: "5.10"
time: "1.5 ч"
---

## Зачем это нужно

Dev и prod почти одинаковы: те же манифесты, но другие ресурсы, хост, расписание бэкапов. Копировать каталоги нельзя: через месяц они разъедутся, и никто не вспомнит, какое отличие было намеренным. Helm решает это шаблонами, но платформенные манифесты (Postgres, Gateway, CronJob) мы писали обычным YAML и не хотим превращать в Go-шаблоны.

Kustomize делает наоборот: есть общая база (base) и тонкий слой поверх (overlay) с патчами. Шаблонов нет, база остаётся валидным YAML, а любое отличие окружения видно одним `diff`. Kustomize встроен в `kubectl`, ставить ничего не надо. В работе он встречается постоянно: Flux и Argo CD читают именно Kustomize-структуру (см. урок 9.3).

Шаг проекта: платформенные манифесты `k8s/base/` получают `kustomization.yaml`, рядом появляются `k8s/overlays/dev` и `k8s/overlays/prod` с патчами ресурсов, хоста и расписания бэкапов; применяем через `kubectl apply -k`.

## Что нужно знать

- [Урок 5.2: Deployment](02-pods-deployments.md) - структура манифеста, `apply`, метки и selector
- [Урок 5.5: StatefulSet и PostgreSQL](05-storage-statefulset-postgres.md) - объект `postgres`, который мы будем патчить
- [Урок 5.6: ConfigMap и Secret](06-config-secrets.md) - как ConfigMap попадает в под и почему поды не перезапускаются сами
- [Урок 5.8: CronJob](08-jobs-cronjob-daemonset.md) - расписание `pg-backup`
- [Урок 5.9: Helm](09-helm.md) - с чем мы сравниваем Kustomize; приложение уже живёт в релизе Helm

## Теория

### База, overlay и сборка

Kustomize работает с каталогом, в котором лежит файл `kustomization.yaml`. Он перечисляет `resources` (файлы или другие каталоги) и трансформации поверх них. Результат сборки (build) это обычный YAML, который печатается в stdout: ничего не пишется в кластер, пока ты сам не передашь его в `kubectl apply`.

Структура из двух уровней:

```text
k8s/
  base/                   общее для всех окружений
    kustomization.yaml
    40-postgres.yaml
  overlays/
    dev/kustomization.yaml    resources: ../../base + патчи dev
    prod/kustomization.yaml   resources: ../../base + патчи prod
```

Overlay ссылается на base путём в `resources`. База ничего не знает об overlay, поэтому её можно собрать и применить отдельно. Файлы базы не меняются: отличие живёт только в overlay. Отсюда главное свойство: чтобы понять, чем prod отличается от dev, читаешь два маленьких файла, а не два больших каталога.

Две команды нужны каждый день: `kubectl kustomize <каталог>` (только собрать и напечатать) и `kubectl apply -k <каталог>` (собрать и применить). Между ними полезен `kubectl diff -k`: покажет, что изменится в живом кластере.

> **Проверь понимание:** чем `kubectl kustomize k8s/overlays/dev` отличается от `kubectl apply -k k8s/overlays/dev`?

<details markdown="1">
<summary>Ответ</summary>

Первая команда только печатает итоговый YAML и не обращается к кластеру для изменений. Вторая собирает тот же YAML и отправляет его в API-сервер. Поэтому сначала всегда `kustomize` (или `diff -k`), потом `apply -k`.

</details>

### Два вида патчей

Патч это изменение конкретного ресурса. Их два, и выбор зависит от того, что правишь.

Стратегическое слияние (strategic merge patch): ты пишешь кусок манифеста с `kind` и `name`, Kustomize склеивает его с оригиналом. Списки контейнеров сливаются по полю `name`, поэтому достаточно указать имя контейнера и новые `resources`. Читается как обычный манифест, подходит для 90% правок.

JSON-патч (JSON 6902): список операций `add`, `replace`, `remove` с путём. Нужен, когда слияние неудобно: удалить поле, добавить элемент в список по индексу, править кастомный ресурс (CRD), у которого нет схемы для слияния. Таким объектом является наш Gateway.

Патч подключается в `patches:`. Указать, к кому он относится, можно через `target` (kind, name, метки) или, для стратегического слияния, просто по `kind` и `name` внутри самого файла. Если цель не найдена, сборка падает с ошибкой: молча ничего не применится (это хорошо, и мы проверим это в разделе «Сломай и почини»).

> **Проверь понимание:** тебе нужно поменять образ у одного из двух контейнеров в поде и одновременно удалить у Gateway один listener. Какой вид патча для чего?

<details markdown="1">
<summary>Ответ</summary>

Образ: стратегическое слияние (или встроенный трансформер `images:`), контейнер выбирается по `name`. Удаление listener: JSON-патч с `op: remove` и путём `/spec/listeners/1`, потому что слиянием элемент из списка не убрать.

</details>

### Метки, образы, генераторы

Кроме патчей есть готовые трансформеры, которые заменяют десятки правок руками.

- `labels` добавляет метки всем ресурсам. С `includeSelectors: false` (по умолчанию в `labels`) метки не попадают в `selector` Deployment и StatefulSet. Это важно: `selector` неизменяем, и старый `commonLabels`, который писал метки и туда, ломал повторный `apply`.
- `images` меняет имя и тег образа по имени, не трогая контейнеры патчем.
- `configMapGenerator` и `secretGenerator` создают ConfigMap или Secret из литералов и файлов и добавляют к имени хеш содержимого: `web-config-7d8b5k4h2f`. Kustomize сам подставляет новое имя во все ссылки. Меняешь значение, меняется хеш, меняется имя, Deployment ссылается на другое имя и выкатывается заново. Так решается проблема из урока 5.6: ConfigMap изменили, а поды не перезапустились.

`secretGenerator` работает так же, но боевой пароль литералом туда не кладут: файл лежит в git (настоящие секреты приходят из Vault, урок 9.2).

### Kustomize или Helm

Это не соперники, а разные инструменты. Helm нужен, когда ты распространяешь приложение и у него много параметров: версионируемый чарт, релиз, история, откат (урок 5.9). Kustomize нужен, когда у тебя свои манифесты и несколько окружений, отличающихся немногим: нет шаблонизатора, нет хранилища релизов, откат делает git.

| | Helm | Kustomize |
|---|---|---|
| Как параметризуется | шаблоны и values | патчи поверх готового YAML |
| Состояние | релиз хранится в кластере (Secret) | нет, есть только манифесты |
| Откат | `helm rollback` | `git revert` и повторный apply |
| Типичное место | чужие приложения, свой сервис с параметрами | окружения платформы, доработка чужих манифестов |

В «Заметках» они уже разделили работу: приложение упаковано в чарт, платформа (namespace, Gateway, Postgres, CronJob) живёт обычным YAML, и окружения для неё различаем Kustomize. Оба часто работают вместе: чужой чарт рендерят `helm template` и дорабатывают патчами, не форкая его.

## Практика

Все задания идут в кластере `kind-notes` из урока 5.1. Первое задание не трогает кластер: только `kubectl kustomize`.

### Задание 1. База и overlay с нуля

**Цель:** понять сборку на минимальном примере, не рискуя проектом.

**Предскажи:** в base у Deployment `web` одна реплика и образ `nginx:1.30`. В overlay `prod` ты поставишь 3 реплики и образ `nginx:1.30-alpine`. Что напечатает `kubectl kustomize` для overlay: два Deployment или один? А файл `base/deployment.yaml` изменится?

<details markdown="1">
<summary>Ответ</summary>

Один Deployment с 3 репликами и новым образом. Файл базы не меняется: патч применяется только в памяти при сборке.

</details>

**Шаги:**

1. Создай каталоги и базовые файлы:

```bash
mkdir -p ~/kz-demo/base ~/kz-demo/overlays/prod && cd ~/kz-demo

cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.30
EOF

cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
EOF
```

2. Патч и overlay:

```bash
cat > overlays/prod/replicas.yaml <<'EOF'
# Стратегическое слияние: kind и name находят цель, остальное сливается
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
EOF

cat > overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: replicas.yaml
images:
  # Меняем только тег, не трогая описание контейнера
  - name: nginx
    newTag: 1.30-alpine
EOF
```

3. Собери оба уровня и сравни:

```bash
kubectl kustomize base | grep -E 'replicas|image:'
kubectl kustomize overlays/prod | grep -E 'replicas|image:'
```

**Что должно получиться:**

```text
  replicas: 1
        image: nginx:1.30
  replicas: 3
        image: nginx:1.30-alpine
```

**Объясни себе:**
- Откуда Kustomize знает, к какому Deployment относится `replicas.yaml`?
- Почему `images` не нужно указывать имя контейнера `web`?

**Типичные ошибки:**
- `error: unable to find one of 'kustomization.yaml', 'kustomization.yml' or 'Kustomization' in directory '/home/user/kz-demo'`: команда запущена не на каталоге с `kustomization.yaml`; укажи `base` или `overlays/prod`.
- `error: accumulating resources: accumulation err='accumulating resources from 'deployment.yml': ...no such file or directory`: в `resources` опечатка в расширении; имя файла должно совпадать буква в букву.

### Задание 2. База платформы «Заметок»

**Цель:** собрать `k8s/base/` в единое целое и применить его, не сломав то, что уже работает.

**Предскажи:** в `k8s/base/` лежат `00-namespace.yaml`, `30-envoyproxy.yaml`, `31-gateway.yaml`, `40-postgres.yaml`, `60-pg-backup-cronjob.yaml`. Файлы `10`, `20`, `32`, `50` уже не там: их заменил Helm-чарт. Что случится, если ты по привычке добавишь в `resources` и их?

<details markdown="1">
<summary>Ответ</summary>

Приложением владеет Helm-релиз `notes`. Повторное создание тех же Deployment, Service и HTTPRoute через `kubectl apply` даст конфликт владельцев, а после следующего `helm upgrade` две системы будут перетирать друг друга. В базу входит только то, чем не управляет Helm.

</details>

**Шаги:**

1. Создай `~/notes/k8s/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Только платформа. Приложение (Deployment, Service, HTTPRoute, ConfigMap) ведёт Helm.
resources:
  - 00-namespace.yaml
  - 30-envoyproxy.yaml
  - 31-gateway.yaml
  - 40-postgres.yaml
  - 60-pg-backup-cronjob.yaml
```

2. Собери и посчитай ресурсы по видам:

```bash
cd ~/notes
kubectl kustomize k8s/base | grep -E '^kind:' | sort | uniq -c
```

3. Проверь, что API-сервер принимает результат, и посмотри разницу с живым кластером:

```bash
kubectl apply -k k8s/base --dry-run=server
kubectl diff -k k8s/base; echo "код выхода: $?"
```

**Что должно получиться:** список видов включает `Namespace`, `EnvoyProxy`, `GatewayClass`, `Gateway`, `StatefulSet`, `Service`, `CronJob` (точный набор зависит от ваших файлов 5.4 и 5.8), `dry-run` печатает строки вида `statefulset.apps/postgres configured (server dry run)`, а `diff` заканчивается кодом `0`: база совпадает с тем, что уже работает.

```text
kind: CronJob
kind: EnvoyProxy
kind: Gateway
kind: GatewayClass
kind: Namespace
kind: Service
kind: StatefulSet
```

**Объясни себе:**
- Почему `kubectl diff` возвращает код 1, если различия есть, и как это использовать в CI?
- Почему нельзя писать `namespace: notes` в `kustomization.yaml`, если в базе есть GatewayClass?

**Типичные ошибки:**
- `error: accumulating resources: accumulation err='accumulating resources from '31-gateway.yml': ...`: в `resources` не то расширение; в проекте файлы называются `.yaml`.
- `error: must build at directory: not a valid directory: evalsymlink failure on '/home/user/notes/k8s/bas' ...`: опечатка в пути к каталогу.

### Задание 3. Overlays dev и prod (шаг проекта)

**Цель:** описать отличия окружений патчами и применить dev к кластеру.

**Предскажи:** dev патчит `postgres` до 50m CPU и 128Mi памяти, prod до 250m и 512Mi. Ты применишь только dev. Перезапустится ли под `postgres-0`, если у StatefulSet поменялся шаблон пода?

<details markdown="1">
<summary>Ответ</summary>

Да. Ресурсы лежат в `spec.template`, поэтому StatefulSet заменит под (порядок и тома сохранятся, данные остаются в PVC). Поэтому такие правки делаем осознанно и не в час пик.

</details>

**Шаги:**

1. Проверь имя контейнера в StatefulSet (патч слияния опирается на него):

```bash
kubectl -n notes get sts postgres -o jsonpath='{.spec.template.spec.containers[*].name}'; echo
```

Ожидается `postgres`. Если у тебя другое имя, подставь его в патчах ниже.

2. Общие патчи dev, `k8s/overlays/dev/postgres-resources.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  template:
    spec:
      containers:
        - name: postgres
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
```

3. `k8s/overlays/dev/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
labels:
  # includeSelectors: false, чтобы не менять неизменяемый selector
  - pairs:
      environment: dev
    includeSelectors: false
patches:
  - path: postgres-resources.yaml
  # Хост Gateway: JSON-патч, у CRD нет схемы для слияния
  - target:
      kind: Gateway
      name: notes-gw
    patch: |-
      - op: add
        path: /spec/listeners/0/hostname
        value: notes.lab
      - op: add
        path: /spec/listeners/1/hostname
        value: notes.lab
  # Бэкап в dev раз в 6 часов
  - target:
      kind: CronJob
      name: pg-backup
    patch: |-
      - op: replace
        path: /spec/schedule
        value: "0 */6 * * *"
```

4. Prod: скопируй оба файла в `k8s/overlays/prod/` и поменяй значения. Структура и патчи те же, отличаются только эти строки:

| Что | dev | prod |
|---|---|---|
| `environment` | dev | prod |
| Postgres requests | 50m, 128Mi | 250m, 512Mi |
| Postgres limits | 250m, 256Mi | 1, 1Gi |
| hostname обоих listener | notes.lab | prod.notes.lab |
| `schedule` CronJob | `0 */6 * * *` | `0 * * * *` |

5. Сравни окружения и примени dev:

```bash
cd ~/notes
diff <(kubectl kustomize k8s/overlays/dev) <(kubectl kustomize k8s/overlays/prod)
kubectl apply -k k8s/overlays/dev
kubectl -n notes rollout status sts/postgres --timeout=180s
kubectl -n notes get sts postgres -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo
```

**Что должно получиться:** `diff` показывает только строки про `environment`, ресурсы, hostname и расписание; после `apply` статефулсет перекатился, а в кластере стоят dev-значения.

```text
statefulset rolling update complete 1 pods at revision postgres-6c9d5b7f8...
{"cpu":"50m","memory":"128Mi"}
```

Номер ревизии у тебя будет другим.

Эталон файлов: [k8s/base и k8s/overlays](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s).

**Объясни себе:**
- Почему prod мы не применяем в тот же namespace `notes` на этом же кластере?
- Чем плох `commonLabels` вместо `labels` с `includeSelectors: false`?
- Хост Gateway задан в overlay, а хост HTTPRoute в values чарта. Что произойдёт, если они разойдутся?

**Типичные ошибки:**
- `The StatefulSet "postgres" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden`: ты попытался патчем поменять `volumeClaimTemplates` (размер диска); размер тома StatefulSet после создания не меняется, расширяй PVC отдельно.
- `error: no matches for Id StatefulSet.v1.apps/postgres.[noNs]; failed to find unique target for patch StatefulSet.v1.apps/postgres.[noNs]`: в патче не совпали `kind` или `name` с базой.
- HTTPRoute не получает статус Accepted: хост в listener не совпал с `hostnames` маршрута; проверь `kubectl -n notes get httproute -o yaml`.

## Сломай и почини

Скрипт ломает overlay `dev` в твоём `~/notes` тремя разными способами. Не читай его, работай как с чужой поломкой.

```bash
mkdir -p ~/break/5.10 && cd ~/break/5.10
BASE=https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/5.10
curl -fsSLO "$BASE/break.sh" && curl -fsSLO "$BASE/fix.sh"
bash break.sh 1        # затем 2 и 3 по очереди; после каждого чини и запускай bash fix.sh
kubectl apply -k ~/notes/k8s/overlays/dev
```

### Симптом

`kubectl apply -k k8s/overlays/dev` падает, ничего в кластере не меняется. Текст ошибки отличается в трёх сценариях.

### Гипотезы

1. Патч ссылается на ресурс, которого нет в базе (опечатка в имени или виде).
2. В `kustomization.yaml` неверный путь: к базе или к файлу патча.
3. В `resources` один и тот же ресурс попал дважды под разными файлами.

### Проверки

```bash
kubectl kustomize ~/notes/k8s/base > /dev/null && echo "база собирается"
kubectl kustomize ~/notes/k8s/overlays/dev > /dev/null
```

Если база собирается, а overlay нет, дело в overlay. Дальше читай первую строку ошибки: в ней всегда названы и файл, и ресурс.

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

**Сценарий 1. Цель патча не найдена.**

```text
error: no matches for Id StatefulSet.v1.apps/postgress.[noNs]; failed to find unique target for patch StatefulSet.v1.apps/postgress.[noNs]
```

В патче или `target` `name: postgress`. Сравни с базой: `kubectl kustomize k8s/base | grep -A3 'kind: StatefulSet'`. Исправь имя на `postgres`. Урок: Kustomize не применяет патчи «на авось», ошибка появляется при сборке, а не в кластере.

**Сценарий 2. Неверный путь.**

```text
error: accumulating resources: accumulation err='accumulating resources from '../../bas': evalsymlink failure on '/home/user/notes/k8s/bas' : lstat /home/user/notes/k8s/bas: no such file or directory'
```

Путь в `resources` относителен каталога с `kustomization.yaml`. Из `k8s/overlays/dev` база лежит в `../../base`. То же правило для `path:` патчей.

**Сценарий 3. Конфликт имён.**

```text
error: accumulating resources: accumulation err='merging resources from 'extra-postgres.yaml': may not add resource with an already registered id: StatefulSet.v1.apps/postgres.[noNs]'
```

В overlay добавили файл с ещё одним StatefulSet `postgres`. Ресурс уже есть в базе; чтобы изменить его, нужен патч, а не второй экземпляр. Убери файл из `resources` и оформи правку как патч.

</details>

## Вопросы с собеседований

### 1. [junior] Нужно два окружения, dev и prod, почти одинаковых. Helm или Kustomize?

Смотря на что смотрю. Если манифесты свои и отличаются немногим (ресурсы, хост, расписание), я беру Kustomize: base плюс два overlay с патчами, никаких шаблонов. Если приложение с десятком параметров или оно распространяется как пакет, беру Helm.

**Что хотят услышать:** критерий выбора (количество параметров, свой или чужой YAML), что можно комбинировать, откат через git против `helm rollback`.

**Красный флаг:** «Kustomize это просто старый Helm» или выбор по привычке без аргументов.

### 2. [middle] `kubectl apply -k` падает с `no matches for Id ... failed to find unique target for patch`. Что делаешь?

Собираю `kubectl kustomize` на базе и на overlay, чтобы понять, где ломается. Читаю в ошибке kind и name, сравниваю с базой (`grep -A3 kind:`). Обычно опечатка в имени, другое `kind` или ресурс переименовали в базе.

**Что хотят услышать:** сборка без кластера, что патч привязан к точному id (kind, name, namespace), а не ищет нечётко.

**Красный флаг:** «Пробую apply ещё раз» или «удалю патч».

### 3. [middle] Добавил `commonLabels` в overlay, `apply` упал на `field is immutable`. Почему?

Старый `commonLabels` пишет метки и в `spec.selector` у Deployment и StatefulSet. Selector неизменяем, поэтому применение поверх существующего ресурса отклоняется. Использую `labels` с `includeSelectors: false`.

**Что хотят услышать:** неизменяемость selector, отличие `commonLabels` и `labels`, что при уже развёрнутом объекте надо пересоздавать.

**Красный флаг:** предлагает `kubectl delete` и apply на проде без оценки простоя.

### 4. [junior] Как узнать, что изменится в кластере, до применения overlay?

`kubectl kustomize <dir>` показывает итоговый YAML. `kubectl diff -k <dir>` сравнивает с живым состоянием, код выхода 1 при различиях. Плюс `kubectl apply -k --dry-run=server`: валидирует на API-сервере.

**Что хотят услышать:** три разных проверки (сборка, diff, серверный dry-run), использование diff в CI.

**Красный флаг:** «просто применю и посмотрю».

### 5. [middle] Поменяли ConfigMap, а поды не перезапустились и работают со старым конфигом. Как сделать, чтобы выкатывалось само?

Через `configMapGenerator`: Kustomize добавляет хеш содержимого к имени ConfigMap и переписывает ссылки в Deployment. Значение изменилось, имя стало другим, шаблон пода изменился, пошла выкатка. Без Kustomize пришлось бы делать `rollout restart` руками или считать хеш в аннотации, как это делает Helm.

**Что хотят услышать:** хеш в имени, автоматическая подмена ссылок, что старые ConfigMap остаются до prune.

**Красный флаг:** «просто удалю поды по одному после каждой правки».

### 6. [middle] Кто-то поправил prod через `kubectl edit`, и он отличается от git. Как это обнаружить и что делать?

`kubectl diff -k overlays/prod` покажет расхождение с манифестами в git. Дальше решаю: если правка нужна, переношу её в патч и коммичу, если случайна, делаю `apply -k` и возвращаю. Системно: GitOps (Flux или Argo CD) сам следит за дрейфом и откатывает ручные правки.

**Что хотят услышать:** git как источник правды, `diff`, GitOps reconciliation, запрет ручных правок на проде.

**Красный флаг:** «оставлю как есть, работает же».

### 7. [middle] Нужно доработать чужой Helm-чарт (добавить метку и ограничения), но форкать не хочется. Как?

Рендерю чарт `helm template` и накладываю Kustomize-патчи поверх результата. Либо использую `postRenderer`/`postRenderers`: Helm или Flux после рендера пропускает манифесты через Kustomize. Форк не нужен, обновление чарта не превращается в слияние веток.

**Что хотят услышать:** `helm template | kustomize`, post-renderer, отказ от форка.

**Красный флаг:** «скопирую чарт к себе и поправлю».

### 8. [middle] Где хранить пароль БД для overlay prod?

Не в `secretGenerator`, иначе значение окажется в git. Секрет в prod создаётся снаружи: External Secrets достаёт его из Vault (урок 9.2), а в git лежит только описание ExternalSecret без значения. Для локального стенда допустимо создать Secret командой.

**Что хотят услышать:** base64 не шифрование, ESO или SOPS или Sealed Secrets, «в git только ссылка».

**Красный флаг:** «положу в `.env` рядом, он же в `.gitignore`» для боевого пароля.

### 9. [junior] Просят добавить staging за час. Что делаешь?

Создаю `overlays/staging/kustomization.yaml` со ссылкой на `../../base` и своими патчами (хост, ресурсы), собираю `kubectl kustomize`, сравниваю `diff` с dev и prod. Базу не трогаю. Применяю в отдельный кластер или namespace.

**Что хотят услышать:** базу не копируют, добавляют только overlay, проверка через `diff`.

**Красный флаг:** копирует каталог prod целиком.

### 10. [middle] Удалил манифест из base, но ресурс остался в кластере. Почему?

`kubectl apply` создаёт и обновляет, но не удаляет то, чего нет в наборе. Нужен prune: `kubectl apply -k --prune` с селектором меток (или ApplySet) либо GitOps-контроллер с включённым `prune: true`, как у Flux. Иначе удаляю вручную и проверяю по метке.

**Что хотят услышать:** prune и его риски (селектор меток), GitOps как штатное решение.

**Красный флаг:** уверен, что apply синхронизирует набор «как rsync --delete».

## Проверено на версиях

- kubectl: 1.37.1 (Kustomize встроен, его версию показывает `kubectl version --client`)
- kind: v0.33.0, версия Kubernetes в кластере как в уроке 5.1
- Envoy Gateway: v1.9.2 (Gateway API, объект `notes-gw`)
- PostgreSQL: 18, образ `postgres:18`
- nginx: 1.30 (демо-задания)
- Helm: v4, версия из урока 5.9
- отдельный бинарь kustomize: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею собрать base и overlay и объяснить, чем `kubectl kustomize` отличается от `apply -k`
- [ ] умею менять ресурс стратегическим слиянием и JSON-патчем и выбирать между ними
- [ ] умею использовать `labels`, `images` и `configMapGenerator` вместо ручных правок
- [ ] умею читать три типовые ошибки сборки: цель патча не найдена, неверный путь, конфликт имён
- [ ] умею сравнить окружения через `diff` и проверить изменения `kubectl diff -k` до применения
- [ ] умею объяснить, почему приложение ведёт Helm, а платформу Kustomize, и как они сочетаются
- [ ] умею ответить на собеседовании «Helm или Kustomize» с критериями выбора

**Дальше:** [Урок 5.11: Масштабирование: HPA и metrics-server](11-scaling-hpa.md)
