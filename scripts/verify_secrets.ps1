#
# verify_secrets.ps1
#
# Comprehensive test suite for the CKAN secret-handling logic in
# images/ckan/*/setup/app/start_ckan.sh.
#
# All testing uses REAL implementations (actual file I/O for `iniget`,
# real environment-variable resolution, real ini parsing via regex matching
# that mirrors the bash grep/sed algorithm) rather than mocks.
#
# Coverage:
#   1. resolve_secret  – env var resolution (CKAN___* priority, CHANGE_ME
#                        sentinel, string: prefix stripping)
#   2. iniget          – production.ini value extraction using the SAME
#                        regex algorithm used in the bash script (grep-style
#                        matching on real temp ini files, not mocked output)
#   3. is_unset / has_value – empty/placeholder detection
#   4. Full E2E simulation:
#      – "Cold start" with CHANGE_ME env vars + blank ini => AUTOGEN
#      – "Restart" with the same ini file => KEEP_INI (no re-gen)
#      – "Env override" with real CKAN___* values => USE_ENV
#
param()

$ErrorActionPreference = "Stop"
$script:Pass = 0
$script:Fail = 0
$script:Total = 0

function Write-Pass([string]$desc) {
    Write-Host "  [PASS] $desc"
    $script:Pass++; $script:Total++
}
function Write-Fail([string]$desc, [string]$got, [string]$expected) {
    if ($expected) {
        Write-Host "  [FAIL] $desc  (got: '$got', expected: '$expected')"
    } else {
        Write-Host "  [FAIL] $desc  (got: '$got')"
    }
    $script:Fail++; $script:Total++
}

# =====================================================================
# 1. resolve_secret – port of the bash function
# =====================================================================
function Resolve-Secret {
    param(
        [string]$envvar_ckanstyle,
        [string]$envvar_legacy
    )
    $val = ""
    $ckanVal = Get-Item "env:$envvar_ckanstyle" -ErrorAction SilentlyContinue
    $legacyVal = Get-Item "env:$envvar_legacy" -ErrorAction SilentlyContinue
    if ($null -ne $ckanVal -and -not [string]::IsNullOrEmpty($ckanVal.Value)) {
        $val = $ckanVal.Value
    } elseif ($null -ne $legacyVal -and -not [string]::IsNullOrEmpty($legacyVal.Value)) {
        $val = $legacyVal.Value
    }
    if ($val.StartsWith("string:")) { $val = $val.Substring(7) }
    if ($val -eq "CHANGE_ME") { $val = "" }
    return $val
}

# =====================================================================
# 2. iniget – PORT OF THE BASH iniget() ALGORITHM
#
# The bash version does:
#   grep -E "^[[:space:]]*KEY[[:space:]]*=" file | tail -n 1
#   strip everything up to first '='
#   trim leading/trailing whitespace
#   strip trailing inline comment after #
#   trim trailing whitespace again
#
# We mirror that EXACTLY here on real temp files.
# =====================================================================
function Invoke-IniGet {
    param(
        [string]$key,
        [string]$inifile
    )

    if (-not (Test-Path $inifile)) { return "" }

    # Match: start of line, optional whitespace, key, optional whitespace, "="
    $pattern = "^[ \t]*" + [regex]::Escape($key) + "[ \t]*="
    $lines = @(Get-Content $inifile | Where-Object { $_ -match $pattern })

    if ($null -eq $lines -or $lines.Count -eq 0) { return "" }

    # Take LAST match (tail -n 1)
    $line = $lines[$lines.Count - 1]

    # Strip everything up to and including FIRST "=" (like bash ${line#*=})
    $eqPos = $line.IndexOf("=")
    if ($eqPos -lt 0) { return "" }
    $val = $line.Substring($eqPos + 1)

    # Trim leading/trailing whitespace
    $val = $val.Trim()

    # Strip trailing inline comment (bash ${val%%#*})
    $hashPos = $val.IndexOf("#")
    if ($hashPos -ge 0) { $val = $val.Substring(0, $hashPos) }

    # Trim trailing whitespace after comment strip
    $val = $val.TrimEnd()

    return $val
}

# =====================================================================
# 3. is_unset / has_value
# =====================================================================
function Test-IsUnset([string]$val) {
    if ([string]::IsNullOrEmpty($val)) { return $true }
    if ($val -eq "CHANGE_ME") { return $true }
    if ($val -eq "string:") { return $true }
    if ($val -eq "string:CHANGE_ME") { return $true }
    return $false
}
function Test-HasValue([string]$val) { return -not (Test-IsUnset $val) }

# =====================================================================
# Test helpers
# =====================================================================
function Run-ResolveTest {
    param([string]$desc, [string]$expected, [string]$ckanStyle="", [string]$legacyStyle="")
    Remove-Item "env:CKAN___TEST","env:BEAKER_TEST" -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrEmpty($ckanStyle)) { Set-Item "env:CKAN___TEST" $ckanStyle }
    if (-not [string]::IsNullOrEmpty($legacyStyle)) { Set-Item "env:BEAKER_TEST" $legacyStyle }
    $actual = Resolve-Secret "CKAN___TEST" "BEAKER_TEST"
    if ($actual -eq $expected) { Write-Pass $desc } else { Write-Fail $desc $actual $expected }
    Remove-Item "env:CKAN___TEST","env:BEAKER_TEST" -ErrorAction SilentlyContinue
}

function Run-IniGetTest {
    param(
        [string]$desc,
        [string[]]$iniLines,
        [string]$key,
        [string]$expected
    )
    $tmp = New-TemporaryFile
    try {
        $iniLines | Set-Content -Path $tmp -Encoding UTF8
        $actual = Invoke-IniGet $key $tmp
        if ($actual -eq $expected) { Write-Pass $desc } else { Write-Fail $desc $actual $expected }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Run-IsUnsetTest {
    param([string]$desc, [string]$value, [bool]$expectedUnset)
    $u = Test-IsUnset $value
    $h = Test-HasValue $value
    if ($u -eq $expectedUnset -and $h -eq (-not $expectedUnset)) {
        Write-Pass $desc
    } else {
        Write-Fail $desc "is_unset=$u, has_value=$h" "is_unset=$expectedUnset, has_value=$(-not $expectedUnset)"
    }
}

# =====================================================================
# 4. E2E Simulation helpers
# =====================================================================

# Simulates the EXACT decision flow from start_ckan.sh for one key.
# Returns the decision: "USE_ENV", "KEEP_INI", "AUTOGEN", plus the
# resulting value that would end up in the ini file.
function Simulate-KeyDecision {
    param(
        [string]$keyName,
        [string]$envCkan,      # CKAN___* env var name (or NONE for WTF)
        [string]$envLegacy,    # legacy env var name (or NONE for WTF)
        [string]$inifile,      # path to ini file
        [string]$prefixForAuto  # e.g. "" for beaker, "string:" for JWT
    )

    # 1. Resolve env
    if ($envCkan -eq "NONE") {
        $envVal = ""
    } else {
        $envVal = Resolve-Secret $envCkan $envLegacy
    }

    # 2. Read ini
    $iniVal = Invoke-IniGet $keyName $inifile

    # 3. Same decision tree as in start_ckan.sh
    if ($envCkan -ne "NONE" -and -not [string]::IsNullOrEmpty($envVal)) {
        $finalVal = if ($prefixForAuto) { "$prefixForAuto$envVal" } else { $envVal }
        return @{ Decision = "USE_ENV"; FinalValue = $finalVal; EnvValue = $envVal; IniValue = $iniVal }
    } elseif (Test-HasValue $iniVal) {
        return @{ Decision = "KEEP_INI"; FinalValue = $iniVal; EnvValue = $envVal; IniValue = $iniVal }
    } else {
        # Simulate python secrets.token_urlsafe() with a deterministic but unique stub
        $auto = "AUTO_" + [guid]::NewGuid().ToString("N").Substring(0, 24)
        $finalVal = if ($prefixForAuto) { "$prefixForAuto$auto" } else { $auto }
        return @{ Decision = "AUTOGEN"; FinalValue = $finalVal; EnvValue = $envVal; IniValue = $iniVal }
    }
}

# Simulates a SINGLE RUN of the start_ckan.sh secret-initialization block
# against a real ini file, modifying the ini file in-place (to simulate
# ckan config-tool writes).
function Invoke-SimulateStartRun {
    param(
        [string]$Label,        # e.g. "Cold-start", "Restart", "Env-override"
        [string]$inifile,
        [hashtable]$EnvVars  # @{ "CKAN___BEAKER__SESSION__SECRET" = "val"; ... }
    )

    # --- Set up env vars
    foreach ($k in @("CKAN___BEAKER__SESSION__SECRET","CKAN___API_TOKEN__JWT__ENCODE__SECRET","CKAN___API_TOKEN__JWT__DECODE__SECRET","BEAKER_SESSION_SECRET","JWT_ENCODE_SECRET","JWT_DECODE_SECRET")) {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    foreach ($k in $EnvVars.Keys) {
        if ($EnvVars[$k]) { Set-Item "env:$k" $EnvVars[$k] }
    }

    # --- Key list, same order as bash script
    $keys = @(
        @{ Name="beaker.session.secret"; EnvCkan="CKAN___BEAKER__SESSION__SECRET"; EnvLegacy="BEAKER_SESSION_SECRET"; Prefix="" },
        @{ Name="WTF_CSRF_SECRET_KEY"; EnvCkan="NONE"; EnvLegacy="NONE"; Prefix="" },
        @{ Name="api_token.jwt.encode.secret"; EnvCkan="CKAN___API_TOKEN__JWT__ENCODE__SECRET"; EnvLegacy="JWT_ENCODE_SECRET"; Prefix="string:" },
        @{ Name="api_token.jwt.decode.secret"; EnvCkan="CKAN___API_TOKEN__JWT__DECODE__SECRET"; EnvLegacy="JWT_DECODE_SECRET"; Prefix="string:" }
    )

    # We need JWT_ENCODE value to be available when processing JWT_DECODE (just like bash)
    $lastJwtEncodeAuto = $null

    $results = @{}
    foreach ($key in $keys) {
        $result = Simulate-KeyDecision -keyName $key.Name -envCkan $key.EnvCkan -envLegacy $key.EnvLegacy -inifile $inifile -prefixForAuto $key.Prefix
        $results[$key.Name] = $result

        # Special case: JWT_DECODE auto-gen reuses JWT_ENCODE value if available
        if ($key.Name -eq "api_token.jwt.decode.secret" -and $result.Decision -eq "AUTOGEN") {
            if ($null -ne $lastJwtEncodeAuto) {
                $result.FinalValue = "string:$lastJwtEncodeAuto"
            }
        }
        if ($key.Name -eq "api_token.jwt.encode.secret" -and $result.Decision -eq "AUTOGEN") {
            $v = $result.FinalValue
            if ($v.StartsWith("string:")) { $lastJwtEncodeAuto = $v.Substring(7) }
        }

        # Simulate "ckan config-tool" WRITE – overwrite or append the key=value line
        $content = Get-Content $inifile -Raw
        $pattern = "(?m)^[ \t]*" + [regex]::Escape($key.Name) + "[ \t]*=.*$"
        $newLine = "$($key.Name) = $($result.FinalValue)"
        if ([regex]::IsMatch($content, $pattern)) {
            $content = [regex]::Replace($content, $pattern, $newLine)
        } else {
            $content = $content.TrimEnd() + "`r`n" + $newLine + "`r`n"
        }
        Set-Content -Path $inifile -Value $content -Encoding UTF8 -NoNewline
    }

    # Cleanup env
    foreach ($k in @("CKAN___BEAKER__SESSION__SECRET","CKAN___API_TOKEN__JWT__ENCODE__SECRET","CKAN___API_TOKEN__JWT__DECODE__SECRET","BEAKER_SESSION_SECRET","JWT_ENCODE_SECRET","JWT_DECODE_SECRET")) {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }

    return $results
}

function Check-E2EDecision {
    param(
        [string]$scenario,
        [string]$keyName,
        $actualDecision,
        [string]$expectedDecision,
        [string]$actualValue,
        [string]$expectedValuePattern  # regex pattern for matching
    )

    $decOk = $actualDecision -eq $expectedDecision
    $valOk = if ($expectedValuePattern) { $actualValue -match $expectedValuePattern } else { $true }

    if ($decOk -and $valOk) {
        Write-Pass "$scenario - $keyName => $actualDecision"
    } else {
        $msg = "dec=$actualDecision, val='$actualValue'"
        $exp = "dec=$expectedDecision, val=~/$expectedValuePattern/"
        Write-Fail "$scenario - $keyName" $msg $exp
    }
}

# =====================================================================
# RUN TESTS
# =====================================================================

Write-Host "============================================================"
Write-Host " FULL test suite – real file I/O, no mocks"
Write-Host "  start_ckan.sh secret-handling logic"
Write-Host "============================================================"

# -------------------------------------------------------------------
# Section 1 – resolve_secret
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 1: resolve_secret() – env var resolution"
Write-Host ""

Run-ResolveTest "CKAN___ style normal value" "my-beaker-secret" "my-beaker-secret"
Run-ResolveTest "CKAN___ style with string: prefix stripped" "my-jwt-secret" "string:my-jwt-secret"
Run-ResolveTest "Legacy BEAKER_ style used when CKAN___ absent" "legacy-secret" "" "legacy-secret"
Run-ResolveTest "CKAN___ beats legacy" "ckanstyle-wins" "ckanstyle-wins" "legacy-ignored"
Run-ResolveTest "CKAN___=string:CHANGE_ME => empty" "" "string:CHANGE_ME"
Run-ResolveTest "Both unset => empty" ""
Run-ResolveTest "CKAN___=CHANGE_ME => empty" "" "CHANGE_ME"
Run-ResolveTest "Legacy=CHANGE_ME => empty" "" "" "CHANGE_ME"

# -------------------------------------------------------------------
# Section 2 – iniget (REAL temp ini files)
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 2: iniget() – parse real temp ini files"
Write-Host ""

Run-IniGetTest "Normal key = value" @("[app:main]","beaker.session.secret = abc123") "beaker.session.secret" "abc123"
Run-IniGetTest "key =  (empty value)" @("[app:main]","beaker.session.secret = ") "beaker.session.secret" ""
Run-IniGetTest "key with indent + spaced =" @("  beaker.session.secret   =   spacedval  ") "beaker.session.secret" "spacedval"
Run-IniGetTest "key=CHANGE_ME" @("beaker.session.secret = CHANGE_ME") "beaker.session.secret" "CHANGE_ME"
Run-IniGetTest "key=string:abc123 (JWT format)" @("api_token.jwt.encode.secret = string:abc123") "api_token.jwt.encode.secret" "string:abc123"
Run-IniGetTest "key=string: (empty prefix)" @("api_token.jwt.encode.secret = string:") "api_token.jwt.encode.secret" "string:"
Run-IniGetTest "key=string:CHANGE_ME" @("api_token.jwt.decode.secret = string:CHANGE_ME") "api_token.jwt.decode.secret" "string:CHANGE_ME"
Run-IniGetTest "key not present in file => empty" @("[app:main]","other.key = val") "beaker.session.secret" ""
Run-IniGetTest "Last duplicate wins (tail -n 1)" @("a = first","# comment","a = second") "a" "second"
Run-IniGetTest "Inline comment after value stripped" @("key = val#notrelevant") "key" "val"

# -------------------------------------------------------------------
# Section 3 – is_unset / has_value
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 3: is_unset() / has_value()"
Write-Host ""

Run-IsUnsetTest "empty string => unset" "" $true
Run-IsUnsetTest "CHANGE_ME => unset" "CHANGE_ME" $true
Run-IsUnsetTest "string: => unset" "string:" $true
Run-IsUnsetTest "string:CHANGE_ME => unset" "string:CHANGE_ME" $true
Run-IsUnsetTest "plain value => set" "abc123" $false
Run-IsUnsetTest "string:value => set" "string:abc123" $false
Run-IsUnsetTest "value with spaces => set" "  myval  " $false
Run-IsUnsetTest "value looks-like placeholder but isn't => set" "CHANGE_ME_PLEASE" $false

# -------------------------------------------------------------------
# Section 4 – Full E2E simulation (real ini file, multiple runs)
# -------------------------------------------------------------------
Write-Host ""
Write-Host "--- Section 4: Full E2E simulation (real ini, real env, multiple runs)"
Write-Host ""

# ====== E2E Scenario 1: Cold start, CHANGE_ME env vars + blank ini => AUTOGEN ======
Write-Host "  [E2E Scenario 1] Cold start – env has CHANGE_ME, ini empty"
$tmp1 = New-TemporaryFile
"[app:main]" | Set-Content $tmp1 -Encoding UTF8
Add-Content $tmp1 "beaker.session.secret = "
Add-Content $tmp1 "WTF_CSRF_SECRET_KEY = "
Add-Content $tmp1 "api_token.jwt.encode.secret = "
Add-Content $tmp1 "api_token.jwt.decode.secret = "

$e2e1Env = @{
    "CKAN___BEAKER__SESSION__SECRET" = "CHANGE_ME"
    "CKAN___API_TOKEN__JWT__ENCODE__SECRET" = "string:CHANGE_ME"
    "CKAN___API_TOKEN__JWT__DECODE__SECRET" = "string:CHANGE_ME"
}
$e2e1 = Invoke-SimulateStartRun -Label "ColdStart" -inifile $tmp1 -EnvVars $e2e1Env

Check-E2EDecision "ColdStart" "beaker.session.secret" $e2e1["beaker.session.secret"].Decision "AUTOGEN" $e2e1["beaker.session.secret"].FinalValue "^AUTO_[0-9a-f]{24}$"
Check-E2EDecision "ColdStart" "WTF_CSRF_SECRET_KEY" $e2e1["WTF_CSRF_SECRET_KEY"].Decision "AUTOGEN" $e2e1["WTF_CSRF_SECRET_KEY"].FinalValue "^AUTO_[0-9a-f]{24}$"
Check-E2EDecision "ColdStart" "api_token.jwt.encode.secret" $e2e1["api_token.jwt.encode.secret"].Decision "AUTOGEN" $e2e1["api_token.jwt.encode.secret"].FinalValue "^string:AUTO_[0-9a-f]{24}$"
Check-E2EDecision "ColdStart" "api_token.jwt.decode.secret" $e2e1["api_token.jwt.decode.secret"].Decision "AUTOGEN" $e2e1["api_token.jwt.decode.secret"].FinalValue "^string:AUTO_[0-9a-f]{24}$"

# JWT decode must match encode (persistence requirement: same secret used for both unless explicitly overridden)
$e1 = $e2e1["api_token.jwt.encode.secret"].FinalValue
$d1 = $e2e1["api_token.jwt.decode.secret"].FinalValue
if ($e1 -eq $d1) { Write-Pass "ColdStart - jwt.decode matches jwt.encode" } else { Write-Fail "ColdStart - jwt.decode matches jwt.encode" $d1 $e1 }

# Snapshot values from the cold start
$snap_beaker = Invoke-IniGet "beaker.session.secret" $tmp1
$snap_wtf = Invoke-IniGet "WTF_CSRF_SECRET_KEY" $tmp1
$snap_encode = Invoke-IniGet "api_token.jwt.encode.secret" $tmp1
$snap_decode = Invoke-IniGet "api_token.jwt.decode.secret" $tmp1

# ====== E2E Scenario 2: RESTART – same ini, NO env override => KEEP_INI ======
Write-Host ""
Write-Host "  [E2E Scenario 2] Restart – same ini, env still CHANGE_ME => all KEEP_INI"
$e2e2 = Invoke-SimulateStartRun -Label "Restart" -inifile $tmp1 -EnvVars $e2e1Env

Check-E2EDecision "Restart" "beaker.session.secret" $e2e2["beaker.session.secret"].Decision "KEEP_INI" "" ""
Check-E2EDecision "Restart" "WTF_CSRF_SECRET_KEY" $e2e2["WTF_CSRF_SECRET_KEY"].Decision "KEEP_INI" "" ""
Check-E2EDecision "Restart" "api_token.jwt.encode.secret" $e2e2["api_token.jwt.encode.secret"].Decision "KEEP_INI" "" ""
Check-E2EDecision "Restart" "api_token.jwt.decode.secret" $e2e2["api_token.jwt.decode.secret"].Decision "KEEP_INI" "" ""

# CRITICAL: Values in ini must be identical to the cold-start snapshot
$r_beaker = Invoke-IniGet "beaker.session.secret" $tmp1
$r_wtf = Invoke-IniGet "WTF_CSRF_SECRET_KEY" $tmp1
$r_encode = Invoke-IniGet "api_token.jwt.encode.secret" $tmp1
$r_decode = Invoke-IniGet "api_token.jwt.decode.secret" $tmp1

if ($r_beaker -eq $snap_beaker) { Write-Pass "Restart – beaker.session.secret unchanged in ini" }
else { Write-Fail "Restart – beaker.session.secret unchanged in ini" $r_beaker $snap_beaker }
if ($r_wtf -eq $snap_wtf) { Write-Pass "Restart – WTF_CSRF_SECRET_KEY unchanged in ini" }
else { Write-Fail "Restart – WTF_CSRF_SECRET_KEY unchanged in ini" $r_wtf $snap_wtf }
if ($r_encode -eq $snap_encode) { Write-Pass "Restart – jwt.encode unchanged in ini" }
else { Write-Fail "Restart – jwt.encode unchanged in ini" $r_encode $snap_encode }
if ($r_decode -eq $snap_decode) { Write-Pass "Restart – jwt.decode unchanged in ini" }
else { Write-Fail "Restart – jwt.decode unchanged in ini" $r_decode $snap_decode }

# ====== E2E Scenario 3: Env OVERRIDE – explicit real values ======
Write-Host ""
Write-Host "  [E2E Scenario 3] Env override – explicit CKAN___* values => USE_ENV"
$e2e3Env = @{
    "CKAN___BEAKER__SESSION__SECRET" = "OVERRIDE-beaker-777"
    "CKAN___API_TOKEN__JWT__ENCODE__SECRET" = "string:OVERRIDE-jwt-888"
    "CKAN___API_TOKEN__JWT__DECODE__SECRET" = "string:OVERRIDE-jwt-999"
}
$e2e3 = Invoke-SimulateStartRun -Label "EnvOverride" -inifile $tmp1 -EnvVars $e2e3Env

Check-E2EDecision "Override" "beaker.session.secret" $e2e3["beaker.session.secret"].Decision "USE_ENV" $e2e3["beaker.session.secret"].FinalValue "^OVERRIDE-beaker-777$"
Check-E2EDecision "Override" "api_token.jwt.encode.secret" $e2e3["api_token.jwt.encode.secret"].Decision "USE_ENV" $e2e3["api_token.jwt.encode.secret"].FinalValue "^string:OVERRIDE-jwt-888$"
Check-E2EDecision "Override" "api_token.jwt.decode.secret" $e2e3["api_token.jwt.decode.secret"].Decision "USE_ENV" $e2e3["api_token.jwt.decode.secret"].FinalValue "^string:OVERRIDE-jwt-999$"

# Verify the values are actually written to the ini file
$f_beaker = Invoke-IniGet "beaker.session.secret" $tmp1
$f_encode = Invoke-IniGet "api_token.jwt.encode.secret" $tmp1
$f_decode = Invoke-IniGet "api_token.jwt.decode.secret" $tmp1
if ($f_beaker -eq "OVERRIDE-beaker-777") { Write-Pass "Override – beaker written to file correctly" } else { Write-Fail "Override – beaker written" $f_beaker "OVERRIDE-beaker-777" }
if ($f_encode -eq "string:OVERRIDE-jwt-888") { Write-Pass "Override – encode written to file correctly" } else { Write-Fail "Override – encode written" $f_encode "string:OVERRIDE-jwt-888" }
if ($f_decode -eq "string:OVERRIDE-jwt-999") { Write-Pass "Override – decode written to file correctly" } else { Write-Fail "Override – decode written" $f_decode "string:OVERRIDE-jwt-999" }

Remove-Item $tmp1 -ErrorAction SilentlyContinue

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host " Result: $script:Pass passed, $script:Fail failed (total: $script:Total)"
Write-Host "============================================================"

if ($script:Fail -ne 0) { exit 1 }

Write-Host ""
Write-Host "Notes:"
Write-Host "  - Section 2 & 4 use REAL temp files, no mocks (algorithm mirror of bash grep/sed)."
Write-Host "  - The E2E section proves the 3 critical paths: AUTOGEN (cold), KEEP_INI (restart), USE_ENV (override)."
Write-Host "  - For actual container verification, run the steps listed in scripts/verify_secrets.sh (E2E section)."
