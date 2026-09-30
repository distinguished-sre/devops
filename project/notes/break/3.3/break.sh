#!/usr/bin/env bash
# Поломки для урока 3.3 «CI в GitHub Actions». Запуск: bash break.sh 1|2|3|fix
# Без sudo: правит только файлы проекта в рабочей копии ~/notes на ветке для упражнения.
set -euo pipefail

WORKFLOW=.github/workflows/ci.yml
GOOD_LINE='python-version: ["3.13", "3.14"]'
BAD_LINE='python-version: ["3.13", "3.14"'
IMPORT_LINE='import shutil'
SEED=data/seed.txt

die() {
  echo "$*" >&2
  exit 1
}

# Проверки перед любым сценарием: не root, мы в репозитории «Заметок», ветка не main.
preflight() {
  [[ $EUID -ne 0 ]] || die "Не запускай через sudo: скрипт правит файлы проекта твоего пользователя."
  command -v git >/dev/null 2>&1 || die "Не найден git. Сначала пройди урок 3.1."
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "Запусти из каталога ~/notes (это не git-репозиторий). Сначала пройди уроки 3.1 и 3.2."
  cd "$top"
  [[ -f app.py && -f Makefile && -f test_app.py ]] || die "В $top нет app.py, Makefile или test_app.py. Сначала пройди урок 1.6."
  git rev-parse --verify -q main >/dev/null || die "Нет ветки main. Сначала пройди урок 3.2."
  git cat-file -e "main:$WORKFLOW" 2>/dev/null || die "В main нет $WORKFLOW: сначала слей PR из задания 2 этого урока."
  local branch
  branch=$(git branch --show-current)
  if [[ $branch == main || $branch == master || -z $branch ]]; then
    die "Ты на ветке '${branch:-detached HEAD}'. Создай ветку для упражнения: git switch -c ci/break-drill"
  fi
}

# Как файл выглядит в main: с этим состоянием сравнивает fix.
restore_from_main() {
  git restore --source=main --worktree -- "$@"
}

case "${1:-}" in
  1)
    preflight
    if grep -qxF "        $BAD_LINE" "$WORKFLOW"; then
      echo "Сценарий 1 уже применён."
    else
      grep -qxF "        $GOOD_LINE" "$WORKFLOW" ||
        die "В $WORKFLOW нет строки '$GOOD_LINE'. Верни файл как в уроке: bash $0 fix"
      # Убираем закрывающую скобку у списка версий: YAML перестаёт разбираться.
      sed -i "s/^        python-version: \[\"3.13\", \"3.14\"\]\$/        $BAD_LINE/" "$WORKFLOW"
      echo "Сценарий 1 готов. Закоммить, отправь ветку и открой Pull Request."
    fi
    ;;
  2)
    preflight
    if grep -qxF "$IMPORT_LINE" app.py; then
      echo "Сценарий 2 уже применён."
    else
      # Неиспользуемый импорт: код работает, но линтер с правилом F401 его не пропустит.
      sed -i "0,/^import /s//$IMPORT_LINE\nimport /" app.py
      echo "Сценарий 2 готов. Закоммить, отправь ветку и открой Pull Request."
    fi
    ;;
  3)
    preflight
    grep -qxF 'data/' .gitignore 2>/dev/null || die "В .gitignore нет строки data/. Сначала пройди урок 3.1 (задание 5)."
    if grep -q 'def test_seed_file' test_app.py; then
      applied=yes
    else
      applied=no
      python3 - <<'PY'
from pathlib import Path

path = Path("test_app.py")
text = path.read_text()
marker = '\n\nif __name__ == "__main__":'
test = '''
    def test_seed_file(self):
        # Читает файл из каталога data/, которого нет в git
        seed = Path(__file__).with_name("data") / "seed.txt"
        self.assertEqual(seed.read_text(), "seed\\n")
'''
if marker not in text:
    raise SystemExit("В test_app.py нет блока if __name__: файл отличается от урока 1.6.")
path.write_text(text.replace(marker, test + marker, 1))
PY
    fi
    mkdir -p data
    [[ -f $SEED ]] || printf 'seed\n' >"$SEED"
    if [[ $applied == yes ]]; then
      echo "Сценарий 3 уже применён."
    else
      echo "Сценарий 3 готов. Проверь у себя: make test. Потом закоммить, отправь ветку и открой Pull Request."
    fi
    ;;
  fix)
    preflight
    restore_from_main "$WORKFLOW" app.py test_app.py
    if [[ -f $SEED ]]; then
      rm -f "$SEED"
      rmdir data 2>/dev/null || true
    fi
    echo "Всё возвращено как в main: ci.yml, app.py и test_app.py, файл $SEED удалён."
    echo "Если ты уже закоммитил поломку, закоммить и это состояние."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
