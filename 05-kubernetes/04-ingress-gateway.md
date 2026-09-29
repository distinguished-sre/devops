---
layout: lesson
title: "Вход в кластер: Ingress и Gateway API"
topic: 5
lesson: "5.4"
time: "2.5 ч"
---

## Зачем это нужно

Service из прошлого урока живёт только внутри кластера. Пользователь приходит с браузером, по имени `notes.lab`, на порты 80 и 443, и ему нужен HTTPS. Кто-то должен принять соединение снаружи, расшифровать TLS, выбрать сервис по имени хоста и пути. В 2026 на собеседованиях спрашивают не «что такое Ingress», а «почему ingress-nginx больше не выбирают для нового проекта и чем его заменяют».
Ingress (входное правило) заморожен, проект ingress-nginx выведен из поддержки, новые кластеры строят на Gateway API. Ты поставишь Envoy Gateway, опишешь вход тремя маленькими манифестами и разберёшь три типовые поломки.
Шаг проекта: «Заметки» открываются снаружи кластера по `http(s)://notes.lab` через Gateway `notes-gw` и HTTPRoute `notes`.

## Что нужно знать

- [Урок 5.1: свой кластер kind](01-why-k8s-cluster.md) - кластер `notes` с пробросом портов 80 и 443 на NodePort 30080 и 30443
- [Урок 5.2: Deployment](02-pods-deployments.md) - три пода `notes`, метки и `kubectl get`, `describe`
- [Урок 5.3: Service и DNS кластера](03-services-dns.md) - Service `notes` на порту 8080, endpoints, `kubectl port-forward`
- [Урок 2.5: nginx как reverse proxy](../02-network/05-nginx.md) - то же самое, что мы сейчас повторим на уровне кластера
- [Урок 2.6: TLS и HTTPS](../02-network/06-tls.md) - сертификат, ключ, SAN, самоподписанный сертификат
- [Урок 2.4: HTTP](../02-network/04-http.md) - заголовок `Host`, коды 404, 502, 503

## Теория

### Как трафик попадает в кластер

Pod и ClusterIP недоступны снаружи. Есть три способа впустить трафик. NodePort открывает порт на каждом узле (30000-32767): просто, но порты неудобные и нет разбора по имени хоста. LoadBalancer просит у облака внешний балансировщик, в kind его нет. Третий способ: один общий прокси (reverse proxy) в кластере, который слушает 80 и 443, читает `Host` и путь и раздаёт запросы по Service. Это тот же nginx из урока 2.5, только настраивается объектами Kubernetes, а не файлом.

Важная деталь: сам объект (Ingress, Gateway, HTTPRoute) ничего не делает. Это только описание желаемого. Работу выполняет контроллер (controller): программа в кластере, которая читает объекты и настраивает реальный прокси. Нет контроллера: объект создан, а трафика нет.

> **Проверь понимание:** ты создал Ingress, `kubectl get ingress` показывает его, а `curl` не отвечает. Что первым делом проверишь?

<details markdown="1">
<summary>Ответ</summary>

Есть ли в кластере Ingress-контроллер и подходит ли `ingressClassName`. Объект Ingress сам по себе трафик не пропускает, его должен подхватить контроллер. Признак: пустая колонка ADDRESS.

</details>

### Ingress: что это и почему он застыл

Ingress (`networking.k8s.io/v1`) описывает правила «хост и путь -> Service». Он умеет мало: маршрутизация HTTP по хосту и пути, TLS на одном хосте. Всё остальное (переписывание путей, таймауты, лимиты, редиректы) контроллеры реализовали через аннотации (annotations), у каждого свои. Манифест под ingress-nginx не работает под Traefik. Плюс один объект держит и точку входа, и маршруты: команда приложения, чтобы поправить маршрут, получает права и на сертификаты всего кластера.

Ingress не удалён и будет жить годами, но развитие остановлено. Самый популярный контроллер ingress-nginx архивирован (выведен из поддержки в марте 2026, проверь актуальный статус на странице проекта). Новые кластеры строят на Gateway API, а Ingress ты обязан уметь читать: в старых кластерах он везде.

### Gateway API: три роли и три объекта

Gateway API делит вход на слои по ролям (role-oriented):

| Объект | Кто владеет | Что описывает |
|---|---|---|
| GatewayClass | провайдер платформы | какой контроллер обслуживает шлюзы (аналог StorageClass) |
| Gateway | администратор кластера | точка входа: порты, протоколы, имена хостов, сертификаты |
| HTTPRoute | команда приложения | маршруты: хост, путь, заголовки, веса, backend Service |

HTTPRoute привязывается к Gateway через `parentRefs`. Gateway решает, чьи маршруты пускать (`allowedRoutes`), поэтому разработчик не может тихо перехватить чужой домен. Возможности, ради которых раньше писали аннотации, теперь часть стандарта: веса трафика (канареечные релизы, тема 9), сопоставление по заголовкам, переписывание пути, редиректы. Есть и не-HTTP: GRPCRoute, TLSRoute, TCPRoute.

Статус пишет контроллер в `status.conditions` каждого объекта. Главные условия: у Gateway `Accepted` и `Programmed`, у HTTPRoute `Accepted` (Gateway принял маршрут) и `ResolvedRefs` (backend Service найден). Диагностика Gateway API почти всегда это чтение conditions.

### Envoy Gateway и kind

Gateway API сам по себе только набор CRD (Custom Resource Definition, пользовательские типы объектов). Реализаций много: Envoy Gateway, Traefik, Cilium, Istio, NGINX Gateway Fabric. В курсе Envoy Gateway v1.9.2: его манифест релиза уже содержит CRD Gateway API v1.6.2. Он ставится одним `kubectl apply` без Helm (Helm появится в [уроке 5.9](09-helm.md)).

Как это работает: контроллер `envoy-gateway` в namespace `envoy-gateway-system` видит твой Gateway и сам создаёт Deployment и Service с Envoy (это и есть прокси). В облаке Service получил бы тип LoadBalancer. В kind балансировщика нет, поэтому через объект EnvoyProxy мы просим тип NodePort с фиксированными портами 30080 и 30443. Именно их kind пробросил на порты 80 и 443 твоего компьютера ещё в уроке 5.1 (`extraPortMappings`). Получается цепочка: `notes.lab:80` -> `127.0.0.1:80` -> узел kind `:30080` -> Envoy -> Service `notes` -> под.

> **Проверь понимание:** почему для kind порты Service Envoy нужно закрепить, а в облаке не нужно?

<details markdown="1">
<summary>Ответ</summary>

kind пробросил на хост только конкретные порты узла (30080 и 30443). NodePort по умолчанию случайный из диапазона 30000-32767 и не совпал бы с пробросом. В облаке балансировщик получает свой адрес и порты 80 и 443.

</details>

### TLS на Gateway

Сертификат хранится в Secret типа `kubernetes.io/tls` (ключи `tls.crt` и `tls.key`). Listener HTTPS в Gateway ссылается на него через `certificateRefs`. TLS завершается на Envoy (`mode: Terminate`), до пода трафик идёт по HTTP внутри кластера. По умолчанию Secret должен лежать в том же namespace, что и Gateway: другой namespace требует явного разрешения (ReferenceGrant), об этом будет поломка в конце урока.

Долг проекта: Secret мы создаём командой из самоподписанного сертификата, и браузер ему не доверяет. В [уроке 9.4](../09-secrets-gitops/04-cert-manager-tls.md) его заменит cert-manager.

## Практика

### Задание 1. Ingress без контроллера

**Цель:** увидеть, что объект Ingress сам по себе ничего не делает, и запомнить формат для чтения чужих кластеров.

**Предскажи:** мы создадим Ingress для `notes.lab` в кластере, где нет контроллера. Что покажет колонка ADDRESS и что ответит `curl`?

<details markdown="1">
<summary>Ответ</summary>

ADDRESS пустой, потому что никто не обработал объект. `curl` получит отказ соединения (порт 80 на узле kind ничем не слушается), хотя Ingress создан без ошибок.

</details>

**Шаги:**

1. Создай Ingress временным файлом (контекст `kind-notes` и Service `notes` из урока 5.3 уже есть), применяй и смотри.

   ```bash
   mkdir -p ~/notes/k8s && cd ~/notes
   cat > /tmp/ingress-demo.yaml <<'YAML'
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: notes-demo
     namespace: notes
   spec:
     ingressClassName: nginx        # такого контроллера у нас нет
     rules:
       - host: notes.lab
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: notes
                   port:
                     number: 8080
   YAML
   kubectl apply -f /tmp/ingress-demo.yaml
   kubectl get ingress -n notes
   curl -sS -m 3 --resolve notes.lab:80:127.0.0.1 http://notes.lab/healthz
   ```

2. Удали демо: Ingress нужен был только для сравнения.

   ```bash
   kubectl delete -f /tmp/ingress-demo.yaml && rm /tmp/ingress-demo.yaml
   ```

**Что должно получиться:**

```text
NAME         CLASS   HOSTS       ADDRESS   PORTS   AGE
notes-demo   nginx   notes.lab             80      5s
curl: (7) Failed to connect to notes.lab port 80 after 0 ms: Couldn't connect to server
```

**Объясни себе:**

- Почему объект создался без ошибок, если контроллера нет?

**Типичные ошибки:**

- `Error from server (NotFound): namespaces "notes" not found`: не создан namespace из урока 5.1: `kubectl apply -f k8s/base/00-namespace.yaml`.

### Задание 2. Ставим Envoy Gateway

**Цель:** получить в кластере контроллер и CRD Gateway API.

**Предскажи:** какие новые типы объектов появятся после установки и в каком namespace запустится контроллер?

<details markdown="1">
<summary>Ответ</summary>

Появятся CRD `gateways`, `gatewayclasses`, `httproutes` и другие из `gateway.networking.k8s.io`, а также `envoyproxies` из `gateway.envoyproxy.io`. Контроллер запустится в namespace `envoy-gateway-system`.

</details>

**Шаги:**

1. Установи манифест релиза. Ключ `--server-side` нужен: CRD слишком велики для обычного `apply` (аннотация не влезает в лимит).

   ```bash
   kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.9.2/install.yaml
   kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
   ```

2. Проверь результат.

   ```bash
   kubectl get pods -n envoy-gateway-system
   kubectl get crd | grep -c 'gateway.networking.k8s.io'
   ```

**Что должно получиться:**

```text
NAME                            READY   STATUS    RESTARTS   AGE
envoy-gateway-7b9c8d6f5-x2k4q   1/1     Running   0          40s
```

Второй командой ты получишь число больше нуля (CRD Gateway API). Имя пода и хэш у тебя будут другими.

**Объясни себе:**

- Почему CRD ставятся вместе с контроллером, а не лежат в самом Kubernetes?

**Типичные ошибки:**

- `Too long: must have at most 262144 bytes`: применили без `--server-side`: повтори с `--server-side`.
- `error: timed out waiting for the condition`: слабый диск или сеть тянут образ: `kubectl describe pod -n envoy-gateway-system`, смотри Events.

### Если у тебя 8 ГБ

Envoy Gateway и три пода `notes` вместе с kind укладываются в 8 ГБ, но впритык. Снизь нагрузку: оставь у Deployment `notes` две реплики (`kubectl scale deploy/notes -n notes --replicas=2`) и закрой браузер и IDE на время урока. Ничего другого ставить не нужно, Envoy запускается в одном экземпляре. В конце урока верни три реплики.

### Задание 3. Gateway и HTTPRoute

**Цель:** описать вход манифестами и получить ответ `notes` через `http://notes.lab`.

**Предскажи:** что будет, если применить только HTTPRoute без Gateway? Что покажет его статус?

<details markdown="1">
<summary>Ответ</summary>

Объект создастся, но `Accepted` не станет True: маршруту не к кому привязаться (parentRef указывает на несуществующий Gateway). Трафика не будет. Ошибки от API не будет, ошибка живёт только в статусе.

</details>

**Шаги:**

1. Файл `~/notes/k8s/base/30-envoyproxy.yaml`: настройки Envoy (NodePort с фиксированными портами).

   ```yaml
   apiVersion: gateway.envoyproxy.io/v1alpha1
   kind: EnvoyProxy
   metadata:
     name: notes-proxy
     namespace: envoy-gateway-system
   spec:
     provider:
       type: Kubernetes
       kubernetes:
         envoyService:
           type: NodePort           # в kind нет облачного балансировщика
           patch:
             type: StrategicMerge
             value:
               spec:
                 ports:
                   - name: http-80
                     port: 80
                     nodePort: 30080   # kind пробросил его на порт 80 хоста
                   - name: https-443
                     port: 443
                     nodePort: 30443   # и этот на 443
   ```

2. Файл `~/notes/k8s/base/31-gateway.yaml`: класс и точка входа с двумя listeners.

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata:
     name: eg
   spec:
     controllerName: gateway.envoyproxy.io/gatewayclass-controller
     parametersRef:
       group: gateway.envoyproxy.io
       kind: EnvoyProxy
       name: notes-proxy
       namespace: envoy-gateway-system
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: notes-gw
     namespace: notes
   spec:
     gatewayClassName: eg
     listeners:
       - name: http
         protocol: HTTP
         port: 80
         hostname: notes.lab
         allowedRoutes:
           namespaces:
             from: Same           # пускаем маршруты только из namespace notes
       - name: https
         protocol: HTTPS
         port: 443
         hostname: notes.lab
         tls:
           mode: Terminate
           certificateRefs:
             - kind: Secret
               name: notes-tls    # Secret создадим в задании 4
         allowedRoutes:
           namespaces:
             from: Same
   ```

3. Файл `~/notes/k8s/base/32-httproute.yaml`: маршрут команды приложения.

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: notes
     namespace: notes
   spec:
     parentRefs:
       - name: notes-gw           # к какому Gateway привязываемся
     hostnames:
       - notes.lab
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: notes          # Service из урока 5.3
             port: 8080
   ```

4. Применяй и жди. Listener HTTPS пока будет с ошибкой: Secret ещё нет, это нормально.

   ```bash
   kubectl apply -f k8s/base/30-envoyproxy.yaml -f k8s/base/31-gateway.yaml -f k8s/base/32-httproute.yaml
   kubectl get gatewayclass eg
   kubectl get httproute notes -n notes -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}'
   curl -s -o /dev/null -w '%{http_code}\n' --resolve notes.lab:80:127.0.0.1 http://notes.lab/healthz
   ```

**Что должно получиться:**

```text
NAME   CONTROLLER                                      ACCEPTED   AGE
eg     gateway.envoyproxy.io/gatewayclass-controller   True       20s
Accepted ResolvedRefs
200
```

Если `curl` сразу вернул `000`, подожди 20-30 секунд: Envoy стартует после создания Gateway.

**Объясни себе:**

- Кто создал Service и Deployment с Envoy, если их нет в твоих манифестах?
- Что означает `from: Same` и что случится с HTTPRoute из другого namespace?

**Типичные ошибки:**

- `no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"`: CRD не установлены: вернись к заданию 2.
- `curl: (7) Failed to connect to notes.lab port 80`: Envoy ещё не запущен или порты не сошлись: `kubectl get svc -n envoy-gateway-system`, ищи `80:30080/TCP`.
- Ответ `404` с пустым телом: Envoy жив, но маршрут не подошёл: проверь `hostnames` и заголовок `Host` (при `--resolve` он верный).

### Задание 4. TLS и шаг проекта

**Цель:** включить HTTPS на Gateway и зафиксировать вход в репозитории проекта. Это шаг сквозного проекта «Заметки».

**Предскажи:** после создания Secret `notes-tls` какие условия у listener `https` станут True и почему `curl` без `-k` всё равно откажет?

<details markdown="1">
<summary>Ответ</summary>

Станут True `Programmed`, `Accepted` и `ResolvedRefs` (ссылка на Secret найдена). Curl откажет с `SSL certificate problem`: сертификат самоподписанный, у системы нет причин ему доверять. Шифрование при этом работает.

</details>

**Шаги:**

1. Выпусти самоподписанный сертификат с SAN `notes.lab` (как в уроке 2.6) во временный каталог и создай из него Secret в namespace `notes`.

   ```bash
   T=$(mktemp -d)
   openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
     -keyout "$T/tls.key" -out "$T/tls.crt" \
     -subj "/CN=notes.lab" -addext "subjectAltName=DNS:notes.lab"
   kubectl create secret tls notes-tls -n notes --cert="$T/tls.crt" --key="$T/tls.key"
   cp "$T/tls.crt" /tmp/notes-lab.crt
   rm -rf "$T"
   ```

2. Проверь листенеры и запрос по HTTPS. Флаг `--cacert` говорит curl доверять именно этому сертификату.

   ```bash
   kubectl get gateway notes-gw -n notes -o jsonpath='{range .status.listeners[*]}{.name}{" "}{.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
   curl -s -o /dev/null -w '%{http_code}\n' --cacert /tmp/notes-lab.crt --resolve notes.lab:443:127.0.0.1 https://notes.lab/healthz
   ```

3. Зафиксируй в git. Secret в репозиторий не кладём: это известный долг (закроется в уроке 9.4).

   ```bash
   cd ~/notes
   git add k8s/base/30-envoyproxy.yaml k8s/base/31-gateway.yaml k8s/base/32-httproute.yaml
   git commit -m "k8s: вход через Envoy Gateway (Gateway API)"
   ```

4. Если в 8 ГБ-режиме ты уменьшал реплики, верни три: `kubectl scale deploy/notes -n notes --replicas=3`.

Эталон файлов: [project/notes/k8s/base](https://github.com/distinguished-sre/devops/tree/devops/project/notes/k8s/base).

**Что должно получиться:**

```text
http True
https True
200
```

Первые две строки: имя листенера и статус `Programmed`, последняя: код ответа по HTTPS.

**Объясни себе:**

- Где именно в цепочке заканчивается TLS и что идёт дальше до пода?
- Почему приватный ключ сертификата не должен попасть в git, и как долг закрывается позже?

**Типичные ошибки:**

- `curl: (60) SSL certificate problem: self-signed certificate`: не передан `--cacert`: добавь его или временно `-k`.
- `Error from server (AlreadyExists): secrets "notes-tls" already exists`: Secret уже есть: `kubectl delete secret notes-tls -n notes` и создай заново.
- `curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL`: у листенера нет сертификата (Secret не найден): смотри conditions Gateway.

## Сломай и почини

Запусти один из сценариев (номер от 1 до 3, либо `random`). Скрипт не читай: ты должен найти причину по симптомам.

```bash
bash ~/notes/break/5.4/break.sh random
```

### Симптом

Вход через `notes.lab` перестал работать так, как в задании 4. Что именно не так, зависит от сценария: то `404` или пустой ответ, то отказ соединения, то ошибка TLS. Приложение и Service при этом в порядке: `kubectl port-forward svc/notes 8080:8080 -n notes` отдаёт `/healthz`.

### Гипотезы

Цепочка сверху вниз, как в [уроке 2.8](../02-network/08-request-path-troubleshooting.md): имя -> порт хоста -> NodePort -> Envoy -> Gateway `Programmed` -> HTTPRoute `Accepted` и `ResolvedRefs` -> endpoints Service. Какие звенья ломаются тихо, без ошибки `apply`?

### Проверки

```bash
kubectl get gateway,httproute -n notes
kubectl describe httproute notes -n notes | sed -n '/Status:/,$p'
kubectl describe gateway notes-gw -n notes | sed -n '/Status:/,$p'
kubectl get svc -n envoy-gateway-system
kubectl get secret -A | grep notes-tls
kubectl get endpoints notes -n notes
```

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

**1. HTTPRoute без Accepted.** В `describe httproute` условие `Accepted: False`, причина `NoMatchingParent` или `BackendNotFound` для parent: в `parentRefs` опечатка в имени Gateway (например `notes-gateway`). API такое принимает молча. Исправление: `parentRefs[0].name: notes-gw` и `kubectl apply -f k8s/base/32-httproute.yaml`. Симптом снаружи: `404` от Envoy.

**2. Gateway без доступа снаружи.** Gateway `Programmed: True`, HTTPRoute `Accepted`, а с хоста `curl: (7) Failed to connect`. Проверка `kubectl get svc -n envoy-gateway-system`: у Service Envoy случайный NodePort (например `80:31844/TCP`), а не `30080`: из EnvoyProxy пропал `nodePort` или GatewayClass не ссылается на `notes-proxy`. Исправление: вернуть `nodePort: 30080` и `30443` в `30-envoyproxy.yaml`, применить, убедиться в `80:30080/TCP`. Ловушка: снаружи это выглядит как «Envoy упал», а Envoy в порядке, не совпали порты.

**3. TLS Secret в неверном namespace.** Listener `https` в статусе: `ResolvedRefs: False`, причина `InvalidCertificateRef` или `RefNotPermitted`, а `curl https` даёт `SSL_ERROR_SYSCALL` или `unexpected eof`. Secret `notes-tls` лежит, например, в `default`, а Gateway в `notes` и ссылается на тот же namespace. Исправление: создать Secret в `notes` (команда из задания 4, `-n notes`) и удалить лишний. HTTP по 80 при этом работает, что подсказывает: проблема именно в листенере HTTPS.

</details>

Выводы для дежурства: у Gateway API ошибки не в выводе `apply`, а в `status.conditions`, поэтому первым делом читай `describe` Gateway и HTTPRoute.

## Вопросы с собеседований

### 1. [junior] Чем Ingress отличается от Service типа LoadBalancer?

LoadBalancer это один внешний адрес на один Service, часто платный балансировщик облака. Ingress (или Gateway) один вход на многих сервисов: по хосту и пути он раздаёт запросы разным Service и завершает TLS. Один балансировщик и много маршрутов дешевле и удобнее.

**Что хотят услышать:** L4 против L7, экономия внешних адресов, TLS на входе, нужен контроллер.

**Красный флаг:** «это одно и то же, просто два способа».

### 2. [junior] Ты применил Ingress, `kubectl get ingress` показывает объект, а сайт не открывается и ADDRESS пуст. Что делаешь?

Проверяю, что в кластере вообще есть контроллер и подходит ли `ingressClassName` (`kubectl get ingressclass`, поды контроллера). Пустой ADDRESS почти всегда значит, что объект никто не обработал. Потом смотрю логи контроллера и events объекта.

**Что хотят услышать:** объект не равен реализации, IngressClass, `describe ingress`, логи контроллера.

**Красный флаг:** пересоздавать Ingress «на всякий случай» или перезапускать поды приложения.

### 3. [junior] Что такое Gateway API и чем он лучше Ingress?

Это преемник Ingress: три объекта (GatewayClass, Gateway, HTTPRoute) с разделением ролей. Администратор владеет входом и сертификатами, команда владеет маршрутами. Веса, заголовки, редиректы и переписывание путей входят в стандарт, а не в аннотации, поэтому конфиги переносятся между реализациями.

**Что хотят услышать:** разделение ролей, переносимость, не только HTTP, статус в conditions.

**Красный флаг:** «просто новый Ingress с другим синтаксисом».

### 4. [junior] Что случилось с ingress-nginx и что ты выберешь для нового кластера?

Проект ingress-nginx выведен из поддержки (архивирован в 2026), новые уязвимости не закрываются. Для нового кластера я беру Gateway API с реализацией, которую поддерживает мой провайдер или команда: Envoy Gateway, Cilium, Traefik, NGINX Gateway Fabric. Старые кластеры планирую мигрировать поэтапно.

**Что хотят услышать:** знание факта, Gateway API как вектор, план миграции, а не паника.

**Красный флаг:** «ставлю ingress-nginx, он самый популярный».

### 5. [middle] Прод отвечает 502 через Gateway, что делаешь?

Иду по цепочке. Сначала `kubectl get httproute,gateway` и conditions: принят ли маршрут, найден ли backend. Затем `kubectl get endpoints` сервиса: есть ли готовые поды, не упали ли пробы. Потом логи пода Envoy (доступ и upstream-ошибки) и `port-forward` прямо на Service, чтобы понять, отвечает ли само приложение.

**Что хотят услышать:** порядок сверху вниз, `endpoints`, readiness, различие 502 (upstream недоступен), 503 (нет здоровых) и 404 (не подошёл маршрут).

**Красный флаг:** сразу рестартить Envoy или приложение без диагностики.

### 6. [middle] Ты применил HTTPRoute, apply прошёл без ошибок, а сайт отдаёт 404. Где искать?

Ошибки Gateway API живут в статусе. Смотрю `describe httproute`: Accepted и ResolvedRefs. Типичные причины: неверное имя в `parentRefs`, hostname не пересекается с listener, маршрут из чужого namespace не разрешён в `allowedRoutes`. Проверяю и заголовок `Host` в запросе.

**Что хотят услышать:** conditions, parentRefs, allowedRoutes, hostnames, Host заголовок.

**Красный флаг:** «в логах apply ошибок нет, значит проблема в приложении».

### 7. [middle] Как в Gateway API сделать канареечный релиз 10% трафика на новую версию?

В HTTPRoute у правила два `backendRefs` на разные Service (стабильный и канарейка) с `weight: 90` и `weight: 10`. Веса это часть стандарта, аннотации не нужны. Меняю веса шагами и смотрю метрики ошибок. Автоматизирует это Argo Rollouts (тема 9).

**Что хотят услышать:** `weight`, два Service, метрики-гейты, откат весом 0.

**Красный флаг:** «нужно два Ingress с аннотацией canary», это специфика одного контроллера.

### 8. [middle] HTTPS на Gateway не поднимается: ошибка про сертификат. Что проверишь?

`describe gateway` и условие `ResolvedRefs` у listener. Проверяю: Secret существует, тип `kubernetes.io/tls`, ключи `tls.crt` и `tls.key`, Secret лежит в том же namespace, что и Gateway (иначе нужен ReferenceGrant). Затем SAN сертификата и срок действия через `openssl x509 -noout -text`.

**Что хотят услышать:** namespace, тип Secret, ReferenceGrant, SAN, срок действия.

**Красный флаг:** отключить TLS «чтобы заработало».

### 9. [middle] В kind Gateway создан, но снаружи недоступен. Прод в облаке работает по тому же манифесту. Почему?

В облаке Service Envoy получает LoadBalancer и внешний адрес. В kind балансировщика нет, я явно задаю NodePort и проброс `extraPortMappings` на хост. Ошибка обычно в несовпадении портов: NodePort случайный, а проброс ждёт 30080. Проверяю `kubectl get svc` в namespace Envoy и `docker ps` для проброса.

**Что хотят услышать:** LoadBalancer против NodePort, `extraPortMappings`, порты, MetalLB как аналог.

**Красный флаг:** «Gateway API не работает на локальных кластерах».

### 10. [middle] Как перенести существующий Ingress на Gateway API без простоя?

Поднимаю Gateway рядом со старым входом и переношу маршруты в HTTPRoute (есть утилита ingress2gateway, но результат проверяю руками, аннотации не переносятся). Проверяю новый вход через `curl --resolve` на его адрес, затем переключаю DNS или вес на новый адрес с малым TTL. Старый Ingress убираю после наблюдения за метриками.

**Что хотят услышать:** параллельный вход, проверка до переключения, DNS с низким TTL, аннотации переписываются вручную.

**Красный флаг:** удалить Ingress и применить HTTPRoute в один заход.

## Проверено на версиях

- kind: v0.33.0
- Kubernetes: 1.36.x и 1.37.x
- kubectl: 1.37.1
- Gateway API: v1.6.2 (CRD входят в манифест Envoy Gateway)
- Envoy Gateway: v1.9.2 (`kubectl apply --server-side`, без Helm)
- OpenSSL из Ubuntu 26.04 LTS и 24.04
- ingress-nginx: выведен из поддержки, в курсе не используется, проверь актуальный статус на странице проекта

## Итог урока: ты умеешь

- [ ] умею объяснить, почему объект Ingress без контроллера не пропускает трафик
- [ ] умею назвать причины, по которым Gateway API заменяет Ingress, и роли GatewayClass, Gateway, HTTPRoute
- [ ] умею установить Envoy Gateway v1.9.2 через `kubectl apply --server-side`
- [ ] умею описать вход в кластер манифестами Gateway и HTTPRoute для `notes.lab`
- [ ] умею выпустить TLS Secret командой и подключить его к listener HTTPS
- [ ] умею читать `status.conditions` Gateway и HTTPRoute и находить причину 404 и отказа соединения
- [ ] умею пройти цепочку «хост -> NodePort -> Envoy -> Service -> под» при диагностике

**Дальше:** [Урок 5.5: Хранилище и StatefulSet: PostgreSQL в кластере](05-storage-statefulset-postgres.md)
