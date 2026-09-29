---
layout: lesson
title: "Диагностика Kubernetes: разбор поломок"
topic: 5
lesson: "5.13"
time: "2 ч"
---

## Зачем это нужно

В два часа ночи алерт говорит «под не работает», а не «у тебя опечатка в теге образа». Кто ищет причину наугад, тратит час; кто идёт по одному и тому же алгоритму, находит её за пять минут. Почти любая поломка в Kubernetes видна в четырёх местах: статус пода, события (events), логи и описание (describe).
Именно этот навык проверяют на собеседованиях: «под не стартует, твои действия».
Шаг проекта: в «Заметках» появляется `docs/runbooks/k8s-triage.md`, короткий алгоритм разбора пода. Код и манифесты проекта не меняются.

## Что нужно знать

- [Урок 5.2: поды и Deployment](02-pods-deployments.md) - жизненный цикл пода, `describe`, `logs`
- [Урок 5.3: Service и DNS кластера](03-services-dns.md) - selector и endpoints
- [Урок 5.5: хранилище и StatefulSet](05-storage-statefulset-postgres.md) - PVC и `postgres-0`
- [Урок 5.6: ConfigMap и Secret](06-config-secrets.md) - `envFrom`, ключи Secret
- [Урок 5.7: пробы, ресурсы, выкатка](07-probes-resources-rollouts.md) - readiness, liveness, OOMKilled
- [Урок 5.9: Helm](09-helm.md) - релиз, `helm history`, `rollback`
- [Урок 5.12: безопасность кластера](12-k8s-security.md) - PSS, NetworkPolicy, RBAC
- [Урок 2.8: путь запроса и диагностика](../02-network/08-request-path-troubleshooting.md) - идея «идти по пути слой за слоем»

## Теория

### Алгоритм: четыре команды и порядок

Диагностика подчиняется простому правилу: сначала узнай, **где** остановился под, и только потом ищи **почему**. Порядок такой.

1. **Статус.** `kubectl get pods -n notes -o wide`. Колонки `STATUS`, `READY`, `RESTARTS`, `NODE`. Статус сразу сужает область поиска.
2. **События.** `kubectl get events -n notes --sort-by=.lastTimestamp`. Планировщик (scheduler), kubelet и контроллеры пишут сюда, почему они не смогли что-то сделать.
3. **Описание.** `kubectl describe pod <имя> -n notes`. Смотри блок `State` / `Last State` (причина и код выхода) и `Events` в самом конце.
4. **Логи.** `kubectl logs <под> -n notes` и `--previous` для уже упавшего запуска. Логи есть только у контейнера, который хоть раз стартовал.

Если под здоров, а сервис не отвечает, идём дальше по сети: Service, endpoints, Gateway (уроки 5.3 и 5.4).

> **Проверь понимание:** почему логи смотрят четвёртым, а не первым?

<details markdown="1">
<summary>Ответ</summary>

Потому что у многих поломок логов просто нет: под в `Pending` ещё не запущен, `ImagePullBackOff` не смог скачать образ, `CreateContainerConfigError` не создал контейнер. Статус и события говорят, до какой стадии дошёл под, а логи имеют смысл, только если контейнер стартовал.

</details>

### Статус пода как карта

Каждый статус указывает на свою стадию жизни пода и свой набор причин.

| Статус | Стадия | Что искать |
|---|---|---|
| `Pending` | под создан, но не размещён на узле | события: `FailedScheduling` (не хватает requests, taint, `nodeSelector`), PVC не привязан |
| `ContainerCreating` | узел выбран, контейнер готовится | том не смонтировался, нет Secret или ConfigMap |
| `ErrImagePull` / `ImagePullBackOff` | не скачивается образ | опечатка в имени или теге, приватный реестр, нет сети |
| `CreateContainerConfigError` | контейнер не создан из-за конфига | нет ключа в Secret или ConfigMap, неверный `envFrom` |
| `CrashLoopBackOff` | контейнер стартует и падает, пауза растёт | `logs --previous`, код выхода в `describe` |
| `Running`, но `0/1 READY` | процесс жив, readiness-проба не проходит | путь пробы, зависимость (БД), события `Unhealthy` |
| `OOMKilled` (в `Last State`) | код выхода 137, память выше limit | лимит `memory`, утечка |
| `Error` / `Completed` | завершился Job или контейнер без перезапуска | код выхода, логи |

Пауза в `CrashLoopBackOff` растёт: 10 с, 20 с, 40 с и так до 5 минут. Поэтому «под просто ещё не перезапустился» после пяти минут не оправдание.

> **Проверь понимание:** под в `Pending`, `kubectl logs` выдаёт пустоту. Это ошибка команды?

<details markdown="1">
<summary>Ответ</summary>

Нет. Контейнера ещё не было, логам взяться неоткуда. Причину `Pending` смотрят в `kubectl describe pod`, в секции `Events` (сообщение `FailedScheduling` объяснит, что не подошло).

</details>

### События и код выхода

События (events) живут в кластере около часа, потом стираются. Поэтому в инциденте их смотрят сразу. Полезные варианты:

```bash
kubectl get events -n notes --sort-by=.lastTimestamp        # свежие в конце
```

Код выхода (exit code) контейнера рассказывает о причине смерти:

- `0` - завершился штатно;
- `1` - ошибка приложения (смотри логи);
- `137` - убит сигналом 9 (SIGKILL), чаще всего `OOMKilled` (память) или kill по `livenessProbe` после таймаута;
- `143` - штатно остановлен SIGTERM (при выкатке это нормально);
- `126` / `127` - команда не исполняемая или не найдена (ошибка в `command`).

Формула: `128 + номер сигнала`. Сигнал 9 даёт 137, сигнал 15 даёт 143 (вспомни сигналы из урока 1.4).

> **Проверь понимание:** в `Last State` стоит `Terminated`, `Reason: Error`, `Exit Code: 1`. Куда смотреть дальше?

<details markdown="1">
<summary>Ответ</summary>

В `kubectl logs <под> --previous`: приложение само завершилось с ошибкой, и причина написана в его последних строках. `OOMKilled` тут нет, иначе был бы код 137.

</details>

### Если сам под здоров: сеть и выкатка

Когда под `Running` и `1/1 Ready`, а клиент получает ошибку, идём по пути запроса изнутри наружу.

1. `kubectl get endpoints notes -n notes`: пусто значит selector не совпал с метками подов или нет готовых подов.
2. `kubectl port-forward svc/notes 8080:8080 -n notes` и `curl`: если так работает, проблема выше по пути (Gateway, HTTPRoute).
3. `kubectl get gateway,httproute -n notes`: условия `Accepted` и `Programmed`.
4. Если приложение обращается к БД: `kubectl get endpoints db -n notes`, статус `postgres-0`, событие про PVC.

Если поломка началась сразу после выкатки, сначала откат: `helm rollback notes <ревизия> -n notes` или `kubectl rollout undo deployment/notes -n notes`. Разбираться будешь после того, как пользователи снова работают.

> **Проверь понимание:** зачем сначала откат, а потом разбор?

<details markdown="1">
<summary>Ответ</summary>

Потому что первая цель инцидента это восстановить сервис, а не понять причину. Откат занимает минуту и безопасен, а причина остаётся в истории ревизий и логах для спокойного разбора.

</details>

### kubectl debug: когда в образе нет инструментов

Образ «Заметок» на `python:3.13-slim`: в нём нет `curl`, `nslookup` и `ps`. Поверх работающего пода можно подключить временный (ephemeral) контейнер с инструментами. В namespace с PSS `restricted` (урок 5.12) ему нужен профиль `restricted`, иначе admission его отклонит.

```bash
kubectl debug -it -n notes <под> --image=busybox:1.37 --target=notes --profile=restricted -- sh
```

Контейнер делит с целевым сетевое пространство, поэтому `wget -qO- http://127.0.0.1:8080/healthz` и `nslookup db` видят то же, что видит приложение. После выхода ephemeral-контейнер остаётся записанным в описании пода, но не работает.

## Практика

Проверь, что кластер запущен и контекст правильный:

```bash
kubectl config current-context
kubectl get pods -n notes
```

```text
kind-notes
NAME                     READY   STATUS    RESTARTS   AGE
notes-6d9c7b8f5d-4kx2p   1/1     Running   0          12m
notes-6d9c7b8f5d-9zq7w   1/1     Running   0          12m
notes-6d9c7b8f5d-tm8hn   1/1     Running   0          12m
postgres-0               1/1     Running   0          40m
```

Имена подов у тебя будут другие, это нормально. Дальше пишу `<под>` там, где нужно подставить своё имя.

### Задание 1. Три статуса за пять минут

**Цель:** вызвать три типовые поломки и по каждой пройти алгоритм: статус, события, describe, логи.

**Предскажи:** если в Deployment написать несуществующий тег образа, что увидит пользователь сайта в момент выкатки: ошибки или работающий сайт (у Deployment `maxUnavailable: 0` из урока 5.7)?

<details markdown="1">
<summary>Ответ</summary>

Сайт продолжит работать. Новый под застрянет в `ImagePullBackOff`, но RollingUpdate не гасит старые поды, пока новый не стал Ready. Плохая выкатка остаётся «зависшей», а не роняет сервис.

</details>

**Шаги:**

1. Поломка A: несуществующий тег образа.

   ```bash
   kubectl set image deployment/notes notes=ghcr.io/<github-user>/notes:9.9.9 -n notes
   kubectl get pods -n notes
   kubectl describe pod -n notes -l app.kubernetes.io/name=notes | grep -A2 'Failed'
   kubectl rollout undo deployment/notes -n notes
   ```

2. Поломка B: слишком большие requests.

   ```bash
   kubectl set resources deployment/notes -n notes --requests=cpu=64,memory=512Gi
   kubectl get pods -n notes
   kubectl get events -n notes --field-selector reason=FailedScheduling | tail -2
   kubectl rollout undo deployment/notes -n notes
   ```

3. Поломка C: ключ, которого нет в Secret.

   ```bash
   kubectl patch deployment notes -n notes --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"X","valueFrom":{"secretKeyRef":{"name":"notes-db","key":"NO_SUCH_KEY"}}}]}]'
   kubectl get pods -n notes
   kubectl describe pod -n notes -l app.kubernetes.io/name=notes | grep -B1 -A3 'NO_SUCH_KEY' | head
   kubectl rollout undo deployment/notes -n notes
   ```

Между поломками дожидайся `kubectl rollout status deployment/notes -n notes`, чтобы состояние вернулось к норме.

**Что должно получиться:**

```text
NAME                     READY   STATUS             RESTARTS   AGE
notes-5f7d8b6c94-x2v8m   0/1     ImagePullBackOff   0          20s
```

```text
Warning  Failed  kubelet  Failed to pull image "ghcr.io/<github-user>/notes:9.9.9": ... not found
```

```text
notes-7c6b9d4f8-q5r2s   0/1   Pending   0   15s
0s   Warning   FailedScheduling   pod/notes-7c6b9d4f8-q5r2s   0/3 nodes are available: 3 Insufficient cpu, 3 Insufficient memory.
```

```text
notes-8b5c7d9f6-m4n7p   0/1   CreateContainerConfigError   0   10s
Error: couldn't find key NO_SUCH_KEY in Secret notes/notes-db
```

**Объясни себе:**

- Какой статус у какой стадии жизни пода: скачивание, размещение, создание контейнера?
- Почему в случаях A, B, C не помогла бы команда `kubectl logs`?
- Почему старые поды продолжали обслуживать трафик все три раза?

**Типичные ошибки:**

- `error: unable to find container named "notes"`: в `set image` имя контейнера указывают до знака равенства; в чарте оно `notes`, проверь `kubectl get deploy notes -n notes -o jsonpath='{.spec.template.spec.containers[*].name}'`.
- `error: you must specify at least one of...` или пустой вывод у `grep`: событие уже стёрлось или ты смотришь не тот под; повтори `kubectl get pods` и возьми новый под.

### Задание 2. CrashLoopBackOff и код выхода

**Цель:** отличить падение приложения от убийства по памяти и научиться пользоваться `--previous`.

**Предскажи:** контейнер падает сразу при старте. `kubectl logs <под>` показывает либо пусто, либо ошибку нового запуска. Какой ключ нужен, чтобы увидеть ошибку, из-за которой контейнер упал в прошлый раз?

<details markdown="1">
<summary>Ответ</summary>

`--previous` (или `-p`). Текущий запуск может ещё не успеть ничего написать, а предыдущий уже записал причину смерти.

</details>

**Шаги:**

1. Подмени команду запуска на несуществующий файл:

   ```bash
   kubectl patch deployment notes -n notes --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["python","/no/such/app.py"]}]'
   sleep 45
   kubectl get pods -n notes
   ```

2. Найди причину:

   ```bash
   kubectl logs -n notes -l app.kubernetes.io/name=notes --previous --tail=3
   kubectl describe pod -n notes -l app.kubernetes.io/name=notes | grep -A6 'Last State'
   ```


**Что должно получиться:**

```text
NAME                     READY   STATUS             RESTARTS      AGE
notes-6d59f5c7b8-hd9wz   0/1     CrashLoopBackOff   3 (28s ago)   62s
```

```text
python: can't open file '/no/such/app.py': [Errno 2] No such file or directory
    Last State:     Terminated
      Reason:       Error
      Exit Code:    2
```

**Объясни себе:**

- Чем `Exit Code: 2` в первом случае принципиально отличается от `137` во втором?
- Почему у OOMKilled в логах приложения может не быть ни строчки об ошибке?

**Типичные ошибки:**

- `Error from server (BadRequest): previous terminated container "notes" in pod "..." not found`: контейнер ещё ни разу не падал; подожди перезапуска или убери `--previous`.
- `error: unable to upgrade connection: container not found`: в момент `exec` или `logs -f` контейнер как раз перезапустился; повтори команду.

### Задание 3. Под здоров, а сайт не отвечает

**Цель:** пройти путь запроса и найти разрыв на уровне Service и БД.

**Предскажи:** что покажет `kubectl get endpoints notes -n notes`, если в Service `notes` ошибочно поменять `selector` на `app.kubernetes.io/name: notez`? Что при этом будет с подами?

<details markdown="1">
<summary>Ответ</summary>

Endpoints станут `<none>`, а поды останутся `Running` и `Ready`: с ними всё в порядке, просто Service их не находит. Клиенты через Gateway получат ошибку (Envoy ответит 503). Это классика: здоровые поды и мёртвый сервис.

</details>

**Шаги:**

1. Убедись в норме: `kubectl get endpoints notes -n notes`.
2. Сломай selector (Service создан из `k8s/base/20-service.yaml` или чарта, правка временная):

   ```bash
   kubectl patch svc notes -n notes --type=merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"notez"}}}'
   kubectl get endpoints notes -n notes
   kubectl get pods -n notes -l app.kubernetes.io/name=notes
   curl -s -o /dev/null -w '%{http_code}\n' http://notes.lab/
   ```

3. Верни исправление и проверь метки:

   ```bash
   kubectl get svc notes -n notes -o wide
   kubectl get pods -n notes --show-labels | head -3
   kubectl patch svc notes -n notes --type=merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"notes"}}}'
   kubectl get endpoints notes -n notes
   ```

**Что должно получиться:**

```text
NAME    ENDPOINTS   AGE
notes   <none>      2h
```

```text
503
```

**Объясни себе:**

- Как связаны `selector` Service и метки подов, и где это видно в выводе?
- Что отличает 503 от 502 в цепочке Gateway, Service, под?

**Типичные ошибки:**

- `curl: (6) Could not resolve host: notes.lab`: нет записи в `/etc/hosts`; добавь `127.0.0.1 notes.lab`.
- `Error from server (NotFound): services "notes" not found`: не тот namespace; добавь `-n notes`.

### Задание 4. Шаг проекта: runbook `docs/runbooks/k8s-triage.md`

**Цель:** закрепить алгоритм документом, который откроет дежурный в ночь инцидента.

**Предскажи:** какая строка в таком документе должна стоять первой: «как искать причину» или «как вернуть сервис»?

<details markdown="1">
<summary>Ответ</summary>

«Как вернуть сервис»: если сбой начался после выкатки, сначала откат, потом разбор. Поэтому раздел про откат идёт в начале, а поиск причины следом.

</details>

**Шаги:**

1. Создай файл:

   ```bash
   mkdir -p ~/notes/docs/runbooks
   cat > ~/notes/docs/runbooks/k8s-triage.md <<'EOF'
   # Runbook: под или сервис «Заметок» не работает

   Контекст `kind-notes`, namespace `notes`. Сначала откат, потом причина.

   ## 0. Началось после выкатки?

   - `helm history notes -n notes`, затем `helm rollback notes <ревизия> -n notes`.
   - Проверка: `kubectl rollout status deployment/notes -n notes`.

   ## 1. Статус

   - `kubectl get pods -n notes -o wide`
   - Pending: события `FailedScheduling` (requests, taint, PVC).
   - ImagePullBackOff: имя и тег образа, доступ к реестру.
   - CreateContainerConfigError: ключ в Secret или ConfigMap.
   - CrashLoopBackOff: шаг 3, код выхода.
   - Running, но 0/1 Ready: путь readiness-пробы и зависимость (БД).

   ## 2. События

   - `kubectl get events -n notes --sort-by=.lastTimestamp`
   - `kubectl describe pod <под> -n notes` (блок Events в конце).

   ## 3. Логи и код выхода

   - `kubectl logs <под> -n notes --previous`
   - 1 или 2: ошибка приложения. 137: OOMKilled или kill по liveness. 143: штатная остановка.

   ## 4. Сеть

   - `kubectl get endpoints notes db -n notes`: пусто значит selector или нет Ready-подов.
   - `kubectl port-forward svc/notes 8080:8080 -n notes`, затем `curl -i http://127.0.0.1:8080/readyz`.
   - `kubectl get gateway,httproute -n notes`: условия Accepted и Programmed.
   - В поде без инструментов: `kubectl debug -it <под> -n notes --image=busybox:1.37 --target=notes --profile=restricted -- sh`.
   EOF
   ```

2. Проверь файл и добавь в git:

   ```bash
   wc -l ~/notes/docs/runbooks/k8s-triage.md
   cd ~/notes && git add docs/runbooks/k8s-triage.md && git commit -m "docs: runbook k8s-triage"
   ```

**Что должно получиться:**

```text
34 /home/user/notes/docs/runbooks/k8s-triage.md
[main 3f2a1c7] docs: runbook k8s-triage
 1 file changed, 34 insertions(+)
```

Чарт `helm/notes` (версия 0.2.0) и `k8s/base/` не меняются. Эталон: `project/notes/docs/runbooks/k8s-triage.md` в [репозитории курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes/docs/runbooks).

**Объясни себе:**

- Чем runbook помогает уставшему человеку в три часа ночи, чего не даёт память?
- Что в нём нужно поправить после первого настоящего инцидента?

**Типичные ошибки:**

- `fatal: not a git repository (or any of the parent directories): .git`: команда `git` запущена вне `~/notes`; выполни `cd ~/notes`.
- `EOF: command not found` или пустой файл: закрывающий `EOF` должен стоять в начале строки без пробелов.

## Сломай и почини

Теперь без подсказок. Скрипт сам выбирает одну из поломок, которые ты видел в темах 5.x, и применяет её к кластеру. Читать скрипт нельзя: цель в том, чтобы найти причину алгоритмом, а не подсмотреть.

```bash
~/notes/break/5.13/break.sh random
```

Скрипт печатает только «поломка применена». Засеки время. Ты решил задачу, когда `kubectl get pods -n notes` показывает все поды `Ready`, а `curl http://notes.lab/readyz` отвечает `200`.

### Симптом

Сайт `notes.lab` отвечает ошибкой или не отвечает, а какие поды и в каком состоянии, ты не знаешь. Запиши симптом одной строкой: код ответа, статус подов, время начала.

### Гипотезы

Составь список из 3-4 вариантов, прежде чем что-то менять. Например:

1. Образ или тег не тот (`ImagePullBackOff`).
2. Под не размещается (`Pending`: ресурсы, PVC, taint).
3. Приложение падает (`CrashLoopBackOff`: конфиг, БД, память).
4. Под жив, но Service или пробы его не видят (пустые endpoints, `0/1 Ready`).
5. Сеть: NetworkPolicy режет DNS или доступ к `db`.

### Проверки

Иди по алгоритму, каждый шаг вычёркивает часть гипотез:

```bash
kubectl get pods -n notes -o wide
kubectl get events -n notes --sort-by=.lastTimestamp | tail -15
kubectl describe pod -n notes <проблемный-под> | tail -25
kubectl logs -n notes <проблемный-под> --previous --tail=20
kubectl get endpoints notes db -n notes
kubectl get netpol,svc -n notes
```

### Исправление

Сначала попробуй найти и исправить сам. Если завис более 10 минут, откат: `helm rollback notes <ревизия> -n notes` или `kubectl rollout undo`. Разбор возможных поломок:

<details markdown="1">
<summary>Разбор сценариев</summary>

- **Неверный образ.** Статус `ImagePullBackOff`, в событиях `Failed to pull image ... not found`. Исправление: вернуть верный тег (`helm upgrade` или `kubectl rollout undo`).
- **Слишком большие requests.** `Pending`, событие `0/3 nodes are available: Insufficient cpu`. Исправление: вернуть значения из `values.yaml`.
- **Нет ключа в Secret.** `CreateContainerConfigError`, `couldn't find key ...`. Исправление: добавить ключ в Secret `notes-db` или убрать ссылку.
- **Падает приложение.** `CrashLoopBackOff`, причина в `logs --previous`. Исправление: вернуть команду или переменную.
- **OOMKilled.** `Exit Code: 137`. Исправление: вернуть limit памяти.
- **Пробы.** `Running`, `0/1 Ready`, события `Readiness probe failed`. Исправление: путь `/readyz`, порт 8080.
- **Пустые endpoints.** Поды здоровы, `ENDPOINTS <none>`. Исправление: selector Service равен меткам подов.
- **NetworkPolicy режет DNS.** Приложение падает с `could not translate host name "db"`. Исправление: разрешить egress к kube-dns на 53 (урок 5.12).

Контроль: все поды `Ready`, `kubectl get endpoints notes -n notes` показывает адреса, `curl -s -o /dev/null -w '%{http_code}\n' http://notes.lab/readyz` печатает `200`.

</details>

## Вопросы с собеседований

### 1. [junior] Под в статусе `CrashLoopBackOff`. Что делаешь?

Смотрю `kubectl describe pod`, блок `Last State`: причину и код выхода. Затем `kubectl logs --previous`, потому что нужен лог упавшего запуска. Дальше по коду: 1 или 2 значит ошибка приложения или конфига, 137 значит память или kill по liveness.

**Что хотят услышать:** `--previous`, код выхода, различие ошибки приложения и OOMKilled, проверку конфигурации и зависимостей.

**Красный флаг:** «удалю под, и он пересоздастся» без выяснения причины.

### 2. [junior] Под висит в `Pending`. Что проверишь?

`describe pod`, события: планировщик пишет `FailedScheduling` и причину (не хватает CPU или памяти под requests, taint без toleration, `nodeSelector`, PVC не привязан). Логов нет, потому что контейнер не запускался.

**Что хотят услышать:** `Pending` означает «не размещён», а не «приложение сломано»; requests, taints, PVC, квоты.

**Красный флаг:** искать причину в логах приложения.

### 3. [junior] Образ не скачивается: `ImagePullBackOff`. Причины?

Опечатка в имени или теге, тега нет в реестре, приватный реестр без `imagePullSecrets`, нет сети до реестра, лимиты реестра. Смотрю точный текст события `Failed`: он скажет, `not found` это или `unauthorized`.

**Что хотят услышать:** чтение события, различие `not found` и `unauthorized`, `imagePullSecrets`, запрет `latest`.

**Красный флаг:** «перезапущу под».

### 4. [middle] После выкатки сайт отвечает 502/503, поды `Running`. Твои действия?

Сначала смотрю `kubectl rollout status` и `get pods`: `0/1 Ready` значит readiness не проходит. Если началось сразу после релиза, откатываю (`helm rollback` или `rollout undo`), сервис поднимается, потом разбираю причину: путь пробы, зависимость от БД, endpoints, Gateway.

**Что хотят услышать:** откат в приоритете, endpoints, readiness против liveness, проверка по слоям (под, Service, Gateway).

**Красный флаг:** правка манифестов прямо на проде без отката и без понимания причины.

### 5. [middle] Контейнер убит с кодом 137, но в логах приложения тишина. Почему?

SIGKILL не даёт приложению ничего записать. Причины: `OOMKilled` (превысил `limits.memory`, видно в `Last State: Reason`) или kill по `livenessProbe`, если приложение не отвечало. Смотрю `describe`, метрики памяти и историю рестартов.

**Что хотят услышать:** 137 равно 128 плюс 9, различие причин, `kubectl top`, requests и limits, утечка против заниженного лимита.

**Красный флаг:** «просто увеличу лимит вдвое» без проверки, течёт ли память.

### 6. [middle] Service создан, поды здоровы, а curl по имени сервиса не проходит. Как ищешь?

`kubectl get endpoints`: пусто значит selector не совпал с метками (или под не Ready). Дальше сравниваю `svc -o wide` и `pods --show-labels`, проверяю порт и `targetPort`, затем DNS изнутри пода и NetworkPolicy.

**Что хотят услышать:** endpoints как первый шаг, selector и метки, `targetPort`, DNS и NetworkPolicy.

**Красный флаг:** пересоздание пода и Service «на удачу».

### 7. [middle] `kubectl logs` не работает, в образе нет ни shell, ни curl. Как отлаживаешь?

`kubectl debug` с ephemeral-контейнером, `--target` на нужный контейнер, чтобы делить сеть и процессы. В namespace с PSS `restricted` добавляю `--profile=restricted`. Для проблем узла есть `kubectl debug node/...`.

**Что хотят услышать:** ephemeral-контейнеры, `--target`, отказ от «поставлю curl в прод-образ».

**Красный флаг:** «пересоберу образ с отладочными утилитами и выкачу в прод».

### 8. [middle] Приложение после включения NetworkPolicy не резолвит `db`. Причина?

Политика `default-deny` закрыла и исходящий трафик, включая DNS. Нужно разрешить egress на kube-dns (порт 53 UDP и TCP) и на сам `db:5432`. Проверяю `nslookup` из ephemeral-контейнера и `kubectl get netpol`.

**Что хотят услышать:** DNS как частая забытая зависимость, разница ingress и egress, проверка изнутри пода.

**Красный флаг:** «отключу NetworkPolicy совсем».

### 9. [middle] Под `Running`, но `0/1 Ready`, рестартов нет. Почему это не баг Kubernetes?

Readiness-проба не проходит: неверный путь или порт, зависимость (БД) недоступна, приложение долго стартует. Kubernetes намеренно не перезапускает такой под, а убирает его из endpoints. Смотрю события `Unhealthy` и вручную дёргаю `/readyz`.

**Что хотят услышать:** различие readiness и liveness, `startupProbe`, связь с endpoints.

**Красный флаг:** путаница «readiness перезапускает контейнер».

### 10. [middle] `helm upgrade` завис или завершился ошибкой, прод деградирует. Порядок?

`helm status` и `helm history`, сравниваю ревизии, откатываю `helm rollback` на последнюю рабочую. Потом причина: `helm get values`, `kubectl get events`, `describe`. Если релиз в `pending-upgrade`, выясняю, не идёт ли параллельное обновление.

**Что хотят услышать:** откат до анализа, ревизии Helm, `--atomic` и `--wait` как профилактика.

**Красный флаг:** `kubectl delete` ресурсов чарта руками.

## Проверено на версиях

- kind: версия не закреплена, проверь актуальную версию на странице проекта
- kubectl: версия не закреплена, проверь актуальную версию на странице проекта
- Envoy Gateway: v1.9.2
- PostgreSQL: 18
- Python (образ приложения): 3.13
- Образ приложения «Заметки»: 0.4.1, chart 0.2.0
- busybox (для отладки): 1.37

## Итог урока: ты умеешь

- [ ] умею по статусу пода определить стадию, на которой он остановился
- [ ] умею читать события и блок `Events` в `kubectl describe`
- [ ] умею отличать ошибку приложения (код 1 или 2) от `OOMKilled` (код 137) и получать логи упавшего запуска через `--previous`
- [ ] умею найти пустые endpoints и сравнить `selector` с метками подов
- [ ] умею подключить ephemeral-контейнер через `kubectl debug` в namespace с PSS `restricted`
- [ ] умею откатить релиз (`helm rollback`, `rollout undo`) раньше, чем найду причину
- [ ] умею оформить алгоритм разбора в runbook `docs/runbooks/k8s-triage.md`

**Дальше:** [Тема 6: Облако](../06-cloud/index.md)
