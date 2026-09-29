---
layout: lesson
title: "Зачем Kubernetes: архитектура и свой кластер kind"
topic: 5
lesson: "5.1"
time: "2 ч"
---

## Зачем это нужно

Compose из [урока 4.5](../04-docker/05-compose-postgres.md) работает на одной машине: она упала, упало всё, а обновление означает остановку старого контейнера. Kubernetes (K8s) держит приложение на многих машинах, сам перезапускает упавшее и приводит систему к состоянию, которое ты описал. На работе кластер это основная платформа для запуска сервисов, и без понимания его устройства любая поломка выглядит как магия.
В этом уроке ты поднимешь свой кластер из контейнеров (kind), найдёшь все его компоненты и научишься читать его состояние.

Шаг проекта: в «Заметках» появятся `kind/kind.yaml` (кластер `notes`: 1 control-plane и 2 worker, проброс портов 80 и 443) и `k8s/base/00-namespace.yaml` (namespace `notes`).

## Что нужно знать

- [Урок 4.1: идея контейнеров](../04-docker/01-containers-idea.md) - kind запускает узлы кластера как контейнеры Docker, порты 80 и 443 хоста должны быть свободны
- [Урок 4.3: тома и сети Docker](../04-docker/03-storage-networks.md) - как контейнеры общаются между собой и с хостом
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - с чем мы сравниваем Kubernetes
- [Урок 4.9: отладка контейнеров](../04-docker/09-docker-troubleshooting.md) - `docker ps`, `docker exec`, `docker logs` пригодятся с узлами kind
- [Урок 2.3: DNS](../02-network/03-dns.md) - запись в `/etc/hosts` для `notes.lab`

## Теория

### Что даёт Kubernetes сверх Compose

Compose описывает набор контейнеров на одном хосте. Kubernetes описывает набор приложений на кластере (cluster), то есть на группе машин, и решает четыре задачи:

1. Размещение: на какой машине запустить контейнер, исходя из свободной памяти и CPU.
2. Самовосстановление: упал контейнер или умер узел, копии запускаются заново на живых узлах.
3. Обновление без простоя: новые копии поднимаются постепенно, старые гасятся после того, как новые готовы.
4. Единый API: всё, от запуска до сетевых правил, делается через один HTTP API и одни и те же YAML-объекты.

Цена: сложность. Для одного приложения на одной ВМ Compose или systemd остаются разумным выбором (см. вопрос 6 ниже). Kubernetes окупается, когда сервисов много, команд несколько, а выкатывать нужно часто.

> **Проверь понимание:** твой сервис живёт на одной ВМ, релиз раз в месяц, простой в 30 секунд допустим. Нужен ли Kubernetes?

<details>
<summary>Ответ</summary>

Скорее нет. Ты получишь платформу, которую надо обновлять, мониторить и изучать, ради выгод, которые тебе не нужны. Compose или systemd плюс хороший откат закрывают задачу. Kubernetes оправдан, когда нужны автоматическое масштабирование, много сервисов и деплои без простоя.

</details>

### Желаемое состояние и цикл согласования

Главная идея: ты не говоришь кластеру «запусти контейнер», ты описываешь, как должно быть («три копии `notes` версии 0.4.0»). Это декларативный подход (declarative). Дальше работает цикл согласования (reconcile loop): контроллер (controller) непрерывно сравнивает желаемое состояние (spec) с фактическим (status) и устраняет разницу.

Отсюда всё поведение кластера: убил под, желаемое число копий не изменилось, значит появится новый; выключился узел, копии переедут; поменял `replicas: 3` на `5`, недостающие создадутся сами. Императивный подход («сделай шаг 1, шаг 2») в Kubernetes тоже возможен (`kubectl run`), но на работе им пользуются для быстрых экспериментов.

> **Проверь понимание:** ты вручную остановил контейнер на узле командой `crictl stop`. Что произойдёт и почему?

<details>
<summary>Ответ</summary>

Kubelet заметит, что контейнер из описания пода не работает, и запустит его снова. Желаемое состояние не менялось, поэтому кластер возвращает систему к нему.

</details>

### Из чего состоит кластер

Кластер делится на управляющий слой (control plane) и рабочие узлы (worker nodes).

Control plane:

| Компонент | Что делает |
|---|---|
| `kube-apiserver` | Единственная дверь в кластер: `kubectl`, kubelet и контроллеры общаются только через него. Проверяет права, валидирует объекты, пишет их в etcd |
| `etcd` | Хранилище ключ-значение с желаемым состоянием всего кластера. Единственный компонент с состоянием: потерян etcd без бэкапа, потерян кластер |
| `kube-scheduler` | Выбирает узел для нового пода по свободным ресурсам и ограничениям. Сам под не запускает, только записывает выбор в объект |
| `kube-controller-manager` | Набор контроллеров: Deployment, ReplicaSet, узлы и другие. Каждый ведёт свой цикл согласования |

Рабочие узлы:

| Компонент | Что делает |
|---|---|
| `kubelet` | Агент на узле: получает от API список подов для этого узла, через контейнерный runtime запускает их, сообщает статус и проверяет пробы |
| `kube-proxy` | Пишет сетевые правила, чтобы обращения к Service попадали в нужные поды (урок 5.3) |
| containerd | Контейнерный runtime: запускает контейнеры, то самое, что стоит внутри Docker |

Kubernetes общается с окружением через стандарты: CRI (container runtime interface), CNI (container network interface, сетевой плагин), CSI (container storage interface, диски). Поэтому runtime, сеть и хранилище можно заменять.

Ещё два системных пода есть почти везде: CoreDNS (DNS кластера, урок 5.3) и сетевой плагин (в kind это kindnet).

Управляющих узлов в проде делают нечётное число (3 или 5): etcd принимает решения большинством (кворум, quorum). Из трёх узлов кластер переживёт потерю одного, из четырёх тоже только одного, поэтому четвёртый только добавляет стоимость.

> **Проверь понимание:** что произойдёт с уже работающими подами, если control plane целиком недоступен?

<details>
<summary>Ответ</summary>

Запущенные поды продолжат работать: kubelet и runtime живут на узлах. Но пока нет API, нельзя ничего менять, не пересоздаются упавшие поды и не масштабируется нагрузка. Этот ответ любят на собеседованиях.

</details>

### Что происходит при kubectl apply

1. `kubectl` читает YAML и отправляет запрос в `kube-apiserver` (адрес и креды берёт из kubeconfig).
2. API проверяет аутентификацию, права и схему объекта, сохраняет его в etcd.
3. Контроллер Deployment видит новый объект и создаёт ReplicaSet, тот создаёт объекты Pod.
4. Scheduler видит поды без узла и записывает в каждый выбранный узел.
5. Kubelet на этом узле видит «свой» под, просит containerd скачать образ и запустить контейнер, потом пишет статус обратно через API.

Никто не звонит по цепочке: каждый компонент смотрит на API и делает свою часть. Поэтому система устойчива: если компонент упал, после возвращения он продолжит с текущего состояния.

> **Проверь понимание:** кто в этой цепочке решает, на каком узле будет под, и кто его реально запускает?

<details>
<summary>Ответ</summary>

Выбирает узел scheduler, запускает kubelet вместе с containerd. Scheduler ничего не запускает, а kubelet ничего не выбирает.

</details>

### kubeconfig, контексты и namespace

`kubectl` знает, куда идти, из файла kubeconfig (по умолчанию `~/.kube/config`, либо путь из переменной `KUBECONFIG`). В нём три списка: кластеры (адрес API и CA), пользователи (сертификат или токен) и контексты (context, связка «кластер + пользователь + namespace по умолчанию»). Текущий контекст определяет, куда попадёт следующая команда, поэтому перед опасной командой на работе смотрят `kubectl config current-context`. Контекст kind называется `kind-<имя кластера>`, у нас это `kind-notes`.

Пространство имён (namespace) делит объекты кластера на логические группы: у каждого приложения свой namespace, имена внутри него уникальны, на него можно навешивать права и лимиты. Системные компоненты живут в `kube-system`. Если namespace не указан, используется `default`, и класть туда свои приложения плохая привычка.

### kind, minikube, k3s

kind (Kubernetes in Docker) запускает каждый узел как контейнер Docker с systemd и containerd внутри. Плюсы: несколько узлов на ноутбуке, старт за минуту, удаление одной командой, используется в CI. Минус: узлы это контейнеры, поэтому доступ снаружи требует проброса портов, а диски и сеть упрощены. minikube поднимает одну ВМ или контейнер и удобен аддонами. k3s это урезанный дистрибутив для небольших реальных серверов и edge. Для курса берём kind: он лучше всего повторяет многоузловой кластер.

Важная деталь: сетевой плагин (CNI) выбирается при создании кластера. В kind по умолчанию kindnet, и заменить его позже нельзя, только пересоздать кластер. В уроке 5.12 нам понадобится NetworkPolicy, и мы вернёмся к этому.

## Практика

### Задание 1. Установить kind и kubectl

**Цель:** получить `kind` v0.33.0 и `kubectl` 1.37.1 с проверкой контрольных сумм, без `curl | bash`.

**Предскажи:** что будет, если файл скачан не полностью, а ты запустил `sha256sum -c`? Что выведет команда?

<details>
<summary>Ответ</summary>

Сумма не совпадёт, `sha256sum` напечатает `FAILED` и вернёт код выхода 1. Именно ради этого проверку делают до установки.

</details>

**Шаги:**

1. Проверь, что Docker работает и порты 80 и 443 свободны (если заняты, останови `nginx` и стенд Compose, как в уроке 4.1):

{% raw %}
```bash
docker version --format '{{.Server.Version}}'
# если порты заняты, ss покажет владельца
sudo ss -tlnp | grep -E ':(80|443)\s' || echo "порты свободны"
```
{% endraw %}

2. Скачай и проверь kind:

```bash
cd "$(mktemp -d)"
curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
curl -fsSLo kind.sha256sum https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64.sha256sum
# в файле с суммой другое имя файла, поэтому берём только хеш
echo "$(cut -d' ' -f1 kind.sha256sum)  kind" | sha256sum -c -
sudo install -m 0755 kind /usr/local/bin/kind
```

3. Скачай и проверь kubectl:

```bash
curl -fsSLO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl
curl -fsSLO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
sudo install -m 0755 kubectl /usr/local/bin/kubectl
```

4. Проверь версии:

```bash
kind version
kubectl version --client
```

На ARM (Ubuntu в ВМ на Apple Silicon) замени `amd64` на `arm64` во всех адресах.

**Что должно получиться:**

```text
kind: OK
kubectl: OK
kind v0.33.0 go1.25.0 linux/amd64
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

Версии Go и Kustomize у тебя могут отличаться, важны `OK` и версии kind и kubectl.

**Объясни себе:**

- Зачем сверять сумму, если скачивание идёт по HTTPS?
- Почему `kubectl` ставят той же минорной версии, что и кластер (допустимо расхождение в одну минорную)?

**Типичные ошибки:**

- `kind: FAILED` и `sha256sum: WARNING: 1 computed checksum did NOT match`: файл скачан не полностью или подменён: удали и скачай заново.
- `curl: (22) The requested URL returned error: 404`: опечатка в версии или архитектуре: сверь адрес со страницей релиза.
- `Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?`: Docker не запущен: `sudo systemctl start docker`.

### Задание 2. Создать кластер `notes` из конфига

**Цель:** описать кластер файлом и создать его: 1 control-plane, 2 worker, порты 80 и 443 хоста проброшены в узел.

**Предскажи:** сколько контейнеров появится в `docker ps` после создания такого кластера? Какие у них будут имена?

<details>
<summary>Ответ</summary>

Три контейнера, по одному на узел: `notes-control-plane`, `notes-worker`, `notes-worker2`. Имя строится из имени кластера.

</details>

**Шаги:**

1. Создай каталоги проекта:

```bash
mkdir -p ~/notes/kind ~/notes/k8s/base
cd ~/notes
```

2. Файл `kind/kind.yaml`:

```yaml
# Кластер kind для проекта «Заметки»
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: notes
nodes:
  - role: control-plane
    # версия Kubernetes задаётся образом узла; проверь тег на странице релиза kind v0.33.0
    image: kindest/node:v1.37.1
    kubeadmConfigPatches:
      # метка узла, на котором будет принимать трафик входной шлюз (урок 5.4)
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # порт хоста 80 -> порт узла 30080 (NodePort шлюза)
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      # порт хоста 443 -> порт узла 30443
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
  - role: worker
    image: kindest/node:v1.37.1
  - role: worker
    image: kindest/node:v1.37.1
```

3. Создай кластер и проверь:

{% raw %}
```bash
kind create cluster --config kind/kind.yaml
kubectl config current-context
kubectl get nodes
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```
{% endraw %}

**Что должно получиться:**

```text
Creating cluster "notes" ...
 * Ensuring node image (kindest/node:v1.37.1)
 * Preparing nodes
 * Writing configuration
 * Starting control-plane
 * Installing CNI
 * Installing StorageClass
 * Joining worker nodes
Set kubectl context to "kind-notes"
kind-notes
NAME                  STATUS   ROLES           AGE   VERSION
notes-control-plane   Ready    control-plane   60s   v1.37.1
notes-worker          Ready    <none>          40s   v1.37.1
notes-worker2         Ready    <none>          40s   v1.37.1
NAMES                 PORTS
notes-worker
notes-worker2
notes-control-plane   0.0.0.0:80->30080/tcp, 0.0.0.0:443->30443/tcp, 127.0.0.1:41235->6443/tcp
```

Оформление строк создания зависит от версии kind, а порт `41235` у тебя будет другой.

### Если у тебя 8 ГБ

Три узла занимают около 2-3 ГБ. Облегчённый режим: удали из `kind/kind.yaml` оба блока `role: worker`, оставив один control-plane, и создай кластер той же командой. kind сам разрешает запуск обычных подов на control-plane, поэтому уроки 5.2-5.7 пройдут; шаги про переезд подов между узлами и `drain` в них помечены. На время работы закрой браузер и IDE и не держи рядом стенд Compose из темы 4.

**Объясни себе (задание 2):**

- Почему на хосте открыты 80 и 443, а внутри узла 30080 и 30443?
- Что означает `6443` и почему порт привязан к `127.0.0.1`?

**Типичные ошибки:**

- `ERROR: failed to create cluster: ... Bind for 0.0.0.0:80 failed: port is already allocated`: порт 80 занят (nginx, стенд Compose): найди владельца `sudo ss -tlnp | grep ':80 '` и останови.
- `ERROR: failed to create cluster: node(s) already exist for a cluster with the name "notes"`: кластер уже есть: `kind delete cluster --name notes` и создай заново.
- `could not find a log line that matches "Reached target .*Multi-User System.*"`: не хватает inotify-лимитов или памяти: `sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512`.

### Задание 3. Осмотреть кластер и системные поды

**Цель:** найти в живом кластере каждый компонент из теории.

**Предскажи:** какие компоненты control plane ты увидишь как поды в `kube-system`, а какие нет?

<details>
<summary>Ответ</summary>

Увидишь `kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager` (kubeadm запускает их как статические поды, static pods), а также `kube-proxy`, `coredns` и `kindnet`. Не увидишь kubelet и containerd: это процессы на узле, а не поды.

</details>

**Шаги:**

```bash
kubectl get nodes -o wide
kubectl get namespaces
kubectl get pods -A -o wide
kubectl -n kube-system get pods -l component=etcd
kubectl describe node notes-worker | head -40
kubectl api-resources | head -20
# контейнеры внутри узла: docker ps их не видит, нужен crictl (клиент CRI)
docker exec notes-control-plane crictl ps
kubectl explain pod.spec.containers.image
```

**Что должно получиться:**

```text
NAMESPACE            NAME                                          READY   STATUS    NODE
kube-system          coredns-xxxxxxxxxx-aaaaa                      1/1     Running   notes-control-plane
kube-system          coredns-xxxxxxxxxx-bbbbb                      1/1     Running   notes-control-plane
kube-system          etcd-notes-control-plane                      1/1     Running   notes-control-plane
kube-system          kindnet-aaaaa                                 1/1     Running   notes-control-plane
kube-system          kindnet-bbbbb                                 1/1     Running   notes-worker
kube-system          kindnet-ccccc                                 1/1     Running   notes-worker2
kube-system          kube-apiserver-notes-control-plane            1/1     Running   notes-control-plane
kube-system          kube-controller-manager-notes-control-plane   1/1     Running   notes-control-plane
kube-system          kube-proxy-aaaaa                              1/1     Running   notes-control-plane
kube-system          kube-scheduler-notes-control-plane            1/1     Running   notes-control-plane
local-path-storage   local-path-provisioner-xxxxxxxxxx-ccccc       1/1     Running   notes-control-plane
```

Вывод сокращён, колонок в реальном больше. Namespace в списке: `default`, `kube-node-lease`, `kube-public`, `kube-system`, `local-path-storage`.

**Ответь письменно:** для каждого пода одной фразой, за что он отвечает. Что такое `local-path-provisioner`? (Подсказка: диски, урок 5.5.)

**Объясни себе:**

- Почему у `etcd` и `kube-apiserver` в имени суффикс `-notes-control-plane`, а у `coredns` случайный хвост?
- Что показывают блоки `Capacity`, `Allocatable` и `Non-terminated Pods` в `describe node`?

**Типичные ошибки:**

- `The connection to the server localhost:8080 was refused - did you specify the right host or port?`: kubectl не нашёл kubeconfig или контекст: `kind export kubeconfig --name notes`.
- `No resources found in kube-system namespace.` для `-l component=etcd`: опечатка в метке, список меток покажет `kubectl -n kube-system get pods --show-labels`.
- `error: the server doesn't have a resource type "gateway"`: такого типа пока нет, CRD Gateway API поставим в уроке 5.4.

### Задание 4. Шаг проекта: namespace `notes` в репозитории

**Цель:** зафиксировать кластер и namespace как код в `~/notes`.

**Предскажи:** что произойдёт, если применить один и тот же файл namespace дважды?

<details>
<summary>Ответ</summary>

Второй раз кластер ответит `unchanged`. `apply` идемпотентен (idempotent): он сравнивает желаемое с фактическим и ничего не делает, если различий нет. Это тот же цикл согласования, только на уровне команды.

</details>

**Шаги:**

1. Файл `k8s/base/00-namespace.yaml`:

```yaml
# Namespace приложения «Заметки»
apiVersion: v1
kind: Namespace
metadata:
  name: notes
  labels:
    app.kubernetes.io/part-of: notes
```

2. Примени дважды, проверь и сделай `notes` namespace по умолчанию для контекста:

```bash
kubectl apply -f k8s/base/00-namespace.yaml
kubectl apply -f k8s/base/00-namespace.yaml
kubectl get namespace notes --show-labels
kubectl config set-context --current --namespace=notes
kubectl config view --minify | grep namespace
```

3. Запись для доменного имени и коммит:

```bash
echo "127.0.0.1 notes.lab" | sudo tee -a /etc/hosts
git add kind k8s && git commit -m "5.1: кластер kind и namespace notes"
```

Если ты на WSL2, запись в `hosts` нужна и в файле Windows (см. урок 2.3).

**Что должно получиться:**

```text
namespace/notes created
namespace/notes unchanged
NAME    STATUS   AGE   LABELS
notes   Active   2s    app.kubernetes.io/part-of=notes,kubernetes.io/metadata.name=notes
    namespace: notes
```

Эталон файлов: [project/notes на GitHub](https://github.com/distinguished-sre/devops/tree/devops/project/notes/kind).

**Объясни себе:**

- Что изменит `set-context --namespace` в поведении команд и чем это опасно?
- Почему `kind.yaml` и манифест лежат в репозитории, а не только в истории терминала?

**Типичные ошибки:**

- `error: the path "k8s/base/00-namespace.yaml" does not exist`: ты не в `~/notes`: `cd ~/notes`.
- `Error from server (BadRequest): ... error validating data: unknown field`: сбились отступы в YAML: `name` и `labels` должны быть вложены в `metadata`.

## Сломай и почини

Запуск: `~/notes/break/5.1/break.sh <n>` (n от 1 до 3, либо `random`). Скрипт не читай: цель в том, чтобы диагностировать по симптомам. После разбора верни рабочий кластер (`kind delete cluster --name notes`, затем создание из `kind/kind.yaml`).

### Симптом

Три возможные картины:

- `kubectl get nodes` отвечает `The connection to the server localhost:8080 was refused - did you specify the right host or port?`;
- `kind create cluster` падает с `port is already allocated`;
- в `kubectl get nodes` один из узлов в состоянии `NotReady`.

### Гипотезы

1. Kubectl не нашёл kubeconfig или в нём нет нужного контекста.
2. Порт хоста занят другим процессом или контейнером.
3. На узле не работает kubelet, либо контейнер узла остановлен.

### Проверки

```bash
kubectl config get-contexts
echo "$KUBECONFIG"
ls -l ~/.kube/config
sudo ss -tlnp | grep -E ':(80|443)\s'
docker ps -a --filter name=notes
docker exec notes-worker systemctl status kubelet --no-pager | head
kubectl describe node notes-worker | grep -A8 Conditions
```

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**Сценарий 1: `localhost:8080 was refused`.** Kubectl не нашёл конфигурацию и пошёл по адресу по умолчанию. Причины: `KUBECONFIG` указывает на пустой файл, `~/.kube/config` удалён или не выбран контекст. Проверка: `kubectl config get-contexts` пуст. Исправление: `kind export kubeconfig --name notes` (вернёт запись и контекст `kind-notes`), затем `kubectl config use-context kind-notes`.

**Сценарий 2: `port is already allocated`.** Порт 80 или 443 хоста слушает `nginx`, старый стенд Compose или прошлый кластер. Проверка: `sudo ss -tlnp | grep ':80 '` и `docker ps` покажут владельца. Исправление: останови владельца (`sudo systemctl stop nginx` или `docker compose down`), при остатках прошлой попытки выполни `kind delete cluster --name notes` и создай кластер снова.

**Сценарий 3: узел `NotReady`.** Kubelet на узле не шлёт heartbeat. Проверка: `kubectl describe node notes-worker`, в блоке Conditions будет `Ready False` или `Unknown`; `docker ps -a` покажет остановленный контейнер узла. Исправление: `docker start notes-worker` (контейнер остановлен) либо `docker exec notes-worker systemctl restart kubelet`. Через полминуты узел вернётся в `Ready`, а вытесненные поды пересоздадутся сами: цикл согласования в действии.

</details>

## Вопросы с собеседований

### 1. [junior] Перечисли компоненты control plane и скажи, что делает каждый.

`kube-apiserver` это единая точка входа, через неё ходят все, включая kubelet. `etcd` хранит состояние кластера. `scheduler` выбирает узел для нового пода. `controller-manager` запускает контроллеры, которые доводят фактическое состояние до желаемого. На узлах ещё kubelet, kube-proxy и containerd.

**Что хотят услышать:** что только apiserver разговаривает с etcd, что scheduler лишь выбирает узел, а запускает kubelet.

**Красный флаг:** «scheduler запускает контейнеры» или «etcd это балансировщик».

### 2. [middle] Что происходит от `kubectl apply -f deploy.yaml` до работающего контейнера?

Kubectl шлёт объект в apiserver, тот аутентифицирует, авторизует, валидирует и пишет в etcd. Контроллер Deployment создаёт ReplicaSet, тот создаёт поды. Scheduler назначает узел, kubelet на узле через CRI поднимает контейнер и докладывает статус.

**Что хотят услышать:** порядок, роль API как общей шины, отсутствие прямых вызовов между компонентами, слова watch и reconcile.

**Красный флаг:** «kubectl подключается к узлу и запускает контейнер».

### 3. [middle] etcd недоступен. Что будет с работающими приложениями и что делать?

Работающие поды продолжат обслуживать трафик: kubelet и runtime живут на узлах. Но API не отвечает, ничего нельзя изменить, ничего не самовосстановится. Восстанавливаю кворум etcd, а если данные потеряны, разворачиваю из снапшота (`etcdctl snapshot restore`). Поэтому бэкап etcd обязателен в самоуправляемых кластерах.

**Что хотят услышать:** разделение control plane и data plane, кворум, снапшоты, что в managed-кластере это забота провайдера.

**Красный флаг:** «все приложения упадут» или «etcd это просто кэш».

### 4. [junior] `kubectl get pods` отвечает `The connection to the server localhost:8080 was refused`. Твои действия?

Это значит, что kubectl не нашёл kubeconfig и пошёл по адресу по умолчанию. Смотрю `echo $KUBECONFIG`, `ls ~/.kube/config`, `kubectl config get-contexts`. Восстанавливаю конфиг (`kind export kubeconfig`, команда провайдера или запрос у администратора) и выбираю контекст.

**Что хотят услышать:** ошибка про клиента, а не про кластер; знание kubeconfig и контекстов.

**Красный флаг:** «перезагружу кластер» или «переустановлю kubectl».

### 5. [middle] Ты выполнил `kubectl delete` и понял, что был не в том контексте. Как не допускать этого?

Показывать текущий контекст в приглашении shell, держать отдельные kubeconfig для прода и теста, в скриптах указывать `--context` явно, а права на прод давать через RBAC так, чтобы случайное удаление было невозможно. В CI кластер указывают явно, а не берут «текущий».

**Что хотят услышать:** технические барьеры против ошибки оператора, а не «буду внимательнее».

**Красный флаг:** «просто проверять глазами».

### 6. [middle] Команда из трёх человек хочет Kubernetes ради одного сервиса на одной ВМ. Что ответишь?

Спрошу, какую проблему решаем. Если её нет (простой допустим, нагрузка ровная), Kubernetes добавит сложность: обновления, мониторинг, сеть, права. Предложу Compose или systemd, хороший откат и бэкапы, а к Kubernetes вернуться при росте числа сервисов. Если проблема в простое при деплое, покажу, как её закрыть проще.

**Что хотят услышать:** оценка цены и выгоды, готовность отговорить от лишнего.

**Красный флаг:** «Kubernetes нужен всем, это стандарт».

### 7. [middle] Ты удалил под, и он вернулся. Другой под удалил, и он не вернулся. Почему?

Первый принадлежал контроллеру (ReplicaSet через Deployment, StatefulSet), который поддерживает число копий. Второй создан голым `kubectl run` или манифестом Pod без владельца, восстанавливать его некому. Проверка: `kubectl get pod <имя> -o jsonpath='{.metadata.ownerReferences}'`.

**Что хотят услышать:** ownerReferences, роль ReplicaSet, что голые поды в проде не используют.

**Красный флаг:** «Kubernetes иногда сам решает».

### 8. [middle] Узел в статусе `NotReady`. Как разбираешься?

Смотрю `kubectl describe node`: блок Conditions и события. Захожу на узел: работает ли `kubelet` (`systemctl status kubelet`, `journalctl -u kubelet`), containerd, есть ли место на диске и память, доступен ли apiserver с узла. Если быстро не вернуть, делаю `cordon` и `drain`, поды переедут на другие узлы.

**Что хотят услышать:** путь от кластера вниз к узлу: describe, kubelet, runtime, диск, сеть; cordon и drain.

**Красный флаг:** «перезагружу все ноды».

### 9. [middle] Зачем нужны namespace и можно ли считать их границей безопасности?

Namespace группируют объекты, дают уникальность имён и точку привязки для RBAC, квот и сетевых политик. Сами по себе они не изолируют: без NetworkPolicy поды из разных namespace свободно общаются, а узлы и ядро общие. Для жёсткой изоляции нужны отдельные кластеры.

**Что хотят услышать:** «мягкая» изоляция и что к ней добавить (RBAC, NetworkPolicy, квоты, Pod Security).

**Красный флаг:** «namespace изолирует всё, как отдельные кластеры».

### 10. [middle] Кластер создан со стандартным CNI, а тебе нужны NetworkPolicy. Что делать?

CNI выбирается при создании кластера, в kind его нельзя заменить на лету. Описываю `disableDefaultCNI: true` в конфиге, создаю кластер заново и ставлю Calico или Cilium. В боевых кластерах CNI меняют, но это плановая операция с окном обслуживания.

**Что хотят услышать:** CNI это фундамент, kindnet стоит по умолчанию, есть альтернативы.

**Красный флаг:** «поставлю второй CNI поверх первого».

## Проверено на версиях

- kind: v0.33.0
- kubectl: 1.37.1
- Kubernetes (образ узла `kindest/node`): v1.37.1, проверь актуальный тег на странице релиза kind
- containerd и kindnet: из образа узла kind v0.33.0
- busybox: 1.37
- Docker Engine: версия не закреплена, проверь актуальную версию на странице проекта
- k9s: версия не закреплена, проверь актуальную версию на странице проекта
- Ubuntu: 26.04 LTS и 24.04

## Итог урока: ты умеешь

- [ ] умею объяснить, чем Kubernetes отличается от Compose и когда он не нужен
- [ ] умею назвать компоненты control plane и узла и что делает каждый
- [ ] умею по шагам рассказать, что происходит при `kubectl apply`
- [ ] умею установить kind и kubectl с проверкой SHA256
- [ ] умею создать кластер из `kind.yaml` и найти его узлы в Docker и системные поды
- [ ] умею читать `kubectl config get-contexts`, переключать контекст и namespace
- [ ] умею по событиям увидеть, какой компонент что сделал с подом
- [ ] умею починить `localhost:8080 refused`, `port is already allocated` и узел `NotReady`

**Дальше:** [Урок 5.2: Поды и Deployment: запускаем «Заметки»](02-pods-deployments.md)
