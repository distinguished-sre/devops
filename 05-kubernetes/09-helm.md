---
layout: lesson
title: "Helm: упаковываем «Заметки» в чарт"
topic: 5
lesson: "5.9"
time: "2.5 ч"
---

{% raw %}

## Зачем это нужно

К этому уроку приложение «Заметки» живёт в четырёх отдельных манифестах: Deployment, Service, ConfigMap и HTTPRoute. Чтобы получить второе окружение, их копируют и правят три строки: хост, число реплик, тег образа. Копии расходятся, и через месяц никто не помнит, чем `prod` отличается от `dev`. Helm решает это шаблонами и значениями, а ещё даёт то, чего нет у `kubectl apply`: историю релизов и откат одной командой.

На работе Helm встречается ежедневно: почти всё чужое (мониторинг, ingress-контроллеры, операторы) ставится чартами, а свои сервисы упаковывают в чарт, чтобы разные команды деплоили одинаково.

Шаг проекта: приложение «Заметки» переезжает в чарт `helm/notes` версии 0.1.0, релиз `notes` ставится в namespace `notes`, а старые манифесты приложения удаляются из `k8s/base/`.

## Что нужно знать

- [Урок 5.2: Pod и Deployment](02-pods-deployments.md) - чарт генерирует Deployment, нужно понимать его поля
- [Урок 5.3: Service и DNS](03-services-dns.md) - Service `notes` и селекторы
- [Урок 5.4: Вход в кластер](04-ingress-gateway.md) - Gateway `notes-gw` и HTTPRoute, который мы упакуем
- [Урок 5.6: ConfigMap и Secret](06-config-secrets.md) - Secret `notes-db` останется вне чарта
- [Урок 5.7: Пробы, ресурсы, rolling update](07-probes-resources-rollouts.md) - пробы и ресурсы переезжают в шаблон
- [Урок 5.8: Job, CronJob, DaemonSet](08-jobs-cronjob-daemonset.md) - CronJob бэкапа останется платформенным манифестом

## Теория

### Чарт, значения, релиз

**Чарт** (chart) это каталог с шаблонами манифестов и значениями по умолчанию. **Релиз** (release) это установленный в кластер экземпляр чарта под именем. Один чарт можно поставить много раз: `notes-dev` и `notes-prod`, это два релиза. **Репозиторий чартов** (repository) или OCI-реестр хранит упакованные чарты, как Docker-реестр хранит образы.

В чарте есть `Chart.yaml`, `values.yaml`, каталог `templates/` (там же `_helpers.tpl` с общими шаблонами и необязательный `NOTES.txt` с подсказкой после установки) и файлы значений для окружений, например `values-dev.yaml`.

Helm рендерит шаблоны на твоей машине в обычный YAML и отправляет его в API-сервер. Никакой серверной части в кластере нет (в Helm 2 был Tiller, в 3 и 4 его нет). Состояние релиза Helm хранит в кластере в Secret типа `helm.sh/release.v1`, по одному на ревизию.

> **Проверь понимание:** где Helm хранит историю релизов и что случится с откатом, если этот Secret удалить?

<details markdown="1">
<summary>Ответ</summary>

В Secret с типом `helm.sh/release.v1` в namespace релиза, по одному на ревизию (`sh.helm.release.v1.notes.v1`, `...v2`). Если удалить их, сами Pod и Service останутся работать, но Helm забудет о релизе: `helm list` его не покажет, откатиться нельзя, а повторный `install` упрётся в существующие объекты.

</details>

### Шаблоны: подстановка, условия, функции

Шаблоны написаны на Go-шаблонизаторе. Значения доступны через `.Values`, данные релиза через `.Release` (имя, namespace), метаданные чарта через `.Chart`. Основные приёмы:

- подстановка: `replicas: {{ .Values.replicaCount }}`;
- значение по умолчанию: `{{ .Values.image.tag | default .Chart.AppVersion }}`;
- обязательное значение: `{{ required "нужен gateway.host" .Values.gateway.host }}`, без него рендер падает с понятной ошибкой;
- условие: `{{- if .Values.gateway.host }} ... {{- end }}`;
- вставка структуры: `{{- toYaml .Values.resources | nindent 12 }}`, где `toYaml` превращает map в YAML-текст, а `nindent 12` добавляет перевод строки и сдвигает каждую строку на 12 пробелов. Отступ в YAML это смысл, поэтому неверный `nindent` самая частая поломка шаблонов;
- цикл: `{{- range $k, $v := .Values.config }}`;
- именованный шаблон: `{{ include "notes.labels" . | nindent 4 }}`, определён в `_helpers.tpl`.

Дефис в `{{-` съедает пробелы и перевод строки слева, `-}}` справа. Без него в выводе появляются пустые строки, что для YAML обычно безвредно, но ломает отступы, если рядом `nindent`.

> **Проверь понимание:** чем `required` лучше, чем `default`, для значения `gateway.host`?

<details markdown="1">
<summary>Ответ</summary>

`default` молча подставит выдуманное значение, и приложение уйдёт в прод с неправильным хостом. `required` остановит рендер с сообщением ещё до обращения к кластеру. Для значений, у которых нет разумного умолчания, нужен `required`.

</details>

### Жизненный цикл релиза

Команды по порядку риска:

- `helm lint` проверяет чарт статически: синтаксис, обязательные поля. Кластер не нужен;
- `helm template` рендерит YAML и печатает. Кластер не нужен. Самая полезная команда отладки: смотришь, что реально уедет;
- `helm install` / `helm upgrade --install` применяет. Вторая форма идемпотентна: ставит, если релиза нет, обновляет, если есть. Её пишут в CI;
- `helm history`, `helm rollback` показывают ревизии и возвращают на любую из них. Откат это новая ревизия с содержимым старой;
- `helm get values`, `helm get manifest` показывают, что установлено на самом деле;
- `helm uninstall` удаляет все объекты релиза.

**Хуки** (hooks) это Job с аннотацией `helm.sh/hook: pre-upgrade` (или `post-install` и т. д.): Helm запускает их до или после операции, например для миграции БД. Упавший `pre-upgrade` хук останавливает обновление.

Полезные флаги: `--wait` ждёт готовности ресурсов, `--atomic` сам откатывает при неудаче (включает `--wait`), `--timeout 3m` задаёт лимит, `-f файл` и `--set ключ=значение` переопределяют значения. Приоритет: `values.yaml` чарта, затем `-f` по порядку, затем `--set`.

### Версия чарта и версия приложения

В `Chart.yaml` два разных номера. `version` это версия самого чарта (шаблоны), она растёт, когда меняешь шаблоны. `appVersion` это версия упакованного приложения, у нас это тег образа `0.4.1`. Их путают, а зря: можно выпустить чарт 0.1.1 с тем же приложением 0.4.1 (поправили пробу), и наоборот.

Чужие чарты Helm 4 умеет тянуть из OCI-реестров (`oci://ghcr.io/...`), это стандарт вместо старых index.yaml-репозиториев. Ещё две вещи, отличающие v4 от v3: применение через server-side apply (сервер сам разбирается с конфликтами полей) и плагины на WebAssembly. Для этого урока разница не важна, команды те же.

### Чего в чарт не кладём

Чарт содержит только приложение. Namespace, Gateway, PostgreSQL и CronJob бэкапа это платформа, у них другой жизненный цикл: Gateway общий для нескольких сервисов, а база живёт годами. Секреты тоже вне чарта: пароль в `values.yaml` попадёт в git и в Secret релиза. Чарт ссылается на готовый Secret по имени (`existingSecret`), пока он создан командой (закроет урок 9.2).



## Практика

Кластер `kind-notes` из урока 5.1 запущен, в namespace `notes` работают Postgres, Envoy Gateway, Secret `notes-db` и Secret `notes-tls`, приложение развёрнуто манифестами 10, 20, 32, 50 из `k8s/base/`. Все команды выполняются в `~/notes`.

### Задание 1. Установка Helm и первый чарт

**Цель:** поставить Helm с проверкой контрольной суммы и увидеть, что генерирует `helm create`.

**Предскажи:** что покажет `sha256sum -c`, если архив скачался обрезанным?

<details markdown="1">
<summary>Ответ</summary>

`FAILED` и код возврата 1: сумма не совпадёт. Ставить такой файл нельзя.

</details>

**Шаги:**

1. Скачай релиз Helm v4.3.0 и проверь SHA256 (для ARM замени `amd64` на `arm64`):

   ```bash
   cd /tmp
   curl -fsSLO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz
   curl -fsSLO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz.sha256sum
   sha256sum -c helm-v4.3.0-linux-amd64.tar.gz.sha256sum
   tar -xzf helm-v4.3.0-linux-amd64.tar.gz
   sudo install linux-amd64/helm /usr/local/bin/helm
   helm version --short
   ```

**Что должно получиться:**

```text
helm-v4.3.0-linux-amd64.tar.gz: OK
v4.3.0
```

**Объясни себе:**

- Зачем сверять контрольную сумму, а не запускать `curl | bash`?
- Чем `helm create` полезен новичку, а чем вреден (подсказка: десяток лишних шаблонов)?

**Типичные ошибки:**

- `sha256sum: WARNING: 1 computed checksum did NOT match`: файл скачан не полностью или подменён. Скачай заново, не устанавливай.

### Задание 2. Чарт «Заметок»: Chart.yaml, values и шаблоны

**Цель:** описать приложение как чарт и убедиться, что `helm template` даёт то же, что лежало в `k8s/base/`.

**Предскажи:** что произойдёт с релизом, если ты не задашь `image.tag`, и что хочется от чарта в этом случае?

<details markdown="1">
<summary>Ответ</summary>

Разумное поведение: взять `appVersion` из `Chart.yaml` (0.4.1). Так тег образа по умолчанию совпадает с версией приложения, а `latest` не появляется нигде.

</details>

**Шаги:**

1. Создай `helm/notes/Chart.yaml`:

   ```yaml
   apiVersion: v2
   name: notes
   description: Приложение Заметки (без БД, Gateway и секретов)
   type: application
   version: 0.1.0
   appVersion: "0.4.1"
   ```

2. Создай `helm/notes/values.yaml`. Пользователя GitHub подставь свой:

   ```yaml
   replicaCount: 3

   image:
     repository: ghcr.io/CHANGE_ME/notes
     tag: ""            # пусто: берётся appVersion из Chart.yaml
     pullPolicy: IfNotPresent

   # Готовый Secret с ключом DATABASE_URL, создан вне чарта
   existingSecret: notes-db

   config:
     STORE: postgres
     HOST: "0.0.0.0"
     PORT: "8080"
     LOG_LEVEL: info
     APP_VERSION: "0.4.1"

   resources:
     requests:
       cpu: 50m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi

   gateway:
     name: notes-gw
     host: notes.lab
   ```

3. Создай `helm/notes/values-dev.yaml`:

   ```yaml
   replicaCount: 2
   config:
     LOG_LEVEL: debug
   ```

4. Создай `helm/notes/templates/_helpers.tpl`:

   ```yaml
   {{- define "notes.labels" -}}
   app.kubernetes.io/name: notes
   app.kubernetes.io/instance: {{ .Release.Name }}
   app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
   app.kubernetes.io/managed-by: {{ .Release.Service }}
   helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
   {{- end }}

   {{- define "notes.selectorLabels" -}}
   app.kubernetes.io/name: notes
   {{- end }}
   ```

5. Создай `helm/notes/templates/configmap.yaml`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: {{ .Release.Name }}-config
     labels:
       {{- include "notes.labels" . | nindent 4 }}
   data:
     {{- range $k, $v := .Values.config }}
     {{ $k }}: {{ $v | quote }}
     {{- end }}
   ```

6. Создай `helm/notes/templates/deployment.yaml`. Селектор оставляем как в уроке 5.3 (`app.kubernetes.io/name: notes`), иначе Service перестанет находить Pod'ы:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: {{ .Release.Name }}
     labels:
       {{- include "notes.labels" . | nindent 4 }}
   spec:
     replicas: {{ .Values.replicaCount }}
     strategy:
       type: RollingUpdate
       rollingUpdate:
         maxSurge: 1
         maxUnavailable: 0
     selector:
       matchLabels:
         {{- include "notes.selectorLabels" . | nindent 6 }}
     template:
       metadata:
         labels:
           {{- include "notes.labels" . | nindent 8 }}
         annotations:
           # при смене конфига меняется хеш, и Pod'ы перезапускаются
           checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
       spec:
         containers:
           - name: notes
             image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
             imagePullPolicy: {{ .Values.image.pullPolicy }}
             ports:
               - name: http
                 containerPort: 8080
             envFrom:
               - configMapRef:
                   name: {{ .Release.Name }}-config
               - secretRef:
                   name: {{ required "нужен existingSecret" .Values.existingSecret }}
             startupProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 2, failureThreshold: 30 }
             livenessProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 10 }
             readinessProbe: { httpGet: { path: /readyz, port: http }, periodSeconds: 5 }
             lifecycle:
               preStop: { exec: { command: ["sleep", "5"] } }
             resources:
               {{- toYaml .Values.resources | nindent 12 }}
   ```

7. Создай `helm/notes/templates/service.yaml`:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: {{ .Release.Name }}
     labels:
       {{- include "notes.labels" . | nindent 4 }}
   spec:
     type: ClusterIP
     selector:
       {{- include "notes.selectorLabels" . | nindent 4 }}
     ports:
       - name: http
         port: 8080
         targetPort: http
   ```

8. Создай `helm/notes/templates/httproute.yaml`:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: {{ .Release.Name }}
     labels:
       {{- include "notes.labels" . | nindent 4 }}
   spec:
     parentRefs:
       - name: {{ .Values.gateway.name }}
     hostnames:
       - {{ required "нужен gateway.host" .Values.gateway.host | quote }}
     rules:
       - backendRefs:
           - name: {{ .Release.Name }}
             port: 8080
   ```

9. Проверь чарт и отрисуй его:

   ```bash
   helm lint helm/notes
   helm template notes helm/notes -n notes -f helm/notes/values-dev.yaml | grep -E '^kind|replicas:|image:|LOG_LEVEL'
   ```

**Что должно получиться:**

```text
==> Linting helm/notes
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
kind: ConfigMap
  LOG_LEVEL: "debug"
kind: Deployment
  replicas: 2
        image: "ghcr.io/CHANGE_ME/notes:0.4.1"
kind: Service
kind: HTTPRoute
```

**Объясни себе:**

- Почему селектор Deployment вынесен в отдельный хелпер без `instance` и версии?
- Что делает `checksum/config` и почему в нём `include` того же ConfigMap?

**Типичные ошибки:**

- `Error: template: notes/templates/deployment.yaml:8:11: executing "notes/templates/deployment.yaml" at <.Values.replicaCount>: nil pointer evaluating interface {}.replicaCount`: пропущен или неверно назван ключ. Сверь `values.yaml`, имена чувствительны к регистру.
- `Error: parse error at (notes/templates/deployment.yaml:5): unexpected "}" in operand`: в шаблоне лишняя или потерянная скобка `}}`.
- `Error: YAML parse error on notes/templates/deployment.yaml: error converting YAML to JSON: yaml: line 12: did not find expected key`: сдвиг после `nindent` неверный, сравни число пробелов с уровнем вложенности.

### Задание 3. Переезд на Helm и обновление

**Цель:** заменить ручные манифесты релизом, затем обновить значения и посмотреть, как Pod'ы перезапускаются по хешу конфига.

**Предскажи:** что скажет Helm, если запустить `helm install` при живых объектах Deployment `notes` из `kubectl apply`?

<details markdown="1">
<summary>Ответ</summary>

Откажется: `invalid ownership metadata`. Helm не берёт под контроль чужие объекты без меток и аннотаций владения. Есть два пути: усыновить (добавить метки и аннотации руками) или удалить старые и поставить релиз. Мы выбираем второе: это учебный кластер, и короткий простой допустим. На проде так не делают, там усыновляют или ставят релиз под другим именем и переключают трафик.

</details>

**Шаги:**

1. Удали app-манифесты и убери их из репозитория (Secret, Gateway и Postgres не трогаем):

   ```bash
   kubectl -n notes delete -f k8s/base/10-deployment.yaml -f k8s/base/20-service.yaml \
     -f k8s/base/32-httproute.yaml -f k8s/base/50-configmap.yaml
   git rm k8s/base/10-deployment.yaml k8s/base/20-service.yaml \
     k8s/base/32-httproute.yaml k8s/base/50-configmap.yaml
   ```

2. Установи релиз и дождись готовности. `--atomic` откатит установку при неудаче:

   ```bash
   helm upgrade --install notes helm/notes -n notes -f helm/notes/values-dev.yaml --atomic --timeout 3m
   helm list -n notes
   kubectl -n notes get deploy,svc,httproute
   ```

3. Поменяй уровень логов через `--set` и снова обнови релиз. Следи за Pod'ами в соседнем терминале (`kubectl -n notes get pods -w`):

   ```bash
   helm upgrade notes helm/notes -n notes -f helm/notes/values-dev.yaml --set config.LOG_LEVEL=warning --atomic
   helm history notes -n notes
   helm get values notes -n notes
   ```

**Что должно получиться:**

```text
NAME    NAMESPACE  REVISION  STATUS    CHART        APP VERSION
notes   notes      1         deployed  notes-0.1.0  0.4.1
```

```text
REVISION  UPDATED                   STATUS      CHART        APP VERSION  DESCRIPTION
1         Tue Sep 29 10:15:02 2026  superseded  notes-0.1.0  0.4.1        Install complete
2         Tue Sep 29 10:17:40 2026  deployed    notes-0.1.0  0.4.1        Upgrade complete
```

```text
USER-SUPPLIED VALUES:
config:
  LOG_LEVEL: warning
replicaCount: 2
```

Во втором терминале видно, как старые Pod'ы заменяются новыми по одному: `maxUnavailable: 0`.

**Объясни себе:**

- Почему во второй ревизии Pod'ы пересоздались, хотя образ не менялся?
- Чем `--set` опасен для воспроизводимости по сравнению с файлом значений?

**Типичные ошибки:**

- `Error: INSTALLATION FAILED: Unable to continue with install: Deployment "notes" in namespace "notes" exists and cannot be imported into the current release: invalid ownership metadata`: старые объекты не удалены. Удали их (шаг 1) или усынови.
- `Error: UPGRADE FAILED: context deadline exceeded`: Pod'ы не стали готовыми за 3 минуты. `--atomic` откатит сам, причину ищи в `kubectl -n notes describe pod` (обычно неверный образ или пустой Secret).
- `Error: INSTALLATION FAILED: no matches for kind "HTTPRoute" in version "gateway.networking.k8s.io/v1"`: не установлены CRD Gateway API (урок 5.4).

### Задание 4. Откат и hooks

**Цель:** намеренно выкатить плохую версию и откатиться.

**Предскажи:** если выкатить несуществующий тег образа без `--atomic`, что покажет `helm list`: `deployed` или `failed`? Что будет с трафиком?

<details markdown="1">
<summary>Ответ</summary>

Без `--wait` Helm считает установку успешной, как только API принял объекты: статус `deployed`. Новые Pod'ы будут в `ImagePullBackOff`, но благодаря `maxUnavailable: 0` и readiness-пробе старые продолжат обслуживать трафик. Это ещё одна причина писать `--atomic` или `--wait` в CI: иначе статус релиза лжёт.

</details>

**Шаги:**

1. Выкати несуществующий тег:

   ```bash
   helm upgrade notes helm/notes -n notes -f helm/notes/values-dev.yaml --set image.tag=9.9.9
   kubectl -n notes get pods
   curl -sk https://notes.lab/healthz
   ```

2. Откатись на прошлую ревизию и посмотри историю:

   ```bash
   helm history notes -n notes
   helm rollback notes 2 -n notes --wait
   helm history notes -n notes
   ```

**Что должно получиться:**

```text
NAME                     READY   STATUS             RESTARTS   AGE
notes-6d9c7b8f54-x2k7p   0/1     ImagePullBackOff   0          20s
notes-7f5c9d6b48-abcde   1/1     Running            0          3m
notes-7f5c9d6b48-fghij   1/1     Running            0          3m
```

```text
REVISION  UPDATED                   STATUS      CHART        APP VERSION  DESCRIPTION
2         Tue Sep 29 10:17:40 2026  superseded  notes-0.1.0  0.4.1        Upgrade complete
3         Tue Sep 29 10:21:05 2026  superseded  notes-0.1.0  0.4.1        Upgrade complete
4         Tue Sep 29 10:22:31 2026  deployed    notes-0.1.0  0.4.1        Rollback to 2
```

`curl` на шаге 1 отвечает 200: старые Pod'ы живы.

**Объясни себе:**

- Почему откат создал ревизию 4, а не вернул счётчик на 2?
- Зачем `--atomic` в CI, если есть ручной `rollback`?

**Типичные ошибки:**

- `Error: no revision for release "notes"`: указан номер ревизии, которой нет в `helm history`.

### Задание 5. Шаг проекта: чарт в репозитории

**Цель:** зафиксировать чарт 0.1.0 в git и проверить, что платформенные манифесты остались в `k8s/base/`.

**Предскажи:** какие файлы остались в `k8s/base/` и почему `helm uninstall notes` не удалит Postgres?

<details markdown="1">
<summary>Ответ</summary>

Остались `00-namespace`, `30-envoyproxy`, `31-gateway`, `40-postgres`, `60-pg-backup-cronjob` (плюс `70-netpol...` появится позже). Postgres не входит в релиз: `helm uninstall` удаляет только объекты, которые Helm сам создал и записал в манифест релиза.

</details>

**Шаги:**

1. Проверь чарт на схему Kubernetes (kubeconform из набора утилит курса):

   ```bash
   helm template notes helm/notes -n notes | kubeconform -strict -ignore-missing-schemas -summary
   ```

2. Проверь состав `k8s/base/`, зафиксируй в git и убедись, что в чарте нет секретов:

   ```bash
   ls k8s/base/
   git add helm/notes k8s/base && git commit -m "helm: чарт notes 0.1.0, приложение переехало из k8s/base"
   grep -rn "password\|DATABASE_URL" helm/notes || echo "секретов в чарте нет"
   ```

**Что должно получиться:**

```text
Summary: 4 resources found parsing stdin - Valid: 3, Invalid: 0, Errors: 0, Skipped: 1
```

```text
00-namespace.yaml
30-envoyproxy.yaml
31-gateway.yaml
40-postgres.yaml
60-pg-backup-cronjob.yaml
```

```text
секретов в чарте нет
```

`Skipped: 1` это HTTPRoute, у kubeconform нет схемы для CRD (поэтому `-ignore-missing-schemas`). Эталон состояния: [helm/notes](https://github.com/distinguished-sre/devops/tree/devops/project/notes/helm/notes).

**Объясни себе:**

- Почему `helm lint` прошёл бы и с неверной `apiVersion`, а kubeconform нет?
- Почему Secret `notes-db` вне чарта и как чарт узнаёт его имя?

**Типичные ошибки:**

- `Error: validating ...: chart.metadata.version is required`: в `Chart.yaml` нет `version`, сверь с заданием 2.

## Сломай и почини

Запусти сценарий (скрипт не читай, разбор ниже) и почини релиз. Номер сценария 1, 2 или 3:

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/5.9/break.sh
bash break.sh 1
```

### Симптом

Ты пытаешься выполнить `helm install` или `helm template`, и Helm возвращает ошибку. Записывай точный текст: он и есть первая подсказка.

### Гипотезы

Релиз с таким именем уже есть; шаблон обращается к ключу, которого нет в values; YAML после подстановки сломан отступами.

### Проверки

```bash
helm list -A --all                                  # в том числе failed и pending
helm template notes helm/notes --debug | head -60   # --debug печатает даже неверный YAML
```

### Исправление

<details markdown="1">
<summary>Разбор всех сценариев</summary>

1. `Error: INSTALLATION FAILED: cannot re-use a name that is still in use`: релиз `notes` уже существует (в том числе в статусе `failed`). Проверь `helm list -A --all`. Либо используй `helm upgrade --install`, либо удали неудачный релиз: `helm uninstall notes -n notes`.
2. `Error: template: notes/templates/deployment.yaml:23:24: executing ... at <.Values.image.tag>: nil pointer evaluating interface {}.tag`: в `values.yaml` пропал блок `image` или ключ переименован. Верни ключ или защити шаблон через `default`. `helm template --debug` покажет строку.
3. `Error: YAML parse error on notes/templates/deployment.yaml: error converting YAML to JSON: yaml: line 45: did not find expected key`: у `toYaml ... | nindent N` неверное N. Найди строку в выводе `helm template --debug` и сравни отступ с соседними полями. Для `resources` внутри контейнера верно 12.

Общий приём: `helm lint`, затем `helm template --debug`, и только потом `install`.

</details>

## Вопросы с собеседований

### 1. [junior] Ты выкатил релиз, приложение начало отдавать 500. Как откатиться?

`helm history notes` показывает ревизии, `helm rollback notes <ревизия> --wait` возвращает нужную. Откат создаёт новую ревизию с содержимым старой. Потом разбираюсь в причине по логам.

**Что хотят услышать:** `history`, `rollback`, `--wait`, откат это новая ревизия; понимание, что откат не возвращает данные в БД и миграции.

**Красный флаг:** «сделаю `kubectl edit` и поправлю руками», после чего релиз расходится с реальностью.

### 2. [junior] Чем `helm lint` отличается от `helm template`?

`lint` статически проверяет чарт и не показывает результат. `template` рендерит YAML и печатает его, кластер тоже не нужен. Использую оба: `lint` ловит структурные ошибки, `template` показывает, что реально уедет.

**Что хотят услышать:** `template --debug`, связка с kubeconform в CI, `--dry-run=server` как проверка на кластере.

**Красный флаг:** «они одно и то же» или «проверяю только на проде».

### 3. [junior] Где Helm хранит состояние релиза?

В Secret типа `helm.sh/release.v1` в namespace релиза, по одному на ревизию. Серверной части в кластере нет.

**Что хотят услышать:** Secret, по ревизии, нет Tiller, `--history-max` ограничивает число.

**Красный флаг:** «в базе Helm» или «в etcd Helm-сервера».

### 4. [middle] Как передать разные настройки для dev и prod?

Общий `values.yaml` с умолчаниями и по файлу на окружение: `-f values-prod.yaml`. Файлы лежат в git. `--set` только для разовых вещей, потому что он не воспроизводим. Секреты не в values.

**Что хотят услышать:** порядок приоритета, файлы в git, отдельные релизы или namespace, причина против `--set`; упоминание Kustomize как альтернативы (урок 5.10).

**Красный флаг:** отдельная копия чарта под каждое окружение.

### 5. [middle] Поменяли ConfigMap, сделали `helm upgrade`, а Pod'ы работают со старым конфигом. Почему?

Переменные из ConfigMap читаются при старте контейнера, шаблон Pod не изменился, поэтому rolling update не запустился. Решение: аннотация `checksum/config` с хешем ConfigMap, тогда любое изменение конфига меняет шаблон Pod. Разово можно `kubectl rollout restart`.

**Что хотят услышать:** `sha256sum` в аннотации, разница между переменными окружения и смонтированным файлом (файл обновляется сам, но приложение должно его перечитать).

**Красный флаг:** «Kubernetes сам подхватит».

### 6. [middle] На `helm install` ошибка `invalid ownership metadata`. Что это и что делать?

Объект с таким именем уже есть и создан не Helm: у него нет меток и аннотаций `app.kubernetes.io/managed-by: Helm` и `meta.helm.sh/release-name`. Helm не трогает чужое. Варианты: удалить объект и установить, либо усыновить, дописав метки и аннотации, если простой недопустим.

**Что хотят услышать:** аннотации `meta.helm.sh/release-name` и `release-namespace`, вывод про миграцию с `kubectl apply` на Helm без простоя.

**Красный флаг:** `--force` без понимания, что он пересоздаёт объекты.

### 7. [middle] В чарте пароль БД. Что не так и как правильно?

Значение попадёт в git, в `helm get values` и в Secret релиза, доступный всем, кто читает Secret'ы в namespace. Правильно: чарт ссылается на существующий Secret (`existingSecret`), а сам Secret создаёт другой механизм: External Secrets, SOPS, Sealed Secrets (урок 9.2).

**Что хотят услышать:** `existingSecret`, сравнение с внешним хранилищем, причина: values это не секретное хранилище.

**Красный флаг:** «зашифрую base64».

### 8. [junior] В чём разница между `version` и `appVersion` в Chart.yaml?

`version` версия чарта (шаблонов), `appVersion` версия приложения. Поменял шаблон: растёт `version`. Вышел новый образ: меняется `appVersion`.

**Что хотят услышать:** пример, где изменилась только одна из них; SemVer.

**Красный флаг:** «это одно и то же».

### 9. [middle] Helm или Kustomize: что выберешь для своего сервиса?

Для чужих приложений и всего, что ставят пакетом, Helm. Для своих манифестов с небольшими различиями окружений хватает Kustomize без шаблонов. Часто вместе: Helm ставит чужое, Kustomize патчит своё или вывод Helm. Выбор зависит от того, нужны ли условия и циклы, и от версионирования пакета.

**Что хотят услышать:** оба подхода, критерии (шаблоны против патчей, история релизов), реальный опыт.

**Красный флаг:** «Helm всегда лучше» или «шаблоны никогда не нужны».

### 10. [middle] `helm install` падает с `cannot re-use a name that is still in use`. Что делаешь?

Релиз с таким именем уже есть в этом namespace, часто в статусе `failed` после неудачной первой установки. Смотрю `helm list -A --all`, затем `helm uninstall` или `helm upgrade --install`. В CI всегда пишу `upgrade --install`.

**Что хотят услышать:** `--all` показывает failed и pending, релиз привязан к namespace.

**Красный флаг:** удаляет Secret релиза руками.

## Проверено на версиях

- Helm: v4.3.0
- kind: v0.33.0
- kubectl: 1.37.1
- Gateway API: v1.6.2, Envoy Gateway: v1.9.2
- Образ приложения: 0.4.1, чарт `notes`: 0.1.0
- kubeconform: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею установить Helm с проверкой SHA256 и узнать его версию
- [ ] умею описать приложение как чарт: `Chart.yaml`, `values.yaml`, шаблоны
- [ ] умею отличить `lint`, `template --debug` и `install`, и проверить чарт до кластера
- [ ] умею ставить и обновлять релиз командой `upgrade --install --atomic`
- [ ] умею смотреть `history`, `get values` и откатываться через `rollback`
- [ ] умею развести значения по окружениям через `-f` и объяснить, почему `--set` хуже
- [ ] умею объяснить, что входит в чарт, а что остаётся платформой, и почему секрет вне чарта
- [ ] умею читать ошибки `nil pointer`, `cannot re-use a name`, `invalid ownership metadata`

{% endraw %}

**Дальше:** [Урок 5.10: Kustomize: окружения без шаблонов](10-kustomize.md)
