# laptop-checkup

Автономный набор проверки ноутбуков под Windows 10/11 с PowerShell 5.1.

- `RUN.cmd` — полный прогон, примерно 35–45 минут.
- `RUN-QUICK.cmd` — короткий прогон для проверки работы набора.
- `CLEANUP.cmd` — уборка после прерванного прогона.

Порядок запуска: [START-HERE.txt](START-HERE.txt).
Состав тестов и ограничения: [README.txt](README.txt).
Ручной осмотр: [BIOS-AND-INSPECTION.txt](BIOS-AND-INSPECTION.txt).

Отдельный сценарий SSD запускается командой:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ssd-check.ps1
```

Снимок состояния SSD после выключения и включения:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ssd-check.ps1 -SnapshotOnly
```

## Получение полного набора из GitHub

Большая сцена Cinebench в `tools` хранится в Git LFS. Установите Git и Git LFS,
затем выполните:

```text
git lfs install
git clone https://github.com/TrueGelen/laptop-checkup.git
cd laptop-checkup
git lfs pull
```

Для запуска нужна папка `tools` с загруженной сценой Git LFS.
Обычный ZIP исходников GitHub может содержать указатель вместо этого файла.
Интернет при самом тестировании не требуется.

Отчёты в `reports` и `ssd-reports`, а также резервные копии `*.bak`
сохраняются локально и исключены из Git.
