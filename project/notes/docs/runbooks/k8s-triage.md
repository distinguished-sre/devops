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
- `kubectl get networkpolicy -n notes`: не режет ли политика DNS или порт 5432.
- В поде без инструментов: `kubectl debug -it <под> -n notes --image=busybox:1.37 --target=notes --profile=restricted -- sh`.
