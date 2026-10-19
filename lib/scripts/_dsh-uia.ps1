# pilot / _dsh-uia.ps1 - read a window's UI Automation tree, and resolve a node by index.
#
# Why this exists: screen_view returns pixels. Finding a control in pixels costs the
# model a guess at coordinates plus another frame to confirm the guess. UI Automation
# hands over the control's role, name and bounding rectangle directly, so a click
# becomes 'the centre of this rect' instead of 'where I think that button is'.
#
# The read uses FindAll with a CacheRequest, not TreeWalker. Measured on a 674-node
# window: TreeWalker ignores the cache request and pays six or seven cross-process
# reads per node (~2.7 s), while FindAll populates every property in one call (~270 ms).
# The price is that a flat list has no parent/child structure, so a node is addressed
# by its position in that list rather than by a path.
#
# Nothing is kept between calls: an index only means anything against the listing it
# came from, and re-reading is the only way to find out that it changed.

$script:DshUiaReady = $false

function Initialize-DshUia {
    if ($script:DshUiaReady) { return }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $script:DshUiaReady = $true
}

<# Read one window's descendants. Every node carries the index that addresses it. #>
function Get-DshUiaNodes {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Handle,
        [int] $MaxNodes = 2000,
        [bool] $IncludeValues = $false,
        [bool] $MeaningfulOnly = $true
    )

    Initialize-DshUia
    $AE = [System.Windows.Automation.AutomationElement]

    $root = $AE::FromHandle($Handle)
    if ($null -eq $root) { return [ordered]@{ ok = $false; error = 'the window exposes no automation element'; nodes = @(); truncated = $false; total = 0 } }

    $cache = New-Object System.Windows.Automation.CacheRequest
    foreach ($prop in @(
        $AE::ControlTypeProperty, $AE::NameProperty, $AE::BoundingRectangleProperty,
        $AE::IsEnabledProperty, $AE::IsOffscreenProperty, $AE::IsPasswordProperty
    )) { $cache.Add($prop) }

    $collection = $null
    $cache.Push()
    try {
        $collection = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    } catch {
        return [ordered]@{ ok = $false; error = ('the tree could not be read: ' + $_.Exception.Message); nodes = @(); truncated = $false; total = 0 }
    } finally {
        $cache.Pop()
    }

    $total = $collection.Count
    $limit = $total
    $truncated = $false
    if ($limit -gt $MaxNodes) { $limit = $MaxNodes; $truncated = $true }

    # Roles a person can operate. Measured on a 673-element window: the filtered
    $interactiveRoles = @('Button','Edit','ComboBox','ListItem','MenuItem','TabItem','CheckBox','RadioButton','Hyperlink','SplitButton','Slider','Spinner','TreeItem','DataItem')
    $bulkRoles = @('DataItem','TreeItem','ListItem','MenuItem')

    $nodes = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $limit; $i++) {
        $el = $collection[$i]
        try {
            $r = $el.Cached.BoundingRectangle
            $left = 0; $top = 0; $w = 0; $h = 0; $hasRect = $false
            if (-not $r.IsEmpty) { $left = [int] $r.X; $top = [int] $r.Y; $w = [int] $r.Width; $h = [int] $r.Height; $hasRect = $true }
            $value = $null
            if ($IncludeValues) {
                if ($el.Cached.IsPassword) {
                    $value = '<password field>'
                } else {
                    try {
                        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                        if ($null -ne $vp) { $value = [string] $vp.Current.Value }
                    } catch { }
                }
            }
            $role = ($el.Cached.ControlType.ProgrammaticName -replace 'ControlType\.', '')
            if ($MeaningfulOnly) {
                if ($interactiveRoles -notcontains $role) { continue }
                # A bulk container row with no name is addressable by index but carries
                # nothing to reason about, and they are the bulk of a large list.
                if ($bulkRoles -contains $role -and $name.Length -eq 0) { continue }
            }
            $nodes.Add([ordered]@{
                index = $i
                role = ($el.Cached.ControlType.ProgrammaticName -replace 'ControlType\.', '')
                name = [string] $el.Cached.Name
                left = $left; top = $top; width = $w; height = $h; hasRect = $hasRect
                enabled = [bool] $el.Cached.IsEnabled
                offscreen = [bool] $el.Cached.IsOffscreen
                value = $value
            })
        } catch {
            # A provider that throws mid-read must not abort the whole listing.
        }
    }

    return [ordered]@{ ok = $true; nodes = $nodes; truncated = $truncated; total = $total }
}

<# Render the nodes as the text the model reads. One line per control. #>
function Format-DshUiaNodes {
    param([object] $Nodes, [bool] $Truncated, [int] $Total)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Nodes) {
        $name = [string] $n.name
        if ($name.Length -gt 200) { $name = $name.Substring(0, 200) + '...' }
        $rect = '(no rect)'
        if ($n.hasRect) { $rect = ('{0},{1} {2}x{3}' -f $n.left, $n.top, $n.width, $n.height) }
        $bits = @()
        if (-not $n.enabled) { $bits += 'disabled' }
        if ($n.offscreen) { $bits += 'offscreen' }
        if ($null -ne $n.value) { $bits += ('value=' + ($n.value -replace '\s+', ' ')) }
        $tail = ''
        if ($bits.Count -gt 0) { $tail = '  ' + ($bits -join ' ') }
        $lines.Add(('{0} [{1}] ''{2}'' @ {3}{4}' -f $n.index, $n.role, $name, $rect, $tail))
    }
    if ($Truncated) { $lines.Add(('... truncated at the node cap ({0} elements in total)' -f $Total)) }
    return $lines.ToArray()
}

<# Resolve an index back to an element by re-reading the same listing. #>
function Resolve-DshUiaIndex {
    param([Parameter(Mandatory = $true)][IntPtr] $Handle, [Parameter(Mandatory = $true)][int] $Index)

    Initialize-DshUia
    $AE = [System.Windows.Automation.AutomationElement]
    $root = $AE::FromHandle($Handle)
    if ($null -eq $root) { return $null }
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    if ($Index -lt 0 -or $Index -ge $all.Count) { return $null }
    return $all[$Index]
}

<# Centre of an element's rectangle, or $null when it has no on-screen box. #>
function Get-DshUiaCentre {
    param([Parameter(Mandatory = $true)][object] $Element)
    try {
        $r = $Element.Current.BoundingRectangle
        if ($r.IsEmpty) { return $null }
        if ($r.Width -le 0 -or $r.Height -le 0) { return $null }
        return [pscustomobject]@{
            x = [int] ($r.X + $r.Width / 2)
            y = [int] ($r.Y + $r.Height / 2)
            left = [int] $r.X; top = [int] $r.Y; width = [int] $r.Width; height = [int] $r.Height
        }
    } catch { return $null }
}
