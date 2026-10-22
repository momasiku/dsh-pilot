
# pilot / _dsh-overlay.ps1 - the visible part of a takeover.
#
# Ring around every monitor, a caption naming the operator, and a halo that follows
# the pointer so it is obvious the movement is not yours. Esc stamps the cancel token
# the host published.
#
# The halo is DRAWING, not the pointer itself: this process never calls SetCursorPos
# and never installs an input hook, because either would add exactly the input lag
# that makes a person's own mouse feel broken while an agent drives. Windows draws
# the real cursor above every window, so the ring and glow sit under it and the
# pointer reads as larger and lit without being replaced.
param(
    [Parameter(Mandatory = $true)][string] $StateDir
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DshOv {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    public const int GWL_EXSTYLE = -20;
    public static void ClickThrough(IntPtr h) {
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        SetWindowLong(h, GWL_EXSTYLE, ex | 0x20 | 0x80 | 0x08000000);
    }
}
"@

$showFile = Join-Path $StateDir 'show.txt'
$quitFile = Join-Path $StateDir 'quit.txt'
$hitFile  = Join-Path $StateDir 'esc.txt'
$logFile  = Join-Path $StateDir 'status.txt'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
function Log([string] $m) {
    try { [System.IO.File]::AppendAllText($logFile, ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m + [Environment]::NewLine)) } catch { }
}

$global:DshOvVsL = [System.Windows.SystemParameters]::VirtualScreenLeft
$global:DshOvVsT = [System.Windows.SystemParameters]::VirtualScreenTop
$vw = [System.Windows.SystemParameters]::VirtualScreenWidth
$vh = [System.Windows.SystemParameters]::VirtualScreenHeight
$unit = [Math]::Min($vw / 1920.0, $vh / 1080.0)
if ($unit -lt 0.75) { $unit = 0.75 }

$coreThickness = [Math]::Max(6, [Math]::Round(8 * $unit))
$glowThickness = [Math]::Max(18, [Math]::Round(36 * $unit))
$blurRadius    = [Math]::Max(18, [Math]::Round(34 * $unit))
$radius        = [Math]::Round(22 * $unit)
$fontSize      = [Math]::Max(30, [Math]::Round(40 * $unit))
$spotD         = [Math]::Round(120 * $unit)
$global:DshOvSpotD = $spotD
$haloD         = [Math]::Round(58 * $unit)

function SB([int] $a, [int] $r, [int] $g, [int] $b) {
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

$window = New-Object System.Windows.Window
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.ResizeMode = 'NoResize'
$window.Left = $global:DshOvVsL
$window.Top = $global:DshOvVsT
$window.Width = $vw
$window.Height = $vh

$root = New-Object System.Windows.Controls.Grid

# ---- halo that follows the pointer ---------------------------------------
# Its own window, not a child of the ring window: a child Grid with runtime
# Margin never painted on this layered surface, while a window that is simply
# moved does. Moving a window is also cheaper than re-laying out a full-screen
# visual tree 30 times a second.
$haloWin = New-Object System.Windows.Window
$haloWin.WindowStyle = 'None'
$haloWin.AllowsTransparency = $true
$haloWin.Background = [System.Windows.Media.Brushes]::Transparent
$haloWin.Topmost = $true
$haloWin.ShowInTaskbar = $false
$haloWin.ShowActivated = $false
$haloWin.ResizeMode = 'NoResize'
$haloWin.Width = $spotD
$haloWin.Height = $spotD
$haloWin.Left = -10000
$haloWin.Top = -10000

$halo = New-Object System.Windows.Controls.Grid
$spot = New-Object System.Windows.Shapes.Ellipse
$spot.Width = $spotD
$spot.Height = $spotD
$spotFill = New-Object System.Windows.Media.RadialGradientBrush
$stop1 = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(155, 70, 150, 255)), 0.0
$stop2 = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(70, 70, 150, 255)), 0.55
$stop3 = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0, 70, 150, 255)), 1.0
$spotFill.GradientStops.Add($stop1) | Out-Null
$spotFill.GradientStops.Add($stop2) | Out-Null
$spotFill.GradientStops.Add($stop3) | Out-Null
$spot.Fill = $spotFill
$halo.Children.Add($spot) | Out-Null

$haloRing = New-Object System.Windows.Shapes.Ellipse
$haloRing.Width = $haloD
$haloRing.Height = $haloD
$haloRing.Stroke = SB 235 236 246 255
$haloRing.StrokeThickness = [Math]::Max(2, [Math]::Round(3 * $unit))
$haloRing.HorizontalAlignment = 'Center'
$haloRing.VerticalAlignment = 'Center'
$halo.Children.Add($haloRing) | Out-Null

$haloWin.Content = $halo
$haloWin.Add_SourceInitialized({
    # This window sits exactly where the pointer is. Without WS_EX_TRANSPARENT it
    # eats the very click it is drawn around.
    $hh = (New-Object System.Windows.Interop.WindowInteropHelper($haloWin)).Handle
    [DshOv]::ClickThrough($hh) | Out-Null
}.GetNewClosure())
$global:DshOvHaloWin = $haloWin


# ---- caption -------------------------------------------------------------
$sans = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Microsoft YaHei, Segoe UI Variable Display, Segoe UI')
$label = New-Object System.Windows.Controls.TextBlock
# Built from UTF-8 bytes on purpose: this file lost its BOM once and PowerShell
# 5.1 then read the literal as GBK, turning the caption into mojibake. Bytes cannot
# be mis-decoded.
$captionBytes = [byte[]]@(0x44,0x53,0x48,0x20,0xE6,0xAD,0xA3,0xE5,0x9C,0xA8,0xE6,0x93,0x8D,0xE4,0xBD,0x9C,0xE4,0xBD,0xA0,0xE7,0x9A,0x84,0xE7,0x94,0xB5,0xE8,0x84,0x91,0x20,0x20,0x20,0xE6,0x8C,0x89,0x20,0x45,0x73,0x63,0x20,0xE5,0x8F,0x96,0xE6,0xB6,0x88)
$label.Text = [System.Text.Encoding]::UTF8.GetString($captionBytes)
$label.FontSize = $fontSize
$label.FontFamily = $sans
$label.FontWeight = [System.Windows.FontWeights]::Bold
$label.Foreground = [System.Windows.Media.Brushes]::White
$label.Opacity = 0.9
$label.HorizontalAlignment = 'Center'
$label.VerticalAlignment = 'Top'
$label.Margin = [System.Windows.Thickness]::new(0, [Math]::Round(34 * $unit), 0, 0)
$capShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$capShadow.Color = [System.Windows.Media.Colors]::Black
$capShadow.BlurRadius = [Math]::Round(26 * $unit)
$capShadow.ShadowDepth = 3
$capShadow.Opacity = 0.9
$label.Effect = $capShadow
$root.Children.Add($label) | Out-Null

$window.Content = $root

$global:DshOvHwnd = [IntPtr]::Zero
$global:DshOvCancelTarget = ''
$global:DshOvStoppedFor = ''
$global:DshOvHotkeyOn = $false

function Enable-Hotkey {
    if ($global:DshOvHotkeyOn -or $global:DshOvHwnd -eq [IntPtr]::Zero) { return }
    $global:DshOvHotkeyOn = [DshOv]::RegisterHotKey($global:DshOvHwnd, 1, 0, 0x1B)
}
function Disable-Hotkey {
    if (-not $global:DshOvHotkeyOn -or $global:DshOvHwnd -eq [IntPtr]::Zero) { return }
    [DshOv]::UnregisterHotKey($global:DshOvHwnd, 1) | Out-Null
    $global:DshOvHotkeyOn = $false
}

function Stop-Takeover {
    $global:DshOvStoppedFor = $global:DshOvCancelTarget
    if ($global:DshOvCancelTarget -ne '') {
        try { [System.IO.File]::WriteAllText($global:DshOvCancelTarget, 'stop', [System.Text.Encoding]::UTF8) } catch { }
    }
    try { [System.IO.File]::WriteAllText($hitFile, (Get-Date).ToString('o'), [System.Text.Encoding]::UTF8) } catch { }
    if ($window.IsVisible) { $window.Hide(); Disable-Hotkey }
    $global:DshOvCancelTarget = ''
}

$script:haloErrors = 0
function Update-Halo {
    # No latching. A failed GetCursorPos (the desktop can be mid-switch between a
    # locked and an active session) used to disable the halo for the rest of the
    # process - which is exactly "it worked at first and then stopped".
    try {
        # The nested struct has to be named, not written as DshOv+POINT: unquoted,
        # PowerShell reads the plus as arithmetic and the call throws on every tick.
        $p = [DshOv+POINT]::new()
        # A frozen position makes the halo verifiable without racing a human hand.
        $freeze = Join-Path $StateDir 'freeze.txt'
        $fx = $null
        if (Test-Path -LiteralPath $freeze) {
            try {
                $parts = ([System.IO.File]::ReadAllText($freeze)).Trim() -split ','
                if ($parts.Count -ge 2) { $fx = @([int] $parts[0], [int] $parts[1]) }
            } catch { }
        }
        $ok = $false
        if ($null -ne $fx) { $p.X = $fx[0]; $p.Y = $fx[1]; $ok = $true } else { $ok = [DshOv]::GetCursorPos([ref] $p) }
        if ($ok) {
            $h = $global:DshOvHaloWin
            if ($null -eq $h) { if (-not $script:haloLogged) { $script:haloLogged = $true; Log 'halo missing' }; return }
            $h.Left = $p.X - ($global:DshOvSpotD / 2)
            $h.Top = $p.Y - ($global:DshOvSpotD / 2)
            $script:haloMoves = [int] $script:haloMoves + 1
            if ($script:haloMoves -le 3 -or ($script:haloMoves % 40) -eq 0) {
                Log ("halo move " + $script:haloMoves + " -> " + $p.X + "," + $p.Y + " margin=" + $h.Margin.Left + "," + $h.Margin.Top)
            }
        }
    } catch {
        $script:haloErrors++
        if ($script:haloErrors -le 3 -or ($script:haloErrors % 300) -eq 0) {
            Log ("halo error " + $script:haloErrors + ": " + $_.Exception.Message)
        }
    }
}

function Update-State {
    $show = Test-Path -LiteralPath $showFile
    if ($show) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($showFile, [System.Text.Encoding]::UTF8).Trim() } catch { }
        if ($raw -eq $global:DshOvStoppedFor) { $show = $false } else { $global:DshOvCancelTarget = $raw }
    }
    if ($show) {
        if (-not $window.IsVisible) {
            # The desktop can change size between shows (a reconnect, a display mode
            # switch); re-fit rather than draw a 1080p ring on a 1600p desktop.
            $w = [System.Windows.SystemParameters]::VirtualScreenWidth
            $h = [System.Windows.SystemParameters]::VirtualScreenHeight
            if ($window.Width -ne $w -or $window.Height -ne $h) {
                $window.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
                $window.Top = [System.Windows.SystemParameters]::VirtualScreenTop
                $window.Width = $w
                $window.Height = $h
            }
            $window.Show(); Enable-Hotkey
            if (-not $global:DshOvHaloWin.IsVisible) { $global:DshOvHaloWin.Show() }
            Log ("shown " + $w + "x" + $h)
        }
        Update-Halo
    } elseif ($window.IsVisible) {
        $window.Hide()
        if ($global:DshOvHaloWin.IsVisible) { $global:DshOvHaloWin.Hide() }
        Disable-Hotkey
        $global:DshOvCancelTarget = ''
    }
    if (Test-Path -LiteralPath $quitFile) { $window.Close() }
}

$window.Add_SourceInitialized({
    $global:DshOvHwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    [DshOv]::ClickThrough($global:DshOvHwnd) | Out-Null
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($global:DshOvHwnd)
    $source.AddHook([System.Windows.Interop.HwndSourceHook]{
        param($msgHwnd, $msg, $wParam, $lParam, [ref] $handled)
        if ($msg -eq 0x0312 -and [int] $wParam -eq 1) { Stop-Takeover; $handled.Value = $true }
        return [IntPtr]::Zero
    })
}.GetNewClosure())

$haloWin.Add_Closed({ })
$window.Add_Closed({
    if ($global:DshOvHaloWin.IsVisible) { $global:DshOvHaloWin.Close() }
    if ($global:DshOvHwnd -ne [IntPtr]::Zero) { [DshOv]::UnregisterHotKey($global:DshOvHwnd, 1) | Out-Null }
})

# No parent watch: a host that dies leaves no trace to watch, and a false positive
# kills the ring the moment the launcher is a short-lived shell. An idle timeout
# bounds the leftover process without ever firing while it is in use.
$global:DshOvTicks = 0
$global:DshOvIdleTicks = 0

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
    Update-State
    $global:DshOvTicks++
    if ($window.IsVisible) { $global:DshOvIdleTicks = 0 } else { $global:DshOvIdleTicks++ }
    # 33 ms * 18000 = ~10 minutes hidden before the process gives the memory back.
    if ($global:DshOvIdleTicks -gt 18000) { $window.Close() }
})
$timer.Start()

# Create the handle and strip activation BEFORE the first Show. Applying the
# extended style from SourceInitialized is too late: Windows has already offered
# the window the foreground by then, and a topmost window that takes focus breaks
# the very actions it is drawn for.
$pre = New-Object System.Windows.Interop.WindowInteropHelper($window)
$preHwnd = $pre.EnsureHandle()
[DshOv]::ClickThrough($preHwnd) | Out-Null
$preHalo = New-Object System.Windows.Interop.WindowInteropHelper($haloWin)
$preHaloHwnd = $preHalo.EnsureHandle()
[DshOv]::ClickThrough($preHaloHwnd) | Out-Null

$window.Show()
$window.Hide()
[System.Windows.Threading.Dispatcher]::Run()
