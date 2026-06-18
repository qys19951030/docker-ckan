#
# verify_secrets.ps1
#
# PowerShell equivalent of verify_secrets.sh.
# Tests the resolve_secret logic ported to PowerShell.
#
param()

$script:Pass = 0
$script:Fail = 0

function Resolve-Secret {
    param(
        [string]$envvar_ckanstyle,
        [string]$envvar_legacy
    )

    $val = ""

    $ckanVal = Get-Item "env:$envvar_ckanstyle" -ErrorAction SilentlyContinue
    $legacyVal = Get-Item "env:$envvar_legacy" -ErrorAction SilentlyContinue

    if ($null -ne $ckanVal -and [string]::IsNullOrEmpty($ckanVal.Value) -eq $false) {
        $val = $ckanVal.Value
    } elseif ($null -ne $legacyVal -and [string]::IsNullOrEmpty($legacyVal.Value) -eq $false) {
        $val = $legacyVal.Value
    }

    if ($val.StartsWith("string:")) {
        $val = $val.Substring(7)
    }

    if ($val -eq "CHANGE_ME") {
        $val = ""
    }

    return $val
}

function Run-Test {
    param(
        [string]$desc,
        [string]$expected,
        [string]$ckanStyle = "",
        [string]$legacyStyle = ""
    )

    Remove-Item "env:CKAN___TEST" -ErrorAction SilentlyContinue
    Remove-Item "env:BEAKER_TEST" -ErrorAction SilentlyContinue

    if (-not [string]::IsNullOrEmpty($ckanStyle)) {
        Set-Item "env:CKAN___TEST" -Value $ckanStyle
    }
    if (-not [string]::IsNullOrEmpty($legacyStyle)) {
        Set-Item "env:BEAKER_TEST" -Value $legacyStyle
    }

    $actual = Resolve-Secret "CKAN___TEST" "BEAKER_TEST"

    if ($actual -eq $expected) {
        Write-Host "  [PASS] $desc"
        $script:Pass++
    } else {
        Write-Host "  [FAIL] $desc  (got: '$actual')"
        $script:Fail++
    }

    Remove-Item "env:CKAN___TEST" -ErrorAction SilentlyContinue
    Remove-Item "env:BEAKER_TEST" -ErrorAction SilentlyContinue
}

Write-Host "============================================================"
Write-Host " Unit tests - resolve_secret() from start_ckan.sh (ported to PS)"
Write-Host "============================================================"

Write-Host ""
Write-Host "-- Path A: secrets PROVIDED via env (must be preserved) --"

Run-Test -desc "CKAN___ style (no prefix)" -expected "my-beaker-secret" -ckanStyle "my-beaker-secret"
Run-Test -desc "CKAN___ style with string: prefix (prefix stripped)" -expected "my-jwt-secret" -ckanStyle "string:my-jwt-secret"
Run-Test -desc "Legacy BEAKER_ style used when CKAN___ style absent" -expected "legacy-secret" -legacyStyle "legacy-secret"
Run-Test -desc "CKAN___ style takes precedence over legacy" -expected "ckanstyle-wins" -ckanStyle "ckanstyle-wins" -legacyStyle "legacy-ignored"
Run-Test -desc "CKAN___ style with string:CHANGE_ME -> treated as empty (auto-gen path)" -expected "" -ckanStyle "string:CHANGE_ME"

Write-Host ""
Write-Host "-- Path B: secrets NOT provided -> must be empty (trigger auto-gen) --"

Run-Test -desc "Both vars UNSET" -expected ""
Run-Test -desc "CKAN___ exactly 'CHANGE_ME' -> treated as empty" -expected "" -ckanStyle "CHANGE_ME"
Run-Test -desc "Legacy exactly 'CHANGE_ME' -> treated as empty" -expected "" -legacyStyle "CHANGE_ME"

Write-Host ""
Write-Host "============================================================"
Write-Host " Result: $script:Pass passed, $script:Fail failed"
Write-Host "============================================================"

if ($script:Fail -ne 0) {
    exit 1
}
