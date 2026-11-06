<#
  laptop-checkup — автономная проверка ноутбука с флешки (Windows 10/11, PowerShell 5.1).

  Ничего не устанавливает и не меняет в настройках системы. Всё временное, что создают тесты,
  удаляется в Invoke-Cleanup; отчёт и логи остаются только на флешке в reports\.
  Сон и отключение экрана на время теста блокируются через SetThreadExecutionState —
  это действует, пока жив процесс, и не трогает настройки электропитания.
#>
param(
  [ValidateSet('Full', 'Quick')][string]$Mode = 'Full',
  [switch]$WithSingle,
  [switch]$CleanupOnly,
  [string]$Label = '',
  [string]$ReportFrom = '',  # пересобрать отчёт из папки готового прогона, без тестов
  [switch]$Unattended,   # без вопросов и паузы в конце (для запуска из другого скрипта)
  [switch]$NoElevate,    # не просить права администратора: SMART/Secure Boot/TPM будут неполными
  [switch]$Elevated
)

$ErrorActionPreference = 'Continue'
$Self  = $MyInvocation.MyCommand.Path
$Root  = Split-Path -Parent $Self
$Tools = Join-Path $Root 'tools'
$inv   = [Globalization.CultureInfo]::InvariantCulture

# ---------- права администратора (нужны для SMART, Secure Boot, TPM) ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $NoElevate -and -not $ReportFrom -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  if ($Elevated) { Write-Host 'Не удалось получить права администратора.' -ForegroundColor Red; Read-Host 'Enter — выход'; exit 1 }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Self`"", '-Mode', $Mode, '-Elevated')
  if ($WithSingle)  { $a += '-WithSingle' }
  if ($CleanupOnly) { $a += '-CleanupOnly' }
  $elevatedOk = $false
  try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a | Out-Null; $elevatedOk = $true }
  catch { Write-Host 'Права администратора не выданы.' -ForegroundColor Yellow }
  if ($elevatedOk) { exit }
  # без прав всё основное работает; не будет SMART-данных диска, CrystalDiskInfo, Secure Boot и TPM
  $ans = Read-Host 'Продолжить без них? Не проверятся SMART диска, Secure Boot и TPM. [Д/н]'
  if ($ans -match '^\s*(н|n)') { exit }
  $NoElevate = $true
}
$IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Host.UI.RawUI.WindowTitle = 'laptop-checkup'

# ---------- длительности ----------
if ($Mode -eq 'Quick') {
  $D = @{ Idle = 20; Cpu = 60; Gpu = 60; Combo = 40; Cool = 15; DiskSec = 5; DiskSize = '256M' }
} else {
  $D = @{ Idle = 120; Cpu = 600; Gpu = 600; Combo = 600; Cool = 60; DiskSec = 10; DiskSize = '1G' }
}

# Ориентиры из обзоров и спецификаций (обновлены 2026-11-01). Обзоры обычно дают один прогон R23 «на холодную»,
# поэтому с ними сравнивается первый проход нашего 10-минутного теста.
# Сравнение «до/после» на одном ноутбуке работает и без профиля.
$NbcGp76 = 'https://www.notebookcheck.net/MSI-Vector-GP76-12UGS-review-Gaming-laptop-on-speed.619683.0.html'
$LmK15   = 'https://laptopmedia.com/review/msi-katana-15-b13v-review-the-generational-leap-is-huge-but-the-price-is-not-very-pleasant/'
$DnA16   = 'https://3dnews.ru/1132160/obzor-gigabyte-gaming-a16-3vh'
$GbA16   = 'https://www.gigabyte.com/Laptop/GIGABYTE-GAMING-A16-GA63H/sp'
$GbA16Jp = 'https://www.gigabyte.com/jp/Laptop/GIGABYTE-GAMING-A16-GA63H/sp'
$IxA16   = 'https://www.ixbt.com/live/mobilepc/gigabyte-gaming-a16-3th-igrovoy-noutbuk-s-ryzen-7-260-i-geforce-rtx-5050.amp.html'
$Profiles = @(
  @{
    Match = 'Katana 17 B13V'; Board = 'MS-17L5'; Name = 'MSI Katana 17 B13VEK (i5-13420H, RTX 4050 до 105 Вт)'
    CbRef = 12356; CbRefText = 'i5-13420H, средний один прогон по ноутбукам (LaptopMedia)'
    GpuWRef = 85; GpuWRefText = 'RTX 4050 в Katana 15 B13V — до 105 Вт не доходит (LaptopMedia)'
    GpuTempRefText = 'в обзоре Katana 15: 74 °C в игре (RTX 4050), другая нагрузка'; GpuTempRefUrl = ($LmK15 + 'p7/')
    Refs = @(
      @{ What = 'Cinebench R23 Multi, i5-13420H'; Value = 'в среднем ~12 350, лучший 12 665'; Src = 'LaptopMedia'; Url = 'https://laptopmedia.com/processor/intel-core-i5-13420h/'; Note = 'обзоров именно Katana 17 с i5 не нашлось — это данные по ноутбукам с этим процессором' },
      @{ What = 'RTX 4050 в игре, 2 и 30 мин'; Value = '2540 МГц, 74 °C, ~85 Вт (лимит 105 Вт)'; Src = 'LaptopMedia, Katana 15 B13V'; Url = ($LmK15 + 'p7/'); Note = '15-дюймовая модель той же платформы' },
      @{ What = 'Процессор через 10–15 мин полной нагрузки'; Value = 'P-ядра 2,5 ГГц, 68 °C, 50 Вт (старт: 4,2 ГГц, 89 °C, 113 Вт)'; Src = 'LaptopMedia, Katana 15 B13V (i7-13620H)'; Url = ($LmK15 + 'p7/'); Note = 'процессор старше, но лимиты мощности платформы те же' },
      @{ What = '3DMark Time Spy Graphics, RTX 4050 105 Вт'; Value = '8 383'; Src = 'LaptopMedia, Katana 15 B13V'; Url = ($LmK15 + 'p5/'); Note = 'наш набор Time Spy не запускает — для сравнения со сторонними замерами' }
    )
  },
  @{
    Match = 'GP76 12UG'; Name = 'MSI Vector GP76 12UGS/12UGSO (i7-12700H, RTX 3070 Ti до 150 Вт)'
    CbRef = 18203; CbRefText = 'обзор Notebookcheck, один прогон'
    GpuWRef = 150; GpuWRefText = 'Extreme Performance (в Auto/Silent — 125 Вт), Notebookcheck'
    GpuTempRefText = 'в обзоре GP76: средняя GPU 68 °C в Prime95 + FurMark, 78 °C в The Witcher 3; это средние, не предел температуры'; GpuTempRefUrl = $NbcGp76
    Refs = @(
      @{ What = 'Cinebench R23 Multi / Single'; Value = '18 203 / 1 778'; Src = 'Notebookcheck'; Url = $NbcGp76; Note = 'лучший R23 Multi для i7-12700H по LaptopMedia — 18 625' },
      @{ What = 'Процессор под длительной нагрузкой'; Value = 'со ~100 Вт быстро сбрасывается до 45 Вт; в Extreme — 70 Вт; в цикле R15 −20%'; Src = 'Notebookcheck'; Url = $NbcGp76; Note = '' },
      @{ What = 'Мощность видеокарты'; Value = '150 Вт в Extreme (вкл. 15 Вт Dynamic Boost), 125 Вт в Auto и Silent'; Src = 'Notebookcheck'; Url = $NbcGp76; Note = '' },
      @{ What = 'Стресс Prime95 + FurMark'; Value = 'CPU 2,2 ГГц / 67 °C, GPU 1780 МГц / 68 °C (средние)'; Src = 'Notebookcheck'; Url = $NbcGp76; Note = 'другая нагрузка, чем у нас; температуры — ориентир здорового охлаждения' },
      @{ What = 'Игра (The Witcher 3)'; Value = 'CPU 82 °C, GPU 78 °C'; Src = 'Notebookcheck'; Url = $NbcGp76; Note = '' },
      @{ What = 'Особенность Extreme Performance'; Value = 'у обозревателей вентиляторы крутились медленно даже под полной нагрузкой → перегрев и сильный троттлинг'; Src = 'Notebookcheck'; Url = $NbcGp76; Note = 'если и у вас в Extreme вентиляторы не раскручиваются — дело в управлении вентиляторами, а не в пасте' }
    )
  },
  @{
    IdPattern = '\bGA63T?H\b|\bGAMING\s+A16\b|\b3THK3\w*'
    ManufacturerPattern = '\bGIGABYTE\b'
    CpuPattern = '\bRyzen\s+7\s+260\b'; GpuPattern = '\bRTX\s+5050\b'
    Name = 'GIGABYTE Gaming A16 GA63H / 3TH (Ryzen 7 260, RTX 5050 8 ГБ)'
    CbRef = 16068; CbRefText = '3DNews, A16 3VH с тем же Ryzen 7 260, но RTX 5060; приближённый ориентир'
    CbRefApproximate = $true
    GpuWRef = 85; GpuWRefText = 'RTX 5050 в A16 3TH: до 85 Вт в Performance, 70 Вт в Balance, 50 Вт в Silent (Ultra-tech, iXBT Live); в спецификации GIGABYTE Japan — 75 Вт'
    GpuPowerInfoOnly = $true
    Expected = @{ Cpu = 'Ryzen 7 260'; Cores = 8; Threads = 16; Gpu = 'RTX 5050'; VramMiB = 8192; RamType = 'DDR5'; RamMTs = 5600; PanelRes = '1920x1200'; PanelHz = 165; BatteryMWh = 76000; RamGB = $null; DiskGB = $null }
    GpuTempRefText = 'точного референса FurMark для этой конфигурации нет; пороги ниже — правила набора'
    Refs = @(
      @{ What = 'Мощность CPU: что подтверждено'; Value = 'AMD: TDP 45 Вт, cTDP 35–54 Вт; официальный лимит CPU именно A16 3TH не найден'; Src = 'AMD'; Url = 'https://www.amd.com/en/products/processors/laptop/ryzen/200-series/amd-ryzen-7-260.html'; Note = 'TDP не равен текущему потреблению или пределу краткого Boost. Наш набор не измеряет мощность CPU. Точный R23 для A16 3TH с RTX 5050 не подтверждён' },
      @{ What = 'Cinebench R23 Multi / Single, Ryzen 7 260'; Value = '16 068 / 1 753; Multi по режимам 16 051–16 140'; Src = '3DNews, A16 3VH'; Url = $DnA16; Note = 'тот же процессор и серия GA63H, но RTX 5060; ориентир CPU приблизительный, результаты GPU этой версии не переносим на RTX 5050' },
      @{ What = 'Процессор под нагрузкой Cinebench R23'; Value = 'в среднем 4,5 ГГц, 65 Вт, 86 °C; максимум 90–91 °C'; Src = '3DNews, A16 3VH'; Url = $DnA16; Note = 'версия с RTX 5060; датчик CPU в обзоре не равен нашей ACPI-зоне' },
      @{ What = 'Видеокарта и паспортная мощность'; Value = 'RTX 5050 Laptop, 8 ГБ GDDR7, до 75 Вт'; Src = 'GIGABYTE Japan'; Url = $GbA16Jp; Note = 'спецификация региональной версии 3TH; фактический лимит зависит от прошивки и режима, это не обязательное среднее потребление в FurMark' },
      @{ What = 'Лимиты RTX 5050 по режимам в обзоре A16 3TH'; Value = 'Performance — до 85 Вт; Balance — до 70 Вт; Silent — до 50 Вт'; Src = 'Ultra-tech, iXBT Live (авторский обзор)'; Url = $IxA16; Note = 'именно Ryzen 7 260 + RTX 5050; расхождение с паспортными 75 Вт не объяснено источниками. Сверьте режим GiMATE и лимит драйвера своего экземпляра; потребление в ваттах не заменяет оценку быстродействия' },
      @{ What = 'Экран'; Value = '16 дюймов, IPS, 1920x1200, 165 Гц, 300 нит'; Src = 'GIGABYTE'; Url = $GbA16; Note = 'панель WUXGA для версии с RTX 5050; проверьте 165 Гц в параметрах экрана Windows' },
      @{ What = 'Аккумулятор и блок питания'; Value = '76 Вт·ч, адаптер 150 Вт'; Src = 'GIGABYTE'; Url = $GbA16; Note = 'сверьте маркировку зарядки и заводскую ёмкость в battery.html' },
      @{ What = 'Режим перед тестом'; Value = 'GiMATE: «Игры» / Performance, питание от штатного адаптера'; Src = '3DNews, A16 3VH'; Url = $DnA16; Note = 'запишите режим и настройки вентиляторов в метку отчёта; для повторных замеров они должны совпадать' }
    )
  }
)

# ---------- общие помощники ----------
function F($v, [string]$fmt = '0.#') { if ($null -eq $v) { '—' } else { ([double]$v).ToString($fmt, $inv) } }
function ParseD($s) {
  if ($null -eq $s) { return $null }
  $s = "$s".Trim()
  if ($s -eq '' -or $s -match 'N/A|Not Supported') { return $null }
  $d = 0.0
  if ([double]::TryParse(($s -replace '[^\d\.\-]', ''), [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d }
  return $null
}
function HtmlEnc([string]$s) { [Net.WebUtility]::HtmlEncode("$s") }

$script:LogFile = $null
function Say([string]$msg, [string]$color = 'Gray') {
  $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $msg
  Write-Host $line -ForegroundColor $color
  if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

$script:Phases = New-Object System.Collections.ArrayList
function Start-Phase([string]$name) {
  $script:CurPhase = [pscustomobject]@{ Name = $name; Start = Get-Date; End = $null }
  [void]$script:Phases.Add($script:CurPhase)
}
function Stop-Phase { if ($script:CurPhase) { $script:CurPhase.End = Get-Date } }

function Wait-Seconds([int]$sec, [string]$label) {
  $end = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $end) {
    $left = [int][math]::Ceiling(($end - (Get-Date)).TotalSeconds)
    Write-Progress -Activity $label -Status ('осталось {0}:{1:00}' -f [int][math]::Floor($left / 60), ($left % 60)) -PercentComplete ([int](100 * ($sec - $left) / [math]::Max($sec, 1)))
    Start-Sleep -Seconds 1
  }
  Write-Progress -Activity $label -Completed
}

function Wait-Procs($procs, [int]$expectSec, [string]$label) {
  # R23 доводит последний проход до конца, поэтому ждём с запасом
  $t0 = Get-Date
  $limit = $expectSec + [math]::Max(300, $expectSec)
  while ($true) {
    $alive = @($procs | Where-Object { $_ -and -not $_.HasExited })
    if (-not $alive.Count) { break }
    $el = [int]((Get-Date) - $t0).TotalSeconds
    if ($el -gt $limit) {
      Say "  $label — превышено время, останавливаю" 'Yellow'
      $alive | ForEach-Object { try { $_.Kill() } catch {} }
      break
    }
    Write-Progress -Activity $label -Status ('прошло {0}:{1:00} из ~{2}:{3:00}' -f [int][math]::Floor($el / 60), ($el % 60), [int][math]::Floor($expectSec / 60), ($expectSec % 60)) -PercentComplete ([int][math]::Min(99, 100 * $el / [math]::Max($expectSec, 1)))
    Start-Sleep -Seconds 1
  }
  Write-Progress -Activity $label -Completed
}

# ---------- уборка ----------
# Состояние пишется в state.json в начале прогона, чтобы CLEANUP.cmd мог доубрать,
# если окно закрыли посреди теста.
function Invoke-Cleanup($state) {
  $log = New-Object System.Collections.ArrayList
  $start = if ($state.Start -is [datetime]) { $state.Start } else { [datetime]::Parse($state.Start, $inv) }

  # 1. процессы, запущенные с флешки, и наши фоновые писатели датчиков
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
    try { $_.Kill(); [void]$log.Add("остановлен процесс $($_.Name) ($($_.Id))") } catch {}
  }
  foreach ($procId in @($state.SamplerPid, $state.GpuLogPid)) {
    if ($procId) {
      $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($p -and $p.StartTime -ge $start.AddSeconds(-5)) { try { $p.Kill(); [void]$log.Add("остановлен $($p.Name) ($procId)") } catch {} }
    }
  }
  Start-Sleep -Milliseconds 800

  # 2. тестовый файл DiskSpd
  if ($state.DiskspdFile -and (Test-Path -LiteralPath $state.DiskspdFile)) {
    Remove-Item -LiteralPath $state.DiskspdFile -Force -ErrorAction SilentlyContinue
    [void]$log.Add("удалён $($state.DiskspdFile)")
  }

  # 2б. промежуточный файл powercfg /batteryreport
  $bt = Join-Path $env:TEMP 'battery-report.xml'
  if (-not $state.BatteryTmpExisted -and (Test-Path -LiteralPath $bt) -and (Get-Item -LiteralPath $bt).CreationTime -ge $start) {
    Remove-Item -LiteralPath $bt -Force -ErrorAction SilentlyContinue
    [void]$log.Add("удалён $bt")
  }

  # 3. Cinebench: настройки в %APPDATA%\Maxon и пустая папка результатов в Документы\MAXON
  $maxonDirs = @(
    @{ Path = (Join-Path $env:APPDATA 'Maxon'); Existed = $state.MaxonExisted },
    @{ Path = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MAXON'); Existed = $state.MaxonDocsExisted }
  )
  foreach ($m in $maxonDirs) {
    if (-not (Test-Path -LiteralPath $m.Path)) { continue }
    if (-not $m.Existed) {
      Remove-Item -LiteralPath $m.Path -Recurse -Force -ErrorAction SilentlyContinue
      [void]$log.Add("удалена папка $($m.Path) (её не было до теста)")
    } else {
      Get-ChildItem -LiteralPath $m.Path -Force | Where-Object { $_.CreationTime -ge $start -and $_.Name -like 'Cinebench*' } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        [void]$log.Add("удалена $($_.FullName)")
      }
    }
  }

  # 4. следы инструментов в их собственных папках на флешке (чтобы не смешивать ноутбуки)
  $cdi = Join-Path $Tools 'cdi'
  foreach ($n in @('DiskInfo.txt', 'DiskInfo.ini', 'Smart')) {
    $p = Join-Path $cdi $n
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue; [void]$log.Add("удалён $p") }
  }
  $fm = Join-Path $Tools 'furmark\FurMark_win64'
  if (Test-Path -LiteralPath $fm) {
    Get-ChildItem -LiteralPath $fm -Recurse -Force -File | Where-Object { $_.CreationTime -ge $start } | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      [void]$log.Add("удалён $($_.FullName)")
    }
  }
  foreach ($p in @($state.ExtraPaths)) {
    if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue; [void]$log.Add("удалён $p") }
  }

  # 5. контроль: что ещё появилось за время теста (только отчёт, не удаляем — могли создать другие программы)
  $watch = @($env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, [Environment]::GetFolderPath('MyDocuments'), $env:ProgramData)
  $newItems = @()
  foreach ($d in $watch) {
    if ($d -and (Test-Path -LiteralPath $d)) {
      $newItems += @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $start } | ForEach-Object { $_.FullName })
    }
  }
  $regNow = @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
  $regNew = @($regNow | Where-Object { $state.HkcuSoftware -notcontains $_ })

  $state | Add-Member -NotePropertyName CleanupDone -NotePropertyValue $true -Force
  $state | Add-Member -NotePropertyName CleanupLog -NotePropertyValue @($log) -Force
  $state | Add-Member -NotePropertyName NewItems -NotePropertyValue $newItems -Force
  $state | Add-Member -NotePropertyName NewRegKeys -NotePropertyValue $regNew -Force
  return $state
}

function Save-State($state, [string]$path) { $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8 }

if ($CleanupOnly) {
  $sf = Get-ChildItem -LiteralPath (Join-Path $Root 'reports') -Recurse -Filter state.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $sf) { Write-Host 'Нет прогонов для уборки.'; Read-Host 'Enter — выход'; exit }
  $st = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $st = Invoke-Cleanup $st
  Save-State $st $sf.FullName
  Write-Host "Уборка по $($sf.FullName):"
  $st.CleanupLog | ForEach-Object { Write-Host "  $_" }
  if (@($st.NewItems).Count -or @($st.NewRegKeys).Count) {
    Write-Host 'Появилось за время теста (не удалялось, проверьте):' -ForegroundColor Yellow
    @($st.NewItems) + @($st.NewRegKeys | ForEach-Object { "HKCU\Software\$_" }) | ForEach-Object { Write-Host "  $_" }
  }
  Read-Host 'Enter — выход'
  exit
}

# =====================================================================
#   1. Сведения о ноутбуке (только чтение)
# =====================================================================
function Get-Info {
  $i = [ordered]@{}
  $cs   = Get-CimInstance Win32_ComputerSystem
  $bios = Get-CimInstance Win32_BIOS
  $bb   = Get-CimInstance Win32_BaseBoard
  $os   = Get-CimInstance Win32_OperatingSystem
  $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

  $i.Manufacturer = "$($cs.Manufacturer)".Trim()
  $i.Model        = "$($cs.Model)".Trim()
  $i.Sku          = "$($cs.SystemSKUNumber)".Trim()
  $i.Serial       = "$($bios.SerialNumber)".Trim()
  $i.BiosVersion  = "$($bios.SMBIOSBIOSVersion)".Trim()
  $i.BiosDate     = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { '' }
  $i.Board        = "$($bb.Product)".Trim()
  $i.Os           = "$($os.Caption) $($os.Version)".Trim()
  $i.OsInstalled  = if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' }
  $i.Cpu          = "$($cpu.Name)".Trim()
  $i.CpuCores     = $cpu.NumberOfCores
  $i.CpuThreads   = $cpu.NumberOfLogicalProcessors
  $i.RamTotalGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

  # виртуализация: при работающем Hyper-V/VBS флаг прошивки читается как False, поэтому смотрим и HypervisorPresent
  $i.VirtFirmware = [bool]$cpu.VirtualizationFirmwareEnabled
  $i.Hypervisor   = [bool]$cs.HypervisorPresent

  # память по слотам
  $typeMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
  $i.RamModules = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    [ordered]@{
      Slot      = "$($_.DeviceLocator)".Trim()
      Bank      = "$($_.BankLabel)".Trim()
      SizeGB    = [math]::Round($_.Capacity / 1GB, 1)
      Type      = $(if ($typeMap.ContainsKey([int]$_.SMBIOSMemoryType)) { $typeMap[[int]$_.SMBIOSMemoryType] } else { "код $($_.SMBIOSMemoryType)" })
      SpeedMTs  = $_.Speed
      RunMTs    = $_.ConfiguredClockSpeed
      Vendor    = "$($_.Manufacturer)".Trim()
      Part      = "$($_.PartNumber)".Trim()
      Serial    = "$($_.SerialNumber)".Trim()
    }
  })
  $arr = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
  $i.RamSlots = if ($arr) { $arr.MemoryDevices } else { $null }

  # видеокарты и режим (гибрид или дискретный MUX)
  $vcs = @(Get-CimInstance Win32_VideoController)
  $i.Gpus = @($vcs | ForEach-Object { [ordered]@{ Name = "$($_.Name)".Trim(); Driver = $_.DriverVersion; Status = $_.Status; Res = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"; Hz = $_.CurrentRefreshRate } })
  $active = @($vcs | Where-Object { $_.Status -eq 'OK' })
  $hasNv  = [bool]($active | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX' })
  $hasIgp = [bool]($active | Where-Object { $_.Name -match 'Intel|Radeon\(TM\) Graphics|AMD Radeon Graphics' })
  $i.GpuMode = if ($hasNv -and $hasIgp) { 'гибридный (MSHybrid/Optimus)' } elseif ($hasNv) { 'только дискретная (MUX)' } else { 'дискретная не найдена' }

  $nv = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
  $i.NvSmi = [bool]$nv
  if ($nv) {
    $q = & nvidia-smi.exe --query-gpu=name,vbios_version,driver_version,enforced.power.limit,power.default_limit,power.max_limit,clocks.max.gr,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($q) {
      $f = $q -split ',\s*'
      $i.Nv = [ordered]@{ Name = $f[0]; Vbios = $f[1]; Driver = $f[2]; PowerLimitW = ParseD $f[3]; PowerDefaultW = ParseD $f[4]; PowerMaxW = ParseD $f[5]; MaxClockMHz = ParseD $f[6]; VramMiB = ParseD $f[7] }
    }
  }

  # экран: модель панели и максимальная частота из EDID
  try {
    $mon = Get-CimInstance -Namespace root\wmi WmiMonitorID -ErrorAction Stop | Select-Object -First 1
    $dec = { param($a) (($a | Where-Object { $_ -ne 0 }) | ForEach-Object { [char]$_ }) -join '' }
    $i.Panel = ('{0} {1} {2}' -f (& $dec $mon.ManufacturerName), (& $dec $mon.ProductCodeID), (& $dec $mon.UserFriendlyName)).Trim()
    $modes = Get-CimInstance -Namespace root\wmi WmiMonitorListedSupportedSourceModes -ErrorAction Stop | Select-Object -First 1
    $i.PanelMaxHz = [math]::Round((($modes.MonitorSourceModes | ForEach-Object { if ($_.VerticalRefreshRateDenominator) { $_.VerticalRefreshRateNumerator / $_.VerticalRefreshRateDenominator } }) | Measure-Object -Maximum).Maximum, 0)
  } catch { $i.Panel = ''; $i.PanelMaxHz = $null }

  # сеть, Bluetooth, проблемные устройства
  $i.Net = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InterfaceDescription) — $($_.Status)" })
  $i.Bluetooth = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -notmatch 'Enumerator|RFCOMM|LE Generic|Avrcp|Hands-Free|Audio' } | ForEach-Object { $_.FriendlyName } | Select-Object -Unique)
  $i.ProblemDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 } | ForEach-Object { [ordered]@{ Name = "$($_.Name)"; Code = $_.ConfigManagerErrorCode } })

  # без прав администратора оба отвечают ложным «нет», поэтому спрашиваем только с правами
  $i.SecureBoot = $null; $i.Tpm = ''
  if ($IsAdmin) {
    try { $i.SecureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch {}
    try { $t = Get-Tpm -ErrorAction Stop; $i.Tpm = "есть: $([bool]$t.TpmPresent), готов: $([bool]$t.TpmReady)" } catch {}
  }

  $i.PowerScheme = ((& powercfg.exe /getactivescheme) -join ' ').Trim()
  $bs = Get-CimInstance -Namespace root\wmi BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1
  $i.AcOnline = if ($bs) { [bool]$bs.PowerOnline } else { $null }
  return $i
}

function Get-BatteryInfo([string]$dir) {
  # powercfg оставляет за собой %TEMP%\battery-report.xml — его убирает Invoke-Cleanup
  $xml = Join-Path $dir 'battery.xml'
  & powercfg.exe /batteryreport /xml /output "$xml" | Out-Null
  & powercfg.exe /batteryreport /output (Join-Path $dir 'battery.html') | Out-Null
  Read-BatteryXml $xml
}

function Read-BatteryXml([string]$xml) {
  $r = [ordered]@{}
  try {
    [xml]$x = Get-Content -LiteralPath $xml -Raw -Encoding UTF8
    $b = @($x.BatteryReport.Batteries.Battery)[0]
    $r.Id = "$($b.Manufacturer) $($b.Id)".Trim()
    $r.DesignMWh = [double]$b.DesignCapacity
    $r.FullMWh = [double]$b.FullChargeCapacity
    $r.Cycles = $b.CycleCount
    if ($r.DesignMWh -gt 0) { $r.HealthPct = [math]::Round(100 * $r.FullMWh / $r.DesignMWh, 1) }
  } catch { $r.Error = "$_" }
  return $r
}

function Get-DiskHealth([string]$dir) {
  $res = [ordered]@{ Disks = @(); CdiText = '' }
  $res.Disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    $rc = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    [ordered]@{
      Name = "$($_.FriendlyName)".Trim(); Bus = "$($_.BusType)"; Media = "$($_.MediaType)"; SizeGB = [math]::Round($_.Size / 1GB, 0)
      Serial = "$($_.SerialNumber)".Trim(); Firmware = "$($_.FirmwareVersion)".Trim()
      Health = "$($_.HealthStatus)"; WearPct = $rc.Wear; TempC = $rc.Temperature; TempMaxC = $rc.TemperatureMax
      PowerOnHours = $rc.PowerOnHours; ReadErrUncorrected = $rc.ReadErrorsUncorrected; WriteErrUncorrected = $rc.WriteErrorsUncorrected
    }
  })
  if (-not $res.Disks.Count) {
    # Запасной инвентарный снимок, если Storage API недоступен. SMART при этом неизвестен.
    $res.Disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
      [ordered]@{ Name="$($_.Model)".Trim(); Serial="$($_.SerialNumber)".Trim(); Firmware="$($_.FirmwareRevision)".Trim()
        Bus=$(if ($_.PNPDeviceID -match '^USBSTOR') { 'USB' } else { "$($_.InterfaceType)" }); Media='не определён'
        SizeGB=[math]::Round($_.Size / 1GB, 0); Health=''; WearPct=$null; TempC=$null; PowerOnHours=$null
        ReadErrUncorrected=$null; WriteErrUncorrected=$null }
    })
  }
  # у CrystalDiskInfo в манифесте requireAdministrator — без прав он сам вызовет запрос UAC
  $exe = Join-Path $Tools 'cdi\DiskInfo64.exe'
  if ($IsAdmin -and (Test-Path -LiteralPath $exe)) {
    $p = Start-Process -FilePath $exe -ArgumentList '/CopyExit' -WorkingDirectory (Split-Path $exe) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {} }
    $txt = Join-Path $Tools 'cdi\DiskInfo.txt'
    if (Test-Path -LiteralPath $txt) {
      Copy-Item -LiteralPath $txt -Destination (Join-Path $dir 'smart-crystaldiskinfo.txt') -Force
      $res.CdiText = Get-Content -LiteralPath $txt -Raw
    }
  }
  return $res
}

function Invoke-DiskSpeed([string]$file) {
  $exe = Join-Path $Tools 'diskspd\amd64\diskspd.exe'
  $r = [ordered]@{}
  if (-not (Test-Path -LiteralPath $exe)) { return $r }
  $tests = [ordered]@{
    SeqReadMBs  = @("-c$($D.DiskSize)", '-b1M', "-d$($D.DiskSec)", '-o8', '-t1', '-W2', '-Sh', '-w0')
    SeqWriteMBs = @("-c$($D.DiskSize)", '-b1M', "-d$($D.DiskSec)", '-o8', '-t1', '-W2', '-Sh', '-w100')
    Rand4kIops  = @("-c$($D.DiskSize)", '-b4K', '-r', "-d$($D.DiskSec)", '-o32', '-t4', '-W2', '-Sh', '-w0')
  }
  foreach ($k in $tests.Keys) {
    $out = & $exe @($tests[$k] + $file) 2>&1 | Out-String
    $out | Set-Content -LiteralPath (Join-Path $script:Rep "diskspd-$k.txt") -Encoding UTF8
  }
  Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  return Read-DiskSpeed $script:Rep
}

# Строка «total:» в блоке «Total IO»: байты | операции | МиБ/с | операций/с
function Read-DiskSpeed([string]$dir) {
  $r = [ordered]@{}
  foreach ($k in @('SeqReadMBs', 'SeqWriteMBs', 'Rand4kIops')) {
    $f = Join-Path $dir "diskspd-$k.txt"
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $m = [regex]::Match((Get-Content -LiteralPath $f -Raw), '(?s)Total IO.*?total:\s*\d+\s*\|\s*\d+\s*\|\s*([\d\.]+)\s*\|\s*([\d\.]+)')
    if ($m.Success) { $r[$k] = if ($k -eq 'Rand4kIops') { ParseD $m.Groups[2].Value } else { ParseD $m.Groups[1].Value } }
  }
  return $r
}

# =====================================================================
#   2. Нагрузка
# =====================================================================
function Start-Cinebench([string]$test, [int]$minSec, [string]$outFile) {
  # Консольный режим R23: прогнать тест не меньше $minSec секунд и напечатать результат.
  # Пишет в stdout, если его перенаправить (через «cmd > файл» вывод теряется — проверено).
  $exe = Join-Path $Tools 'cinebench\Cinebench.exe'
  Start-Process -FilePath $exe -ArgumentList "g_Cinebench${test}Test=true g_CinebenchMinimumTestDuration=$minSec" -WorkingDirectory (Split-Path $exe) -PassThru -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
}

# Итог R23 — строка «CB 15178.80 (0.00)»; по проходам — «Values: {a, b, …} -> Avg/Deviation».
function Get-CinebenchScore([string]$outFile) {
  if (-not (Test-Path -LiteralPath $outFile)) { return $null }
  $t = Get-Content -LiteralPath $outFile -Raw
  $m = [regex]::Matches($t, '(?m)^CB\s+([\d\.]+)')
  $passes = @()
  $v = [regex]::Matches($t, 'Values:\s*\{([^}]*)\}')
  if ($v.Count) { $passes = @($v[$v.Count - 1].Groups[1].Value -split ',' | ForEach-Object { ParseD $_ } | Where-Object { $null -ne $_ }) }
  if ($m.Count) {
    return [pscustomobject]@{ Score = ParseD $m[$m.Count - 1].Groups[1].Value; Passes = $passes; Incomplete = $false }
  }
  if ($passes.Count) {
    # Сохраняем завершённые проходы прерванного теста, не выдавая их за итог CB.
    return [pscustomobject]@{ Score = ($passes | Measure-Object -Average).Average; Passes = $passes; Incomplete = $true }
  }
  return $null
}
function Format-Passes($cb) {
  if (-not $cb -or $cb.Passes.Count -lt 2) { return '' }
  ' (проходов {0}: первый {1}, последний {2})' -f $cb.Passes.Count, (F $cb.Passes[0] '0'), (F $cb.Passes[-1] '0')
}

function Start-FurMark([int]$sec, [string]$outFile) {
  $exe = Join-Path $Tools 'furmark\FurMark_win64\furmark.exe'
  $a = @('--demo', 'furmark-gl', '--width', '1280', '--height', '720', '--max-time', "$sec", '--no-score-box', '--hpgfx', '1', '--disable-traces')
  Start-Process -FilePath $exe -ArgumentList $a -WorkingDirectory (Split-Path $exe) -PassThru -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
}

# =====================================================================
#   3. Отчёт
# =====================================================================
function Read-Csv([string]$path, [string[]]$header) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  if ($header) { return @(Import-Csv -LiteralPath $path -Header $header) }
  return @(Import-Csv -LiteralPath $path)
}
function Get-Time([string]$s) {
  $d = [datetime]::MinValue
  foreach ($f in @('yyyy-MM-dd HH:mm:ss.fff', 'yyyy/MM/dd HH:mm:ss.fff')) {
    if ([datetime]::TryParseExact($s.Trim(), $f, $inv, 'None', [ref]$d)) { return $d }
  }
  return $null
}
function Get-Slice($rows, $phase, [double]$fromFrac = 0, [double]$toFrac = 1) {
  if (-not $phase -or -not $phase.End) { return @() }
  $len = ($phase.End - $phase.Start).TotalSeconds
  $a = $phase.Start.AddSeconds($len * $fromFrac); $b = $phase.Start.AddSeconds($len * $toFrac)
  @($rows | Where-Object { $_.T -and $_.T -ge $a -and $_.T -le $b })
}
# Только секунды реальной нагрузки: Cinebench с флешки стартует до пары минут, и простой
# в начале этапа исказил бы сравнение «начало/конец».
function Get-Loaded($rows, [string]$col, [double]$min) { @($rows | Where-Object { $v = ParseD $_.$col; $null -ne $v -and $v -ge $min }) }
function Get-Part($rows, [double]$from, [double]$to) {
  $r = @($rows); $n = $r.Count
  if (-not $n) { return @() }
  $a = [int][math]::Floor($n * $from); $b = [int][math]::Ceiling($n * $to) - 1
  if ($b -lt $a) { $b = $a }
  @($r[$a..$b])
}
function Get-Stat($rows, [string]$col) {
  $v = @($rows | ForEach-Object { ParseD $_.$col } | Where-Object { $null -ne $_ })
  if (-not $v.Count) { return $null }
  $m = $v | Measure-Object -Average -Maximum -Minimum
  [pscustomobject]@{ Avg = $m.Average; Max = $m.Maximum; Min = $m.Minimum; N = $v.Count }
}
function Get-Share($rows, [scriptblock]$cond) {
  $n = @($rows).Count
  if (-not $n) { return $null }
  100.0 * @($rows | Where-Object $cond).Count / $n
}
function Get-Reasons($r) {
  $s = "$($r.reasons)".Trim()
  if ($s -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }
  return 0
}

$script:Verdicts = New-Object System.Collections.ArrayList
function V([string]$level, [string]$what, [string]$text, [string]$basis = '', [string]$reference = '', [string]$sourceUrl = '') {
  if (-not $basis) {
    $basis = switch -Wildcard ($what) {
      'Батарея' { 'Пороги набора по остаточной ёмкости: норма ≥85%, внимание 75–<85%, плохо <75% от DesignCapacity.' }
      'Память' { 'Число модулей и тип считываются из SMBIOS; число активных каналов и заводское происхождение модулей этим не подтверждаются.' }
      'SSD *' { 'Плохо: статус Windows не Healthy либо неисправленные ошибки >0; внимание: износ ≥20%. Отсутствие SMART не означает исправность.' }
      'Процессор: Cinebench*' { 'Первый проход / референс: норма ≥90%, внимание 80–<90%, плохо <80%. При приблизительном референсе оценка справочная.' }
      'Процессор: частота*' { 'Порог набора по снижению частоты относительно начала: норма <20%, внимание 20–<35%, плохо ≥35%. Просадка сама по себе не доказывает перегрев.' }
      'Процессор: температура*' { 'ACPI-зона не является датчиком CPU Package; официальный Tjmax к ней не применяется. Температура приводится справочно.' }
      'Видеокарта: температура' { 'Пороги набора по максимуму: норма <84 °C, внимание 84–<88 °C, плохо ≥88 °C. Это диагностическое правило, не официальный предел GPU.' }
      'Видеокарта: тепловой троттлинг' { 'Доля загруженных отсчётов GPU с thermal-флагами nvidia-smi (0x20/0x40). Пороги набора: норма <2%, внимание 2–<15%, плохо ≥15%. Ожидается отсутствие устойчивого теплового ограничения; краткие пики возможны.' }
      'Видеокарта: аппаратное*' { 'Внимание при HW Slowdown / HW Power Brake (маска 0x88) ≥1% загруженных отсчётов. Причина требует проверки питания, температур и режима.' }
      'Видеокарта: мощность*' { 'Среднее потребление / фактический лимит: норма ≥85%, внимание 70–<85%, плохо <70% (эвристика набора). Для A16 — справочно; достижение лимита не подтверждает быстродействие.' }
      'Зарядка' { 'Внимание: разряд >3 Вт при подключённом питании в ≥10% отсчётов совместной нагрузки. Отсутствие такого разряда не подтверждает номинал адаптера.' }
      'Устройства' { 'Сравнение с ConfigManagerErrorCode=0; отключённые устройства (код 22) исключены.' }
      'Питание' { 'Для сравнения производительности требуется питание от штатного адаптера.' }
      default { 'Фактическое состояние, сообщённое Windows; числовой референс неприменим.' }
    }
  }
  if ($reference) { $basis += ' Референс: ' + $reference }
  [void]$script:Verdicts.Add([pscustomobject]@{ Level = $level; What = $what; Text = $text; Basis = $basis; SourceUrl = $sourceUrl })
}

function Find-Profile($info, [switch]$IdentityOnly) {
  $gpuNames = @($info.Nv.Name) + @($info.Gpus | ForEach-Object { $_.Name })
  $Profiles | Where-Object {
    $modelMatch = if ($_.IdPattern) { "$($info.Model) $($info.Board) $($info.Sku)" -match $_.IdPattern }
                  else { $info.Model -like "*$($_.Match)*" -or ($_.Board -and $info.Board -like "*$($_.Board)*") }
    $modelMatch -and (-not $_.ManufacturerPattern -or $info.Manufacturer -match $_.ManufacturerPattern) -and
      ($IdentityOnly -or ((-not $_.CpuPattern -or $info.Cpu -match $_.CpuPattern) -and
      (-not $_.GpuPattern -or @($gpuNames -match $_.GpuPattern).Count -gt 0)))
  } | Select-Object -First 1
}

function Get-HardwareAudit($ctx, $profile) {
  $i = $ctx.Info; $e = $profile.Expected
  $rows = New-Object System.Collections.ArrayList
  function Add-Audit($component, $expected, $actual, $status, $reason) {
    [void]$rows.Add([pscustomobject]@{ Component=$component; Expected=$expected; Actual=$actual; Status=$status; Reason=$reason })
  }
  $unknown = 'Не задано: нужен полный SKU / исходная комплектация'
  $state = 'не сверено'; $reason = $unknown
  if ($e.Cpu) {
    $state = if ($i.Cpu -match $profile.CpuPattern -and $i.CpuCores -eq $e.Cores -and $i.CpuThreads -eq $e.Threads) { 'совпадает' } else { 'расхождение' }
    $reason = 'Модель из задания; ядра/потоки по GIGABYTE. Расхождение потоков может быть связано с настройкой BIOS.'
  }
  Add-Audit 'CPU' $(if ($e.Cpu) { "$($e.Cpu), $($e.Cores) ядер / $($e.Threads) потоков" } else { $unknown }) "$($i.Cpu), $($i.CpuCores) ядер / $($i.CpuThreads) потоков" $state $reason
  Add-Audit 'Мощность CPU' 'Лимит конкретного ноутбука не подтверждён' 'Не измеряется этим набором' 'нет данных' 'TDP AMD 45 Вт и cTDP 35–54 Вт — характеристики процессора; 65 Вт в обзоре A16 3VH не являются официальным лимитом A16 3TH.'
  # Последняя строка о Ryzen применима только к выбранному профилю A16.
  if (-not $e.Cpu) { $rows[$rows.Count-1].Reason = 'Нужны показания мощности CPU Package и лимитов под нагрузкой; текущий набор их не собирает.' }
  $gpuNames = (@($i.Nv.Name) + @($i.Gpus | ForEach-Object { $_.Name }) | Where-Object { $_ } | Select-Object -Unique) -join '; '
  $state = 'не сверено'
  if ($e.Gpu) { $state = if ($gpuNames -match $profile.GpuPattern) { 'совпадает' } else { 'расхождение' } }
  Add-Audit 'GPU' $(if ($e.Gpu) { "$($e.Gpu) Laptop" } else { $unknown }) $gpuNames $state 'Модель из задания; отсутствие дискретной GPU также может быть связано с драйвером или режимом iGPU.'
  $state = 'нет данных'
  if ($i.Nv.VramMiB) { $state = if (-not $e.VramMiB) { 'не сверено' } elseif ([math]::Abs($i.Nv.VramMiB - $e.VramMiB) -le 256) { 'совпадает' } else { 'расхождение' } }
  Add-Audit 'Видеопамять' $(if ($e.VramMiB) { "$($e.VramMiB) МиБ, GDDR7 по спецификации" } else { $unknown }) "$(F $i.Nv.VramMiB '0') МиБ" $state 'Объём считывает nvidia-smi; тип GDDR текущий набор не определяет. Допуск 256 МиБ на резерв драйвера.'
  Add-Audit 'Мощность GPU' $(if ($profile.GpuWRefText) { $profile.GpuWRefText } else { 'Референс не задан' }) "Лимит $(F $i.Nv.PowerLimitW '0') Вт; максимум $(F $i.Nv.PowerMaxW '0') Вт" 'сверить режим' 'Лимит сообщает драйвер; выберите одинаковый режим GiMATE/MSI Center. Ватты не заменяют тест производительности.'
  $modules = @($i.RamModules | Where-Object { $_.SizeGB -gt 0 })
  $ramGB = ($modules | ForEach-Object { $_.SizeGB } | Measure-Object -Sum).Sum
  $state = 'не сверено'
  if (-not $modules.Count) { $state = 'нет данных' }
  elseif ($e.RamGB) { $state = if ($ramGB -ge $e.RamGB) { 'совпадает' } else { 'расхождение' } }
  Add-Audit 'RAM: объём' $(if ($e.RamGB) { "$($e.RamGB) ГБ" } else { $unknown }) "$(F $ramGB) ГБ установлено; модулей $($modules.Count), слотов $($i.RamSlots)" $state 'Используется сумма ёмкостей планок, а не доступная Windows память. Без исходного объёма уменьшение ёмкости не определить.'
  foreach ($m in $modules) {
    $state = 'не сверено'; $reason = 'Марка и артикул из SMBIOS. Происхождение планки и тайминги не подтверждены; иной производитель сам по себе не означает ухудшение.'
    if ($e.RamType) {
      $state = 'совпадает по типу'
      if ($m.Type -ne $e.RamType -or ($m.SpeedMTs -gt 0 -and $m.SpeedMTs -lt $e.RamMTs)) { $state = 'проверить: ниже ориентира' }
      elseif (-not $m.SpeedMTs -or -not $m.RunMTs) { $state = 'данные неполные' }
      elseif ($m.RunMTs -lt $e.RamMTs) { $state = 'проверить: снижена скорость' }
      $reason += ' DDR5-5600 — возможность платформы по GIGABYTE, не доказательство заводской поставки; снижение скорости также зависит от BIOS и сочетания планок.'
    }
    Add-Audit "RAM: $($m.Slot)" $(if ($e.RamType) { "$($e.RamType), ориентир до $($e.RamMTs) МТ/с" } else { $unknown }) "$($m.Vendor) $($m.Part); $($m.SizeGB) ГБ $($m.Type); паспорт $($m.SpeedMTs), работает $($m.RunMTs) МТ/с; S/N $($m.Serial)" $state $reason
  }
  $disks = @($ctx.Disk.Disks | Where-Object { $_.Bus -ne 'USB' })
  if (-not $disks.Count) { Add-Audit 'SSD' $unknown 'Нет данных о внутренних накопителях' 'нет данных' 'Данные диска отсутствуют в этом прогоне; исправность и комплектация не подтверждены.' }
  foreach ($d in $disks) {
    Add-Audit 'Накопитель' $(if ($e.DiskGB) { "SSD не менее $($e.DiskGB) ГБ" } else { $unknown }) "$($d.Name); $($d.SizeGB) ГиБ; $($d.Media) / $($d.Bus); S/N $($d.Serial); FW $($d.Firmware)" 'не сверено' 'Сверьте модель, ёмкость и интерфейс с объявлением/исходной спецификацией. Точная заводская модель SSD не известна; скорость см. в результатах DiskSpd.'
  }
  if ($disks.Count -and $e.RamType) {
    $ssd = @($disks | Where-Object { $_.Media -eq 'SSD' -or $_.Bus -eq 'NVMe' })
    $total = ($ssd | ForEach-Object { $_.SizeGB } | Measure-Object -Sum).Sum
    $state = 'не сверено'
    if ($e.DiskGB) { $state = if ($total -ge 0.90 * $e.DiskGB) { 'совпадает' } else { 'расхождение' } }
    Add-Audit 'SSD: суммарная ёмкость' $(if ($e.DiskGB) { "$($e.DiskGB) ГБ из объявления" } else { $unknown }) "$(F $total '0') ГиБ; SSD/NVMe устройств: $($ssd.Count)" $state 'При сравнении с десятичными ГБ допускается 10% на пересчёт в ГиБ. SSD с неизвестным типом Windows может потребовать ручной сверки.'
  }
  $screen = (@($i.Gpus | Where-Object { $_.Hz -and $_.Res -ne 'x' } | ForEach-Object { "$($_.Res) @ $($_.Hz) Гц" })) -join '; '
  $state = 'не сверено'
  if ($e.PanelHz) { $state = if (-not $i.PanelMaxHz) { 'нет данных' } elseif ($i.PanelMaxHz -lt $e.PanelHz) { 'проверить частоту' } else { 'сверить разрешение' } }
  Add-Audit 'Экран' $(if ($e.PanelRes) { "16 дюймов, IPS, $($e.PanelRes), $($e.PanelHz) Гц" } else { $unknown }) "$($i.Panel); EDID максимум $(F $i.PanelMaxHz '0') Гц; сейчас $screen" $state 'Текущий режим Windows не равен максимальному разрешению панели. Модель панели, IPS и цветовой охват требуют сверки; возможен внешний монитор.'
  Add-Audit 'Батарея' $(if ($e.BatteryMWh) { "$($e.BatteryMWh) мВт·ч по спецификации" } else { $unknown }) "$($ctx.Battery.Id); заводская $(F $ctx.Battery.DesignMWh '0'), полная $(F $ctx.Battery.FullMWh '0') мВт·ч" 'сверить ёмкость' 'DesignCapacity сообщает контроллер установленной батареи; износ не доказывает оригинальность или отсутствие замены.'
  Add-Audit 'Блок питания' $(if ($e.Cpu) { '150 Вт по GIGABYTE' } else { $unknown }) 'Маркировка адаптера программно не читается' 'проверить руками' 'Сверьте выходное напряжение и ток на наклейке; номинальная мощность = В × А.'
  Add-Audit 'Сеть' $unknown ($i.Net -join '; ') 'не сверено' 'Показаны названия адаптеров Windows; для проверки замены нужна исходная модель.'
  return $rows
}

# Всё для отчёта читается из файлов папки прогона — так отчёт можно пересобрать
# без повторного теста: checkup.ps1 -ReportFrom <папка>.
function Import-Ctx([string]$dir) {
  $run = Get-Content -LiteralPath (Join-Path $dir 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $ctx = @{
    Started = [datetime]::Parse($run.Started, $inv)
    Label   = $run.Label
    Mode    = $run.Mode
    Info    = Get-Content -LiteralPath (Join-Path $dir 'info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Battery = Read-BatteryXml (Join-Path $dir 'battery.xml')
    Disk    = [ordered]@{ Disks = @() }
    Speed   = Read-DiskSpeed $dir
    CbMulti  = Get-CinebenchScore (Join-Path $dir 'cinebench-cpu.txt')
    CbCombo  = Get-CinebenchScore (Join-Path $dir 'cinebench-combo.txt')
    CbSingle = Get-CinebenchScore (Join-Path $dir 'cinebench-single.txt')
    Phases  = @()
  }
  $dj = Join-Path $dir 'disk.json'
  if (Test-Path -LiteralPath $dj) { $ctx.Disk.Disks = @(Get-Content -LiteralPath $dj -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) }
  $pf = Join-Path $dir 'phases.csv'
  if (Test-Path -LiteralPath $pf) {
    $ctx.Phases = @(Import-Csv -LiteralPath $pf | ForEach-Object {
      [pscustomobject]@{ Name = $_.Name; Start = (Get-Time $_.Start); End = $(if ($_.End) { Get-Time $_.End } else { $null }) }
    })
  }
  return $ctx
}

function Build-Report($ctx) {
  $info = $ctx.Info; $bat = $ctx.Battery; $disk = $ctx.Disk; $spd = $ctx.Speed
  $prof = Find-Profile $info
  $auditProfile = Find-Profile $info -IdentityOnly
  $audit = @(Get-HardwareAudit $ctx $auditProfile)
  $audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Rep 'hardware-inventory.json') -Encoding UTF8
  $script:Verdicts.Clear()

  $sens = Read-Csv (Join-Path $script:Rep 'sensors.csv')
  foreach ($r in $sens) { $r | Add-Member -NotePropertyName T -NotePropertyValue (Get-Time $r.time) -Force }
  $gpu = Read-Csv (Join-Path $script:Rep 'gpu.csv') @('time', 'temp', 'power', 'clock', 'memclock', 'util', 'pstate', 'reasons', 'limit')
  # Отбрасываем заведомый мусор: первое показание nvidia-smi бывает в сотни ватт,
  # а спящая в гибридном режиме видеокарта отдаёт 0 °C.
  $pMax = 1000; if ($info.Nv.PowerMaxW) { $pMax = 1.5 * $info.Nv.PowerMaxW }
  foreach ($r in $gpu) {
    $r | Add-Member -NotePropertyName T -NotePropertyValue (Get-Time $r.time) -Force
    $t = ParseD $r.temp; if ($null -ne $t -and $t -le 0) { $r.temp = '' }
    $p = ParseD $r.power; if ($null -ne $p -and $p -gt $pMax) { $r.power = '' }
  }
  $ph = @{}; foreach ($p in $ctx.Phases) { $ph[$p.Name] = $p }

  # --- ориентиры и вердикты ---
  if ($info.AcOnline -eq $false) { V 'bad' 'Питание' 'Тест шёл от батареи — цифры производительности недостоверны. Подключите зарядку и повторите.' }

  if ($bat.HealthPct) {
    $lvl = if ($bat.HealthPct -ge 85) { 'ok' } elseif ($bat.HealthPct -ge 75) { 'warn' } else { 'bad' }
    V $lvl 'Батарея' ('Ёмкость {0}% от заводской ({1} из {2} мВт·ч), циклов: {3}' -f (F $bat.HealthPct), (F $bat.FullMWh '0'), (F $bat.DesignMWh '0'), $bat.Cycles)
  } else { V 'info' 'Батарея' 'Данные ёмкости недоступны; износ не оценён.' }

  $ramN = @($info.RamModules).Count
  if ($ramN -eq 1) { V 'warn' 'Память' 'Обнаружена одна планка. Для пропускной способности обычно предпочтительны две; число каналов этим набором не измеряется.' }
  elseif ($ramN -ge 2) { V 'ok' 'Память' ("Планок: $ramN, {0} ГБ, {1}" -f $info.RamTotalGB, (($info.RamModules | ForEach-Object { $_.Type } | Select-Object -Unique) -join '/')) }
  else { V 'info' 'Память' 'SMBIOS не предоставил данные о планках; комплектацию не удалось проверить.' }
  foreach ($a in $audit | Where-Object { $_.Status -eq 'расхождение' -or $_.Status -like 'проверить:*' }) {
    V 'warn' ("Комплектация: $($a.Component)") $a.Actual ("Ожидается: $($a.Expected). $($a.Reason)")
  }

  $probs = @($info.ProblemDevices | Where-Object { $_.Code -ne 22 })
  if ($probs.Count) { V 'warn' 'Устройства' ('С ошибками: ' + (($probs | ForEach-Object { "$($_.Name) (код $($_.Code))" }) -join '; ')) }
  else { V 'ok' 'Устройства' 'Ошибок в диспетчере устройств нет' }

  foreach ($dk in @($disk.Disks | Where-Object { $_.Bus -ne 'USB' })) {
    $lvl = if ($dk.Health -eq 'Healthy') { 'ok' } else { 'info' }; $notes = @()
    if (-not $dk.Health) { $notes += 'SMART/статус здоровья недоступен, исправность не подтверждена' }
    if ($dk.Health -and $dk.Health -ne 'Healthy') { $lvl = 'bad'; $notes += "состояние Windows: $($dk.Health)" }
    if ($dk.ReadErrUncorrected -gt 0 -or $dk.WriteErrUncorrected -gt 0) { $lvl = 'bad'; $notes += "неисправленные ошибки: чтение $($dk.ReadErrUncorrected), запись $($dk.WriteErrUncorrected)" }
    if ($null -ne $dk.WearPct -and $dk.WearPct -ge 20 -and $lvl -eq 'ok') { $lvl = 'warn' }
    V $lvl "SSD $($dk.Name)" (('износ {0}%, наработка {1} ч, t° сейчас {2} °C' -f (F $dk.WearPct '0'), (F $dk.PowerOnHours '0'), (F $dk.TempC '0')) + $(if ($notes) { '; ' + ($notes -join '; ') } else { '' }))
  }

  # процессор
  $cpuPh = $ph['cpu']
  $cbMulti = if ($ctx.CbMulti) { $ctx.CbMulti.Score } else { $null }
  $cpuLoad  = Get-Loaded (Get-Slice $sens $cpuPh 0 1) 'cpu_util_pct' 80
  $cpuFirst = Get-Stat (Get-Part $cpuLoad 0 0.1) 'cpu_mhz'
  $cpuLast  = Get-Stat (Get-Part $cpuLoad 0.5 1) 'cpu_mhz'
  $cpuTz    = Get-Stat $cpuLoad 'tz_max_c'
  if ($null -ne $cbMulti) {
    $lvl = 'info'; $ref = ''
    if ($prof) {
      # обзоры меряют один прогон «на холодную» — сравниваем с ним наш первый проход
      $first = if ($ctx.CbMulti.Passes.Count) { $ctx.CbMulti.Passes[0] } else { $cbMulti }
      $pct = 100 * $first / $prof.CbRef
      $ref = '; первый проход — {0}% от ориентира {1} ({2})' -f (F $pct '0'), (F $prof.CbRef '0'), $prof.CbRefText
      if ($prof.CbRefApproximate) {
        $ref += '; справочное сравнение: лимит мощности CPU этого экземпляра не измерен, по этому отличию исправность не оцениваем'
      } else {
        $lvl = if ($pct -ge 90) { 'ok' } elseif ($pct -ge 80) { 'warn' } else { 'bad' }
      }
    }
    if ($ctx.CbMulti.Incomplete) {
      V 'warn' 'Процессор: Cinebench R23 Multi' (("{0} баллов — среднее сохранённых проходов" -f (F $cbMulti '0')) + (Format-Passes $ctx.CbMulti) + '; итоговая строка CB отсутствует, тест прерван. Это частичный результат, для окончательного балла повторите CPU-тест.') 'Восстановлено из последней строки Values в cinebench-cpu.txt; официальный итог CB не получен, оценка по референсу не выставляется.'
    } else {
      V $lvl 'Процессор: Cinebench R23 Multi' (("{0} баллов в среднем за тест" -f (F $cbMulti '0')) + (Format-Passes $ctx.CbMulti) + $ref)
    }
  } else { V 'warn' 'Процессор: Cinebench R23 Multi' 'Результат не получен — см. cinebench-cpu.txt' }
  if ($cpuFirst -and $cpuLast) {
    $drop = 100 * ($cpuFirst.Avg - $cpuLast.Avg) / [math]::Max($cpuFirst.Avg, 1)
    $lvl = if ($drop -lt 20) { 'ok' } elseif ($drop -lt 35) { 'warn' } else { 'bad' }
    V $lvl 'Процессор: частота под нагрузкой' ('в начале {0} МГц → во второй половине {1} МГц (просадка {2}%)' -f (F $cpuFirst.Avg '0'), (F $cpuLast.Avg '0'), (F $drop '0'))
  }
  if ($cpuTz) {
    V 'info' 'Процессор: температура (ACPI-зона)' ('средняя {0} °C, максимум {1} °C' -f (F $cpuTz.Avg), (F $cpuTz.Max))
  }

  # видеокарта
  $gPh = $ph['gpu']
  $gAll = Get-Loaded (Get-Slice $gpu $gPh 0 1) 'util' 90
  $gSteady = Get-Part $gAll 0.3 1
  $gT = Get-Stat $gAll 'temp'; $gP = Get-Stat $gSteady 'power'; $gC = Get-Stat $gSteady 'clock'
  if ($gT) {
    $lvl = if ($gT.Max -lt 84) { 'ok' } elseif ($gT.Max -lt 88) { 'warn' } else { 'bad' }
    V $lvl 'Видеокарта: температура' ('средняя {0} °C, максимум {1} °C; отсчётов под нагрузкой {2}' -f (F $gT.Avg), (F $gT.Max), $gT.N) '' $prof.GpuTempRefText $prof.GpuTempRefUrl
    $reasonRows = @($gAll | Where-Object { "$($_.reasons)".Trim() -match '^0x[0-9a-fA-F]+$' })
    $thermal = Get-Share $reasonRows { ((Get-Reasons $_) -band 0x60) -ne 0 }
    $hw = Get-Share $reasonRows { ((Get-Reasons $_) -band 0x88) -ne 0 }
    if ($reasonRows.Count) {
      $lvl = if ($thermal -lt 2) { 'ok' } elseif ($thermal -lt 15) { 'warn' } else { 'bad' }
      V $lvl 'Видеокарта: тепловой троттлинг' ('{0}% загруженных отсчётов с доступными флагами ({1} из {2}); покрытие {3} из {4}' -f (F $thermal '0'), @($reasonRows | Where-Object { ((Get-Reasons $_) -band 0x60) -ne 0 }).Count, $reasonRows.Count, $reasonRows.Count, @($gAll).Count) '' '' 'https://docs.nvidia.com/deploy/nvml-api/latest/api/group__nvmlClocksEventReasons.html'
    } else { V 'info' 'Видеокарта: тепловой троттлинг' 'Флаги причин ограничения nvidia-smi недоступны; отсутствие троттлинга не подтверждено.' }
    if ($hw -ge 1) { V 'warn' 'Видеокарта: аппаратное замедление' ('{0}% времени (бывает при слабом/неоригинальном блоке питания или перегреве)' -f (F $hw '0')) }
    $lim = $info.Nv.PowerLimitW
    $txt = 'средняя {0} Вт, частота {1} МГц' -f (F $gP.Avg '0'), (F $gC.Avg '0')
    if ($lim) { $txt += ' (лимит {0} Вт, максимум с Dynamic Boost {1} Вт)' -f (F $lim '0'), (F $info.Nv.PowerMaxW '0') }
    # Лимит зависит от режима (у GP76: 150 Вт в Extreme, 125 Вт в остальных), поэтому
    # вердикт — от фактического лимита драйвера во время теста, а обзор — для справки.
    $lvl = 'info'
    $limRun = (Get-Stat $gSteady 'limit')
    if ($gP -and $limRun -and $limRun.Max -gt 0) {
      $pct = 100 * $gP.Avg / $limRun.Max
      $lvl = if ($pct -ge 85) { 'ok' } elseif ($pct -ge 70) { 'warn' } else { 'bad' }
      $txt += '; {0}% от лимита во время теста ({1} Вт)' -f (F $pct '0'), (F $limRun.Max '0')
    }
    if ($prof) { $txt += '; ориентир: {0} Вт — {1}' -f $prof.GpuWRef, $prof.GpuWRefText }
    if ($prof.GpuPowerInfoOnly) {
      $lvl = 'info'
      $txt += '; потребление само по себе не подтверждает исправность или неисправность: учитывайте режим, частоты и троттлинг'
    }
    V $lvl 'Видеокарта: мощность под нагрузкой' $txt
  } else { V 'info' 'Видеокарта: температура' 'Нет пригодных показаний температуры при загрузке GPU ≥90%; оценка не выполнена.' }

  # зарядка под совместной нагрузкой
  $cPh = $ph['combo']
  $cs = Get-Slice $sens $cPh 0 1
  if ($cs.Count) {
    $dis = Get-Share $cs { $_.ac_online -eq '1' -and $_.batt_discharging -eq '1' -and (ParseD $_.batt_discharge_mw) -gt 3000 }
    if ($dis -ge 10) { V 'warn' 'Зарядка' ('При подключённом блоке питания батарея разряжалась более чем на 3 Вт в {0}% отсчётов совместной нагрузки; проверьте адаптер и режим зарядки' -f (F $dis '0')) }
    else { V 'info' 'Зарядка' ('Разряд более 3 Вт от сети: {0}% отсчётов; признак устойчивого разряда не выявлен' -f (F $dis '0')) }
  }
  $comboCpu = Get-Stat (Get-Part (Get-Loaded (Get-Slice $sens $cPh 0 1) 'cpu_util_pct' 80) 0.3 1) 'cpu_mhz'
  $comboTz  = Get-Stat (Get-Slice $sens $cPh 0 1) 'tz_max_c'
  $comboG   = Get-Part (Get-Loaded (Get-Slice $gpu $cPh 0 1) 'util' 90) 0.3 1
  $comboGT  = Get-Stat (Get-Slice $gpu $cPh 0 1) 'temp'
  $comboGP  = Get-Stat $comboG 'power'

  if ($info.VirtFirmware -or $info.Hypervisor) { V 'info' 'Виртуализация' 'включена' } else { V 'info' 'Виртуализация' 'выключена в BIOS — включается там же (Intel VT-x / VT-d)' }

  # --- сводка для телефона ---
  $recoveryNotes = ''
  $notesPath = Join-Path $script:Rep 'RECOVERY-NOTES.txt'
  if (Test-Path -LiteralPath $notesPath) { $recoveryNotes = Get-Content -LiteralPath $notesPath -Raw -Encoding UTF8 }
  $sum = New-Object System.Collections.ArrayList
  [void]$sum.Add("laptop-checkup $($ctx.Started.ToString('yyyy-MM-dd HH:mm')) режим $($ctx.Mode)$(if ($ctx.Label) { ", метка: $($ctx.Label)" })")
  [void]$sum.Add("$($info.Manufacturer) $($info.Model) | S/N $($info.Serial) | BIOS $($info.BiosVersion) $($info.BiosDate)")
  [void]$sum.Add("CPU $($info.Cpu) | RAM $($info.RamTotalGB) ГБ: " + (($info.RamModules | ForEach-Object { "$($_.Slot) $($_.SizeGB)ГБ $($_.Type)-$($_.RunMTs)" }) -join ', '))
  [void]$sum.Add("GPU $($info.Nv.Name) | лимит $(F $info.Nv.PowerLimitW '0') Вт, макс $(F $info.Nv.PowerMaxW '0') Вт | режим: $($info.GpuMode) | питание: $(if ($info.AcOnline) { 'от сети' } else { 'БАТАРЕЯ' })")
  [void]$sum.Add("Экран: $($info.Panel) | сейчас $(@($info.Gpus | Where-Object { $_.Hz } | ForEach-Object { "$($_.Res)@$($_.Hz)" }) -join ', ') | макс. $(F $info.PanelMaxHz '0') Гц")
  [void]$sum.Add('')
  if ($recoveryNotes) { [void]$sum.Add($recoveryNotes); [void]$sum.Add('') }
  foreach ($v in $script:Verdicts) {
    [void]$sum.Add(('[{0}] {1}: {2}' -f $v.Level.ToUpper(), $v.What, $v.Text))
    [void]$sum.Add("  Основание: $($v.Basis)$(if ($v.SourceUrl) { ' ' + $v.SourceUrl })")
  }
  [void]$sum.Add(''); [void]$sum.Add('Сверка комплектующих:')
  foreach ($a in $audit) { [void]$sum.Add("[$($a.Status)] $($a.Component): $($a.Actual) | ожидается: $($a.Expected) | $($a.Reason)") }
  [void]$sum.Add('')
  [void]$sum.Add(('Простой: CPU {0} МГц, ACPI {1} °C | GPU {2} °C, {3} Вт' -f (F (Get-Stat (Get-Slice $sens $ph['idle']) 'cpu_mhz').Avg '0'), (F (Get-Stat (Get-Slice $sens $ph['idle']) 'tz_max_c').Avg), (F (Get-Stat (Get-Slice $gpu $ph['idle']) 'temp').Avg '0'), (F (Get-Stat (Get-Slice $gpu $ph['idle']) 'power').Avg '0')))
  [void]$sum.Add(('Совместная нагрузка: CPU {0} МГц, ACPI макс {1} °C | GPU макс {2} °C, {3} Вт' -f (F $comboCpu.Avg '0'), (F $comboTz.Max), (F $comboGT.Max '0'), (F $comboGP.Avg '0')))
  if ($ctx.CbCombo) { [void]$sum.Add("Cinebench R23 Multi при нагруженной видеокарте: $(F $ctx.CbCombo.Score '0')$(Format-Passes $ctx.CbCombo)$(if ($ctx.CbCombo.Incomplete) { ' — частичный результат: итог CB отсутствует' })") }
  if ($ctx.CbSingle) { [void]$sum.Add("Cinebench R23 Single: $(F $ctx.CbSingle.Score '0')$(if ($ctx.CbSingle.Incomplete) { ' — частичный результат: итог CB отсутствует' })") }
  if ($spd.Count) { [void]$sum.Add(('SSD: чтение {0} МБ/с, запись {1} МБ/с, 4K случайное чтение {2} IOPS' -f (F $spd.SeqReadMBs '0'), (F $spd.SeqWriteMBs '0'), (F $spd.Rand4kIops '0'))) }
  [void]$sum.Add("Батарея: $($bat.Id), $(F $bat.FullMWh '0')/$(F $bat.DesignMWh '0') мВт·ч, циклов $($bat.Cycles)")
  [void]$sum.Add("Сеть: $($info.Net -join '; ')")
  [void]$sum.Add("Виртуализация: прошивка $($info.VirtFirmware), гипервизор $($info.Hypervisor) | Secure Boot: $($info.SecureBoot) | TPM: $($info.Tpm)")
  [void]$sum.Add("Windows: $($info.Os), установлена $($info.OsInstalled) | $($info.PowerScheme)")
  if ($prof) {
    [void]$sum.Add('')
    [void]$sum.Add("Ориентиры из обзоров и спецификаций ($($prof.Name)):")
    foreach ($r in $prof.Refs) { [void]$sum.Add("  $($r.What): $($r.Value) [$($r.Src)] $($r.Url) — $($r.Note)") }
  }
  $sum | Set-Content -LiteralPath (Join-Path $script:Rep 'summary.txt') -Encoding UTF8

  # --- HTML ---
  $color = @{ ok = '#1a7f37'; warn = '#b58100'; bad = '#cf222e'; info = '#57606a' }
  $label = @{ ok = 'норма'; warn = 'внимание'; bad = 'плохо'; info = 'инфо' }
  $rowsV = ($script:Verdicts | ForEach-Object { "<tr><td><span class='tag' style='background:$($color[$_.Level])'>$($label[$_.Level])</span></td><td>$(HtmlEnc $_.What)</td><td>$(HtmlEnc $_.Text)</td><td>$(HtmlEnc $_.Basis)$(if ($_.SourceUrl) { " <a href='$(HtmlEnc $_.SourceUrl)'>Источник</a>" })</td></tr>" }) -join "`n"
  $auditRows = ($audit | ForEach-Object { "<tr><td>$(HtmlEnc $_.Component)</td><td>$(HtmlEnc $_.Expected)</td><td>$(HtmlEnc $_.Actual)</td><td>$(HtmlEnc $_.Status)</td><td>$(HtmlEnc $_.Reason)</td></tr>" }) -join "`n"
  $ram = ($info.RamModules | ForEach-Object { "<tr><td>$(HtmlEnc $_.Slot) / $(HtmlEnc $_.Bank)</td><td>$($_.SizeGB) ГБ</td><td>$(HtmlEnc $_.Type)</td><td>$($_.SpeedMTs) / $($_.RunMTs) МТ/с</td><td>$(HtmlEnc $_.Vendor) $(HtmlEnc $_.Part)</td></tr>" }) -join "`n"
  $phaseRows = ($ctx.Phases | Where-Object { $_.End } | ForEach-Object {
    $s = Get-Slice $sens $_ 0 1; $g = Get-Slice $gpu $_ 0 1
    $c = Get-Stat $s 'cpu_mhz'; $z = Get-Stat $s 'tz_max_c'; $gt = Get-Stat $g 'temp'; $gp = Get-Stat $g 'power'; $gc = Get-Stat $g 'clock'
    "<tr><td>$(HtmlEnc $_.Name)</td><td>$(F ($_.End - $_.Start).TotalSeconds '0') с</td><td>$(F $c.Avg '0') / $(F $c.Min '0')</td><td>$(F $z.Avg) / $(F $z.Max)</td><td>$(F $gt.Avg '0') / $(F $gt.Max '0')</td><td>$(F $gp.Avg '0') / $(F $gp.Max '0')</td><td>$(F $gc.Avg '0')</td></tr>"
  }) -join "`n"
  $files = (Get-ChildItem -LiteralPath $script:Rep -File | ForEach-Object { "<li><a href='$($_.Name)'>$(HtmlEnc $_.Name)</a></li>" }) -join ''
  $refs = ''
  if ($prof) {
    $refRows = ($prof.Refs | ForEach-Object { "<tr><td>$(HtmlEnc $_.What)</td><td>$(HtmlEnc $_.Value)</td><td><a href='$(HtmlEnc $_.Url)'>$(HtmlEnc $_.Src)</a></td><td class='mut'>$(HtmlEnc $_.Note)</td></tr>" }) -join "`n"
    $refs = "<h2>Ориентиры из обзоров и спецификаций — $(HtmlEnc $prof.Name)</h2><div class='wrap'><table><tr><th>Что</th><th>Значение</th><th>Источник</th><th>Примечание</th></tr>$refRows</table></div>" +
      "<p class='mut'>Обзоры обычно дают один прогон Cinebench «на холодную», а наш тест идёт 10 минут: с обзором сравнивайте первый проход. Средняя за 10 минут ниже — это нормально, если просадка небольшая.</p>"
  }

  $html = @"
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Проверка ноутбука</title>
<style>
:root{--bg:#fff;--fg:#1f2328;--mut:#57606a;--line:#d0d7de;--card:#f6f8fa}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8d96a0;--line:#30363d;--card:#161b22}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,Segoe UI,sans-serif;margin:0;padding:16px;max-width:1000px}
h1{font-size:22px;margin:0 0 4px} h2{font-size:17px;margin:24px 0 8px} .mut{color:var(--mut)}
table{border-collapse:collapse;width:100%;margin:6px 0} td,th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
th{color:var(--mut);font-weight:600} .tag{color:#fff;border-radius:10px;padding:1px 8px;font-size:12px;white-space:nowrap}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 14px} .wrap{overflow-x:auto}
pre{white-space:pre-wrap;font-size:13px}
</style></head><body>
<h1>$(HtmlEnc "$($info.Manufacturer) $($info.Model)")</h1>
<div class="mut">S/N $(HtmlEnc $info.Serial) · BIOS $(HtmlEnc $info.BiosVersion) ($(HtmlEnc $info.BiosDate)) · $(HtmlEnc $ctx.Started.ToString('yyyy-MM-dd HH:mm')) · режим $($ctx.Mode)$(if ($ctx.Label) { ' · ' + (HtmlEnc $ctx.Label) })</div>
$(if ($recoveryNotes) { "<h2>Примечания к восстановленному отчёту</h2><div class='card'><pre>$(HtmlEnc $recoveryNotes)</pre></div>" })
<h2>Итог</h2><div class="wrap"><table><tr><th>Оценка</th><th>Что</th><th>Измерено</th><th>Референс и основание оценки</th></tr>$rowsV</table></div>
<h2>Сверка комплектующих</h2>
<p class="mut">Сравнение с заявленной конфигурацией и опубликованными возможностями платформы. Без полного SKU и исходной ведомости нельзя доказать заводское происхождение RAM, SSD и панели. «Не сверено» означает отсутствие исходных данных, а не подтверждение комплектации.</p>
<div class="wrap"><table><tr><th>Компонент</th><th>Ожидается</th><th>Установлено / измерено</th><th>Результат</th><th>Основание и ограничения</th></tr>$auditRows</table></div>
<h2>Конфигурация</h2><div class="card">
Процессор: $(HtmlEnc $info.Cpu) ($($info.CpuCores) ядер / $($info.CpuThreads) потоков)<br>
Видеокарта: $(HtmlEnc $info.Nv.Name) · лимит $(F $info.Nv.PowerLimitW '0') Вт (макс. $(F $info.Nv.PowerMaxW '0') Вт) · VBIOS $(HtmlEnc $info.Nv.Vbios) · драйвер $(HtmlEnc $info.Nv.Driver) · режим: $(HtmlEnc $info.GpuMode)<br>
Экран: $(HtmlEnc $info.Panel) · максимум $(F $info.PanelMaxHz '0') Гц · сейчас $(HtmlEnc ((@($info.Gpus | Where-Object { $_.Hz } | ForEach-Object { "$($_.Res)@$($_.Hz)" })) -join ', '))<br>
Память: $($info.RamTotalGB) ГБ, слотов $($info.RamSlots)<br>
Сеть: $(HtmlEnc ($info.Net -join '; '))<br>
Bluetooth: $(HtmlEnc ($info.Bluetooth -join '; '))<br>
Windows: $(HtmlEnc $info.Os), установлена $(HtmlEnc $info.OsInstalled) · $(HtmlEnc $info.PowerScheme)<br>
Secure Boot: $(HtmlEnc $info.SecureBoot) · TPM: $(HtmlEnc $info.Tpm)
</div>
<div class="wrap"><table><tr><th>Слот</th><th>Объём</th><th>Тип</th><th>Номинал / работает</th><th>Модуль</th></tr>$ram</table></div>
<h2>Этапы</h2>
<div class="wrap"><table><tr><th>Этап</th><th>Длит.</th><th>CPU МГц сред/мин</th><th>ACPI °C сред/макс</th><th>GPU °C сред/макс</th><th>GPU Вт сред/макс</th><th>GPU МГц</th></tr>$phaseRows</table></div>
<p class="mut">ACPI-зона — датчик прошивки ноутбука; обычно близок к температуре процессора, но не равен ей. Для сравнения «до/после» важно, что датчик один и тот же.</p>
$refs
<h2>Сводка (для отправки)</h2><div class="card"><pre>$(HtmlEnc ($sum -join "`n"))</pre></div>
<h2>Проверить руками</h2><div class="card">Петли и корпус · битые пиксели и засветы · клавиатура и тачпад · порты · звук, микрофон, камера · Wi-Fi/Bluetooth · пароль BIOS · отвязка учётной записи Microsoft</div>
<h2>Файлы</h2><ul>$files</ul>
</body></html>
"@
  $html | Set-Content -LiteralPath (Join-Path $script:Rep 'report.html') -Encoding UTF8
  return $sum
}

function Show-Summary($sum) {
  Write-Host ''
  $sum | ForEach-Object {
    $c = if ($_ -like '`[OK`]*') { 'Green' } elseif ($_ -like '`[WARN`]*') { 'Yellow' } elseif ($_ -like '`[BAD`]*') { 'Red' } else { 'Gray' }
    Write-Host $_ -ForegroundColor $c
  }
  Write-Host ''
}

if ($ReportFrom) {
  $script:Rep = (Resolve-Path -LiteralPath $ReportFrom).Path
  Show-Summary (Build-Report (Import-Ctx $script:Rep))
  Write-Host "Отчёт: $(Join-Path $script:Rep 'report.html')"
  exit
}

# =====================================================================
#   Основной прогон
# =====================================================================
Add-Type -Namespace LC -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
[void][LC.Power]::SetThreadExecutionState([uint32]2147483651)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED

Write-Host ''
Write-Host '  Проверка ноутбука — режим ' -NoNewline; Write-Host $Mode -ForegroundColor Cyan
$total = $D.Idle + $D.Cpu + $D.Gpu + $D.Combo + 2 * $D.Cool + 3 * $D.DiskSec + 120
Write-Host ('  Займёт примерно {0} мин. Перед стартом:' -f [math]::Ceiling($total / 60))
Write-Host '   - подключите зарядку;'
Write-Host '   - закройте программы;'
Write-Host '   - выберите режим производительности (у MSI — Extreme Performance в MSI Center)'
Write-Host '     (у GIGABYTE A16 — «Игры» / Performance в GiMATE)'
Write-Host '     и режим видеокарты — одинаковые для замеров, которые будете сравнивать.'
Write-Host ''
$labelIn = if ($Unattended) { $Label } else { Read-Host '  Метка отчёта (например «до чистки»), Enter — без метки' }

$started = Get-Date
$infoQuick = Get-CimInstance Win32_ComputerSystem
$serialQ = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
$safe = { param($s) ($s -replace '[^\w\-]+', '_').Trim('_') }
$name = '{0}_{1}_{2}' -f $started.ToString('yyyyMMdd-HHmmss'), (& $safe "$($infoQuick.Model)"), (& $safe $serialQ)
if ($labelIn) { $name += '_' + (& $safe $labelIn) }
$script:Rep = Join-Path (Join-Path $Root 'reports') $name
New-Item -ItemType Directory -Path $script:Rep -Force | Out-Null
$script:LogFile = Join-Path $script:Rep 'run.log'
@{ Started = $started.ToString('o', $inv); Label = $labelIn; Mode = $Mode } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Rep 'run.json') -Encoding UTF8

$state = [pscustomobject]@{
  Start        = $started.ToString('o', $inv)
  MaxonExisted = (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Maxon'))
  MaxonDocsExisted = (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MAXON'))
  BatteryTmpExisted = (Test-Path -LiteralPath (Join-Path $env:TEMP 'battery-report.xml'))
  DiskspdFile  = (Join-Path ([IO.Path]::GetTempPath()) 'laptop-checkup-diskspd.dat')
  HkcuSoftware = @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
  SamplerPid   = $null
  GpuLogPid    = $null
  ExtraPaths   = @()
  CleanupDone  = $false
}
$stateFile = Join-Path $script:Rep 'state.json'
Save-State $state $stateFile

$ctx = @{ Started = $started; Label = $labelIn }
try {
  Say "Отчёт: $script:Rep" 'Cyan'
  Say 'Собираю сведения о ноутбуке…'
  $ctx.Info = Get-Info
  $ctx.Info | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Rep 'info.json') -Encoding UTF8
  Say ("  {0} {1}, S/N {2}; {3}; GPU: {4}" -f $ctx.Info.Manufacturer, $ctx.Info.Model, $ctx.Info.Serial, $ctx.Info.Cpu, $ctx.Info.GpuMode)
  if ($ctx.Info.AcOnline -eq $false) {
    Say 'Ноутбук работает от батареи! Подключите зарядку — иначе результаты недостоверны.' 'Red'
    if (-not $Unattended) { Read-Host 'Подключите зарядку и нажмите Enter (или продолжайте как есть)' }
    $ctx.Info.AcOnline = [bool](Get-CimInstance -Namespace root\wmi BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1).PowerOnline
  }

  Say 'Батарея…'
  $ctx.Battery = Get-BatteryInfo $script:Rep
  Say ("  ёмкость {0}% от заводской, циклов {1}" -f (F $ctx.Battery.HealthPct), $ctx.Battery.Cycles)

  Say 'Накопители (SMART)…'
  $ctx.Disk = Get-DiskHealth $script:Rep
  ConvertTo-Json -InputObject @($ctx.Disk.Disks) -Depth 3 | Set-Content -LiteralPath (Join-Path $script:Rep 'disk.json') -Encoding UTF8
  $ctx.Disk.Disks | ForEach-Object { Say ("  {0} [{1}]: {2}, износ {3}%, {4} ч" -f $_.Name, $_.Bus, $_.Health, (F $_.WearPct '0'), (F $_.PowerOnHours '0')) }

  Say 'Скорость SSD (DiskSpd)…'
  $ctx.Speed = Invoke-DiskSpeed $state.DiskspdFile
  Say ("  чтение {0} МБ/с, запись {1} МБ/с, 4K {2} IOPS" -f (F $ctx.Speed.SeqReadMBs '0'), (F $ctx.Speed.SeqWriteMBs '0'), (F $ctx.Speed.Rand4kIops '0'))

  # --- фоновые писатели датчиков ---
  $sp = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'sampler.ps1')`"", '-Out', "`"$(Join-Path $script:Rep 'sensors.csv')`"") -WindowStyle Hidden -PassThru
  $state.SamplerPid = $sp.Id
  if ($ctx.Info.NvSmi) {
    $reasonField = 'clocks_event_reasons.active'
    & nvidia-smi.exe --query-gpu=$reasonField --format=csv,noheader 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $reasonField = 'clocks_throttle_reasons.active' }
    $q = "timestamp,temperature.gpu,power.draw,clocks.gr,clocks.mem,utilization.gpu,pstate,$reasonField,enforced.power.limit"
    $gp = Start-Process nvidia-smi.exe -ArgumentList @("--query-gpu=$q", '--format=csv,noheader,nounits', '-lms', '1000', '-f', "`"$(Join-Path $script:Rep 'gpu.csv')`"") -WindowStyle Hidden -PassThru
    $state.GpuLogPid = $gp.Id
  } else { Say 'nvidia-smi не найден — датчики видеокарты не пишутся' 'Yellow' }
  Save-State $state $stateFile

  Start-Phase 'idle'; Say "Простой $($D.Idle) с (фон для сравнения)…"; Wait-Seconds $D.Idle 'Простой'; Stop-Phase

  Start-Phase 'cpu'; Say "Процессор: Cinebench R23 Multi, не меньше $($D.Cpu) с…" 'Cyan'
  $cbOut = Join-Path $script:Rep 'cinebench-cpu.txt'
  $p = Start-Cinebench 'CpuX' $D.Cpu $cbOut
  Wait-Procs @($p) $D.Cpu 'Cinebench R23 Multi'; Stop-Phase
  $ctx.CbMulti = Get-CinebenchScore $cbOut
  Say ("  результат: {0}{1}" -f (F $ctx.CbMulti.Score '0'), (Format-Passes $ctx.CbMulti)) 'Green'

  if ($WithSingle) {
    Start-Phase 'cpu-single'; Say 'Процессор: Cinebench R23 Single (один проход)…' 'Cyan'
    $cb1 = Join-Path $script:Rep 'cinebench-single.txt'
    $p = Start-Cinebench 'Cpu1' 1 $cb1
    Wait-Procs @($p) 420 'Cinebench R23 Single'; Stop-Phase
    $ctx.CbSingle = Get-CinebenchScore $cb1
    Say ("  результат: {0}" -f (F $ctx.CbSingle.Score '0')) 'Green'
  }

  Start-Phase 'cool1'; Wait-Seconds $D.Cool 'Остывание'; Stop-Phase

  if ($ctx.Info.NvSmi) {
    Start-Phase 'gpu'; Say "Видеокарта: FurMark $($D.Gpu) с…" 'Cyan'
    $p = Start-FurMark $D.Gpu (Join-Path $script:Rep 'furmark-gpu.txt')
    Wait-Procs @($p) $D.Gpu 'FurMark'; Stop-Phase
    Start-Phase 'cool2'; Wait-Seconds $D.Cool 'Остывание'; Stop-Phase
  }

  Start-Phase 'combo'; Say "Совместная нагрузка CPU + GPU $($D.Combo) с…" 'Cyan'
  $p1 = Start-Cinebench 'CpuX' $D.Combo (Join-Path $script:Rep 'cinebench-combo.txt')
  $procs = @($p1)
  if ($ctx.Info.NvSmi) { $procs += Start-FurMark $D.Combo (Join-Path $script:Rep 'furmark-combo.txt') }
  Wait-Procs $procs $D.Combo 'CPU + GPU'; Stop-Phase
  $ctx.CbCombo = Get-CinebenchScore (Join-Path $script:Rep 'cinebench-combo.txt')
}
catch {
  Say "Ошибка: $_" 'Red'
  Say $_.ScriptStackTrace 'DarkGray'
}
finally {
  $script:Phases | Select-Object Name, @{ n = 'Start'; e = { $_.Start.ToString('yyyy-MM-dd HH:mm:ss.fff', $inv) } }, @{ n = 'End'; e = { if ($_.End) { $_.End.ToString('yyyy-MM-dd HH:mm:ss.fff', $inv) } } } |
    Export-Csv -LiteralPath (Join-Path $script:Rep 'phases.csv') -NoTypeInformation -Encoding UTF8
  Say 'Уборка…'
  $state = Invoke-Cleanup $state
  Save-State $state $stateFile
  $state.CleanupLog | ForEach-Object { Say "  $_" 'DarkGray' }
  if (@($state.NewItems).Count -or @($state.NewRegKeys).Count) {
    Say 'Появилось за время теста (не удалялось — могли создать другие программы):' 'Yellow'
    @($state.NewItems) + @($state.NewRegKeys | ForEach-Object { "HKCU\Software\$_" }) | ForEach-Object { Say "  $_" 'Yellow' }
  }
  [void][LC.Power]::SetThreadExecutionState([uint32]2147483648)   # ES_CONTINUOUS — вернуть как было
}

try {
  Say 'Готовлю отчёт…'
  # пустые выводы (FurMark в stdout не пишет) только загромождают папку
  Get-ChildItem -LiteralPath $script:Rep -File | Where-Object { $_.Length -eq 0 } | Remove-Item -Force -ErrorAction SilentlyContinue
  Show-Summary (Build-Report (Import-Ctx $script:Rep))
  Say "Отчёт: $(Join-Path $script:Rep 'report.html')" 'Cyan'
} catch {
  Say "Ошибка при сборке отчёта: $_" 'Red'
  Say $_.ScriptStackTrace 'DarkGray'
}
if (-not $Unattended) { Read-Host 'Enter — закрыть окно' }
