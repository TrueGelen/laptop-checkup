# Run in Windows PowerShell 5.1; loads definitions without starting hardware tests.
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\checkup.ps1') -Raw -Encoding UTF8
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:checks = 0
function Assert($condition, [string]$message) {
  if (-not $condition) { throw "FAIL: $message" }
  $script:checks++
}
$fixture = Join-Path $PSScriptRoot 'fixtures\furmark-render-speed.txt'
$samples = @(Read-FurMarkFps $fixture)
Assert ($samples.Count -eq 5) 'Parse real FurMark stdout; exclude startup FPS=0 and final summary'
Assert ($samples[0].fps -eq 151 -and $samples[-1].fps -eq 185) 'Use current FPS, not average FPS from the final summary'
Assert ($samples[0].time_sec -eq 1 -and $samples[-1].time_sec -eq 5) 'Preserve elapsed rendering time'
Assert ($samples[0].last_frame_ms -eq 9.632) 'Parse fractional numbers independently of Windows locale'
Assert (@(Read-FurMarkFps (Join-Path $PSScriptRoot 'missing.txt')).Count -eq 0) 'Old reports without FPS must remain readable'
$short = Get-FpsSummary $samples
Assert ($short.Avg -eq 179.4 -and $null -eq $short.DropPct) 'Short output must retain FPS without claiming warm-up loss'
$series = @(1..100 | ForEach-Object {
  [pscustomobject]@{ time_sec = $_; fps = $(if ($_ -le 10) { 200 } else { 100 }); frame = $_ * 100 }
})
$stats = Get-FpsSummary $series
Assert ($stats.First -eq 200 -and $stats.Last -eq 100 -and $stats.DropPct -eq 50) 'Measure rendering loss from first and last time windows'
$series | ForEach-Object { $_.fps = 300 - $_.fps }
$growth = Get-FpsSummary $series
Assert ($growth.DropPct -eq -100) 'An FPS increase must not be reported as a positive loss'
$sparse = @($series[0], $series[-1])
Assert ($null -eq (Get-FpsSummary $sparse).DropPct) 'Sparse output must not produce a warm-up comparison'
$date = [datetime]'2026-11-17 22:35:46'
Assert ((Get-ReportFolderName $date 'G6X9KG' 'SN123' 'after setup') -eq 'after_setup_20261117-223546_G6X9KG_SN123') 'Report label must be the folder prefix'
Assert ((Get-ReportFolderName $date 'G6X9KG' 'SN123' '') -eq '20261117-223546_G6X9KG_SN123') 'Unlabelled reports must start with the timestamp'
Assert ((Get-ReportFolderName $date 'G6X9KG' 'SN123' ' /:*? ') -eq '20261117-223546_G6X9KG_SN123') 'An empty sanitized label must not add a prefix'
Assert ((Get-ReportFolderName $date 'G6X9KG' 'SN123' '../after:setup') -eq 'after_setup_20261117-223546_G6X9KG_SN123') 'Labels must not create subdirectories or invalid Windows filenames'
# Regress the native crash reproduced with --disable-traces + --print-render-speed.
function Start-Process {
  param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
  $script:launchArgs = $ArgumentList
  $script:launchOutput = $RedirectStandardOutput
}
$Tools = 'C:\fixture with spaces\tools'
Start-FurMark 60 'C:\fixture with spaces\reports\furmark-gpu.txt'
Assert ($script:launchArgs -contains '--print-render-speed' -and $script:launchArgs -notcontains '--disable-traces') 'Enable native FPS output without the flag combination that crashes FurMark'
Assert ($script:launchOutput -eq 'C:\fixture with spaces\reports\furmark-gpu.txt') 'Keep the raw FPS log inside the report directory'
Remove-Item Function:\Start-Process
Write-Host "PASS: $script:checks FPS/naming checks (PowerShell $($PSVersionTable.PSVersion))"
