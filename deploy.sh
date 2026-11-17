#!/usr/bin/env bash
# Выкладывает скрипты набора на флешку (папка tools копируется отдельно, см. fetch-tools.sh).
# .ps1 и README получают BOM — иначе PowerShell 5.1 читает кириллицу как ANSI; всем файлам — CRLF.
# Использование: ./deploy.sh [F:\laptop-checkup]
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST_WIN="${1:-F:\\laptop-checkup}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Исходники из GitHub уже могут иметь BOM и CRLF: нормализуем их перед выкладкой.
python3 - "$SRC" "$STAGE" <<'PY'
from pathlib import Path
import sys
source, stage = map(Path, sys.argv[1:])
bom_files = ('checkup.ps1', 'sampler.ps1', 'README.txt', 'START-HERE.txt', 'BIOS-AND-INSPECTION.txt')
for name in bom_files + ('RUN.cmd', 'RUN-QUICK.cmd', 'CLEANUP.cmd', 'report-charts.js', 'report-charts.css'):
    text = (source / name).read_text(encoding='utf-8-sig')
    data = text.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8')
    (stage / name).write_bytes((b'\xef\xbb\xbf' if name in bom_files else b'') + data)
PY

rc=0
(cd /mnt/c && cmd.exe /c robocopy "$(wslpath -w "$STAGE")" "$DEST_WIN" /R:1 /W:1 /NJH /NDL /NP) | tr -d '\r' || rc=$?
# у robocopy коды 0–7 — успех
[ "$rc" -lt 8 ] || { echo "robocopy завершился с кодом $rc" >&2; exit 1; }
