# pilot / _dsh-capture.ps1 - one capture, executed in whatever process called it.
#
# Extracted from desktop-probe.ps1 so the same code serves two callers:
#   * desktop-probe.ps1  - one frame per process (the fallback path);
#   * desktop-worker.ps1 - frames in the warm process (the fast path).
#
# Differences from the one-shot script it came from: failures throw instead of
# printing JSON and exiting, and the result is returned instead of being printed.
$ErrorActionPreference = 'Stop'

$script:CaptureStopPayload = $null

function Write-ProbeError([string] $message) {
    $script:CaptureStopPayload = [ordered]@{ ok = $false; error = $message }
    throw [System.Exception]::new($message)
}

function Get-ProcessNameSafe([uint32] $pidValue) {
    try { return (Get-Process -Id $pidValue -ErrorAction Stop).ProcessName } catch { return $null }
}

function ConvertTo-WindowInfo([IntPtr] $handle, [bool] $withProcess) {
    if ($handle -eq [IntPtr]::Zero) { return $null }
    $title = [DshProbe]::WindowTitle($handle)
    $class = [DshProbe]::WindowClass($handle)
    $rect = [DshProbe]::WindowRect($handle)
    $pidValue = [uint32] 0
    $null = [DshProbe]::GetWindowThreadProcessId($handle, [ref] $pidValue)
    return [ordered]@{
        handle  = ('0x{0:X}' -f $handle.ToInt64())
        title   = $title
        class   = $class
        process = if ($withProcess) { Get-ProcessNameSafe $pidValue } else { $null }
        pid     = [int] $pidValue
        bounds  = ('{0},{1},{2},{3}' -f $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
    }
}


<#
Capture the desktop, a monitor, a region or one window. $Params carries out,
screen, window, region and includeCursor.
#>
function Invoke-DshCapture {
    param([object] $Params)

    $params = if ($null -eq $Params) { [pscustomobject]@{} } else { $Params }

$outPath = if ($params.PSObject.Properties.Name -contains 'out') { [string] $params.out } else { '' }
if ([string]::IsNullOrWhiteSpace($outPath)) { Write-ProbeError 'params.out (the PNG destination) is required' }

$screenMode = if ($params.PSObject.Properties.Name -contains 'screen' -and $null -ne $params.screen) { [string] $params.screen } else { 'primary' }
$windowQuery = if ($params.PSObject.Properties.Name -contains 'window' -and $null -ne $params.window) { [string] $params.window } else { '' }
$regionSpec = if ($params.PSObject.Properties.Name -contains 'region' -and $null -ne $params.region) { [string] $params.region } else { '' }
$includeCursor = [bool] ($params.PSObject.Properties.Name -contains 'includeCursor' -and $params.includeCursor)
$rulers = $true
if ($params.PSObject.Properties.Name -contains 'rulers') { $rulers = [bool] $params.rulers }


# ------------------------------------------------------------ screen inventory
# Re-enumerated on every capture, deliberately.
#
# System.Windows.Forms.Screen.AllScreens is a static cache that only refreshes
# when the process pumps WM_DISPLAYCHANGE. The warm worker is a -NonInteractive
# read loop with no message pump, so that cache is never invalidated: after a
# resolution change the worker keeps reporting the geometry it saw at startup.
# Measured here - a worker alive 13 hours reported
# <screens>primary WinDisc 0,0,1600,900</screens> while the same result carried
# <image_size>1024x768</image_size>. Restarting the worker produced the correct
# 1024x768. Two answers to one question, inside the very result the coordinate
# contract is read from. EnumDisplayMonitors re-queries per call, so there is no
# cache to go stale.
$screens = @()
$screenBounds = @()
$rows = @()
try {
    $rows = @([DshProbe]::Monitors())
} catch {
    Write-ProbeError "the desktop is not available to this session (screen enumeration failed: $($_.Exception.Message))"
}
foreach ($row in $rows) {
    $parts = $row -split '\|'
    if ($parts.Count -lt 6) { continue }
    $left = [int] $parts[2]; $top = [int] $parts[3]; $right = [int] $parts[4]; $bottom = [int] $parts[5]
    if (($right - $left) -le 0 -or ($bottom - $top) -le 0) { continue }
    $screens += [ordered]@{
        device  = $parts[0]
        primary = ($parts[1] -eq '1')
        bounds  = ('{0},{1},{2},{3}' -f $left, $top, ($right - $left), ($bottom - $top))
    }
    $screenBounds += [pscustomobject]@{ X = $left; Y = $top; Width = ($right - $left); Height = ($bottom - $top) }
}
if ($screens.Count -eq 0) { Write-ProbeError 'the desktop is not available to this session (no interactive display)' }

$primaryIndex = 0
for ($i = 0; $i -lt $screens.Count; $i++) { if ($screens[$i].primary) { $primaryIndex = $i; break } }
$primaryDip = $screenBounds[$primaryIndex]

# Resolution order: an explicit window, then a region, then the screen mode.
$kind = $null
$captureDip = $null
$scale = $null

if (-not [string]::IsNullOrWhiteSpace($windowQuery)) {
    $needle = $windowQuery.ToLowerInvariant()
    $candidate = $null
    foreach ($process in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })) {
        $handle = $process.MainWindowHandle
        if (-not [DshProbe]::IsWindowVisible($handle)) { continue }
        $title = [DshProbe]::WindowTitle($handle)
        if ($title.ToLowerInvariant().Contains($needle) -or $process.ProcessName.ToLowerInvariant().Contains($needle)) {
            if ($null -eq $candidate) { $candidate = $process }
        }
    }
    if ($null -eq $candidate) { Write-ProbeError "no visible top-level window matches '$windowQuery'" }
    $handle = $candidate.MainWindowHandle
    $rect = [DshProbe]::WindowRect($handle)
    $captureDip = [pscustomobject]@{ X = $rect.Left; Y = $rect.Top; Width = ($rect.Right - $rect.Left); Height = ($rect.Bottom - $rect.Top) }
    $kind = 'window'
} elseif (-not [string]::IsNullOrWhiteSpace($regionSpec)) {
    $parts = @($regionSpec -split '[,\s]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ne 4) { Write-ProbeError "region must be 'x,y,width,height' (got '$regionSpec')" }
    try { $r = @($parts | ForEach-Object { [int] $_ }) } catch { Write-ProbeError "region must contain four integers (got '$regionSpec')" }
    if ($r[2] -le 0 -or $r[3] -le 0) { Write-ProbeError 'region width and height must be positive' }
    $captureDip = [pscustomobject]@{ X = $r[0]; Y = $r[1]; Width = $r[2]; Height = $r[3] }
    $kind = 'region'
} elseif ($screenMode -eq 'all') {
    # SM_XVIRTUALSCREEN(76), SM_YVIRTUALSCREEN(77), SM_CXVIRTUALSCREEN(78), SM_CYVIRTUALSCREEN(79).
    # GetSystemMetrics is a live call; SystemInformation.VirtualScreen comes from the
    # same WinForms cache as Screen.AllScreens and goes stale for the same reason.
    $vx = [DshProbe]::GetSystemMetrics(76)
    $vy = [DshProbe]::GetSystemMetrics(77)
    $vw = [DshProbe]::GetSystemMetrics(78)
    $vh = [DshProbe]::GetSystemMetrics(79)
    if ($vw -le 0 -or $vh -le 0) { $vx = $primaryDip.X; $vy = $primaryDip.Y; $vw = $primaryDip.Width; $vh = $primaryDip.Height }
    $captureDip = [pscustomobject]@{ X = $vx; Y = $vy; Width = $vw; Height = $vh }
    $kind = 'all'
} elseif ($screenMode -eq 'primary') {
    $captureDip = $primaryDip
    $kind = 'primary'
} else {
    $index = 0
    if (-not [int]::TryParse($screenMode, [ref] $index)) { Write-ProbeError "screen must be 'primary', 'all', or a monitor index (got '$screenMode')" }
    if ($index -lt 0 -or $index -ge $screens.Count) { Write-ProbeError "monitor index $index is out of range (0..$($screens.Count - 1))" }
    $captureDip = $screenBounds[$index]
    $kind = "screen:$index"
}

# --------------------------------------------------------------------- capture
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object System.Drawing.Bitmap($captureDip.Width, $captureDip.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$imageWidth = 0
$imageHeight = 0
try {
    $graphics.CopyFromScreen($captureDip.X, $captureDip.Y, 0, 0, $bitmap.Size)
    if ($includeCursor) {
        try {
            $cursor = [DshProbe]::Cursor()
            $cx = $cursor.X - $captureDip.X
            $cy = $cursor.Y - $captureDip.Y
            if ($cx -ge 0 -and $cy -ge 0 -and $cx -lt $bitmap.Width -and $cy -lt $bitmap.Height) {
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 0, 0)), 2
                $graphics.DrawLine($pen, ($cx - 14), $cy, ($cx + 14), $cy)
                $graphics.DrawLine($pen, $cx, ($cy - 14), $cx, ($cy + 14))
                $pen.Dispose()
            }
        } catch {
            # A cursor overlay is cosmetic: never fail a capture over it.
        }
    }
    if ($rulers) {
        # Coordinate rulers: ticks every $rulerStep pixels along the top and left
        # edge, each labelled with the SCREEN coordinate it sits at (capture origin
        # plus the local offset). The model can then read a position straight off
        # the image instead of counting pixels, which also survives any later
        # downscaling by the attachment store - the ratio in the envelope says what
        # the labels have to be multiplied by.
        try {
            $rulerStep = if ($bitmap.Width -ge 800) { 200 } else { 100 }
            $font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
            $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 64, 64))
            $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 0, 0, 0))
            $tick = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(170, 255, 64, 64)), 1
            try {
                for ($x = $rulerStep; $x -lt $bitmap.Width; $x += $rulerStep) {
                    $graphics.DrawLine($tick, $x, 0, $x, 10)
                    $label = [string] ([int] $captureDip.X + $x)
                    $graphics.DrawString($label, $font, $shadow, ($x + 2), 13)
                    $graphics.DrawString($label, $font, $ink, ($x + 1), 12)
                }
                for ($y = $rulerStep; $y -lt $bitmap.Height; $y += $rulerStep) {
                    $graphics.DrawLine($tick, 0, $y, 10, $y)
                    $label = [string] ([int] $captureDip.Y + $y)
                    $graphics.DrawString($label, $font, $shadow, 13, ($y + 2))
                    $graphics.DrawString($label, $font, $ink, 12, ($y + 1))
                }
                $originLabel = ('origin {0},{1}  step {2}' -f [int] $captureDip.X, [int] $captureDip.Y, $rulerStep)
                $graphics.DrawString($originLabel, $font, $shadow, 15, 30)
                $graphics.DrawString($originLabel, $font, $ink, 14, 29)
            } finally {
                $tick.Dispose()
                $font.Dispose()
                $ink.Dispose()
                $shadow.Dispose()
            }
        } catch {
            # Rulers are an aid: never fail a capture over them.
        }
    }
    $directory = Split-Path -Parent $outPath
    if (-not [string]::IsNullOrEmpty($directory) -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $bitmap.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $imageWidth = $bitmap.Width
    $imageHeight = $bitmap.Height
} catch {
    Write-ProbeError "screen capture failed: $($_.Exception.Message)"
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

# DIP -> physical. Both the capture rect and the DIP screen rect come from the
# same monitor, so the ratio is the monitor's real scale factor.
if ($captureDip.Width -gt 0) { $scale = [math]::Round(($imageWidth / $captureDip.Width), 4) } else { $scale = 1 }
$originX = [int] [math]::Round($captureDip.X * $scale)
$originY = [int] [math]::Round($captureDip.Y * $scale)

# ------------------------------------------------------------------- foreground
$foreground = ConvertTo-WindowInfo ([DshProbe]::GetForegroundWindow()) $true
$cursorInfo = $null
try {
    $cursor = [DshProbe]::Cursor()
    $screen = $screens | Where-Object {
        $b = ($_.bounds -split ',') | ForEach-Object { [int] $_ }
        $cursor.X -ge $b[0] -and $cursor.X -lt ($b[0] + $b[2]) -and $cursor.Y -ge $b[1] -and $cursor.Y -lt ($b[1] + $b[3])
    } | Select-Object -First 1
    $cursorInfo = [ordered]@{
        x      = $cursor.X
        y      = $cursor.Y
        screen = if ($null -ne $screen) { $screen.device } else { $null }
    }
} catch {
    $cursorInfo = $null
}

$result = [ordered]@{
    ok               = $true
    path             = (Resolve-Path -LiteralPath $outPath).Path
    kind             = $kind
    imageWidth       = $imageWidth
    imageHeight      = $imageHeight
    originX          = $originX
    originY          = $originY
    scale            = $scale
    dpiAware         = $true
    dipBounds        = ('{0},{1},{2},{3}' -f $captureDip.X, $captureDip.Y, $captureDip.Width, $captureDip.Height)
    screens          = $screens
    cursor           = $cursorInfo
    foregroundWindow = $foreground
    rulers           = [bool] $rulers
    capturedAt       = [DateTimeOffset]::Now.ToString('o')
}
    return $result
}