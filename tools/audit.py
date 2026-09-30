#!/usr/bin/env python3
"""Аудит уроков без LLM: доля теории и термины, которые встречаются раньше объяснения.

Источник терминов: таблицы «Словарик урока». Термин считается введённым в том
уроке, где он впервые попал в словарик (порядок уроков из _data/course.yml).

Запуск из корня репозитория:
  python3 tools/audit.py                  # сводка по всем урокам
  python3 tools/audit.py 2.1 2.2          # подробный список правок по урокам
  python3 tools/audit.py --json > a.json  # всё в JSON
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORD = r"[\w\-]"


def lessons():
    data = json.loads(subprocess.check_output(
        ["yq", "-o", "json", ".", str(ROOT / "_data/course.yml")]))
    out = []
    for t in data["topics"]:
        for l in t["lessons"]:
            path = ROOT / t["dir"] / f'{l["slug"]}.md'
            out.append({"id": str(l["id"]), "path": path})
    return out


def strip_code(text):
    """Строки урока с пометкой: внутри блока кода или нет. Inline-код остаётся."""
    rows, code = [], False
    lines = text.splitlines() or [""]
    front = lines[0] == "---"
    for i, line in enumerate(lines, 1):
        if front:
            # front matter: служебные поля, как код (в поиск не идут)
            rows.append((i, line, True))
            front = not (i > 1 and line == "---")
            continue
        if line.lstrip().startswith("```"):
            code = not code
            rows.append((i, line, True))
            continue
        rows.append((i, line, code))
    return rows


def sections(rows):
    """Разбивка по заголовкам ##: имя -> (первая строка, последняя строка)."""
    secs, cur, start = [], None, 1
    for i, line, code in rows:
        if not code and line.startswith("## "):
            if cur:
                secs.append((cur, start, i - 1))
            cur, start = line[3:].strip(), i
    if cur:
        secs.append((cur, start, rows[-1][0]))
    return secs


def words(rows, a, b):
    return sum(len(line.split()) for i, line, code in rows if a <= i <= b)


def glossary(rows, secs):
    sec = next((s for s in secs if s[0].startswith("Словарик")), None)
    if not sec:
        return []
    terms = []
    for i, line, code in rows:
        if sec[1] < i <= sec[2] and line.startswith("|") and not line.startswith("|---"):
            cell = line.split("|")[1].strip()
            if cell in ("Термин", ""):
                continue
            terms.append(cell)
    return terms


def variants(cell):
    """«Маска подсети (netmask), CIDR» -> ['Маска подсети', 'netmask', 'CIDR']."""
    cell = cell.replace("`", "").replace("**", "")
    if not re.search(r"\w", cell):
        return []
    out = []
    for m in re.findall(r"\(([^)]*)\)", cell):
        # в скобках обычно английский оригинал: берём только латиницу
        out += [x.strip() for x in m.split(",") if re.fullmatch(r"[A-Za-z][\w .-]{2,}", x.strip())]
    main = re.sub(r"\([^)]*\)", "", cell)
    out += [p.strip() for p in re.split(r"[,;]| / ", main) if len(p.strip()) >= 2]
    return out


def notable(term):
    """Для ссылок вперёд: отбрасываем короткие бытовые слова («цель», «блок»)."""
    if " " in term:
        return len(term) >= 5
    if re.search(r"[A-Za-z]", term):
        # короткие строчные латинские слова: обрывки команд (for, log, red)
        return len(term) >= 5 or term.isupper()
    return len(term) >= 7


def pattern(term):
    """Грубая основа для русских слов, точное совпадение для латиницы."""
    out = []
    for w in term.split():
        if re.fullmatch(r"[А-Яа-яЁё]+", w) and len(w) > 5:
            out.append(re.escape(w[:-2]) + r"[а-яё]{0,4}")
        elif re.fullmatch(r"[А-Яа-яЁё]+", w) and len(w) > 3:
            out.append(re.escape(w[:-1]) + r"[а-яё]{0,3}")
        else:
            out.append(re.escape(w))
    body = r"\s+".join(out)
    flags = 0 if (len(term) <= 4 and term.isupper()) else re.IGNORECASE
    return re.compile(rf"(?<!{WORD}){body}(?!{WORD})", flags)


EXPLAINED = re.compile(r"^[`»]*(\s*\([^)]*[а-яё][^)]*\)|\*\*:|\*\*\s[-–]\s|\s[-–—]\s|,?\s+это\s|,\s+(то есть|котор))")


def first_hit(rows, pat, start=1, blob=None):
    """Строка первой встречи термина; None, если его нет или он объяснён на месте."""
    if blob is not None and not pat.search(blob):
        return None
    for i, line, code in rows:
        if i < start or code or line.startswith("#") or line.startswith("|"):
            continue
        m = pat.search(line)
        if m:
            return None if EXPLAINED.match(line[m.end():]) else i
    return None


def audit(only=None):
    ls = lessons()
    intro = {}  # термин (lower) -> id урока, где впервые в словарике
    orig = {}   # термин (lower) -> как записан в словарике
    info = []
    for l in ls:
        text = l["path"].read_text()
        rows = strip_code(text)
        secs = sections(rows)
        total = words(rows, 1, rows[-1][0])
        th = next((s for s in secs if s[0] == "Теория"), None)
        theory = words(rows, th[1], th[2]) if th else 0
        gl = glossary(rows, secs)
        body_end = next((s[1] for s in secs if s[0].startswith("Словарик")), rows[-1][0])
        info.append({"id": l["id"], "path": str(l["path"].relative_to(ROOT)),
                     "rows": rows, "secs": secs, "total": total, "theory": theory,
                     "gl": gl, "body_end": body_end,
                     "theory_start": th[1] if th else None})
        for cell in gl:
            for v in variants(cell):
                intro.setdefault(v.lower(), l["id"])
                orig.setdefault(v.lower(), v)

    order = {x["id"]: n for n, x in enumerate(info)}
    pats = {t: pattern(t) for t in intro}
    for x in info:
        x["early"], x["forward"] = [], []
        if only and x["id"] not in only:
            continue
        rows, n = x["rows"], order[x["id"]]
        gs = next((s for s in x["secs"] if s[0].startswith("Словарик")), None)
        body = [r for r in rows if not (gs and gs[1] <= r[0] <= gs[2])]
        own = {v.lower() for c in x["gl"] for v in variants(c)}
        blob = "\n".join(r[1] for r in body if not r[2])
        early, forward = [], []
        # свои термины, которые встречаются до раздела «Теория»
        for t in sorted(own):
            hit = first_hit(body, pats[t], blob=blob)
            if hit and x["theory_start"] and hit < x["theory_start"]:
                early.append((t, hit))
        # термины из более поздних уроков, которыми урок уже пользуется
        for t, where in intro.items():
            if order[where] > n and t not in own and notable(orig[t]):
                hit = first_hit(body, pats[t], blob=blob)
                if hit:
                    forward.append((t, where, hit))
        x["early"], x["forward"] = early, forward
    return info


def section_of(x, line):
    for name, a, b in x["secs"]:
        if a <= line <= b:
            return name
    return "?"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    info = audit(set(args) or None)
    if "--json" in sys.argv:
        for x in info:
            for k in ("rows", "secs"):
                x.pop(k)
        json.dump(info, sys.stdout, ensure_ascii=False, indent=1)
        return
    if not args:
        print("урок  теория%  слов  рано  вперёд")
        for x in info:
            pct = round(100 * x["theory"] / x["total"]) if x["total"] else 0
            flag = " <45" if pct < 45 else ""
            print(f'{x["id"]:5} {pct:6}% {x["total"]:6} {len(x["early"]):5} {len(x["forward"]):6}{flag}')
        return
    for x in info:
        if x["id"] not in args:
            continue
        pct = round(100 * x["theory"] / x["total"]) if x["total"] else 0
        print(f'## {x["id"]} {x["path"]}: теория {pct}% ({x["theory"]} из {x["total"]} слов)')
        print("Свои термины урока, которые встречаются до «Теории» (объясни на месте первой встречи):")
        for t, line in x["early"]:
            print(f"  {x['path']}:{line} [{section_of(x, line)}] {t}")
        print("Термины, которые курс вводит позже (коротко объясни и дай ссылку вперёд):")
        for t, where, line in sorted(x["forward"], key=lambda r: r[2]):
            print(f"  {x['path']}:{line} [{section_of(x, line)}] {t} (вводится в {where})")


if __name__ == "__main__":
    main()
