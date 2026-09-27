#requires -Version 5.1
<#
  desktop-probe.ps1 — DSH desktop-vision sensor half.

  Captures the interactive desktop (primary monitor, one monitor, all monitors
  composited, a screen region, or a single top-level window) to a PNG, and
  reports the geometry the model needs to map image pixels back onto physical
  screen coordinates.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File desktop-probe.ps1 -ParamsPath <params.json>
  Params: { "out": "<png path>", "screen": "primary|all|<index>", "region": "x,y,w,h",
            "includeCursor": false|true, "window": "<title or process substring>" }
  Stdout: one JSON object. Exit 0 on success, 1 on failure (still JSON).

  The params file is read as UTF-8 (never through the process code page, so
  non-ASCII window titles and paths survive), and the process is made
  per-monitor DPI aware first, so every rect it reports is in real physical
  pixels and matches what SetCursorPos / mouse_event consume.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string] $ParamsJson,
    [string] $ParamsPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- Win32 bridge
$nativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DshProbe {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

    public static bool BecomeDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true; } catch {}
        try { if (SetProcessDpiAwareness(2) == 0) return true; } catch {}
        try { if (SetProcessDPIAware()) return true; } catch {}
        return false;
    }
    public static RECT WindowRect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
    public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }
    public static string WindowTitle(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string WindowClass(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@
$null = Add-Type -TypeDefinition $nativeSource -Language CSharp
$null = [DshProbe]::BecomeDpiAware()

# ------------------------------------------------------------------- utilities
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

function Write-ProbeError([string] $message) {
    [ordered]@{ ok = $false; error = $message } | ConvertTo-Json -Compress -Depth 6
    [Console]::Out.Flush()
    exit 1
}

# ---------------------------------------------------------------------- params
$params = $null
if (-not [string]::IsNullOrWhiteSpace($ParamsPath)) {
    try { $ParamsJson = [System.IO.File]::ReadAllText($ParamsPath, [System.Text.Encoding]::UTF8) }
    catch { Write-ProbeError "could not read the params file '$ParamsPath': $($_.Exception.Message)" }
}
if (-not [string]::IsNullOrWhiteSpace($ParamsJson)) {
    try { $params = $ParamsJson | ConvertFrom-Json } catch { Write-ProbeError "invalid params JSON: $($_.Exception.Message)" }
}
if ($null -eq $params) { $params = [pscustomobject]@{} }

$outPath = if ($params.PSObject.Properties.Name -contains 'out') { [string] $params.out } else { '' }
if ([string]::IsNullOrWhiteSpace($outPath)) { Write-ProbeError 'params.out (the PNG destination) is required' }

$screenMode = if ($params.PSObject.Properties.Name -contains 'screen' -and $null -ne $params.screen) { [string] $params.screen } else { 'primary' }
$windowQuery = if ($params.PSObject.Properties.Name -contains 'window' -and $null -ne $params.window) { [string] $params.window } else { '' }
$regionSpec = if ($params.PSObject.Properties.Name -contains 'region' -and $null -ne $params.region) { [string] $params.region } else { '' }
$includeCursor = [bool] ($params.PSObject.Properties.Name -contains 'includeCursor' -and $params.includeCursor)

# ------------------------------------------------------------ screen inventory
$screens = @()
try {
    Add-Type -AssemblyName System.Windows.Forms
    $all = [System.Windows.Forms.Screen]::AllScreens
    foreach ($s in $all) {
        $screens += [ordered]@{
            device  = $s.DeviceName
            primary = [bool] $s.Primary
            bounds  = ('{0},{1},{2},{3}' -f $s.Bounds.X, $s.Bounds.Y, $s.Bounds.Width, $s.Bounds.Height)
        }
    }
} catch {
    Write-ProbeError "the desktop is not available to this session (screen enumeration failed: $($_.Exception.Message))"
}
if ($screens.Count -eq 0) { Write-ProbeError 'the desktop is not available to this session (no interactive display)' }

$primaryDip = $all | Where-Object { $_.Primary } | Select-Object -First 1
if ($null -eq $primaryDip) { $primaryDip = $all[0] }

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
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $captureDip = [pscustomobject]@{ X = $bounds.X; Y = $bounds.Y; Width = $bounds.Width; Height = $bounds.Height }
    $kind = 'all'
} elseif ($screenMode -eq 'primary') {
    $captureDip = $primaryDip.Bounds
    $kind = 'primary'
} else {
    $index = 0
    if (-not [int]::TryParse($screenMode, [ref] $index)) { Write-ProbeError "screen must be 'primary', 'all', or a monitor index (got '$screenMode')" }
    if ($index -lt 0 -or $index -ge $screens.Count) { Write-ProbeError "monitor index $index is out of range (0..$($screens.Count - 1))" }
    $captureDip = $all[$index].Bounds
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
    capturedAt       = [DateTimeOffset]::Now.ToString('o')
}
$result | ConvertTo-Json -Compress -Depth 8
[Console]::Out.Flush()
exit 0
