# =============================================================================
#  NEXT-GEN BROADCAST  -  doctor
#  MoonFros Presents  -  v2.0.1
#
#  Answers one question: "why is nothing happening?"
#  It changes nothing. It reads files and prints what it finds.
#
#  Run it by double-clicking NGB_Doctor.bat. It writes ngb_doctor.txt next to
#  itself - send that file back and the answer is in it.
# =============================================================================

param([string]$Sider = "")

$ErrorActionPreference = "Continue"
$script:here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:report = Join-Path $script:here "ngb_doctor.txt"
$script:problems = 0
$script:warnings = 0
$script:lines = New-Object System.Collections.ArrayList

function Emit([string]$text) {
    Write-Host $text
    [void]$script:lines.Add($text)
}

function Check([string]$label, [string]$state, [string]$detail, [string]$hint) {
    $tag = "[ OK ]"
    if ($state -eq "fail") { $tag = "[FAIL]"; $script:problems++ }
    elseif ($state -eq "warn") { $tag = "[WARN]"; $script:warnings++ }
    $line = "  $tag $label"
    if ($detail -ne "") { $line = $line + "  -  $detail" }
    Emit $line
    if ($hint -ne "" -and $state -ne "ok") { Emit "         -> $hint" }
}

function Get-PEMachine([string]$path) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    } catch {
        return 0
    }
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        if ($peOff -le 0 -or $peOff -gt 4096) { return 0 }
        $fs.Position = $peOff
        $sig = $br.ReadUInt32()
        if ($sig -ne 0x00004550) { return 0 }
        return [int]$br.ReadUInt16()
    } catch {
        return 0
    } finally {
        $fs.Close()
    }
}

function Read-Text([string]$path) {
    try { return [System.IO.File]::ReadAllText($path) } catch { return "" }
}

function Read-Lines([string]$path) {
    $text = Read-Text $path
    if ($text -eq "") { return @() }
    return $text -split "`r?`n"
}

function Last-Lines([string]$path, [int]$count) {
    $all = Read-Lines $path
    if ($all.Count -eq 0) { return @() }
    $start = [Math]::Max(0, $all.Count - $count)
    return $all[$start..($all.Count - 1)]
}

# -----------------------------------------------------------------------------
Emit "=================================================================="
Emit "  NEXT-GEN BROADCAST  -  doctor report"
Emit "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Emit "  Script folder: $script:here"
Emit "=================================================================="
Emit ""

# -----------------------------------------------------------------------------
#  1. find the Sider folder
# -----------------------------------------------------------------------------
Emit "1. SIDER FOLDER"

if ($Sider -eq "") {
    # the installer leaves the answer in install_log.txt, right next to us
    $logPath = Join-Path $script:here "install_log.txt"
    if (Test-Path $logPath) {
        foreach ($l in (Read-Lines $logPath)) {
            if ($l -match '^\s*Sider folder:\s*(.+?)\s*$') {
                $candidate = $Matches[1]
                if (Test-Path (Join-Path $candidate "sider.ini")) { $Sider = $candidate }
            }
        }
    }
}
if ($Sider -eq "") {
    $parent = Split-Path -Parent $script:here
    if (Test-Path (Join-Path $parent "sider.ini")) { $Sider = $parent }
}

if ($Sider -eq "") {
    Emit "  Could not find it automatically."
    Emit ""
    Emit "  Drag your Sider folder (the one with sider.ini in it) onto"
    Emit "  NGB_Doctor.bat, then run it again. Or type the path here:"
    $typed = Read-Host "  Sider folder"
    if ($typed -ne "") { $Sider = $typed }
}

if ($Sider -eq "") {
    Check "Sider folder" "fail" "not given" "run NGB_Doctor.bat with the Sider folder dragged onto it"
    Emit ""
    Emit "  Nothing else can be checked without it."
    $script:lines | Set-Content -Path $script:report -Encoding UTF8
    Write-Host ""
    Write-Host "Report written to $script:report"
    exit 1
}

$Sider = $Sider.Trim('"').Trim()
$Sider = $Sider.TrimEnd('\')

if (Test-Path (Join-Path $Sider "sider.ini")) {
    Check "Sider folder" "ok" $Sider ""
} else {
    Check "Sider folder" "fail" "$Sider (no sider.ini inside)" `
        "that is not a Sider folder; the folder must contain sider.ini"
}

$iniPath = Join-Path $Sider "sider.ini"
$modDir  = Join-Path $Sider "modules"
$stateDir = Join-Path $Sider "content\ngb-presentation"

Emit ""

# -----------------------------------------------------------------------------
#  2. the mod's own files
# -----------------------------------------------------------------------------
Emit "2. THE MOD'S FILES"

$lua = Join-Path $modDir "NGB_Presentation.lua"
if (Test-Path $lua) {
    $size = (Get-Item $lua).Length
    $text = Read-Text $lua
    $hasInit = $text.Contains("function m.init")
    $ver = ""
    if ($text -match 'm\.VERSION\s*=\s*"([^"]+)"') { $ver = $Matches[1] }
    if ($size -lt 100000) {
        Check "modules\NGB_Presentation.lua" "fail" "$size bytes" `
            "that is too small to be the real file - copy it again (it is about 200 KB)"
    } elseif (-not $hasInit) {
        Check "modules\NGB_Presentation.lua" "fail" "$size bytes but no init function" `
            "the file is not the module - copy it again from the mod folder"
    } else {
        Check "modules\NGB_Presentation.lua" "ok" "$size bytes, version $ver" ""
    }
} else {
    Check "modules\NGB_Presentation.lua" "fail" "missing" `
        "run install.bat again; the file belongs in $modDir"
}

$ini = Join-Path $modDir "NGB_Presentation.ini"
if (Test-Path $ini) {
    Check "modules\NGB_Presentation.ini" "ok" "present" ""
} else {
    Check "modules\NGB_Presentation.ini" "warn" "missing" `
        "the mod still runs on built-in defaults; re-run install.bat to get the settings file"
}

$dll = Join-Path $Sider "ngb-render\NGB_Render.dll"
if (Test-Path $dll) {
    $dsize = (Get-Item $dll).Length
    $machine = Get-PEMachine $dll
    if ($machine -eq 0x8664) {
        Check "ngb-render\NGB_Render.dll" "ok" ("$dsize bytes, x64 PE") ""
    } elseif ($machine -eq 0) {
        Check "ngb-render\NGB_Render.dll" "fail" "$dsize bytes but not a valid DLL" `
            "the file is damaged - copy it again"
    } else {
        Check "ngb-render\NGB_Render.dll" "fail" ("$dsize bytes, machine 0x{0:X4}" -f $machine) `
            "wrong architecture - this must be the 64-bit DLL from the package"
    }
} else {
    Check "ngb-render\NGB_Render.dll" "fail" "missing from $Sider\ngb-render" `
        "run install.bat again; without it nothing can be drawn (the mod still loads)"
}

if (Test-Path $stateDir) {
    Check "content\ngb-presentation" "ok" "present" ""
} else {
    Check "content\ngb-presentation" "warn" "not created yet" `
        "it is created the first time the module runs, so it may appear after the game starts"
}

Emit ""

# -----------------------------------------------------------------------------
#  3. sider.ini
# -----------------------------------------------------------------------------
Emit "3. sider.ini"

$iniLines = Read-Lines $iniPath
$values = @{}
$moduleLines = New-Object System.Collections.ArrayList
foreach ($raw in $iniLines) {
    $line = $raw
    if ($line -match '^\s*[;#]') { continue }
    if ($line -match '^\s*\[') { continue }
    $m = [regex]::Match($line, '^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*$')
    if (-not $m.Success) { continue }
    $key = $m.Groups[1].Value.ToLower()
    $val = $m.Groups[2].Value
    if ($key -eq "lua.module") { [void]$moduleLines.Add($val) }
    elseif (-not $values.ContainsKey($key)) { $values[$key] = $val }
}

function Setting([string]$name, [string]$want, [string]$why) {
    if (-not $values.ContainsKey($name)) {
        Check "sider.ini: $name" "fail" "line is missing" "$why"
        return
    }
    $have = $values[$name]
    if ($have -eq "1") {
        Check "sider.ini: $name" "ok" "= 1" ""
    } elseif ($have -eq "0") {
        Check "sider.ini: $name" "fail" ("= 0") "$why"
    } else {
        Check "sider.ini: $name" "warn" ("= " + $have) "expected 1"
    }
}

Setting "lua.enabled" "1" "add 'lua.enabled = 1' to sider.ini"
Setting "luajit.ext.enabled" "1" "the module cannot load the DLL without it; set it to 1"
Setting "match-stats.enabled" "1" "without it there is no score and no clock; set it to 1"

$wanted = "NGB_Presentation.lua"
$found = $false
$dupes = 0
foreach ($v in $moduleLines) {
    if ($v -match 'NGB_Presentation\.lua') { $found = $true; $dupes++ }
}
if ($found -and $dupes -eq 1) {
    Check "sider.ini: lua.module = `"$wanted`"" "ok" "registered once" ""
} elseif ($found) {
    Check "sider.ini: lua.module = `"$wanted`"" "warn" "registered $dupes times" `
        "remove the duplicates; one line is enough"
} else {
    Check "sider.ini: lua.module = `"$wanted`"" "fail" "not registered" `
        "add this line to sider.ini: lua.module = `"$wanted`""
}

# our private settings belong in modules\NGB_Presentation.ini, not here
$stray = @()
foreach ($k in @("experimental_player_stats", "probe_enabled", "probe_dump_region",
                 "renderer", "dll_enabled", "allow_unsafe_memory_reads",
                 "state_write_hz", "presentation_style")) {
    if ($values.ContainsKey($k)) { $stray += $k }
}
if ($stray.Count -gt 0) {
    Check "sider.ini: mod settings in the wrong file" "warn" ($stray -join ", ") `
        "those belong in $ini; Sider ignores them here, so they do nothing"
} else {
    Check "sider.ini: no mod settings in the wrong file" "ok" "" ""
}

Emit ""

# -----------------------------------------------------------------------------
#  4. what the module and the renderer have actually written
# -----------------------------------------------------------------------------
Emit "4. PROOF OF LIFE  (these files are written while the game runs)"

function Age([string]$path) {
    $t = (Get-Item $path).LastWriteTime
    $s = [int]((Get-Date) - $t).TotalSeconds
    return "$s s ago  ($($t.ToString('HH:mm:ss')))"
}

$stateJson = Join-Path $stateDir "state.json"
$heartbeat = Join-Path $stateDir "heartbeat.txt"
$renderTxt = Join-Path $stateDir "render.txt"
$dllLog   = Join-Path $stateDir "ngb-dll.log"

if (Test-Path $stateJson) {
    Check "state.json" "ok" "written $(Age $stateJson)" `
        ""
    $script:moduleStarted = $true
} else {
    Check "state.json" "fail" "never written" `
        "the module has never reached the end of its start-up - see section 6"
    $script:moduleStarted = $false
}

if (Test-Path $heartbeat) {
    Check "heartbeat.txt" "ok" "written $(Age $heartbeat)" ""
} else {
    Check "heartbeat.txt" "warn" "not written yet" `
        "written from the first game frame onwards; start the game and let the menu load"
}

if (Test-Path $renderTxt) {
    Check "render.txt (the DLL is inside a frame)" "ok" "written $(Age $renderTxt)" ""
} else {
    Check "render.txt (the DLL is inside a frame)" "warn" "not written yet" `
        "the DLL has not drawn anything yet; start the game and press F8 in a match"
}

Emit ""

# -----------------------------------------------------------------------------
#  5. the logs
# -----------------------------------------------------------------------------
Emit "5. WHAT THE LOGS SAY"

$siderLog = Join-Path $Sider "sider.log"
if (Test-Path $siderLog) {
    $recent = Last-Lines $siderLog 800
    $ngb = @()
    $errs = @()
    foreach ($l in $recent) {
        if ($l -match 'NGB') { $ngb += $l }
        if ($l -match 'lua ERROR|ERROR from module|error loading|attempt to ') { $errs += $l }
    }
    if ($ngb.Count -gt 0) {
        Check "sider.log mentions NGB" "ok" "$($ngb.Count) lines" ""
        Emit "        (last 12 of them)"
        $startIdx = [Math]::Max(0, $ngb.Count - 12)
        for ($i = $startIdx; $i -lt $ngb.Count; $i++) { Emit ("        | " + $ngb[$i]) }
    } else {
        Check "sider.log mentions NGB" "fail" "nothing in the last 800 lines" `
            "Sider never started the module: check the three sider.ini lines above, then start the game through Sider again"
    }
    if ($errs.Count -gt 0) {
        Emit ""
        Emit "  Errors in sider.log (this is usually the answer):"
        $startIdx = [Math]::Max(0, $errs.Count - 20)
        for ($i = $startIdx; $i -lt $errs.Count; $i++) { Emit ("        ! " + $errs[$i]) }
    }
} else {
    Check "sider.log" "warn" "not found at $siderLog" `
        "start the game through Sider at least once"
}

if (Test-Path $dllLog) {
    Emit ""
    Emit "  ngb-dll.log (last 12 lines):"
    $tail = Last-Lines $dllLog 12
    foreach ($l in $tail) { Emit ("        | " + $l) }
} else {
    Emit ""
    Emit "  ngb-dll.log does not exist yet - the DLL has not been loaded."
}

Emit ""

# -----------------------------------------------------------------------------
#  6. verdict
# -----------------------------------------------------------------------------
Emit "=================================================================="
Emit "  VERDICT"
Emit "=================================================================="

if ($script:problems -eq 0 -and $script:warnings -eq 0) {
    Emit "  Everything checks out."
    Emit ""
    Emit "  If the cards still do not appear: start a match and press F8."
    Emit "  If the test card appears, the drawing part works and the mod"
    Emit "  is simply waiting for a goal."
} elseif ($script:moduleStarted -eq $false) {
    Emit "  The module has never finished starting up."
    Emit ""
    Emit "  Fix the [FAIL] lines above first, in this order:"
    Emit "    1. the three sider.ini lines (section 3)"
    Emit "    2. modules\NGB_Presentation.lua present (section 2)"
    Emit "    3. ngb-render\NGB_Render.dll present (section 2)"
    Emit ""
    Emit "  Then start the game THROUGH Sider and run this again."
    Emit "  If it still fails, the error is in section 5 - send me this file."
} else {
    Emit "  The module starts, so look at the warnings above."
    Emit ""
    Emit "  Press F8 in a match: a card stamped DEMO - NOT REAL DATA must"
    Emit "  appear. That is the whole drawing test."
}

Emit ""
Emit "  Report written to: $script:report"
Emit "  Send that file if you want it looked at."
Emit "=================================================================="

$script:lines | Set-Content -Path $script:report -Encoding UTF8

if ($script:problems -gt 0) { exit 1 }
exit 0
