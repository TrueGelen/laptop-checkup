# Run in Windows PowerShell 5.1: powershell -NoProfile -File tests\profiles.ps1
# Load only profile data and function definitions: never start hardware tests/UAC.
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\checkup.ps1') -Raw -Encoding UTF8
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$start = $source.IndexOf('$NbcGp76 =')
$end = $source.IndexOf('# ----------', $start)
Invoke-Expression $source.Substring($start, $end - $start)
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:Verdicts = New-Object System.Collections.ArrayList
$script:checks = 0
function Assert($condition, [string]$message) {
  if (-not $condition) { throw "FAIL: $message" }
  $script:checks++
}
function New-G6xInfo {
  @{
    Manufacturer = 'GIGABYTE'; Model = 'G6X 9KG'; Board = 'G6X'; Sku = '9KG-43KZ894SD'
    Cpu = '13th Gen Intel(R) Core(TM) i7-13650HX'; CpuCores = 14; CpuThreads = 20
    Nv = @{ Name = 'NVIDIA GeForce RTX 4060 Laptop GPU'; VramMiB = 8188; PowerLimitW = 105; PowerMaxW = 105 }
    Gpus = @(@{ Name = 'NVIDIA GeForce RTX 4060 Laptop GPU'; Res = '1920x1200'; Hz = 165 })
    RamModules = @(
      @{ Slot = 'A'; SizeGB = 8; Type = 'DDR5'; SpeedMTs = 4800; RunMTs = 4800 },
      @{ Slot = 'B'; SizeGB = 8; Type = 'DDR5'; SpeedMTs = 4800; RunMTs = 4800 }
    )
    RamTotalGB = 16; RamSlots = 2; PanelMaxHz = 165; AcOnline = $true
  }
}
$info = New-G6xInfo
$profile = Find-Profile $info
Assert ($null -ne $profile) 'G6X 9KG target configuration must have a reference profile'
$ctx = @{
  Info = $info; Started = Get-Date; Mode = 'Quick'; Label = 'fixture'
  Battery = @{ DesignMWh = 73000; FullMWh = 70000; HealthPct = 95.9; Cycles = 10 }
  Disk = @{ Disks = @(@{ Name = 'fixture SSD'; Bus = 'NVMe'; Media = 'SSD'; SizeGB = 953.7; Health = 'Healthy' }) }
  CbMulti = @{ Score = 18000; Passes = @(18879, 17121) }; Speed = @{}; Phases = @()
}
$audit = @(Get-HardwareAudit $ctx $profile)
$text = $audit | ConvertTo-Json -Depth 8
Assert ($text -match 'GDDR6' -and $text -notmatch 'GDDR7|Ryzen|A16|5600') 'G6X audit must not inherit A16 specifications'
Assert (@($audit | Where-Object { $_.Expected -match '^180 ' }).Count -eq 1) 'G6X adapter must be 180 W'
Assert (@($audit | Where-Object { $_.Expected -match '^73000 ' }).Count -eq 1) 'G6X battery must be 73 Wh'
Assert (@($audit | Where-Object { $_.Component -eq 'CPU' -and $_.Status -ne '' }).Count -eq 1) 'CPU audit must be present'
$baselineStatus = ($audit | Where-Object { $_.Component -eq 'RAM: A' }).Status
$info.RamModules[0].RunMTs = 4000
$slow = @(Get-HardwareAudit $ctx $profile)
Assert (($slow | Where-Object { $_.Component -eq 'RAM: A' }).Status -ne $baselineStatus) 'Lower RAM speed must be flagged'
$info.RamModules[0].RunMTs = 4800
$info.CpuThreads = 12
$wrongCpu = @(Get-HardwareAudit $ctx $profile)
Assert (($wrongCpu | Where-Object { $_.Component -eq 'CPU' }).Status -ne ($audit | Where-Object { $_.Component -eq 'CPU' }).Status) 'Incorrect CPU thread count must be flagged'
$info.CpuThreads = 20
$capacityRows = @($audit | Where-Object { $_.Component -match '^(RAM|SSD):' -and $_.Expected -match '^\D+(16|1024) ' })
Assert ($capacityRows.Count -eq 2) 'Target RAM and SSD capacities must appear in the audit'
$info.RamModules = @(@{ Slot = 'A'; SizeGB = 8; Type = 'DDR5'; SpeedMTs = 4800; RunMTs = 4800 })
$ctx.Disk.Disks[0].SizeGB = 476.8
$smaller = @(Get-HardwareAudit $ctx $profile)
foreach ($row in $capacityRows) {
  $actual = $smaller | Where-Object { $_.Component -eq $row.Component }
  Assert ($actual.Status -ne $row.Status) "Reduced target capacity must be flagged: $($row.Expected)"
}
$info.RamModules = (New-G6xInfo).RamModules
$ctx.Disk.Disks[0].SizeGB = 953.7
$info.Nv.Name = 'NVIDIA GeForce RTX 4050 Laptop GPU'; $info.Gpus = @()
Assert ($null -eq (Find-Profile $info)) 'RTX 4050 must not receive RTX 4060 benchmark references'
Assert ($null -ne (Find-Profile $info -IdentityOnly)) 'Identity audit must still detect a GPU mismatch'
$info = New-G6xInfo; $info.Cpu = 'Intel Core i7-13620H'
Assert ($null -eq (Find-Profile $info)) 'Different CPU must not receive G6X references'
$info = New-G6xInfo; $info.Manufacturer = 'Other'
Assert ($null -eq (Find-Profile $info)) 'Different manufacturer must not receive G6X references'
$info = New-G6xInfo; $info.Model = 'G6'; $info.Board = ''; $info.Sku = ''
Assert ($null -eq (Find-Profile $info)) 'G6 must not be confused with G6X'
$info = New-G6xInfo; $info.Model = ''; $info.Board = ''
Assert ($null -ne (Find-Profile $info)) 'Full target SKU must identify the profile'
$info = New-G6xInfo; $info.Nv = $null
Assert ($null -ne (Find-Profile $info)) 'Windows GPU inventory must identify the profile when nvidia-smi is unavailable'
$a16 = @{ Manufacturer = 'GIGABYTE'; Model = 'GAMING A16'; Cpu = 'AMD Ryzen 7 260'; Nv = @{ Name = 'RTX 5050' }; RamModules = @(@{ Slot = 'A'; SizeGB = 16; Type = 'DDR5'; SpeedMTs = 5600; RunMTs = 5600 }) }
$a16Profile = Find-Profile $a16
Assert ($a16Profile.Name -match 'A16') 'A16 profile selection must remain intact'
$a16Audit = @(Get-HardwareAudit @{ Info = $a16; Battery = @{}; Disk = @{} } $a16Profile)
$a16Text = $a16Audit | ConvertTo-Json -Depth 8
Assert ($a16Text -match 'GDDR7' -and $a16Text -match '5600' -and @($a16Audit | Where-Object { $_.Expected -match '^150 ' }).Count -eq 1) 'A16 audit must retain its own specifications'
foreach ($model in @('MSI Katana 17 B13VEK', 'MSI GP76 12UGSO')) {
  Assert ($null -ne (Find-Profile @{ Model = $model })) "Existing profile must still match $model"
}
$ctx.Info = New-G6xInfo
$script:Rep = Join-Path ([IO.Path]::GetTempPath()) ('laptop-checkup-test-' + [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $script:Rep)
try {
  $sampleStart = [datetime]'2026-11-16 12:00:00'
  $ctx.Phases = @(@{ Name = 'gpu'; Start = $sampleStart; End = $sampleStart.AddSeconds(10) })
  @('2026-11-16 12:00:00.000,75,80,2000,8000,99,0,0,105',
    '2026-11-16 12:00:05.000,75,80,2000,8000,99,0,0,105',
    '2026-11-16 12:00:10.000,75,80,2000,8000,99,0,0,105') |
    Set-Content (Join-Path $script:Rep 'gpu.csv') -Encoding ASCII
  Build-Report $ctx | Out-Null
  $html = Get-Content (Join-Path $script:Rep 'report.html') -Raw -Encoding UTF8
  $summary = Get-Content (Join-Path $script:Rep 'summary.txt') -Raw -Encoding UTF8
  Assert ($html -match '18879' -and $summary -match '18879') 'Both report formats must contain the Cinebench reference'
  Assert ($html -match 'G6X--2024/sp' -and $html -match '818851') 'HTML must link to official specifications and original review'
  Assert ($summary -match 'Entertainment' -and $summary -match '105') 'Summary must include reference mode and GPU power'
  Assert ($html -notmatch 'GDDR7|DDR5-5600') 'Generated G6X report must not leak A16 hardware expectations'
  $cpuVerdict = $script:Verdicts | Where-Object { $_.Text -match '18879' }
  Assert ($cpuVerdict.Level -eq 'info') 'Regional review comparison must remain informational'
  $gpuVerdict = $script:Verdicts | Where-Object { $_.Text -match '2000' -and $_.Text -match '105' }
  Assert ($gpuVerdict.Level -eq 'info') 'GPU power below maximum TGP must remain informational'
  Assert ($gpuVerdict.Basis -notmatch 'A16') 'G6X GPU-power basis must not describe only A16'
  $ctx.Info.Model = 'Unknown'; $ctx.Info.Board = ''; $ctx.Info.Sku = ''
  Build-Report $ctx | Out-Null
  $unknown = Get-Content (Join-Path $script:Rep 'report.html') -Raw -Encoding UTF8
  Assert ($unknown -notmatch '818851|GDDR6|GDDR7') 'Unknown laptops must not inherit model-specific expectations'
} finally { Remove-Item -LiteralPath $script:Rep -Recurse -Force }
Write-Host "PASS: $script:checks profile/audit/report checks (PowerShell $($PSVersionTable.PSVersion))"
