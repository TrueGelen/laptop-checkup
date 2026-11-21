#!/usr/bin/env bash
# Скачивает программы набора с официальных сайтов, сверяет суммы и распаковывает в <dest>/tools.
# Использование: ./fetch-tools.sh <dest>
set -euo pipefail
DEST="${1:?укажи папку назначения}"
DL="$DEST/.downloads"
mkdir -p "$DL"/{cinebench,furmark,diskspd,cdi} "$DEST"/tools/{cinebench,furmark,diskspd,cdi}

# url | файл | алгоритм | сумма (для Cinebench Maxon суммы не публикует — записана при первой сборке 2026-10-24)
fetch() {
  local url="$1" out="$2" algo="$3" sum="$4"
  curl -fsSL --max-time 900 -o "$out" "$url"
  echo "$sum  $out" | "${algo}sum" -c -
}
fetch https://installer.maxon.net/cinebench/CinebenchR23.zip "$DL/cinebench/CinebenchR23.zip" sha256 fff6d34b8f696de64a534fc9f0788ec1e9f1bda880a88aed92df8b96d1797c42
fetch https://www.geeks3d.com/dl/get/830 "$DL/furmark/FurMark_2.10.2_win64.zip" sha256 27ab2e723e2e65df720bcafea681d2104744eda4a1e0a0374d7e61eaa820e63b
fetch https://github.com/microsoft/diskspd/releases/download/v2.3/DiskSpd.ZIP "$DL/diskspd/DiskSpd.zip" sha256 18609981e8b04b4f645f1fd182ad0541615fe71722de36a9a933c54f747218a3
fetch https://sourceforge.net/projects/crystaldiskinfo/files/9.9.3/CrystalDiskInfo9_9_3.zip/download "$DL/cdi/CrystalDiskInfo9_9_3.zip" md5 7f33883c23bf93ad49c9969f2d5428eb

unzip -qo "$DL/cinebench/CinebenchR23.zip" -d "$DEST/tools/cinebench"
unzip -qo "$DL/furmark/FurMark_2.10.2_win64.zip" -d "$DEST/tools/furmark"
unzip -qo "$DL/diskspd/DiskSpd.zip" -d "$DEST/tools/diskspd"
unzip -qo "$DL/cdi/CrystalDiskInfo9_9_3.zip" -d "$DEST/tools/cdi"
rm -rf "$DEST/tools/diskspd/arm64" "$DEST/tools/diskspd/amd64/diskspd.pdb" "$DEST/tools/diskspd/diskspd.wprp" "$DL"
du -sh "$DEST"/tools/*
