param(
    [Parameter(Mandatory=$true)][string]$Ini,
    [Parameter(Mandatory=$true)][ValidateSet('add','remove')][string]$Mode,
    [string]$Module = 'NGB_Presentation.lua'
)
# =============================================================================
#  _ngb_ini.ps1 - safe sider.ini editing for the Next-Gen Broadcast mod.
#
#  add    : registers  luajit.ext.enabled = 1,  match-stats.enabled = 1  and
#           lua.module = "NGB_Presentation.lua"
#           by inserting a line next to the existing lua.module lines (or at the
#           end of the file). Nothing else in the file is touched.
#  remove : removes only this mod's lua.module line (and its marker comment).
#
#  A backup (sider.ini.ngb.bak) is written before the first change.
# =============================================================================
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Ini)) { Write-Host "  [X] sider.ini not found: $Ini"; exit 2 }

$moduleLine = 'lua.module = "' + $Module + '"'
$luajitLine = 'luajit.ext.enabled = 1'
$matchStatsLine = 'match-stats.enabled = 1'
$moduleRx   = '^\s*lua\.module\s*=\s*"' + [regex]::Escape($Module) + '"'

$lines = New-Object System.Collections.ArrayList
foreach ($l in [IO.File]::ReadAllLines($Ini)) { [void]$lines.Add($l) }
$changed = $false

if ($Mode -eq 'add') {
    # ---- luajit.ext.enabled -------------------------------------------------
    $hasExt = $false
    $extOffAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*luajit\.ext\.enabled\s*=') {
            $hasExt = $true
            if ($lines[$i] -match '^\s*luajit\.ext\.enabled\s*=\s*0\s*$') { $extOffAt = $i }
        }
    }
    if (-not $hasExt) {
        $at = $lines.Count
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*lua\.module\s*=') { $at = $i; break } }
        [void]$lines.Insert($at, $luajitLine)
        $changed = $true
        Write-Host "  sider.ini : added  $luajitLine"
    } elseif ($extOffAt -ge 0) {
        $lines[$extOffAt] = $luajitLine
        $changed = $true
        Write-Host "  sider.ini : changed luajit.ext.enabled 0 -> 1 (required for live stats)"
    } else {
        Write-Host "  sider.ini : luajit.ext.enabled already on"
    }

    # ---- match-stats.enabled ------------------------------------------------
    #  Sider's match library is what gives the mod the live score and clock.
    $hasMs = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*match\-stats\.enabled\s*=') {
            $hasMs = $true
            if ($lines[$i] -match '^\s*match\-stats\.enabled\s*=\s*0\s*$') {
                $lines[$i] = $matchStatsLine
                $changed = $true
                Write-Host "  sider.ini : changed match-stats.enabled 0 -> 1 (live score and clock)"
            }
        }
    }
    if (-not $hasMs) {
        $at = $lines.Count
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*lua\.module\s*=') { $at = $i; break }
        }
        [void]$lines.Insert($at, $matchStatsLine)
        $changed = $true
        Write-Host "  sider.ini : added  $matchStatsLine"
    }

    # ---- lua.module ---------------------------------------------------------
    $hasModule = $false
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $moduleRx) { $hasModule = $true } }
    if (-not $hasModule) {
        $at = $lines.Count
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*lua\.module\s*=') { $at = $i + 1 } }
        [void]$lines.Insert($at, '; Next-Gen Football Broadcast Presentation - MoonFros')
        [void]$lines.Insert($at + 1, $moduleLine)
        $changed = $true
        Write-Host "  sider.ini : added  $moduleLine"
    } else {
        Write-Host "  sider.ini : module already registered"
    }
}
else {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match $moduleRx) {
            $lines.RemoveAt($i); $changed = $true
        }
        elseif ($lines[$i] -match '^;\s*Next-Gen Football Broadcast Presentation') {
            $lines.RemoveAt($i); $changed = $true
        }
    }
    if ($changed) { Write-Host "  sider.ini : module entry removed" }
    Write-Host "  sider.ini : match-stats.enabled left as it is (other mods may use it)"
    else { Write-Host "  sider.ini : nothing to remove" }
}

if ($changed) {
    Copy-Item -LiteralPath $Ini -Destination ($Ini + '.ngb.bak') -Force
    [IO.File]::WriteAllLines($Ini, $lines, (New-Object System.Text.UTF8Encoding($false)))
}
exit 0
