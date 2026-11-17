# Pure data checks; no hardware tests, UAC, or external dependencies.
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\checkup.ps1') -Raw -Encoding UTF8
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:checks = 0
function Assert($condition, [string]$message) {
  if (-not $condition) { throw "FAIL: $message" }
  $script:checks++
}
$script:Rep = Join-Path ([IO.Path]::GetTempPath()) ('laptop-checkup-charts-test-' + [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $script:Rep)
try {
  $t = [datetime]'2026-11-17 22:37:00'
  $ctx = @{ Started = $t.AddMinutes(-5); Phases = @(@{Name='gpu';Start=$t;End=$t.AddSeconds(20)})
    CbMulti = @{Passes=@(17000,15000);Incomplete=$true}; CbCombo = @{Passes=@(12000)} }
  $sens = @(
    @{T=$t;cpu_mhz='2700.5';cpu_util_pct='125';tz_max_c='97.9'},
    @{T=$t.AddSeconds(2);cpu_mhz='N/A';cpu_util_pct='';tz_max_c=''},
    @{T=$null;cpu_mhz=2000;cpu_util_pct=100;tz_max_c=98}
  )
  $gpu = @(
    @{T=$t;temp='0';clock=300;power='';util=0;reasons='N/A';limit=105},
    @{T=$t.AddSeconds(1);temp='87.1';clock=1750;power=71;util=100;reasons='0x20';limit=105},
    @{T=$t.AddSeconds(2);temp=87;clock=1700;power=70;util=0;reasons='0x20';limit=105}
  )
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\furmark-render-speed.txt') -Destination (Join-Path $script:Rep 'furmark-gpu.txt')
  $data = Get-ChartData $ctx $sens $gpu | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
  Assert ($data.cpu.Count -eq 2 -and $data.cpu[0].Count -eq 4) 'Keep the CPU tuple shape and omit rows without a timestamp'
  Assert ($data.cpu[0][0] -eq 0 -and $data.cpu[1][0] -eq 2) 'Align sensors to the first recorded sample, not the earlier script launch'
  Assert ($data.cpu[0][1] -eq 2700.5 -and $data.cpu[0][2] -eq 125) 'Preserve fractional clocks and Windows CPU utility above 100 percent'
  Assert ($null -eq $data.cpu[1][1] -and $null -eq $data.cpu[1][3]) 'Missing data must remain null to produce line gaps'
  Assert ($null -eq $data.gpu[0][1] -and $null -eq $data.gpu[0][3]) 'Do not chart sleeping-GPU temperature zero or missing power as valid readings'
  Assert ($null -eq $data.gpu[0][5] -and $data.gpu[1][5] -eq 1 -and $data.gpu[2][5] -eq 0) 'Distinguish unavailable thermal flags, loaded throttling, and idle samples'
  Assert ($data.gpu[1][6] -eq 105) 'Keep the measured power limit as a separate series'
  Assert ($data.duration -eq 20 -and $data.phases[0].start -eq 0) 'Retain the phase extent beyond the last sensor sample'
  Assert ($data.fps[0].points.Count -eq 5 -and $data.fps[0].points[0][0] -eq 1) 'FPS must retain its own rendering-time axis'
  Assert ($data.fps[1].points.Count -eq 0) 'An unmeasured phase must not receive invented FPS'
  Assert ($data.cinebench[0].points[1][1] -eq 15000 -and $data.cinebench[1].points[0][0] -eq 1) 'Preserve each Cinebench pass, including a single-pass series'
  Assert ($data.cinebench[0].label -ne 'CPU') 'Identify incomplete CPU benchmarks'
  Assert ($null -eq (Get-ChartNumber 'NaN') -and $null -eq (Get-ChartNumber 'Infinity')) 'Reject nonfinite values before producing JSON'
  $empty = Get-ChartData @{Started=$t;Phases=@()} @() @() | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  Assert ($empty.cpu.Count -eq 0 -and $empty.gpu.Count -eq 0 -and $empty.duration -gt 0) 'Reports without sensors must still have a valid chart payload'
} finally { Remove-Item -LiteralPath $script:Rep -Recurse -Force }
Write-Host "PASS: $script:checks chart-data checks (PowerShell $($PSVersionTable.PSVersion))"
