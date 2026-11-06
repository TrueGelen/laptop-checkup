param([switch]$SnapshotOnly, [switch]$Elevated, [switch]$NoPause)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$script:Rep = $null
$script:SmartExe = Join-Path $Root 'tools\smartmontools\smartctl.exe'
$script:Device = ''

function Save-Json($Value, [string]$Path) {
  ConvertTo-Json -InputObject $Value -Depth 24 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Say([string]$Message) {
  $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Message
  Write-Host $line
  if ($script:Rep) { Add-Content -LiteralPath (Join-Path $script:Rep 'run.log') -Value $line -Encoding UTF8 }
}
function Invoke-Captured([string]$Exe, [string[]]$ArgumentList, [string]$Stem, [int]$Timeout = 30) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  # All arguments are individual Windows paths, switches or numeric values.
  if (@($ArgumentList | Where-Object { $_.Contains('"') -or $_.EndsWith('\') }).Count) { throw 'Unsupported process argument' }
  $psi.Arguments = ($ArgumentList | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($Timeout * 1000)
    if ($timedOut) { $p.Kill(); [void]$p.WaitForExit(5000) }
    $out = $stdout.GetAwaiter().GetResult()
    $err = $stderr.GetAwaiter().GetResult()
    $result = [pscustomobject]@{ ExitCode = $p.ExitCode; TimedOut = $timedOut; Seconds = $watch.Elapsed.TotalSeconds; Stdout = $out; Stderr = $err }
    $out | Set-Content -LiteralPath (Join-Path $script:Rep ($Stem + '.stdout.txt')) -Encoding UTF8
    $err | Set-Content -LiteralPath (Join-Path $script:Rep ($Stem + '.stderr.txt')) -Encoding UTF8
    Save-Json ([ordered]@{ Exe = $Exe; Arguments = $ArgumentList; ExitCode = $result.ExitCode; TimedOut = $timedOut; Seconds = $result.Seconds }) (Join-Path $script:Rep ($Stem + '.process.json'))
    return $result
  } finally { $p.Dispose() }
}
function Get-Smart([string]$Stem, [string[]]$Options = @('-x')) {
  $r = Invoke-Captured $script:SmartExe (@('--json=o') + $Options + @($script:Device)) $Stem 20
  if ($r.TimedOut) { throw "smartctl: timeout ($Stem)" }
  try { $data = ConvertFrom-Json -InputObject $r.Stdout } catch { throw "smartctl returned no valid JSON ($Stem); see stderr/stdout" }
  Save-Json $data (Join-Path $script:Rep ($Stem + '.json'))
  if ($data.smartctl.output) { $data.smartctl.output | Set-Content -LiteralPath (Join-Path $script:Rep ($Stem + '.txt')) -Encoding UTF8 }
  $details = (@($data.smartctl.messages | ForEach-Object { $_.string }) -join '; ')
  if (($r.ExitCode -band 1) -ne 0) { throw "smartctl command-line error ($Stem), exit $($r.ExitCode): $details" }
  if (($r.ExitCode -band 2) -ne 0) { throw "smartctl could not open/identify the disk ($Stem), exit $($r.ExitCode): $details" }
  # Higher exit bits describe SMART/log findings; preserve them for analysis.
  return $data
}
function Get-Counters($Smart) {
  $h = $Smart.nvme_smart_health_information_log
  if (-not $h) { return $null }
  [pscustomobject]@{
    Serial = $Smart.serial_number; Model = $Smart.model_name
    PowerCycles = $h.power_cycles; UnsafeShutdowns = $h.unsafe_shutdowns
    PowerOnHours = $h.power_on_hours; PercentageUsed = $h.percentage_used
    MediaErrors = $h.media_errors; ErrorLogEntries = $h.num_err_log_entries
    CriticalWarning = $h.critical_warning; TemperatureC = $h.temperature
    DataUnitsRead = $h.data_units_read; DataUnitsWritten = $h.data_units_written
  }
}
function Get-CounterDiff($Before, $After) {
  $a = Get-Counters $Before; $b = Get-Counters $After
  if (-not $a -or -not $b -or -not $a.Serial -or $a.Serial -ne $b.Serial) { return $null }
  $diff = [ordered]@{ Serial = $b.Serial }
  foreach ($name in @('PowerCycles','UnsafeShutdowns','PowerOnHours','MediaErrors','ErrorLogEntries','DataUnitsRead','DataUnitsWritten')) {
    $diff[$name] = if ($null -ne $a.$name -and $null -ne $b.$name) { [decimal]$b.$name - [decimal]$a.$name } else { $null }
  }
  return [pscustomobject]$diff
}
function Get-LatestTest($Smart) {
  @($Smart.nvme_self_test_log.table | Where-Object { $null -ne $_ }) | Select-Object -First 1
}
function Invoke-ShortTest($Before) {
  if ($Before.device.protocol -ne 'NVMe') { return [pscustomobject]@{ Status = 'not_nvme'; Detail = 'Short self-test skipped: this launcher handles NVMe self-test logs only.' } }
  if ($Before.nvme_optional_admin_commands.self_test -ne $true) {
    return [pscustomobject]@{ Status = 'unsupported'; Detail = 'SSD does not advertise Device Self-test support. This is not a failure.' }
  }
  $op = $Before.nvme_self_test_log.current_self_test_operation
  if ($null -eq $op.value) { return [pscustomobject]@{ Status = 'unavailable'; Detail = 'Cannot read current self-test state; no new test started.' } }
  if ($op.value -ne 0) { return [pscustomobject]@{ Status = 'already_running'; Detail = $op.string } }
  Say 'Запускаю короткий встроенный тест SSD; ожидание не более 3 минут...'
  $start = Get-Smart 'selftest-start' @('-t', 'short')
  if (($start.smartctl.exit_status -band 7) -ne 0) { return [pscustomobject]@{ Status = 'start_failed'; Detail = 'Controller/driver rejected the test; see selftest-start files.' } }
  $oldLog = ConvertTo-Json -InputObject $Before.nvme_self_test_log.table -Compress -Depth 12
  $seenRunning = $false
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $pollNumber = 0
  while ($watch.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep -Seconds 5
    $pollNumber++
    $poll = Get-Smart ('selftest-poll-{0:00}' -f $pollNumber) @('-l', 'selftest')
    $state = $poll.nvme_self_test_log.current_self_test_operation
    if ($null -eq $state.value) { return [pscustomobject]@{ Status = 'unavailable'; Detail = 'Self-test status cannot be read; no pass claimed.' } }
    if ($state.value -ne 0) {
      $seenRunning = $true
      Say ("Тест SSD: $($poll.nvme_self_test_log.current_self_test_completion_percent)%")
      continue
    }
    $entry = Get-LatestTest $poll
    $newLog = ConvertTo-Json -InputObject $poll.nvme_self_test_log.table -Compress -Depth 12
    if (-not $entry -or (-not $seenRunning -and $newLog -eq $oldLog)) {
      return [pscustomobject]@{ Status = 'unconfirmed'; Detail = 'No provably new result in the test log; no pass claimed.' }
    }
    if ($entry.self_test_code.value -ne 1) { return [pscustomobject]@{ Status = 'unconfirmed'; Detail = 'Newest log entry is not a short test.'; Entry = $entry } }
    $status = if ($entry.self_test_result.value -eq 0) { 'passed' } else { 'not_passed' }
    return [pscustomobject]@{ Status = $status; Detail = $entry.self_test_result.string; Entry = $entry }
  }
  return [pscustomobject]@{ Status = 'still_running'; Detail = 'Waiting stopped after 3 minutes. SSD self-test was not aborted and may still be running. Keep laptop powered for several more minutes.' }
}
function Save-StorageEvents {
  $cutoff = (Get-Date).AddDays(-14)
  $queryErrors = @()
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $cutoff; Id = @(7,11,15,17,18,19,41,51,55,98,129,140,153,157,6008) } -MaxEvents 1500 -ErrorAction SilentlyContinue -ErrorVariable queryErrors |
    Where-Object { $_.ProviderName -match 'disk|stor|nvme|ntfs|whea|Kernel-Power|EventLog' } |
    Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message)
  Save-Json $events (Join-Path $script:Rep 'windows-events.json')
  $events | Format-List | Out-String -Width 240 | Set-Content -LiteralPath (Join-Path $script:Rep 'windows-events.txt') -Encoding UTF8
  Save-Json ([ordered]@{ LookbackDays = 14; QueryLimit = 1500; Returned = $events.Count; QueryMessages = @($queryErrors | ForEach-Object { $_.ToString() }); Note = 'System-wide events, not all necessarily related to this SSD. Empty query is not proof of health.' }) (Join-Path $script:Rep 'windows-events-status.json')
}

$exitCode = 0
$powerGuard = $false
$result = [ordered]@{ Version = 2; Started = (Get-Date).ToString('o'); SnapshotOnly = [bool]$SnapshotOnly; Status = 'running'; Failures = @() }
try {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Elevated) { throw 'Administrator rights were not granted.' }
    $launchArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Elevated'
    if ($SnapshotOnly) { $launchArgs += ' -SnapshotOnly' }
    if ($NoPause) { $launchArgs += ' -NoPause' }
    try { $child = Start-Process powershell.exe -Verb RunAs -ArgumentList $launchArgs -PassThru -Wait; exit $child.ExitCode }
    catch { throw 'Для чтения SSD нужны права администратора. Запустите ещё раз и подтвердите запрос Windows.' }
  }
  $expectedHash = 'B5DB94E5082C042BE44994B7A4FA8F7B5C8E713B2AB1C9A560D8F7A7995EA27D'
  if ((Get-FileHash -LiteralPath $script:SmartExe -Algorithm SHA256).Hash -ne $expectedHash) { throw 'smartctl.exe missing or checksum mismatch.' }
  $systemLetter = $env:SystemDrive.TrimEnd(':')
  $partition = Get-Partition -DriveLetter $systemLetter
  $disk = Get-Disk -Number $partition.DiskNumber
  if ($disk.BusType -eq 'USB') { throw 'Windows is on a USB disk; cannot automatically select an internal SSD.' }
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $mode = if ($SnapshotOnly) { 'snapshot' } else { 'quick' }
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $script:Rep = Join-Path $Root ("ssd-reports\${stamp}_$mode")
  [void](New-Item -ItemType Directory -Path $script:Rep -Force)
  $script:Device = '/dev/pd' + $disk.Number
  $result.Computer = [ordered]@{ Manufacturer = $cs.Manufacturer; Model = $cs.Model; LastBoot = $os.LastBootUpTime.ToString('o') }
  $result.Disk = [ordered]@{ SystemDrive = $env:SystemDrive; Number = $disk.Number; Name = $disk.FriendlyName; Bus = "$($disk.BusType)"; SizeBytes = $disk.Size; Device = $script:Device }
  Save-Json $result (Join-Path $script:Rep 'result.json')
  Say "Проверяется системный диск $env:SystemDrive — $($disk.FriendlyName), $([math]::Round($disk.Size / 1GB)) ГиБ."
  Say 'Результаты пишутся на флешку. Не закрывайте окно до окончания.'
  Add-Type -Namespace SsdQuick -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
  [void][SsdQuick.Power]::SetThreadExecutionState([uint32]2147483649)
  $powerGuard = $true
  $before = Get-Smart 'smart-before'
  if (-not $before.serial_number -or -not $before.model_name) { throw 'Cannot identify SSD from SMART; no test started.' }
  $result.SsdSerial = $before.serial_number
  $result.SsdModel = $before.model_name
  $result.CountersBefore = Get-Counters $before
  Say "SMART: $($before.model_name), S/N $($before.serial_number)"
  # Every previous baseline stays immutable; only compare the same serial number.
  $previous = Get-ChildItem -LiteralPath (Join-Path $Root 'ssd-reports') -Directory | Where-Object { $_.FullName -ne $script:Rep } | Sort-Object Name -Descending
  foreach ($folder in $previous) {
    $path = Join-Path $folder.FullName 'smart-after.json'
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try { $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    $diff = Get-CounterDiff $old $before
    if ($diff) { $result.PreviousRun = $folder.Name; $result.SincePreviousRun = $diff; break }
  }
  if (-not $SnapshotOnly) {
    try { $result.SelfTest = Invoke-ShortTest $before }
    catch { $result.SelfTest = [ordered]@{ Status = 'error'; Detail = $_.ToString() }; $result.Failures += "Self-test: $_"; Say "Встроенный тест: $_" }
    Say "Встроенный тест: $($result.SelfTest.Status)"
    # Never load the disk while a self-test may still be running.
    $readAllowed = $result.SelfTest.Status -in @('unsupported','not_nvme','passed','not_passed')
    if ($readAllowed) {
      Say 'Проверяю чтение: 64 участка по диску и 1 ГиБ последовательно (без записи)...'
      $worker = Join-Path $Root 'ssd-read-probe.ps1'
      $probePath = Join-Path $script:Rep 'read-probe.json'
      $wmi = Get-CimInstance Win32_DiskDrive -Filter "Index = $($disk.Number)"
      $argsRead = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-DiskNumber',"$($disk.Number)",'-ExpectedModel',"$($wmi.Model)",'-ExpectedSize',"$($wmi.Size)",'-OutputPath',$probePath)
      try {
        $proc = Invoke-Captured (Join-Path $PSHOME 'powershell.exe') $argsRead 'read-probe' 60
        if ($proc.TimedOut) { $result.ReadProbe = [ordered]@{ Status = 'timeout'; Detail = 'Read probe stopped after 60 seconds; see partial read-probe.json.' } }
        elseif (Test-Path -LiteralPath $probePath) { $result.ReadProbe = Get-Content -LiteralPath $probePath -Raw -Encoding UTF8 | ConvertFrom-Json }
        else { $result.ReadProbe = [ordered]@{ Status = 'error'; Detail = 'No read probe result. See process stdout/stderr.' } }
      } catch { $result.ReadProbe = [ordered]@{ Status = 'error'; Detail = $_.ToString() } }
    } else { $result.ReadProbe = [ordered]@{ Status = 'skipped'; Detail = 'Self-test state unresolved or already running; no competing read load started.' } }
  }
  try { Save-StorageEvents } catch { $result.Failures += "Windows events: $_" }
  $after = Get-Smart 'smart-after'
  $result.CountersAfter = Get-Counters $after
  $result.DuringRun = Get-CounterDiff $before $after
  $result.Status = 'collected'
} catch {
  $result.Status = 'error'
  $result.Failures += $_.ToString()
  $exitCode = 1
  Say "ОШИБКА: $_"
} finally {
  if ($powerGuard) { [void][SsdQuick.Power]::SetThreadExecutionState([uint32]2147483648) }
  if ($script:Rep) {
    $result.Finished = (Get-Date).ToString('o')
    Save-Json $result (Join-Path $script:Rep 'result.json')
    $lines = @("SSD QUICK CHECK — $($result.Status)", "SSD: $($result.SsdModel); S/N $($result.SsdSerial)", "Начало: $($result.Started)", "Конец: $($result.Finished)", '')
    if ($result.SelfTest) { $lines += "Встроенный тест: $($result.SelfTest.Status) — $($result.SelfTest.Detail)" }
    if ($result.ReadProbe) { $lines += "Проверка чтением: $($result.ReadProbe.Status) — $($result.ReadProbe.Detail)" }
    $lines += @('', 'SMART после проверки:', ($result.CountersAfter | Format-List | Out-String), 'Изменения SMART за этот запуск:', ($result.DuringRun | Format-List | Out-String))
    if ($result.SincePreviousRun) { $lines += @("Изменения с прошлого запуска: $($result.PreviousRun)", ($result.SincePreviousRun | Format-List | Out-String)) }
    $lines += @('Проверка выборочная: исправность всей памяти и отсутствие будущих сбоев не гарантирует.', 'Результат collected означает сбор данных, а не заключение об исправности.', 'Ошибки сбора:', ($result.Failures -join "`r`n"))
    $lines | Set-Content -LiteralPath (Join-Path $script:Rep 'summary.txt') -Encoding UTF8
    if ($result.Status -eq 'error') { Say "Сбор прерван из-за ошибки. Диагностика: $script:Rep" }
    else { Say "Сбор завершён. Результаты: $script:Rep" }
  }
}
if (-not $NoPause) { [void](Read-Host 'Enter — закрыть окно') }
exit $exitCode
