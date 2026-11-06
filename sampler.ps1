# Пишет датчики процессора, ACPI-зон и батареи в CSV, пока процесс не остановят.
# Только чтение: CIM-классы производительности и root\wmi BatteryStatus, без драйверов.
param(
  [Parameter(Mandatory = $true)][string]$Out,
  [int]$IntervalMs = 2000
)
$inv = [Globalization.CultureInfo]::InvariantCulture
function N($v) { if ($null -eq $v -or "$v" -eq '') { '' } else { ([double]$v).ToString('0.##', $inv) } }

$w = New-Object IO.StreamWriter($Out, $false, (New-Object Text.UTF8Encoding($false)))
$w.AutoFlush = $true
$w.WriteLine('time,cpu_mhz,cpu_perf_pct,cpu_util_pct,cpu_perf_limit_pct,cpu_limit_flags,tz_max_c,tz_passive_min_pct,tz_reasons,tz_all,ac_online,batt_discharging,batt_charge_mw,batt_discharge_mw,batt_remaining_mwh')

while ($true) {
  $t0 = Get-Date
  $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction SilentlyContinue
  $zones = @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue)
  $b = Get-CimInstance -Namespace root\wmi BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1

  $mhz = $null
  if ($p) { $mhz = [double]$p.ProcessorFrequency * [double]$p.PercentProcessorPerformance / 100 }
  $tzMax = $null; $tzPassive = $null; $tzReasons = 0; $tzAll = @()
  foreach ($z in $zones) {
    $c = [double]$z.Temperature - 273.15
    if ($null -eq $tzMax -or $c -gt $tzMax) { $tzMax = $c }
    if ($null -eq $tzPassive -or $z.PercentPassiveLimit -lt $tzPassive) { $tzPassive = $z.PercentPassiveLimit }
    $tzReasons = $tzReasons -bor [int]$z.ThrottleReasons
    $tzAll += ($z.Name -replace '[,;=]', '_') + '=' + (N $c)
  }

  $row = @(
    $t0.ToString('yyyy-MM-dd HH:mm:ss.fff', $inv),
    (N $mhz),
    (N $p.PercentProcessorPerformance),
    (N $p.PercentProcessorUtility),
    (N $p.PercentPerformanceLimit),
    (N $p.PerformanceLimitFlags),
    (N $tzMax),
    (N $tzPassive),
    (N $tzReasons),
    ($tzAll -join ';'),
    $(if ($b) { [int][bool]$b.PowerOnline } else { '' }),
    $(if ($b) { [int][bool]$b.Discharging } else { '' }),
    (N $b.ChargeRate),
    (N $b.DischargeRate),
    (N $b.RemainingCapacity)
  )
  $w.WriteLine(($row -join ','))

  $left = $IntervalMs - [int]((Get-Date) - $t0).TotalMilliseconds
  if ($left -gt 0) { Start-Sleep -Milliseconds $left }
}
