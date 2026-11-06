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

### ZIP без установки Git

1. [Скачайте ZIP](https://github.com/TrueGelen/laptop-checkup/archive/refs/heads/main.zip)
   или выберите на странице репозитория **Code → Download ZIP**.
2. Распакуйте архив целиком в папку с правами записи. Не запускайте тест из самого архива.
3. Подключите зарядку, закройте программы и запустите `RUN.cmd` из распакованной папки.
4. Подтвердите запрос прав администратора и дождитесь завершения.

В настройках репозитория включено добавление Git LFS-файлов в архивы:
ZIP содержит настоящую сцену Cinebench, устанавливать Git и Git LFS не нужно.
Сохраните папку `tools` рядом со скриптами.
Результаты появятся в `reports` внутри распакованной папки.

### Клонирование через Git

Большая сцена Cinebench в `tools` хранится в Git LFS.
Для клонирования установите Git и Git LFS, затем выполните:

```text
git lfs install
git clone https://github.com/TrueGelen/laptop-checkup.git
cd laptop-checkup
git lfs pull
```

Интернет при самом тестировании не требуется.

Отчёты в `reports` и `ssd-reports`, а также резервные копии `*.bak`
сохраняются локально и исключены из Git.
