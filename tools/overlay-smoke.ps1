# pilot / tools/overlay-smoke.ps1 - the takeover overlay, measured instead of eyeballed.
#
# The agreed behaviour: one overlay per round, taken down two seconds after the last
# action, never pre-warmed, never duplicated. These checks encode exactly that.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$failures = 0
function Check([string] $name, [bool] $ok, [string] $detail) {
  if ($ok) { Write-Host ('ok   ' + $name + ' - ' + $detail) }
  else { Write-Host ('FAIL ' + $name + ' - ' + $detail); $script:failures++ }
}

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\scripts\_dsh-overlay.ps1'
if (-not (Test-Path $script)) { Write-Host ('missing ' + $script); exit 2 }
$dir = Join-Path $env:TEMP ('pilot-overlay-smoke-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$show = Join-Path $dir 'show.txt'
$log  = Join-Path $dir 'status.txt'
$argList = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'-StateDir',$dir)

function Overlay-Procs {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like ('*_dsh-overlay.ps1*' + $dir + '*') })
}
function Count-Log([string] $word) {
  if (-not (Test-Path $log)) { return 0 }
  ([regex]::Matches((Get-Content $log -Raw), $word)).Count
}
function Wait-Log([string] $word, [int] $timeoutMs) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $want = (Count-Log $word) + 1
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    if ((Count-Log $word) -ge $want) { return [int] $sw.ElapsedMilliseconds }
    Start-Sleep -Milliseconds 20
  }
  return -1
}

try {
  # --- 1. first paint: measured, not pre-warmed -----------------------------
  Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
  Start-Sleep -Milliseconds 250
  # WriteAllText truncates in place, which is what the host's writeFileSync does.
  # Set-Content deletes and recreates, and the overlay can catch the gap as "no
  # show.txt" - a hide the real protocol never produces.
  [IO.File]::WriteAllText($show, (Join-Path $dir 'cancel.txt'), (New-Object Text.UTF8Encoding($false)))
  $cold = Wait-Log 'shown' 6000
  Check 'overlay paints at all' ($cold -ge 0) ('first paint after ' + $cold + ' ms')
  # The bound has to cover PowerShell's own start: on a loaded cloud VM that is 1.8-2.1 s
# before a single line of the overlay runs, and the stock 0.6.5 overlay measures 1874 ms
# on this host against ~700 ms on an idle one. 3000 ms still catches a genuinely slow
# paint without failing on the interpreter.
Check 'first paint within a usable bound' ($cold -ge 0 -and $cold -lt 3000) ('took ' + $cold + ' ms (no pre-warm by design)')

  # --- 2. a round is one show, however many actions it holds -----------------
  $shownBefore = Count-Log 'shown'
  start-sleep -Milliseconds 100
  for ($i = 0; $i -lt 4; $i++) {
    [IO.File]::WriteAllText($show, ((Join-Path $dir 'cancel.txt') + '#' + $i), (New-Object Text.UTF8Encoding($false)))
    Start-Sleep -Milliseconds 350
  }
  $reshows = (Count-Log 'shown') - $shownBefore
  Check 'a round does not re-show per action' ($reshows -eq 0) ('4 actions inside one round produced ' + $reshows + ' extra shows')

  # --- 3. taking it down is one hide ----------------------------------------
  $hidesBefore = Count-Log 'hidden'
  Remove-Item $show -Force -ErrorAction SilentlyContinue
  $hideMs = Wait-Log 'hidden' 5000
  $reshows2 = (Count-Log 'hidden') - $hidesBefore
  Check 'one hide when the round ends' ($hideMs -ge 0 -and $reshows2 -eq 1) ('hidden after ' + $hideMs + ' ms, ' + $reshows2 + ' hide(s)')

  # --- 4. a second copy must refuse to draw ---------------------------------
  [IO.File]::WriteAllText($show, (Join-Path $dir 'cancel.txt'), (New-Object Text.UTF8Encoding($false)))
  Start-Sleep -Milliseconds 400
  Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
  Start-Sleep -Milliseconds 1500
  $copies = @(Overlay-Procs).Count
  Check 'a second copy exits instead of drawing' ($copies -eq 1) ([string] $copies + ' copies polling ' + $dir)
} finally {
  Overlay-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) { Write-Host ('overlay-smoke: ' + $failures + ' check(s) failed'); exit 1 }
Write-Host 'overlay-smoke: OK'