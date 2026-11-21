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

Все отчёты основного теста находятся в [reports](reports/README.md): здесь хранятся
предыдущие замеры и создаются новые. Папка включена в Git; исходные файлы сохранённых
замеров снабжены SHA-256. Отдельные отчёты SSD хранятся в `ssd-reports` и также
включены в Git. Резервные копии `*.bak` исключены из Git.

На этом ПК основная рабочая копия находится в `D:\work\my\laptop-checkup`.
Запускайте `RUN.cmd` или `RUN-QUICK.cmd` из этой папки в Windows.

Новые папки отчётов имеют формат `[метка_]<дата>_<модель>_<серийник>`.
FurMark сохраняет FPS примерно раз в секунду в `furmark-gpu.txt` и
`furmark-combo.txt`, а отчёт создаёт соответствующие `*-fps.csv` и показывает
изменение среднего FPS между первыми и последними 10% времени отсчётов.
Это изменение внутри теста, а не измерение потери FPS в играх.

Вкладка **«Графики»** в HTML-отчёте показывает температуру ACPI, частоту и загрузку CPU;
температуру, частоту, загрузку, потребление и лимит мощности GPU. Есть фильтр этапов,
общий курсор для датчиков и отметки теплового ограничения GPU. Отдельно показаны FPS
FurMark по времени рендеринга и баллы Cinebench по проходам. Пропуски данных остаются
разрывами линий; не записанный в старых замерах FPS не восстанавливается.

Готовый `report.html` содержит данные, стили и JavaScript: для его просмотра интернет
и соседние файлы не нужны. Для **создания** отчёта сохраняйте `report-charts.js` и
`report-charts.css` рядом с `checkup.ps1`; `deploy.sh` копирует их автоматически.
Оригиналы замеров можно оставить нетронутыми и пересобрать копию через `-ReportFrom`.

Проверки в Windows PowerShell 5.1, без нагрузки на оборудование:

```powershell
powershell -NoProfile -File tests\profiles.ps1
powershell -NoProfile -File tests\fps.ps1
powershell -NoProfile -File tests\charts.ps1
```

Дополнительная проверка интерфейса требует Node.js и Playwright только на машине
разработчика: `node tests/charts-browser.cjs [путь-к-report.html]`.
При нестандартном расположении Playwright и Chrome можно задать `PLAYWRIGHT_MODULE`
и `CHROME_BIN`. При обычном использовании набора эти зависимости не требуются.
