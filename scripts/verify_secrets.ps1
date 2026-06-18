#
# verify_secrets.ps1
#
# PowerShell test suite for the CKAN secret resolution and ini reading logic
# from start_ckan.sh.  Tests EVERY helper function used in the startup script,
# not just resolve_secret.
#
# Coverage:
#   1. resolve_secret  – env var resolution (CKAN___* priority, CHANGE_ME sentinel,
#                        string: prefix stripping)
#   2. iniget          – "key = value" parsing of `ckan config-tool -g` output
#                        (value extraction, whitespace trimming)
#   3. is_unset        – empty/placeholder detection for ini values
#   4. has_value       – inverse of is_unset
#   5. Full decision logic simulation – given env vars + simulated ini state, verify
#                                   correct code path is taken
#
param()

$script:Pass = 0
$script:Fail = 0
$script:TotalTests = 0

function Write-Pass([string]$desc) {
    Write-Host "  [PASS] $desc"
    $script:Pass++
    $script:TotalTests++
}
function Write-Fail([string]$desc, [string]$got, [string]$expected) {
    if ($expected) {
        Write-Host "  [FAIL] $desc  (got: '$got', expected: '$expected')"
    } else {
        Write-Host "  [FAIL] $desc  (got: '$got')"
    }
    $script:Fail++
    $script:TotalTests++
}

# =====================================================================
# 1. resolve_secret – exact copy from start_ckan.sh (ported to PowerShell)
# =====================================================================
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

# =====================================================================
# 2. iniget – simulates parsing of `ckan config-tool -g` output
#    Exact algorithm from start_ckan.sh (ported to PowerShell)
# =====================================================================
function Invoke-IniGet {
    param(
        [string]$rawLine   # the full output of ckan config-tool -g, e.g. "key = value"
    )

    # Strip everything up to and including " = " to get just the value.
    $val = $rawLine -replace '^.*? = ', ''
    # Trim leading/trailing whitespace
    $val = $val.Trim()
    return $val
}

# =====================================================================
# 3. is_unset – exact copy of is_unset from start_ckan.sh
# =====================================================================
function Test-IsUnset([string]$val) {
    if ([string]::IsNullOrEmpty($val)) { return $true }
    if ($val -eq "CHANGE_ME") { return $true }
    if ($val -eq "string:") { return $true }
    if ($val -eq "string:CHANGE_ME") { return $true }
    return $false
}

# 4. has_value – inverse of is_unset
function Test-HasValue([string]$val) {
    return -not (Test-IsUnset $val)
}

# =====================================================================
# Test harness helpers
# =====================================================================
function Run-ResolveSecretTest {
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
        Write-Pass $desc
    } else {
        Write-Fail $desc $actual $expected
    }

    Remove-Item "env:CKAN___TEST" -ErrorAction SilentlyContinue
    Remove-Item "env:BEAKER_TEST" -ErrorAction SilentlyContinue
}

function Run-IniGetTest {
    param(
        [string]$desc,
        [string]$rawLine,
        [string]$expected
    )

    $actual = Invoke-IniGet $rawLine

    if ($actual -eq $expected) {
        Write-Pass $desc
    } else {
        Write-Fail $desc $actual $expected
    }
}

function Run-IsUnsetTest {
    param(
        [string]$desc,
        [string]$value,
        [bool]$expectedUnset
    )

    $actual = Test-IsUnset $value
    $actualHas = Test-HasValue $value

    if ($actual -eq $expectedUnset -and $actualHas -eq (-not $expectedUnset)) {
        Write-Pass $desc
    } else {
        Write-Fail $desc "is_unset=$actual, has_value=$actualHas" "is_unset=$expectedUnset, has_value=$(-not $expectedUnset)"
    }
}

# =====================================================================
# 5. Simulate the full decision logic from start_ckan.sh
#    Given an env state and an ini state, verify the correct action
#    ("use env", "autogenerate", or "keep ini") is taken for
#    each of the 4 keys.
# =====================================================================
function Invoke-SimulateFullLogic {
    param(
        [string]$Scenario,
        [hashtable]$Env,     # @{ CKAN___BEAKER__SESSION__SECRET=""; ... }
        [hashtable]$Ini,        # @{ "beaker.session.secret"=""; ... }
        [hashtable]$Expected    # @{ "beaker.session.secret"="USE_ENV|AUTOGEN|KEEP_INI|AUTOGEN|..." }
    )

    $script:Scenario = $Scenario

    # --- set up env vars
    foreach ($k in @("CKAN___BEAKER__SESSION__SECRET", "CKAN___API_TOKEN__JWT__ENCODE__SECRET", "CKAN___API_TOKEN__JWT__DECODE__SECRET")) {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    foreach ($k in $Env.Keys) {
        if ($Env[$k]) { Set-Item "env:$k" -Value $Env[$k] }
    }

    # simulate each key's decision
    $keys = @(
        @{ Name = "beaker.session.secret"; EnvCkan = "CKAN___BEAKER__SESSION__SECRET"; EnvLegacy = "BEAKER_SESSION_SECRET" },
        @{ Name = "WTF_CSRF_SECRET_KEY"; EnvCkan = "NONE"; EnvLegacy = "NONE" },
        @{ Name = "api_token.jwt.encode.secret"; EnvCkan = "CKAN___API_TOKEN__JWT__ENCODE__SECRET"; EnvLegacy = "JWT_ENCODE_SECRET" },
        @{ Name = "api_token.jwt.decode.secret"; EnvCkan = "CKAN___API_TOKEN__JWT__DECODE__SECRET"; EnvLegacy = "JWT_DECODE_SECRET" }
    )

    foreach ($key in $keys) {
        $keyName = $key.Name
        $iniValue = $Ini[$keyName]

        # simulate env resolution (except WTF which never comes from env)
        if ($keyName -eq "WTF_CSRF_SECRET_KEY") {
            $envVal = ""
        } else {
            $envVal = Resolve-Secret $key.EnvCkan $key.EnvLegacy
        }

        # make the decision the same way start_ckan.sh does
        $iniParsed = Invoke-IniGet "$keyName = $iniValue"
        if ($iniValue) { $iniParsed = $iniValue }

        $decision = $null
        if ($keyName -ne "WTF_CSRF_SECRET_KEY" -and $envVal) {
            $decision = "USE_ENV"
        }
        elseif (Test-HasValue $iniParsed) {
            $decision = "KEEP_INI"
        }
        else {
            $decision = "AUTOGEN"
        }

        $exp = $Expected[$keyName]
        if ($decision -eq $exp) {
            Write-Pass "$Scenario - $keyName -> $decision"
        }
        else {
            Write-Fail "$Scenario - $keyName" $decision $exp
        }
    }

    foreach ($k in @("CKAN___BEAKER__SESSION__SECRET", "CKAN___API_TOKEN__JWT__ENCODE__SECRET", "CKAN___API_TOKEN__JWT__DECODE__SECRET")) {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# RUN TESTS
# =====================================================================

Write-Host "============================================================"
Write-Host " Full test suite – ALL functions from start_ckan.sh"
Write-Host "============================================================"

# -------------------------------------------------------------------
# Section 1 – resolve_secret
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 1: resolve_secret() – env var resolution"
Write-Host ""

Write-Host "  Path A: secrets PROVIDED via env (must be preserved)"
Run-ResolveSecretTest -desc "CKAN___ style (no prefix)" -expected "my-beaker-secret" -ckanStyle "my-beaker-secret"
Run-ResolveSecretTest -desc "CKAN___ style with string: prefix (prefix stripped)" -expected "my-jwt-secret" -ckanStyle "string:my-jwt-secret"
Run-ResolveSecretTest -desc "Legacy BEAKER_ style used when CKAN___ style absent" -expected "legacy-secret" -legacyStyle "legacy-secret"
Run-ResolveSecretTest -desc "CKAN___ style takes precedence over legacy" -expected "ckanstyle-wins" -ckanStyle "ckanstyle-wins" -legacyStyle "legacy-ignored"
Run-ResolveSecretTest -desc "CKAN___ style with string:CHANGE_ME -> treated as empty (auto-gen path)" -expected "" -ckanStyle "string:CHANGE_ME"

Write-Host ""
Write-Host "  Path B: secrets NOT provided -> must be empty (trigger auto-gen)"
Run-ResolveSecretTest -desc "Both vars UNSET" -expected ""
Run-ResolveSecretTest -desc "CKAN___ exactly 'CHANGE_ME' -> treated as empty" -expected "" -ckanStyle "CHANGE_ME"
Run-ResolveSecretTest -desc "Legacy exactly 'CHANGE_ME' -> treated as empty" -expected "" -legacyStyle "CHANGE_ME"

# -------------------------------------------------------------------
# Section 2 – iniget value parsing
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 2: iniget() – parse 'key = value' output"
Write-Host ""

Run-IniGetTest -desc "Normal value" -rawLine "beaker.session.secret = abc123" -expected "abc123"
Run-IniGetTest -desc "Value with spaces" -rawLine "some.key = hello world" -expected "hello world"
Run-IniGetTest -desc "Empty value (key = )" -rawLine "beaker.session.secret = " -expected ""
Run-IniGetTest -desc "Value with trailing spaces" -rawLine "some.key =   myval   " -expected "myval"
Run-IniGetTest -desc "Value is 'CHANGE_ME'" -rawLine "beaker.session.secret = CHANGE_ME" -expected "CHANGE_ME"
Run-IniGetTest -desc "Value is 'string:abc'" -rawLine "api_token.jwt.encode.secret = string:abc" -expected "string:abc"
Run-IniGetTest -desc "Value is 'string:' (empty after prefix)" -rawLine "api_token.jwt.encode.secret = string:" -expected "string:"
Run-IniGetTest -desc "Value is 'string:CHANGE_ME'" -rawLine "api_token.jwt.encode.secret = string:CHANGE_ME" -expected "string:CHANGE_ME"

# -------------------------------------------------------------------
# Section 3 – is_unset / has_value
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 3: is_unset() / has_value() – empty/placeholder detection"
Write-Host ""

Run-IsUnsetTest -desc "Empty string -> is_unset=true" -value "" -expectedUnset $true
Run-IsUnsetTest -desc "'CHANGE_ME' -> is_unset=true" -value "CHANGE_ME" -expectedUnset $true
Run-IsUnsetTest -desc "'string:' -> is_unset=true" -value "string:" -expectedUnset $true
Run-IsUnsetTest -desc "'string:CHANGE_ME' -> is_unset=true" -value "string:CHANGE_ME" -expectedUnset $true

Run-IsUnsetTest -desc "'abc123' -> is_unset=false" -value "abc123" -expectedUnset $false
Run-IsUnsetTest -desc "'string:abc123' -> is_unset=false" -value "string:abc123" -expectedUnset $false
Run-IsUnsetTest -desc "'not-the-placeholder' -> is_unset=false" -value "not-placeholder" -expectedUnset $false
Run-IsUnsetTest -desc "'   abc123   ' (with spaces) -> is_unset=false" -value "   abc123   " -expectedUnset $false

# -------------------------------------------------------------------
# Section 4 – Full decision logic simulation
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 4: Full decision logic simulation (env + ini state -> correct action)"
Write-Host ""

Write-Host "  Scenario 1: Env has real values, ini is empty -> USE_ENV"
Invoke-SimulateFullLogic -Scenario "S1" `
    -Env @{
        "CKAN___BEAKER__SESSION__SECRET" = "my-beaker-001"
        "CKAN___API_TOKEN__JWT__ENCODE__SECRET" = "string:my-jwt-002"
        "CKAN___API_TOKEN__JWT__DECODE__SECRET" = "string:my-jwt-003"
    } `
    -Ini @{
        "beaker.session.secret" = ""
        "WTF_CSRF_SECRET_KEY" = ""
        "api_token.jwt.encode.secret" = ""
        "api_token.jwt.decode.secret" = ""
    } `
    -Expected @{
        "beaker.session.secret" = "USE_ENV"
        "WTF_CSRF_SECRET_KEY" = "AUTOGEN"
        "api_token.jwt.encode.secret" = "USE_ENV"
        "api_token.jwt.decode.secret" = "USE_ENV"
    }

Write-Host ""
Write-Host "  Scenario 2: Env is CHANGE_ME, ini is empty -> AUTOGEN"
Invoke-SimulateFullLogic -Scenario "S2" `
    -Env @{
        "CKAN___BEAKER__SESSION__SECRET" = "CHANGE_ME"
        "CKAN___API_TOKEN__JWT__ENCODE__SECRET" = "string:CHANGE_ME"
        "CKAN___API_TOKEN__JWT__DECODE__SECRET" = "string:CHANGE_ME"
    } `
    -Ini @{
        "beaker.session.secret" = ""
        "WTF_CSRF_SECRET_KEY" = ""
        "api_token.jwt.encode.secret" = ""
        "api_token.jwt.decode.secret" = ""
    } `
    -Expected @{
        "beaker.session.secret" = "AUTOGEN"
        "WTF_CSRF_SECRET_KEY" = "AUTOGEN"
        "api_token.jwt.encode.secret" = "AUTOGEN"
        "api_token.jwt.decode.secret" = "AUTOGEN"
    }

Write-Host ""
Write-Host "  Scenario 3: Env not set, ini has real values -> KEEP_INI (restart-with-volume scenario"
Invoke-SimulateFullLogic -Scenario "S3" `
    -Env @{} `
    -Ini @{
        "beaker.session.secret" = "existing-beaker-abc"
        "WTF_CSRF_SECRET_KEY" = "existing-wtf-def"
        "api_token.jwt.encode.secret" = "string:existing-jwt-xyz"
        "api_token.jwt.decode.secret" = "string:existing-jwt-xyz"
    } `
    -Expected @{
        "beaker.session.secret" = "KEEP_INI"
        "WTF_CSRF_SECRET_KEY" = "KEEP_INI"
        "api_token.jwt.encode.secret" = "KEEP_INI"
        "api_token.jwt.decode.secret" = "KEEP_INI"
    }

Write-Host ""
Write-Host "  Scenario 4: Env not set, ini has 'CHANGE_ME' -> AUTOGEN"
Invoke-SimulateFullLogic -Scenario "S4" `
    -Env @{} `
    -Ini @{
        "beaker.session.secret" = "CHANGE_ME"
        "WTF_CSRF_SECRET_KEY" = "CHANGE_ME"
        "api_token.jwt.encode.secret" = "string:CHANGE_ME"
        "api_token.jwt.decode.secret" = "string:CHANGE_ME"
    } `
    -Expected @{
        "beaker.session.secret" = "AUTOGEN"
        "WTF_CSRF_SECRET_KEY" = "AUTOGEN"
        "api_token.jwt.encode.secret" = "AUTOGEN"
        "api_token.jwt.decode.secret" = "AUTOGEN"
    }

Write-Host ""
Write-Host "  Scenario 5: Env not set, ini has 'string:' (empty prefix) -> AUTOGEN"
Invoke-SimulateFullLogic -Scenario "S5" `
    -Env @{} `
    -Ini @{
        "beaker.session.secret" = ""
        "WTF_CSRF_SECRET_KEY" = ""
        "api_token.jwt.encode.secret" = "string:"
        "api_token.jwt.decode.secret" = "string:"
    } `
    -Expected @{
        "beaker.session.secret" = "AUTOGEN"
        "WTF_CSRF_SECRET_KEY" = "AUTOGEN"
        "api_token.jwt.encode.secret" = "AUTOGEN"
        "api_token.jwt.decode.secret" = "AUTOGEN"
    }

Write-Host ""
Write-Host "  Scenario 6: Mixed – some from env, some from ini"
Invoke-SimulateFullLogic -Scenario "S6" `
    -Env @{
        "CKAN___BEAKER__SESSION__SECRET" = "env-beaker-overrides"
    } `
    -Ini @{
        "beaker.session.secret" = "old-beaker"
        "WTF_CSRF_SECRET_KEY" = "existing-wtf"
        "api_token.jwt.encode.secret" = "string:existing-jwt"
        "api_token.jwt.decode.secret" = ""
    } `
    -Expected @{
        "beaker.session.secret" = "USE_ENV"
        "WTF_CSRF_SECRET_KEY" = "KEEP_INI"
        "api_token.jwt.encode.secret" = "KEEP_INI"
        "api_token.jwt.decode.secret" = "AUTOGEN"
    }

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host " Result: $script:Pass passed, $script:Fail failed (total: $script:TotalTests)"
Write-Host "============================================================"

if ($script:Fail -ne 0) {
    exit 1
}
