---
layout: lesson
title: "Service mesh: Istio ambient"
topic: 8
lesson: "8.10"
time: "2.5 ч"
---

## Зачем это нужно

В кластере десятки сервисов, и каждый команда пишет по-своему: один шифрует трафик, другой нет, у третьего нет таймаутов, а кто кому вообще разрешён ходить, никто не помнит. Сервисная сетка (service mesh) выносит шифрование, проверку «кто ты» и телеметрию из кода в инфраструктуру: приложение не меняется, а трафик между подами получает mTLS, политики доступа и метрики. Цена: лишние компоненты, ресурсы и новый класс поломок. На собеседованиях спрашивают именно про это: что даёт mesh, чем ambient отличается от sidecar и что делать, когда после включения политики сервис отвечает 503.
Шаг проекта: ставим Istio 1.31.1 в режиме ambient, включаем в него namespace `notes`, ограничиваем доступ к приложению через AuthorizationPolicy, добавляем waypoint с таймаутом и retry, а в конце урока Istio снимаем: в базовую платформу он не входит.

## Что нужно знать

- [Урок 5.3: Service и DNS](../05-kubernetes/03-services-dns.md) - Service и endpoints, к ним привязывается вся сетка
- [Урок 5.4: Ingress и Gateway API](../05-kubernetes/04-ingress-gateway.md) - Gateway, HTTPRoute и Envoy Gateway остаются входом в кластер
- [Урок 5.12: безопасность кластера](../05-kubernetes/12-k8s-security.md) - ServiceAccount, NetworkPolicy и PSS `restricted` в ns `notes`
- [Урок 2.6: TLS](../02-network/06-tls.md) - сертификаты, доверие и что такое взаимная проверка (mTLS)
- [Урок 8.9: мониторинг в Kubernetes](09-k8s-monitoring.md) - Prometheus в ns `monitoring` продолжает собирать метрики приложения

## Теория

### Что такое service mesh и зачем она

Сервисная сетка (service mesh) состоит из двух частей. Управляющая часть (control plane) хранит политики, выдаёт сертификаты и раздаёт настройки. Часть данных (data plane) это прокси, через которые реально идёт трафик между подами. Приложение об этом не знает: оно по-прежнему открывает соединение на `notes:8080`.

Что сетка даёт без правок кода:

- mTLS (mutual TLS): обе стороны предъявляют сертификаты, трафик шифруется, а у каждого пода есть проверяемая личность (identity). В Istio личность это SPIFFE-идентификатор вида `spiffe://cluster.local/ns/notes/sa/notes`, то есть привязка к namespace и ServiceAccount;
- авторизация: «сервис A может вызывать только `GET /notes` сервиса B»;
- телеметрия: метрики запросов и соединений между сервисами, трейсы;
- управление трафиком: таймауты, повторы (retry), распределение по версиям.

Чего сетка не даёт: она не чинит плохой код, не заменяет Kubernetes NetworkPolicy целиком и не отменяет валидацию на входе. Это ещё один слой, который надо эксплуатировать.

> **Проверь понимание:** назови две вещи, которые mesh делает без изменения кода приложения, и одну, которую не сделает.

<details markdown="1">
<summary>Ответ</summary>

Делает: шифрует трафик между подами (mTLS) и ограничивает, кто с кем может общаться (авторизация по identity); ещё собирает метрики запросов. Не сделает: не исправит ошибку в бизнес-логике, не защитит от SQL-инъекции и не заменит проверку прав пользователя внутри приложения.

</details>

### Sidecar и ambient: два способа поставить прокси

Классический режим (sidecar) добавляет в каждый под контейнер с Envoy. Плюсы: полный набор возможностей на уровне каждого пода. Минусы: память и CPU на каждый под, обновление mesh требует перезапуска всех подов, сайдкар может помешать старту приложения и завершению задач (Job).

Режим ambient убирает сайдкары и делит работу на два слоя:

- ztunnel (zero-trust tunnel) работает на каждом узле как DaemonSet. Он шифрует соединения между подами, проверяет identity и применяет простые (L4) политики: кто, откуда, на какой порт. Общается с другими ztunnel по протоколу HBONE (HTTP-based overlay network) на порту 15008;
- waypoint это необязательный Envoy, который поднимается отдельным Deployment для namespace или сервиса. Он нужен, когда важно содержимое HTTP: пути, методы, заголовки, таймауты, retry. Если L7 не нужен, waypoint не ставят и не платят за него.

Отсюда ключевое правило ambient: L4 (mTLS, политика по identity и порту) даёт ztunnel сразу, L7 (метод, путь, retry) только через waypoint. Подключить под к mesh можно меткой на namespace: поды перезапускать не нужно, это главное операционное отличие от sidecar.

> **Проверь понимание:** политика запрещает `DELETE /notes/1`, но waypoint не создан. Сработает ли она?

<details markdown="1">
<summary>Ответ</summary>

Нет. Метод и путь это L7, а ztunnel понимает только L4. Политика с L7-условием, привязанная к подам без waypoint, не будет обеспечена, поэтому правила про методы и пути пишут для waypoint. Это частая причина «политика есть, а трафик идёт».

</details>

### Из чего состоит Istio в ambient

При установке профиля `ambient` появляются три компонента в ns `istio-system`:

| Компонент | Тип | Роль |
|---|---|---|
| `istiod` | Deployment | control plane: раздаёт конфигурацию, выдаёт сертификаты |
| `ztunnel` | DaemonSet | шифрование и L4-политики на каждом узле |
| `istio-cni-node` | DaemonSet | перенаправляет трафик подов в ztunnel без initContainer |

Политики доступа задаются объектом `AuthorizationPolicy`. Ключевое поведение: пока для рабочей нагрузки нет ни одной политики, разрешено всё. Как только появилась хотя бы одна политика с действием `ALLOW`, разрешено только то, что в ней перечислено, всё остальное отклоняется. Ловушка: одна добавленная «разрешающая» политика неожиданно закрывает всё остальное, включая Prometheus и ingress.

Что видит клиент отклонённого соединения зависит от того, кто клиент. Envoy Gateway при обрыве соединения ответит 503 с текстом `upstream connect error or disconnect/reset before headers`. Классический curl из пода покажет `Connection reset by peer` или пустой ответ.

> **Проверь понимание:** в ns есть одна политика ALLOW для сервиса A. Сервис B, который раньше свободно ходил в A, перестал работать. Почему и как проверить?

<details markdown="1">
<summary>Ответ</summary>

Наличие ALLOW-политики переводит нагрузку в режим «только перечисленное». B не попал в список (по identity или namespace). Проверка: `kubectl get authorizationpolicy -A`, затем сравнить identity клиента (`kubectl get pod ... -o jsonpath` на serviceAccountName) с `from.source` политики.

</details>

## Практика

Среда: кластер kind `notes` (контекст `kind-notes`) с приложением из 8.9 (релиз Helm `notes`, версия образа 0.7.0, ns `notes`), Envoy Gateway и Gateway `notes-gw` из 5.4, `notes.lab` в `/etc/hosts`. Рабочий каталог `~/notes`. На узле kind Istio с профилем ambient требует около 1.5 ГБ памяти, вместе со стеком мониторинга из 8.9 нужно минимум 16 ГБ RAM.

### Если у тебя 8 ГБ

Освободи память перед уроком: удали стек мониторинга (`helm -n monitoring uninstall <релиз из 8.9>`, имя покажет `helm -n monitoring list`). Задание 4 про метрики ztunnel выполни по описанию без запуска. Политику из задания 3 оставь как есть: строка про namespace `monitoring` безвредна, если такого namespace нет. После урока стек мониторинга можно поставить заново командой из 8.9.

### Задание 1. Установка Istio ambient

**Цель:** поставить Istio 1.31.1 профилем `ambient` и убедиться, что три компонента работают.

**Предскажи:** сколько подов `ztunnel` будет в кластере kind с одним узлом? Будет ли в ns `notes` после установки хоть один новый под?

<details markdown="1">
<summary>Ответ</summary>

По одному `ztunnel` и `istio-cni-node` на каждый узел, значит по одному на узле kind. В ns `notes` новых подов нет: Istio ambient ничего не добавляет в поды и их не перезапускает.

</details>

**Шаги:**

1. Скачай `istioctl` и проверь контрольную сумму (без `curl | bash`):

```bash
cd "$(mktemp -d)"
V=1.31.1
BASE=https://github.com/istio/istio/releases/download/$V
curl -fsSLO "$BASE/istioctl-$V-linux-amd64.tar.gz"
curl -fsSLO "$BASE/istioctl-$V-linux-amd64.tar.gz.sha256"
sha256sum -c "istioctl-$V-linux-amd64.tar.gz.sha256"
tar xzf "istioctl-$V-linux-amd64.tar.gz"
sudo install -m 0755 istioctl /usr/local/bin/istioctl
istioctl version --remote=false
```

2. Установи Istio (Gateway API уже установлен вместе с Envoy Gateway в 5.4, отдельно его ставить не нужно):

```bash
kubectl config use-context kind-notes
istioctl install --set profile=ambient --skip-confirmation
kubectl -n istio-system get pods
```

**Что должно получиться:**

```text
istioctl-1.31.1-linux-amd64.tar.gz: OK
client version: 1.31.1
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-x7k2q      1/1     Running   0          40s
istiod-6c9d7b8f5-4hm2p    1/1     Running   0          55s
ztunnel-9wq5d             1/1     Running   0          40s
```

**Объясни себе:**

- Почему ztunnel развёрнут DaemonSet, а istiod Deployment?
- Что произойдёт с работающими подами `notes` сразу после установки?

**Типичные ошибки:**

- `Error: failed to install manifests: ... no matches for kind "Gateway"`: нет CRD Gateway API. Проверь `kubectl get crd gateways.gateway.networking.k8s.io`; они приходят с манифестом Envoy Gateway (урок 5.4).
- `sha256sum: WARNING: 1 computed checksum did NOT match`: архив скачался не полностью. Удали файл и скачай заново.
- `ztunnel ... CrashLoopBackOff` и в логах `too many open files`: у узла (контейнера kind) мало inotify-лимитов. Подними `sudo sysctl fs.inotify.max_user_instances=512` на хосте.

### Задание 2. Включаем namespace в mesh и смотрим mTLS

**Цель:** подключить `notes` к ambient без перезапуска подов и увидеть, что трафик между подами идёт по HBONE с identity.

**Предскажи:** изменится ли число контейнеров в поде `notes` после включения в mesh? Если из ns без mesh отправить запрос на `notes:8080`, он пройдёт?

<details markdown="1">
<summary>Ответ</summary>

Число контейнеров не изменится: прокси не внутри пода, а на узле. Запрос из ns без mesh пройдёт: режим по умолчанию разрешает и mTLS, и обычный трафик (в Istio это PERMISSIVE). Именно поэтому можно включать mesh постепенно.

</details>

**Шаги:**

1. Создай тестовый namespace клиентов и включи в ambient три namespace: приложение, клиенты и вход. Envoy Gateway включаем в mesh, чтобы его трафик имел identity:

```bash
kubectl create namespace mesh-lab
for ns in notes mesh-lab envoy-gateway-system monitoring; do
  kubectl get ns "$ns" >/dev/null 2>&1 && \
  kubectl label namespace "$ns" istio.io/dataplane-mode=ambient --overwrite
done
kubectl get ns -L istio.io/dataplane-mode
```

2. Если в ns `notes` действует default-deny из 5.12, разреши порт HBONE (учебное правило, не часть проекта):

```bash
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-hbone
  namespace: notes
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - ports:
        - port: 15008
          protocol: TCP
YAML
```

3. Запусти два клиента с разными ServiceAccount и вызови приложение:

```bash
kubectl -n mesh-lab create serviceaccount curl-ok
kubectl -n mesh-lab create serviceaccount curl-bad
for sa in curl-ok curl-bad; do
  kubectl -n mesh-lab run "$sa" --image=curlimages/curl:8.16.0 \
    --overrides="{\"spec\":{\"serviceAccountName\":\"$sa\"}}" \
    --command -- sleep 3600
done
kubectl -n mesh-lab wait --for=condition=Ready pod/curl-ok pod/curl-bad --timeout=90s
kubectl -n mesh-lab exec curl-ok -- curl -s http://notes.notes:8080/
```

4. Проверь, что трафик идёт через HBONE, и найди identity в логе ztunnel:

```bash
istioctl ztunnel-config workload -n notes
kubectl -n istio-system logs ds/ztunnel --tail=200 | grep 'dst.workload' | tail -n 2
```

**Что должно получиться:**

```text
Notes service v0.7.0
NAMESPACE POD NAME       ADDRESS     NODE          WAYPOINT PROTOCOL
notes     notes-7d9f8b6c5-x2k4p 10.244.0.15 notes-control-plane None     HBONE
```

В логе ztunnel видны поля `src.identity="spiffe://cluster.local/ns/mesh-lab/sa/curl-ok"` и `dst.service`. Число подов в `notes` и число контейнеров в них прежнее.

**Объясни себе:**

- Откуда у клиентского пода взялся SPIFFE-идентификатор, если приложение ничего не настраивало?
- Почему ingress из `envoy-gateway-system` мы включили в mesh, хотя Envoy Gateway остался прежним?

**Типичные ошибки:**

- `curl: (7) Failed to connect to notes.notes port 8080 after 5 ms: Could not connect to server`: в ns `notes` действует default-deny без правила для 15008. Примени `allow-hbone` из шага 2.
- `Error from server (Forbidden): pods "curl-ok" is forbidden: violates PodSecurity`: клиент создан в ns `notes` с PSS `restricted`. Клиенты живут в `mesh-lab`, там PSS не включён.
- Пусто в `PROTOCOL` (`TCP` вместо `HBONE`): namespace без метки или под создан до istio-cni. Проверь `kubectl get ns notes --show-labels` и перезапусти под.

### Задание 3. AuthorizationPolicy: пускаем только своих

**Цель:** ограничить доступ к приложению так, чтобы работали ingress, Prometheus и один клиент, а второй клиент получил отказ.

**Предскажи:** после применения политики `ALLOW` на `notes` что получит `curl-bad`? А что увидит внешний пользователь через `https://notes.lab`, если `envoy-gateway-system` не перечислить в политике?

<details markdown="1">
<summary>Ответ</summary>

`curl-bad` получит отказ на уровне соединения (`curl: (56) Recv failure: Connection reset by peer` или `(52) Empty reply`). Внешний пользователь без строки про `envoy-gateway-system` получит 503 от Envoy Gateway: `upstream connect error or disconnect/reset before headers. reset reason: connection termination`. Политика ALLOW отсекает всё, что не перечислено.

</details>

**Шаги:**

1. Создай `k8s/mesh/authz-policy.yaml`:

```yaml
# Разрешаем доступ к приложению notes только доверенным источникам.
# Всё, что не перечислено, отклоняется ztunnel (L4, по identity).
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: notes-allow
  namespace: notes
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: notes
  action: ALLOW
  rules:
    - from:
        # Вход в кластер: Envoy Gateway
        - source:
            namespaces: ["envoy-gateway-system"]
        # Сбор метрик: Prometheus
        - source:
            namespaces: ["monitoring"]
        # Единственный разрешённый учебный клиент
        - source:
            principals: ["cluster.local/ns/mesh-lab/sa/curl-ok"]
      to:
        - operation:
            ports: ["8080"]
```

2. Примени и проверь три пути:

```bash
kubectl apply -f k8s/mesh/authz-policy.yaml
kubectl -n mesh-lab exec curl-ok -- curl -s -o /dev/null -w '%{http_code}\n' http://notes.notes:8080/healthz
kubectl -n mesh-lab exec curl-bad -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://notes.notes:8080/healthz
curl -sk --resolve notes.lab:443:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://notes.lab/healthz
```

**Что должно получиться:**

```text
200
000
200
```

`000` у `curl-bad` значит, что соединение оборвано до ответа.

**Объясни себе:**

- Почему отказ приходит не как HTTP 403, а как обрыв соединения?
- Что случилось бы с метриками в Prometheus, если бы строки `monitoring` не было?

**Типичные ошибки:**

- `error: unable to recognize "k8s/mesh/authz-policy.yaml": no matches for kind "AuthorizationPolicy" in version "security.istio.io/v1"`: Istio не установлен или CRD не созданы; вернись к заданию 1.
- `upstream connect error or disconnect/reset before headers. reset reason: connection termination` на `https://notes.lab`: вход не в списке. Проверь, что `envoy-gateway-system` в ambient и стоит в политике.
- `curl-ok` тоже получает `000`: опечатка в identity. Он строится как `cluster.local/ns/<namespace>/sa/<serviceaccount>`, без префикса `spiffe://`.

### Задание 4. Waypoint: таймаут, retry и L7

**Цель:** добавить waypoint для сервиса `notes` и настроить таймаут и повтор запросов, которых без него не было.

**Предскажи:** демонстрационный `/slow?sec=5` при таймауте 2 секунды на waypoint. Какой статус вернётся клиенту и сколько времени займёт запрос?

<details markdown="1">
<summary>Ответ</summary>

Около 2 секунд и статус 504 (Gateway Timeout): waypoint сам обрывает ожидание. Без waypoint запрос длился бы все 5 секунд и вернул 200.

</details>

**Шаги:**

1. Создай `k8s/mesh/waypoint.yaml`: сам waypoint и правило для внутренних вызовов сервиса `notes`:

```yaml
# Waypoint: L7-прокси для сервисов namespace notes.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: notes
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
---
# Таймаут и повторы для вызовов Service notes внутри кластера.
# Поле retry в Gateway API экспериментальное: проверь актуальную версию на странице проекта.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: notes-mesh
  namespace: notes
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: notes
      port: 8080
  rules:
    - timeouts:
        request: 2s
      retry:
        attempts: 2
        backoff: 100ms
        codes: [503]
      backendRefs:
        - name: notes
          port: 8080
```

2. Примени, привяжи waypoint к namespace и проверь таймаут:

```bash
kubectl apply -f k8s/mesh/waypoint.yaml
kubectl -n notes wait --for=condition=Programmed gateway/waypoint --timeout=90s
kubectl label namespace notes istio.io/use-waypoint=waypoint --overwrite
istioctl ztunnel-config service -n notes | grep -E 'NAME|notes '
time kubectl -n mesh-lab exec curl-ok -- curl -s -o /dev/null -w '%{http_code}\n' 'http://notes.notes:8080/slow?sec=5'
```

**Что должно получиться:**

```text
gateway.gateway.networking.k8s.io/waypoint condition met
NAMESPACE SERVICE NAME       SERVICE VIP   WAYPOINT ENDPOINTS
notes     notes              10.96.44.120  waypoint 1/1
504

real    0m2.1s
```

**Объясни себе:**

- Почему таймаут потребовал waypoint, а mTLS в задании 2 нет?
- Чем повтор запроса опасен для `POST /notes` и когда retry безопасен (вернёшься к вопросу в [уроке 8.11](11-reliability-patterns-burn-rate.md))?

**Типичные ошибки:**

- `The HTTPRoute "notes-mesh" is invalid: spec.rules[0].retry: Invalid value`: в CRD Gateway API нет экспериментального поля. Убери блок `retry`, таймаут останется рабочим.
- `WAYPOINT` пустой в списке сервисов: не выставлена метка `istio.io/use-waypoint` на namespace или сервис.
- Запрос на `/slow?sec=5` возвращает 200 за 5 секунд: трафик идёт мимо waypoint. Проверь, что клиент в ambient namespace и вызывает имя сервиса, а не IP пода.

### Задание 5. Шаг проекта: mesh в «Заметках» и уборка

**Цель:** зафиксировать mesh-манифесты в проекте, убедиться, что сервис по-прежнему доступен снаружи, и снять Istio, потому что в базовую платформу он не входит.

**Предскажи:** после `istioctl uninstall` метки `istio.io/dataplane-mode` на namespace останутся. Что произойдёт с трафиком?

<details markdown="1">
<summary>Ответ</summary>

Трафик пойдёт как обычно: метка сама по себе ничего не делает без ztunnel. Но AuthorizationPolicy и Gateway `waypoint` остаются как объекты; их нужно удалить явно, иначе кластер захламлён. Метки тоже убирай.

</details>

**Шаги:**

1. Убедись, что в репозитории лежат оба файла, и закоммить:

```bash
cd ~/notes
ls k8s/mesh/
git add k8s/mesh/authz-policy.yaml k8s/mesh/waypoint.yaml
git commit -m "Istio ambient: AuthorizationPolicy и waypoint (учебный шаг 8.10)"
```

2. Проверь полный путь снаружи и метрики через Prometheus (пропусти второе в режиме 8 ГБ):

```bash
curl -sk --resolve notes.lab:443:127.0.0.1 https://notes.lab/
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 3; curl -s 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22notes%22%7D' | head -c 200; kill %1
```

3. Сними mesh в правильном порядке: политики и метки, потом Istio:

```bash
kubectl delete -f k8s/mesh/authz-policy.yaml -f k8s/mesh/waypoint.yaml
for ns in notes mesh-lab envoy-gateway-system monitoring; do
  kubectl label namespace "$ns" istio.io/dataplane-mode- istio.io/use-waypoint- 2>/dev/null
done
kubectl delete networkpolicy allow-hbone -n notes --ignore-not-found
kubectl delete namespace mesh-lab
istioctl uninstall --purge -y
kubectl delete namespace istio-system
kubectl -n notes get pods
```

**Что должно получиться:**

```text
Notes service v0.7.0
{"status":"success","data":{"resultType":"vector","result":[{"metric":{"job":"notes"
namespace "istio-system" deleted
NAME                     READY   STATUS    RESTARTS   AGE
notes-7d9f8b6c5-x2k4p    1/1     Running   0          2h
```

Проект: `k8s/mesh/authz-policy.yaml` и `k8s/mesh/waypoint.yaml`, приложение v7, образ 0.7.0. Эталон: [k8s/mesh](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/mesh).

**Объясни себе:**

- Почему порядок «сначала политики и метки, потом uninstall» важен?
- Что из mesh тебе реально нужно в проде «Заметок», а что избыточно?

**Типичные ошибки:**

- `Error from server (NotFound): error when deleting "k8s/mesh/waypoint.yaml": gateways.gateway.networking.k8s.io "waypoint" not found`: уже удалён вручную. Безвредно, ключ `--ignore-not-found` заглушит.
- `namespace "istio-system" is being terminated` долго: ждёт удаления ресурсов. Посмотри `kubectl get all -n istio-system`, обычно проходит за минуту.
- Приложение отвечает 503 после uninstall: остался `AuthorizationPolicy` или waypoint. `kubectl get authorizationpolicy,gateway -A`.

## Сломай и почини

Скачай скрипт по прямой ссылке и запусти один из сценариев (номер 1-3 или `random`). Содержимое скрипта не читай: цель найти причину по симптомам.

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/8.10/break.sh
bash break.sh random
```

### Симптом

Тебе сообщили одно из трёх: (1) снаружи `https://notes.lab` отвечает `503 upstream connect error or disconnect/reset before headers`, хотя поды `Running`; (2) трафик между сервисами не шифруется, ztunnel показывает `TCP` вместо `HBONE`; (3) таймаут 2 секунды в `HTTPRoute` есть, но `/slow?sec=5` всё равно отвечает 200 через 5 секунд.

### Гипотезы

1. Политика `AuthorizationPolicy` отсекает вход (Envoy Gateway не в списке разрешённых).
2. Namespace не включён в ambient (нет метки), либо под создан раньше и не подхвачен.
3. Waypoint создан, но не привязан к сервису или namespace (нет метки `istio.io/use-waypoint`, waypoint не `Programmed`).

### Проверки

```bash
kubectl get authorizationpolicy -A
kubectl get ns notes envoy-gateway-system --show-labels
istioctl ztunnel-config workload -n notes
istioctl ztunnel-config service -n notes
kubectl -n notes get gateway waypoint
kubectl -n istio-system logs ds/ztunnel --tail=50 | grep -i deny
```

Смотри на: есть ли ALLOW-политика и кого она перечисляет; колонку `PROTOCOL` (HBONE или TCP); колонку `WAYPOINT` у сервиса; в логе ztunnel слова `policy rejection`.

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

1. Политика без `envoy-gateway-system` (или с неверным identity): поправь `from.source` в `k8s/mesh/authz-policy.yaml`, `kubectl apply`. Идентификатор строится как `cluster.local/ns/<ns>/sa/<sa>`, а вход проверяй по namespace. Проверка: `curl -sk --resolve notes.lab:443:127.0.0.1 https://notes.lab/healthz` отдаёт 200.
2. Нет метки: `kubectl label namespace notes istio.io/dataplane-mode=ambient`. Поды перезапускать не нужно, но новые соединения пойдут по HBONE, а долгоживущие старые останутся как были.
3. Waypoint не привязан: `kubectl label namespace notes istio.io/use-waypoint=waypoint`, дождись `Programmed` у Gateway. Проверка: колонка `WAYPOINT` в `ztunnel-config service` не пуста, а `/slow?sec=5` даёт 504 за 2 секунды.

Общая мысль: в ambient у каждой из трёх поломок свой слой. Идентичность и метки смотри в ztunnel, L7-правила смотри в waypoint, вход смотри в Gateway.

</details>

## Вопросы с собеседований

### 1. [junior] Что даёт service mesh и когда она не нужна?

Mesh даёт mTLS между сервисами, авторизацию по identity, метрики и управление трафиком (таймауты, retry) без правок кода. Для трёх сервисов и одной команды она обычно не нужна: хватит TLS на входе, NetworkPolicy и библиотек с таймаутами. Нужна, когда сервисов много, команд несколько и нужны единые правила шифрования и доступа.

**Что хотят услышать:** конкретные функции, цену (ресурсы, сложность, ещё один слой отказов), критерий выбора.

**Красный флаг:** «mesh нужна всем, потому что это современно» или «это просто балансировщик».

### 2. [middle] Чем ambient отличается от sidecar и что ты выберешь для нового кластера?

В sidecar в каждом поде свой Envoy: много памяти, обновление mesh требует рестарта подов. В ambient шифрование и L4-политики делает ztunnel на узле, а L7 берёт на себя необязательный waypoint. Для нового кластера с умеренными требованиями к L7 я бы начал с ambient: меньше ресурсов и проще обновление. Sidecar оставил бы там, где нужны L7-функции на каждом поде и есть опыт.

**Что хотят услышать:** ztunnel против waypoint, L4 против L7, подключение меткой без рестарта, компромиссы.

**Красный флаг:** не знает, что L7-политики в ambient требуют waypoint.

### 3. [middle] Прод отвечает 503 `upstream connect error or disconnect/reset before headers` сразу после добавления AuthorizationPolicy. Что делаешь?

Первым делом откатываю политику или добавляю недостающий источник, чтобы снять инцидент. Потом разбираюсь: `kubectl get authorizationpolicy -A`, смотрю, что ALLOW-политика закрыла всё неперечисленное, сверяю identity входа и Prometheus с `from.source`, читаю лог ztunnel на policy rejection.

**Что хотят услышать:** понимание, что одна ALLOW-политика переводит нагрузку в «запрещено всё остальное», проверка ingress и мониторинга, порядок «сначала восстановить».

**Красный флаг:** перезапускает поды и приложение, не глядя на политики.

### 4. [middle] После включения mesh в namespace часть трафика идёт без шифрования. Как проверить и почему так бывает?

Смотрю `istioctl ztunnel-config workload` и колонку протокола: `HBONE` значит трафик в mesh, `TCP` нет. Причины: у клиента или сервера namespace без метки ambient, старый под, трафик идёт из-вне mesh. В режиме PERMISSIVE незашифрованный трафик разрешён; для запрета включают строгий режим (`PeerAuthentication` в режиме STRICT).

**Что хотят услышать:** PERMISSIVE против STRICT, проверка по протоколу, необходимость обе стороны в mesh.

**Красный флаг:** «раз Istio стоит, всё шифруется».

### 5. [junior] Что такое mTLS и чем он отличается от обычного TLS?

В обычном TLS клиент проверяет сервер, а сервер клиента нет. В mTLS сертификаты предъявляют обе стороны, поэтому сервер знает, кто именно к нему пришёл. В mesh сертификаты выдаёт control plane, и они привязаны к ServiceAccount пода, поэтому политики пишут по identity, а не по IP.

**Что хотят услышать:** взаимная проверка, identity вместо IP, автоматическая выдача и ротация сертификатов.

**Красный флаг:** путает mTLS с «шифрованием паролем».

### 6. [middle] Хочешь запретить `DELETE` на сервисе, но политика не срабатывает. В чём дело?

Метод это L7, а ztunnel понимает только L4. Без waypoint правило про метод не применяется к трафику. Создаю waypoint для сервиса или namespace, привязываю его и переношу политику на waypoint (`targetRefs`). Проверяю, что у сервиса в `ztunnel-config service` стоит WAYPOINT.

**Что хотят услышать:** граница L4/L7 в ambient, привязка waypoint.

**Красный флаг:** «политика написана правильно, значит баг Istio».

### 7. [middle] Ты включил retry на уровне mesh, а приложение тоже повторяет запросы. Что произойдёт?

Повторы перемножаются: 3 попытки в приложении на 3 попытки в mesh дают до 9 запросов к упавшему сервису, и нагрузка на него растёт именно тогда, когда ему плохо (retry storm). Повторять нужно на одном уровне, с ограничением числа попыток, с backoff и jitter, и только идемпотентные запросы.

**Что хотят услышать:** усиление нагрузки, идемпотентность, единое место для retry, ссылка на бюджет повторов.

**Красный флаг:** «чем больше retry, тем надёжнее».

### 8. [middle] Команда просит включить Istio во всём кластере в пятницу. Как ты это организуешь?

Отказываюсь от «всего сразу». Включаю mesh по одному namespace, начиная с некритичного, в PERMISSIVE. Проверяю метрики и ошибки, потом добавляю вход и мониторинг в mesh, потом политики от простых к строгим, у каждой есть откат одной командой. Пятница не лучший день для первого шага.

**Что хотят услышать:** постепенность, откат, наблюдаемость до и после, риск для ingress и мониторинга.

**Красный флаг:** «включим метку на все namespace сразу».

### 9. [middle] Prometheus перестал собирать метрики приложения после включения mesh-политики. Причины?

Скорее всего ALLOW-политика не перечисляет Prometheus. Проверяю политики на нагрузке, identity или namespace Prometheus и включён ли он в mesh (без mesh у него нет identity, и правило по namespace не сработает). Ещё смотрю NetworkPolicy и порт HBONE 15008.

**Что хотят услышать:** ALLOW закрывает остальное, у клиента вне mesh нет identity, порядок диагностики.

**Красный флаг:** идёт менять scrape-конфиг Prometheus, не проверив политику.

### 10. [middle] Как из mesh получить метрики и что это даст SRE?

ztunnel отдаёт метрики уровня TCP (соединения, байты) на порту 15020, waypoint отдаёт HTTP-метрики (запросы, коды, латентность) в формате Prometheus. Их собирают через ServiceMonitor или PodMonitor. Это готовые золотые сигналы между сервисами без правок кода: ошибки и задержки видны по паре «клиент, сервер».

**Что хотят услышать:** L4 против L7 метрики, Prometheus, связка с SLO.

**Красный флаг:** считает, что L7-метрики есть без waypoint.

## Проверено на версиях

- Istio: 1.31.1 (профиль `ambient`)
- Envoy Gateway: v1.9.2
- Kubernetes: версия из kind, закреплённого в уроке 5.1
- Gateway API: CRD из релиза Envoy Gateway v1.9.2 (поле `retry` в HTTPRoute экспериментальное: проверь актуальную версию на странице проекта)
- curl (образ клиента): curlimages/curl 8.16.0
- kube-prometheus-stack: chart 91.8.2

## Итог урока: ты умеешь

- [ ] умею объяснить, что даёт service mesh и чем ambient отличается от sidecar
- [ ] умею установить Istio ambient и проверить его компоненты
- [ ] умею подключить namespace к mesh меткой и увидеть HBONE и identity
- [ ] умею написать AuthorizationPolicy по namespace и ServiceAccount и предсказать, кого она закроет
- [ ] умею создать waypoint и настроить таймаут для сервиса
- [ ] умею диагностировать 503 после включения политики по политикам, меткам и логу ztunnel
- [ ] умею снять Istio без остатка, не сломав вход и мониторинг

**Дальше:** [Урок 8.11: Надёжность: retry, circuit breaker и burn-rate алерты](11-reliability-patterns-burn-rate.md)
