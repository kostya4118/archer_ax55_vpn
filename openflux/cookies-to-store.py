#!/usr/bin/env python3
"""
cookies-to-store.py — превратить выгруженный из браузера cookies.txt в
хранилище cookies ядра OpenFlux.

Зачем: с 15 октября mail.ru закрыл анонимный доступ к публичным документам
(issue #193), и выходному узлу нужен вход в учётную запись. Ядро берёт его из
файла `--cookie-store`: это JSON вида

    {"<ссылка на документ>": {"имя": "значение", ...}}

где ключ верхнего уровня — ровно та ссылка, что стоит в настройках узла
(`cookieKey` в main.go возвращает URL документа для всех транспортов, кроме
oneme).

Как получить cookies.txt: в браузере, где выполнен вход, расширением вроде
«Get cookies.txt LOCALLY» выгрузить cookies для домена mail.ru. Формат —
Netscape, семь полей через табуляцию.

Запуск:

    python3 cookies-to-store.py cookies.txt \\
        --url https://cloud.mail.ru/public/XXXX/YYYY \\
        --domain mail.ru \\
        --out cookies.json

Файл содержит действующую сессию учётной записи: его нельзя никуда
пересылать, а на узле он должен лежать с правами 600.
"""

import argparse
import json
import os
import sys


def read_netscape(path, domain_filter):
    """Читает Netscape cookies.txt. Возвращает {имя: значение}.

    Строки с '#HttpOnly_' — это тоже обычные записи, просто помеченные:
    браузерные расширения так отмечают недоступные из JavaScript cookies, а
    они-то для входа и главные.
    """
    jar = {}
    skipped = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                if not line.startswith("#HttpOnly_"):
                    continue
                line = line[len("#HttpOnly_"):]
            parts = line.split("\t")
            if len(parts) < 7:
                skipped += 1
                continue
            domain, _flag, _path, _secure, _expires, name, value = parts[:7]
            if domain_filter and domain_filter not in domain:
                continue
            # Позже встреченное значение перекрывает раннее: так ведёт себя и
            # браузер, когда одно имя задано на домене и на поддомене.
            jar[name] = value
    return jar, skipped


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cookies_txt", help="выгруженный из браузера файл в формате Netscape")
    ap.add_argument("--url", required=True,
                    help="ссылка на документ — она же ключ в хранилище, "
                         "должна совпадать с URL= в настройках узла")
    ap.add_argument("--domain", default="",
                    help="брать только cookies, чей домен содержит эту строку "
                         "(например mail.ru)")
    ap.add_argument("--out", default="cookies.json", help="куда записать (по умолчанию cookies.json)")
    ap.add_argument("--merge", action="store_true",
                    help="дописать в существующий файл, не затирая записи других документов")
    args = ap.parse_args()

    jar, skipped = read_netscape(args.cookies_txt, args.domain)
    if not jar:
        sys.exit("В файле нет подходящих cookies. Проверь домен в --domain "
                 "и то, что выгрузка сделана из окна, где выполнен вход.")

    store = {}
    if args.merge and os.path.exists(args.out):
        try:
            with open(args.out, "r", encoding="utf-8") as fh:
                store = json.load(fh)
            if not isinstance(store, dict):
                sys.exit(f"{args.out} не похож на хранилище cookies — там не объект JSON.")
        except json.JSONDecodeError as exc:
            sys.exit(f"{args.out} не читается как JSON: {exc}")

    store[args.url] = jar

    # 600 сразу при создании: файл — это действующая сессия учётной записи.
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(store, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    print(f"{args.out}: {len(jar)} cookies для {args.url}")
    if skipped:
        print(f"пропущено строк без семи полей: {skipped}")
    print("Имена (значения не печатаю):", ", ".join(sorted(jar)))


if __name__ == "__main__":
    main()
