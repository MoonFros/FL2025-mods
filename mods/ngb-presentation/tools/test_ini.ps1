# =============================================================================
#  test_ini.ps1 - add / remove / re-add test for _ngb_ini.ps1  (problem 9)
#
#  Runs the real script against throw-away copies of sample sider.ini files and
#  checks the result line by line. This is the test that would have caught the
#  `else` that hung off a Write-Host and made uninstall.bat fail.
#
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_ini.ps1
#  Exit code 0 = all cases passed.
# =============================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) '_ngb_ini.ps1'
if (-not (Test-Path -LiteralPath $script)) { Write-Host "[X] _ngb_ini.ps1 not found at $script"; exit 2 }

$fail = 0
$pass = 0
function Check([string]$name, [bool]$cond, [string]$detail) {
    if ($cond) { $script:pass++; Write-Host ("  ok   " + $name) }
    else { $script:fail++; Write-Host ("  FAIL " + $name + "  " + $detail) }
}

$tmp = Join-Path $env:TEMP ("ngb_ini_test_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function New-Ini([string]$name, [string[]]$lines) {
    $p = Join-Path $tmp $name
    [IO.File]::WriteAllLines($p, $lines, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}
function Read-Ini([string]$p) { return [IO.File]::ReadAllLines($p) }

try {
    # ---------------------------------------------------------------- case 1
    Write-Host "case 1: clean sider.ini, add then remove"
    $ini = New-Ini 'case1.ini' @(
        '; sider.ini',
        'lua.enabled = 1',
        'lua.module = "SomeOtherMod.lua"',
        'match-stats.enabled = 0'
    )
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini -Mode add -Module 'NGB_Presentation.lua' | Out-Null
    Check 'add exits 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    $l = Read-Ini $ini
    Check 'module line added'    ([bool]($l -match '^\s*lua\.module\s*=\s*"NGB_Presentation\.lua"'))
    Check 'luajit.ext.enabled=1' ([bool]($l -match '^\s*luajit\.ext\.enabled\s*=\s*1'))
    Check 'match-stats flipped'  ([bool]($l -match '^\s*match-stats\.enabled\s*=\s*1'))
    Check 'other mod kept'       ([bool]($l -match 'SomeOtherMod\.lua'))
    Check 'backup written'       (Test-Path -LiteralPath ($ini + '.ngb.bak'))
    $added = $l.Count

    # add twice must not duplicate
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini -Mode add -Module 'NGB_Presentation.lua' | Out-Null
    $l2 = Read-Ini $ini
    Check 'second add is idempotent' ($l2.Count -eq $added) ("$($l2.Count) vs $added")

    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini -Mode remove -Module 'NGB_Presentation.lua' | Out-Null
    Check 'remove exits 0  (this is the problem-9 regression)' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    $l3 = Read-Ini $ini
    Check 'module line gone'     (-not [bool]($l3 -match 'NGB_Presentation\.lua'))
    Check 'marker comment gone'  (-not [bool]($l3 -match 'Next-Gen Football Broadcast'))
    Check 'other mod survives'   ([bool]($l3 -match 'SomeOtherMod\.lua'))
    Check 'luajit.ext kept'      ([bool]($l3 -match '^\s*luajit\.ext\.enabled\s*=\s*1'))
    Check 'match-stats kept'     ([bool]($l3 -match '^\s*match-stats\.enabled\s*=\s*1'))

    # ---------------------------------------------------------------- case 2
    Write-Host "case 2: sider.ini with luajit.ext.enabled = 0 and no module lines"
    $ini2 = New-Ini 'case2.ini' @('luajit.ext.enabled = 0', 'lua.enabled = 1')
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini2 -Mode add -Module 'NGB_Presentation.lua' | Out-Null
    $m2 = Read-Ini $ini2
    Check 'luajit flipped to 1' ([bool]($m2 -match '^\s*luajit\.ext\.enabled\s*=\s*1'))
    Check 'module registered'   ([bool]($m2 -match 'NGB_Presentation\.lua'))
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini2 -Mode remove -Module 'NGB_Presentation.lua' | Out-Null
    Check 'remove on a non-installed file exits 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

    # ---------------------------------------------------------------- case 3
    Write-Host "case 3: uninstall on a file the mod was never added to"
    $ini3 = New-Ini 'case3.ini' @('lua.enabled = 1')
    $before = (Read-Ini $ini3) -join "`n"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini3 -Mode remove -Module 'NGB_Presentation.lua' | Out-Null
    Check 'exits 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    Check 'file unchanged' (((Read-Ini $ini3) -join "`n") -eq $before)
    Check 'no backup created' (-not (Test-Path -LiteralPath ($ini3 + '.ngb.bak')))

    # ---------------------------------------------------------------- case 4
    Write-Host "case 4: CRLF file with BOM is not corrupted"
    $ini4 = Join-Path $tmp 'case4.ini'
    $bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($ini4, "lua.enabled = 1`r`nlua.module = `"Other.lua`"`r`n", $bom)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini4 -Mode add -Module 'NGB_Presentation.lua' | Out-Null
    $raw = [IO.File]::ReadAllText($ini4)
    Check 'other module still on its line' ($raw -match 'lua\.module = "Other\.lua"')
    Check 'our module present'             ($raw -match 'NGB_Presentation\.lua')
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ini $ini4 -Mode remove -Module 'NGB_Presentation.lua' | Out-Null
    $raw2 = [IO.File]::ReadAllText($ini4)
    Check 'other module still there after remove' ($raw2 -match 'lua\.module = "Other\.lua"')
    Check 'our module gone'                       (-not ($raw2 -match 'NGB_Presentation\.lua'))
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
