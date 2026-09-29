---
layout: lesson
title: "Service и DNS кластера"
topic: 5
lesson: "5.3"
time: "1.5 ч"
---

## Зачем это нужно

Поды в Kubernetes смертны: удалил, обновил образ, узел упал, и у нового пода другой IP. Если клиент ходит по IP пода, он ломается при каждой выкладке. Service (сервис) даёт группе подов один постоянный адрес и DNS-имя, а заодно раскидывает трафик по живым репликам.

На работе это самый частый источник вопросов «почему не ходит»: пустые endpoints, неверный `targetPort`, обращение к сервису из чужого namespace. Разобрав механику один раз, ты за минуту находишь причину в любой из этих ситуаций.

Шаг проекта: в «Заметках» появляется `k8s/base/20-service.yaml`, и три реплики становятся доступны по имени `notes.notes.svc:8080`.

## Что нужно знать

- [Урок 5.2: поды и Deployment](02-pods-deployments.md) - Deployment `notes` с тремя репликами и метками `app.kubernetes.io/name: notes`, `kubectl port-forward`
- [Урок 5.1: кластер kind](01-why-k8s-cluster.md) - контекст `kind-notes`, namespace `notes`
- [Урок 2.3: DNS](../02-network/03-dns.md) - A-записи, `dig`, search-домены в `resolv.conf`
- [Урок 2.4: HTTP и curl](../02-network/04-http.md) - коды ответа, `curl -v`
- [Урок 4.3: тома и сети Docker](../04-docker/03-storage-networks.md) - как контейнеры находят друг друга по имени в пользовательской сети

Перед началом убедись, что `kubectl -n notes get deploy notes` показывает `3/3`, иначе вернись к уроку 5.2.

## Теория

### Проблема: IP пода нестабилен

Каждый под получает собственный IP из сети подов (Pod CIDR). Он живёт ровно столько, сколько сам под. Deployment пересоздаёт поды при обновлении, падении, эвакуации узла, и каждый раз адрес новый. Можно посмотреть:

```bash
kubectl -n notes get pods -o wide
```

Второй вывод после `kubectl delete pod` покажет другой IP у нового пода. Значит, нужен посредник с постоянным адресом, который знает, какие поды сейчас живы.

Service (сервис) это объект API, у которого есть:

- виртуальный IP (ClusterIP), не привязанный ни к одному узлу или поду;
- DNS-имя, которое заводит CoreDNS;
- `selector`: набор меток, по которому сервис ищет свои поды;
- `ports`: какой порт сервис слушает (`port`) и на какой порт пода шлёт (`targetPort`).

> **Проверь понимание:** почему нельзя прописать в конфиге клиента IP пода `notes-abc12`, если под работает уже неделю?

<details markdown="1">
<summary>Ответ</summary>

Под может исчезнуть в любой момент (обновление, падение, эвакуация узла), а новый получит другой IP. Долгоживущего адреса у пода нет, он есть у Service.

</details>

### Selector и endpoints: как сервис находит поды

Сервис не хранит список подов сам. Контроллер EndpointSlice (объект «срез конечных точек») следит за подами, у которых метки совпали с `selector` сервиса и которые готовы (Ready), и записывает их IP:порт в объекты EndpointSlice. Старый объект `Endpoints` показывает то же самое и удобен для быстрого взгляда: `kubectl get endpoints notes`.

Связь идёт только по меткам:

```text
Service notes                      Pod notes-7d9f-abc12
selector:                          metadata.labels:
  app.kubernetes.io/name: notes <-   app.kubernetes.io/name: notes   (совпало, попал в endpoints)
```

Имя Deployment, имя образа и имя контейнера роли не играют. Совпали метки: под в списке. Не совпали: список пуст, а сервис при этом создаётся без ошибок. Это ловушка номер один: `kubectl apply` не ругается, ругается потом `curl`.

Второе условие: под должен быть Ready. Пока у пода нет readiness-пробы (она появится в уроке 5.7), он считается готовым сразу после старта контейнера. Под, который ещё не прошёл пробу, в endpoints не попадает, и это как раз защита от трафика в непрогретый процесс.

> **Проверь понимание:** ты создал сервис, а `kubectl get endpoints notes` показывает `<none>`. Какие две причины проверишь первыми?

<details markdown="1">
<summary>Ответ</summary>

1. Метки в `selector` сервиса не совпадают с метками подов (опечатка, другой ключ или значение). Сравни `kubectl get svc notes -o yaml` и `kubectl get pods --show-labels`.
2. Подов с такими метками нет, или они не Ready (CrashLoopBackOff, не прошла readiness-проба).

</details>

### port и targetPort

`port` это порт на виртуальном IP сервиса, по которому обращаются клиенты. `targetPort` это порт внутри пода, куда сервис перенаправляет соединение. Наши «Заметки» слушают 8080 и в контейнере, и в сервисе, поэтому в проекте оба равны 8080. Но они независимы: сервис может слушать 80, а слать на 8080. Если `targetPort` указан неверно, endpoints будут заполнены (под ведь найден), а соединение упадёт: `Connection refused` или зависание. Это вторая по частоте ошибка, и она коварнее первой: `get endpoints` выглядит здоровым.

`targetPort` можно задать и именем порта контейнера (`name: http` в Deployment), тогда номер порта можно менять в одном месте. В нашем проекте используем число, чтобы было проще читать.

> **Проверь понимание:** endpoints у сервиса заполнены тремя адресами, но `curl` даёт `Connection refused`. Что проверишь?

<details markdown="1">
<summary>Ответ</summary>

`targetPort` сервиса против порта, который реально слушает приложение в поде. Проверить: `kubectl get endpoints notes` покажет адреса вместе с портом (например `10.244.1.5:8081`), сравни его с `containerPort` и с тем, что слушает процесс (`kubectl exec ... -- ss -ltn`).

</details>

### Типы Service

| Тип | Что делает | Когда |
|---|---|---|
| `ClusterIP` (по умолчанию) | Виртуальный IP, доступный только внутри кластера | Связь между сервисами: приложение и база |
| `NodePort` | ClusterIP плюс открытый порт (30000-32767) на каждом узле | Учебные стенды, точка входа для балансировщика; так работает вход в kind в уроке 5.4 |
| `LoadBalancer` | NodePort плюс внешний балансировщик от облака | Публикация в облаке; в kind без MetalLB адрес не выдаётся (`<pending>`) |
| `ExternalName` | CNAME на внешнее имя, без проксирования | Дать внутреннее имя внешнему сервису |
| Headless (`clusterIP: None`) | Без виртуального IP, DNS возвращает IP всех подов | StatefulSet: обращаться к конкретной реплике, урок 5.5 |

Для «Заметок» нужен `ClusterIP`: приложение ходит внутри кластера, а вход снаружи организует Gateway в следующем уроке.

### Как работает ClusterIP: kube-proxy

ClusterIP не принадлежит ни одному сетевому интерфейсу: на него нельзя сделать `ping` (ответа не будет), сервис отвечает только на свои порты. Работает это так: на каждом узле работает kube-proxy, он следит за сервисами и EndpointSlice и прописывает в ядро правила (iptables или IPVS, в kind по умолчанию iptables), которые подменяют адрес назначения: пакет, идущий на `ClusterIP:8080`, переписывается на `IP-пода:8080`, выбранный случайно из списка. Ты уже видел такую подмену в Docker: `-p` тоже строит правила DNAT, см. [урок 4.3](../04-docker/03-storage-networks.md).

Важное следствие: балансировка идёт по соединениям, а не по запросам. Одно долгоживущее соединение (keep-alive, gRPC) будет привязано к одному поду.

> **Проверь понимание:** почему `ping <ClusterIP>` не отвечает, хотя `curl <ClusterIP>:8080` работает?

<details markdown="1">
<summary>Ответ</summary>

У ClusterIP нет сетевого интерфейса, который отвечал бы на ICMP. Есть только правила DNAT для портов сервиса. Проверять доступность нужно тем протоколом и портом, которые сервис обслуживает.

</details>

### DNS кластера

CoreDNS (DNS-сервер кластера, работает подами в `kube-system`) заводит для каждого сервиса запись:

```text
<сервис>.<namespace>.svc.cluster.local
```

Для нас это `notes.notes.svc.cluster.local`. Короткие формы работают благодаря search-доменам в `/etc/resolv.conf` каждого пода (тема DNS из [урока 2.3](../02-network/03-dns.md)):

```text
search notes.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

Из пода в namespace `notes`:

- `notes` работает (подставляется `notes.svc.cluster.local`);
- `notes.notes` работает из любого namespace;
- `notes.notes.svc.cluster.local` работает всегда.

Из пода в другом namespace короткое `notes` не сработает: подставится `other.svc.cluster.local` и вернётся `NXDOMAIN`. Правило для конфигов: между namespace пиши как минимум `<сервис>.<namespace>`.

`ndots:5` значит: имя, в котором меньше пяти точек, сначала пробуют с каждым search-доменом, и только потом как абсолютное. Поэтому внешний `example.com` из пода даёт лишние DNS-запросы. Это известная причина задержек DNS в кластерах, полный вариант имени с точкой на конце (`example.com.`) их убирает.

> **Проверь понимание:** из пода в namespace `default` нужно обратиться к сервису `notes` в namespace `notes`. Какое имя напишешь?

<details markdown="1">
<summary>Ответ</summary>

`notes.notes` (или полное `notes.notes.svc.cluster.local`). Просто `notes` не сработает: резолвер будет искать `notes.default.svc.cluster.local`.

</details>

## Практика

### Задание 1. Создай Service и найди endpoints

**Цель:** дать «Заметкам» постоянный адрес и увидеть, как selector превращается в список подов.

**Предскажи:** сколько адресов будет в endpoints, если реплик 3? Что покажет `kubectl get endpoints notes` до создания сервиса?

<details markdown="1">
<summary>Ответ</summary>

Три адреса `IP:8080`. До создания сервиса объекта `notes` в endpoints нет: `Error from server (NotFound): endpoints "notes" not found`.

</details>

**Шаги:**

1. Создай `k8s/base/20-service.yaml` в репозитории `~/notes`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: notes
  namespace: notes
  labels:
    app.kubernetes.io/name: notes
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: notes   # ищем поды с этой меткой (как в Deployment)
  ports:
    - name: http
      port: 8080          # порт сервиса
      targetPort: 8080    # порт приложения внутри пода
```

2. Примени и посмотри:

```bash
cd ~/notes
kubectl apply -f k8s/base/20-service.yaml
kubectl -n notes get svc notes
kubectl -n notes get endpoints notes
kubectl -n notes get pods -o wide
```

3. Сравни IP в endpoints с IP подов.

**Что должно получиться:**

```text
service/notes created
NAME    TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
notes   ClusterIP   10.96.142.17   <none>        8080/TCP   3s
NAME    ENDPOINTS                                         AGE
notes   10.244.1.4:8080,10.244.1.5:8080,10.244.2.3:8080   3s
```

Адреса будут другими, но их три, и они совпадают с колонкой `IP` в `get pods -o wide`.

**Объясни себе:**

- Откуда сервис узнал адреса подов, если в манифесте их нет?
- Что изменится в endpoints, если удалить один под?
- Почему `CLUSTER-IP` не совпадает ни с одним IP пода?

**Типичные ошибки:**

- `Error from server (NotFound): namespaces "notes" not found`: namespace не создан, вернись к уроку 5.1 и выполни `kubectl apply -f k8s/base/00-namespace.yaml`.
- `ENDPOINTS` равно `<none>`: метки в `selector` не совпали с метками подов, сравни с `kubectl -n notes get pods --show-labels`.
- `error: the path "k8s/base/20-service.yaml" does not exist`: команда запущена не из `~/notes`.

### Задание 2. Проверь сервис изнутри кластера

**Цель:** убедиться, что сервис доступен по DNS-имени из другого пода, и увидеть балансировку.

**Предскажи:** какие из имён сработают из временного пода в namespace `notes`: `notes`, `notes.notes`, `notes.notes.svc.cluster.local`, `notes.default`?

<details markdown="1">
<summary>Ответ</summary>

Первые три сработают. `notes.default` попросит сервис `notes` в namespace `default`, которого нет: `NXDOMAIN`.

</details>

**Шаги:**

1. Запусти одноразовый под с отладочными инструментами. Он живёт, пока ты в его оболочке, и удаляется при выходе (`--rm`):

```bash
kubectl -n notes run tmp --rm -it --restart=Never --image=nicolaka/netshoot:v0.14 -- bash
```

2. Внутри пода:

```bash
# смотрим настройки DNS пода
cat /etc/resolv.conf
# резолвим короткое и полное имя
dig +short notes
dig +short notes.notes.svc.cluster.local
# ходим по имени
curl -s http://notes:8080/healthz
# 6 запросов подряд, важен код ответа
for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w '%{http_code}\n' http://notes:8080/healthz; done
exit
```

3. Из второго терминала, пока под жив, можно посмотреть логи подов и увидеть, что запросы разошлись: `kubectl -n notes logs -l app.kubernetes.io/name=notes --prefix --tail=3`.

**Что должно получиться:**

```text
search notes.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
10.96.142.17
10.96.142.17
{"status": "ok"}
200
200
200
200
200
200
```

Точное тело ответа `/healthz` зависит от версии приложения, важен код 200. `dig +short` возвращает ClusterIP сервиса, а не IP подов.

**Объясни себе:**

- Почему `dig notes` вернул тот же адрес, что и полное имя?
- Кто в этом эксперименте выбрал под, который ответил?
- Чем это отличается от `kubectl port-forward` из урока 5.2?

**Типичные ошибки:**

- `Error from server (AlreadyExists): pods "tmp" already exists`: прошлый под остался после обрыва сессии, удали `kubectl -n notes delete pod tmp`.
- `curl: (6) Could not resolve host: notes`: команда запущена в другом namespace (без `-n notes`), короткое имя не находится.
- `ErrImagePull` у пода `tmp`: нет доступа к Docker Hub, образ можно заранее загрузить: `docker pull nicolaka/netshoot:v0.14 && kind load docker-image nicolaka/netshoot:v0.14 --name notes`.

### Задание 3. Убей под и понаблюдай endpoints

**Цель:** увидеть, что сервис сам перестраивает список подов, а клиент про это ничего не знает.

**Предскажи:** сколько адресов будет в endpoints через секунду после `kubectl delete pod`? Изменится ли `CLUSTER-IP`?

<details markdown="1">
<summary>Ответ</summary>

Обычно снова три: удалённый под выпадает из списка, ReplicaSet создаёт новый, тот попадает в список после старта контейнера. Промежуточно на секунду-две может быть два адреса. `CLUSTER-IP` не изменится никогда, пока жив сервис.

</details>

**Шаги:**

1. В первом терминале следи за endpoints:

```bash
kubectl -n notes get endpoints notes -w
```

2. Во втором удали один под:

```bash
kubectl -n notes delete pod $(kubectl -n notes get pods -o name | head -1)
```

3. Останови наблюдение (Ctrl+C) и сравни `get svc` до и после.

**Что должно получиться:**

```text
NAME    ENDPOINTS                                         AGE
notes   10.244.1.4:8080,10.244.1.5:8080,10.244.2.3:8080   5m
notes   10.244.1.5:8080,10.244.2.3:8080                   5m
notes   10.244.1.5:8080,10.244.2.3:8080,10.244.2.6:8080   5m
```

Порядок строк может отличаться. Безопасные выкладки с readiness-пробой разберём в уроке 5.7.

**Объясни себе:** кто удаляет адрес из endpoints: kubelet, ReplicaSet или контроллер EndpointSlice? Что почувствует клиент, если удалить все три пода сразу?

**Типичные ошибки:**

- `No resources found`: метка в `-l` набрана неверно, проверь `--show-labels`.
- В endpoints остался адрес умершего пода на несколько секунд: это задержка обновления, нормальная; она же причина 502 при выкладке без `preStop`.

### Задание 4. Шаг проекта: Service в git и вход через port-forward

**Цель:** закрепить `20-service.yaml` в репозитории и проверить сервис с хоста.

**Предскажи:** к чему подключается `kubectl port-forward svc/notes`: к сервису целиком или к одному поду?

<details markdown="1">
<summary>Ответ</summary>

К одному конкретному поду, который выбирается из endpoints в момент запуска команды. Балансировки по трём репликам порт-форвард не даёт, а при пересоздании этого пода соединение оборвётся.

</details>

**Шаги:**

1. Убедись, что файл в проекте применён и совпадает с кластером:

```bash
cd ~/notes
kubectl diff -f k8s/base/20-service.yaml && echo "различий нет"
```

2. Пробрось порт и проверь с хоста (в другом терминале):

```bash
kubectl -n notes port-forward svc/notes 8080:8080
```

```bash
curl -s -i http://127.0.0.1:8080/healthz | head -1
```

3. Останови порт-форвард (Ctrl+C) и закоммить:

```bash
git add k8s/base/20-service.yaml
git commit -m "k8s: Service notes (ClusterIP 8080)"
```

**Что должно получиться:**

```text
различий нет
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
HTTP/1.0 200 OK
```

Состояние проекта: Service `notes` `:8080`, DNS `notes.notes.svc`, вход снаружи пока только через `port-forward` (постоянный вход появится в [уроке 5.4](04-ingress-gateway.md)), хранилище всё ещё `emptyDir`, образ `notes:0.4.0`. Эталон: [k8s/base/20-service.yaml](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/base/20-service.yaml).

**Объясни себе:** почему порт-форвард годится для отладки, но не для публикации? Что будет с соединением при пересоздании пода?

**Типичные ошибки:**

- `Unable to listen on port 8080: Listeners failed to create with the following errors: [unable to create listener: Error listen tcp4 127.0.0.1:8080: bind: address already in use]`: порт 8080 на хосте занят (например, локальный `app.py` или Compose из темы 4). Выбери другой: `8081:8080`.
- `error: unable to forward port because pod is not running. Current status=Pending`: под не запущен, смотри `kubectl -n notes describe pod`.
- `lost connection to pod`: под пересоздался, запусти команду заново.

## Сломай и почини

Запусти сценарий (скрипт не читай, диагностируй так, как в реальной жизни):

```bash
cd ~/notes
bash break/5.3/break.sh 1
```

Сценарии: 1, 2, 3 (или `random`). Чтобы вернуть исправное состояние, применяй `kubectl apply -f k8s/base/20-service.yaml`.

### Симптом

Из пода `tmp` (задание 2) запрос `curl http://notes:8080/healthz` перестал работать: соединение отклонено, зависает или имя не находится. Приложение при этом `3/3 Running`.

### Гипотезы

1. Сервис не нашёл поды (метки).
2. Сервис нашёл поды, но шлёт не на тот порт.
3. Клиент ищет сервис по короткому имени из другого namespace.
4. CoreDNS не работает.

### Проверки

```bash
kubectl -n notes get svc notes -o wide
kubectl -n notes get endpoints notes
kubectl -n notes get pods --show-labels
kubectl -n notes describe svc notes
kubectl -n kube-system get pods -l k8s-app=kube-dns
```

Если endpoints пусты, сравни `Selector` из `describe svc` с метками подов. Если endpoints есть, но порт в них не 8080, смотри `targetPort`. Если сервис исправен, зайди в клиентский под и запусти `cat /etc/resolv.conf` и `dig` с коротким и полным именем.

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

**1. Selector не совпал с labels.** Симптом: `kubectl get endpoints notes` показывает `<none>`, `curl` даёт `Connection refused` (на ClusterIP без endpoints правила kube-proxy отвечают отказом). Причина: в `selector` другое значение метки (например, `app.kubernetes.io/name: note`). Починка: привести `selector` к меткам подов и применить `kubectl apply -f k8s/base/20-service.yaml`. Способ отладки: `describe svc` показывает `Selector` и `Endpoints: <none>`.

**2. Неверный targetPort.** Симптом: endpoints заполнены (`10.244.1.4:8081,...`), но `curl` получает `Connection refused` или висит. Причина: `targetPort` не равен порту приложения. Починка: `targetPort: 8080`. Способ отладки: в `get endpoints` порт после двоеточия должен совпадать с портом контейнера; проверь непосредственно из клиента `curl PODIP:8080/healthz`: если он работает, а через сервис нет, виноват сервис.

**3. DNS-имя из другого namespace.** Симптом: из пода в namespace `default` `curl http://notes:8080` даёт `curl: (6) Could not resolve host: notes`, `dig notes` возвращает `NXDOMAIN`. Сервис при этом исправен. Причина: короткое имя резолвится в namespace клиента. Починка: `notes.notes` или полное имя. Способ отладки: `cat /etc/resolv.conf` в клиенте показывает search-домен другого namespace.

</details>

## Вопросы с собеседований

### 1. [junior] Что такое Service и зачем он нужен, если есть Deployment?

Deployment следит, чтобы работало нужное число подов, но у подов IP меняется при каждом пересоздании. Service даёт постоянный виртуальный IP и DNS-имя и балансирует соединения по готовым подам, найденным по меткам. Клиент ходит на имя сервиса и не знает, сколько подов и где они.

**Что хотят услышать:** стабильный адрес, selector по меткам, endpoints, DNS, балансировка.

**Красный флаг:** «Service запускает поды» или «сервис нужен только для доступа снаружи».

### 2. [middle] Сервис создан, но запросы не проходят. У Service пустые endpoints. Что делаешь?

Сравниваю `selector` сервиса и метки подов: `describe svc`, `get pods --show-labels`. Если совпадают, смотрю, что поды вообще есть и они Ready: `get pods`, `describe pod`, упавшая readiness-проба выкидывает под из endpoints. Смотрю namespace: сервис и поды должны быть в одном.

**Что хотят услышать:** порядок «selector, метки, Ready, namespace», `get endpoints` или EndpointSlice.

**Красный флаг:** перезапускает поды или сервис, не сравнивая метки.

### 3. [middle] Endpoints есть, а `curl` на сервис отвечает `Connection refused`. Твои действия?

Проверяю `targetPort` и порт в endpoints против порта, на котором реально слушает процесс. Иду в под (`kubectl exec`, `ss -ltn`) и делаю `curl` напрямую на IP пода: если напрямую работает, ошибка в сервисе. Если напрямую нет, приложение слушает `127.0.0.1` вместо `0.0.0.0` или упало.

**Что хотят услышать:** разделение «сервис или приложение» проверкой напрямую в под, `bind 0.0.0.0`.

**Красный флаг:** считает, что причина только в сети кластера.

### 4. [junior] Как один под находит другой по имени? Как выглядит полное имя сервиса?

Через DNS кластера (CoreDNS): `<сервис>.<namespace>.svc.cluster.local`. В своём namespace достаточно `notes`, из чужого нужно хотя бы `notes.notes`. Это работает благодаря search-доменам в `/etc/resolv.conf` пода.

**Что хотят услышать:** формат имени, search-домены, зависимость от namespace.

**Красный флаг:** «по IP пода» или «через переменные окружения» как основной способ.

### 5. [middle] Из пода в namespace `billing` `curl http://notes:8080` не резолвится. В чём дело?

Короткое имя дополняется search-доменом своего namespace, получается `notes.billing.svc.cluster.local`, такого сервиса нет, ответ `NXDOMAIN`. Надо ходить на `notes.notes` или полное имя. Проверяю `cat /etc/resolv.conf` и `dig`.

**Что хотят услышать:** search-домены, `ndots`, namespace как часть имени.

**Красный флаг:** «CoreDNS сломан, перезапускаем».

### 6. [middle] Чем отличаются ClusterIP, NodePort и LoadBalancer? Что выберешь для базы и для публичного сайта?

ClusterIP только внутри кластера. NodePort добавляет порт на каждом узле. LoadBalancer поверх этого просит у облака внешний балансировщик. База: ClusterIP (headless для StatefulSet). Публичный сайт: обычно один LoadBalancer или NodePort на входной шлюз (Ingress или Gateway API), а приложения за ним остаются ClusterIP.

**Что хотят услышать:** каждый следующий тип включает предыдущий, вход через шлюз, а не по LoadBalancer на каждый сервис (дорого).

**Красный флаг:** NodePort на базу «чтобы было удобно подключаться».

### 7. [middle] Как ClusterIP на самом деле работает, если у этого адреса нет интерфейса?

kube-proxy на каждом узле по данным EndpointSlice пишет правила iptables или IPVS, которые заменяют адрес назначения ClusterIP на IP выбранного пода (DNAT). Отдельного процесса-балансировщика на пути нет. Балансировка по соединениям, не по запросам.

**Что хотят услышать:** kube-proxy, DNAT, EndpointSlice, «по соединениям».

**Красный флаг:** «сервис это отдельный прокси-под».

### 8. [middle] Во время выкладки пользователи получают короткие всплески 502. Почему связано с Service?

Удаляемый под выводится из endpoints и получает SIGTERM параллельно, а правила на узлах обновляются не мгновенно. Часть трафика долетает до уже закрывающегося пода. Лечится readiness-пробой, паузой `preStop` и graceful shutdown приложения (урок 5.7).

**Что хотят услышать:** гонка между удалением из endpoints и SIGTERM, `preStop sleep`, обработка SIGTERM.

**Красный флаг:** «увеличить число реплик» как единственный ответ.

### 9. [junior] Что такое headless-сервис и когда он нужен?

Сервис с `clusterIP: None`: у него нет виртуального IP, DNS возвращает адреса всех подов. Нужен StatefulSet, чтобы клиент обращался к конкретной реплике по стабильному имени (`db-0.db`), например к primary в базе.

**Что хотят услышать:** нет ClusterIP, DNS выдаёт адреса подов, StatefulSet.

**Красный флаг:** «это сервис без селектора, значит не работает».

### 10. [middle] Как из своего ноутбука быстро достучаться до сервиса в кластере, не публикуя его?

`kubectl port-forward svc/notes 8080:8080`: локальный порт пробрасывается через API-сервер к одному поду из endpoints. Годится для отладки. Не годится для постоянного доступа: один под, сессия рвётся при пересоздании, нет нормальной аутентификации.

**Что хотят услышать:** port-forward идёт в один под, только для отладки; постоянный вход через Gateway или Ingress.

**Красный флаг:** предлагает открыть NodePort на проде ради быстрой проверки.

## Проверено на версиях

- Kubernetes: 1.37.1 (допустимо 1.36.5), kubectl 1.37.1
- kind: v0.33.0
- CoreDNS: версия из образа узла kind (`kindest/node` под Kubernetes 1.37.1)
- nicolaka/netshoot: тег v0.14, проверь актуальный тег на странице проекта

## Итог урока: ты умеешь

- [ ] умею создать Service типа ClusterIP и связать его с подами через selector
- [ ] умею по `get endpoints` и `describe svc` понять, нашёл ли сервис поды
- [ ] умею объяснить разницу между `port` и `targetPort` и найти неверный `targetPort`
- [ ] умею обратиться к сервису по DNS-имени из пода, в том числе из другого namespace
- [ ] умею проверить сервис изнутри кластера временным подом с `curl` и `dig`
- [ ] умею объяснить, как kube-proxy превращает ClusterIP в IP пода
- [ ] умею открыть сервис на хост через `kubectl port-forward` и назвать его ограничения

**Дальше:** [Урок 5.4: вход в кластер: Ingress и Gateway API](04-ingress-gateway.md)
