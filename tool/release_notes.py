#!/usr/bin/env python3
"""Release body for a version: its CHANGELOG.md section + which APK to pick.

    python3 tool/release_notes.py v2.4.0 > notes.md
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def section(version: str) -> str:
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|^\[[0-9])", text, re.S | re.M)
    return m.group(1).strip() if m else ""


def notes(tag: str) -> str:
    v = tag.lstrip("v")
    body = section(v) or "Подробности — в [CHANGELOG.md](https://github.com/KOTBCTAKAHE/mangaflow-app/blob/main/CHANGELOG.md)."
    return f"""{body}

---

**Какой APK скачать:**
- `MangaFlow-{tag}-arm64.apk` — большинство современных телефонов
- `MangaFlow-{tag}-armv7.apk` — старые 32-битные устройства
- `MangaFlow-{tag}-universal.apk` — если не уверены (больше размер)

Обновление ставится поверх установленного приложения. Сервер по умолчанию: https://api-manga.aniroom.space (меняется в Настройках).
Полная история — [CHANGELOG.md](https://github.com/KOTBCTAKAHE/mangaflow-app/blob/main/CHANGELOG.md).
"""


if __name__ == "__main__":
    sys.stdout.write(notes(sys.argv[1]))
