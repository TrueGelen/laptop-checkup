param(
  [Parameter(Mandatory=$true)][int]$DiskNumber,
  [Parameter(Mandatory=$true)][string]$ExpectedModel,
  [Parameter(Mandatory=$true)][long]$ExpectedSize,
  [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$probe = [ordered]@{ Status = 'running'; Detail = ''; DiskNumber = $DiskNumber; ReadOnly = $true; Samples = @(); SequentialBytes = 0; Started = (Get-Date).ToString('o') }
$stream = $null
$exitCode = 0
function Save-Probe { ConvertTo-Json -InputObject $probe -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
try {
  $disk = Get-CimInstance Win32_DiskDrive -Filter "Index = $DiskNumber"
  if (-not $disk -or "$($disk.Model)" -ne $ExpectedModel -or [long]$disk.Size -ne $ExpectedSize) { throw 'Selected physical disk changed before read probe.' }
  if ($ExpectedSize -lt 4GB) { throw 'Disk too small for the selected probe.' }
  Save-Probe
  $devicePath = '\\.\PhysicalDrive' + $DiskNumber
  # FileAccess.Read is deliberate: no raw writes, no filesystem changes.
  $stream = New-Object IO.FileStream($devicePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 1MB, [IO.FileOptions]::None)
  $buffer = New-Object byte[] (1MB)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $maxOffset = $ExpectedSize - 2MB
  for ($i = 0; $i -lt 64; $i++) {
    if ($clock.Elapsed.TotalSeconds -gt 45) { throw 'Read probe exceeded its 45-second budget.' }
    $offset = [long]([math]::Floor(($maxOffset * $i / 63) / 4096) * 4096)
    [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
    $t = [Diagnostics.Stopwatch]::StartNew()
    $done = 0
    while ($done -lt $buffer.Length) {
      $n = $stream.Read($buffer, $done, $buffer.Length - $done)
      if ($n -le 0) { throw "Unexpected end of device at offset $offset" }
      $done += $n
    }
    $probe.Samples += [pscustomobject]@{ Offset = $offset; Bytes = $done; Milliseconds = $t.Elapsed.TotalMilliseconds }
    Save-Probe
  }
  [void]$stream.Seek(64MB, [IO.SeekOrigin]::Begin)
  $seqClock = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt 1024; $i++) {
    if ($clock.Elapsed.TotalSeconds -gt 45) { throw 'Read probe exceeded its 45-second budget.' }
    $done = 0
    while ($done -lt $buffer.Length) {
      $n = $stream.Read($buffer, $done, $buffer.Length - $done)
      if ($n -le 0) { throw 'Unexpected end of device during sequential reading' }
      $done += $n
    }
    $probe.SequentialBytes += $done
    if (($i % 128) -eq 0) { Save-Probe }
  }
  $probe.SequentialSeconds = $seqClock.Elapsed.TotalSeconds
  $probe.SequentialMiBs = ($probe.SequentialBytes / 1MB) / [math]::Max(0.001, $probe.SequentialSeconds)
  $probe.Status = 'completed'
  $probe.Detail = '64 sampled 1 MiB reads and 1 GiB sequential read completed. This is not a full-surface or data-integrity verification.'
} catch {
  $probe.Status = 'error'
  $probe.Detail = $_.ToString()
  $exitCode = 1
} finally {
  if ($stream) { $stream.Dispose() }
  $probe.Finished = (Get-Date).ToString('o')
  Save-Probe
}
exit $exitCode
