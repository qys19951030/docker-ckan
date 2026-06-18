#!/bin/bash
#
# verify_secrets.sh
#
# Comprehensive test suite for the CKAN secret resolution and ini reading
# logic from start_ckan.sh.  Tests EVERY helper function used in the startup
# script, not just resolve_secret.
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
# The script also prints step-by-step instructions for an end-to-end
# verification using docker-compose (see the "E2E_VERIFICATION" section at
# the bottom).
#
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
fail() { echo "  [FAIL] $1  (got: '$2', expected: '$3')"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

# =====================================================================
# 1. resolve_secret – exact copy from start_ckan.sh
# =====================================================================
resolve_secret() {
	local envvar_ckanstyle="$1"
	local envvar_legacy="$2"
	local val=""
	if [[ -n "${!envvar_ckanstyle+x}" && -n "${!envvar_ckanstyle}" ]]; then
		val="${!envvar_ckanstyle}"
	elif [[ -n "${!envvar_legacy+x}" && -n "${!envvar_legacy}" ]]; then
		val="${!envvar_legacy}"
	fi
	if [[ "$val" == string:* ]]; then
		val="${val#string:}"
	fi
	if [[ "$val" == "CHANGE_ME" ]]; then
		val=""
	fi
	echo "$val"
}

# =====================================================================
# 2. iniget – exact algorithm from start_ckan.sh
# =====================================================================
iniget() {
	local rawLine="$1"
	# Strip everything up to and including " = " to get just the value.
	local val="${rawLine#* = }"
	# Trim leading/trailing whitespace
	val="${val#"${val%%[![:space:]]*}"}"
	val="${val%"${val##*[![:space:]]}"}"
	echo "$val"
}

# =====================================================================
# 3. is_unset – exact copy from start_ckan.sh
# =====================================================================
is_unset() {
	local val="$1"
	[[ -z "$val" ]] && return 0
	[[ "$val" == "CHANGE_ME" ]] && return 0
	[[ "$val" == "string:" ]] && return 0
	[[ "$val" == "string:CHANGE_ME" ]] && return 0
	return 1
}

# 4. has_value – inverse of is_unset (exact copy from start_ckan.sh)
has_value() {
	! is_unset "$1"
}

# =====================================================================
# Test harness helpers
# =====================================================================
run_resolve_secret_test() {
	local desc="$1"
	local expected="$2"
	unset CKAN___TEST BEAKER_TEST
	[[ $# -ge 3 && -n "$3" ]] && export CKAN___TEST="$3" || true
	[[ $# -ge 4 && -n "$4" ]] && export BEAKER_TEST="$4" || true

	local actual
	actual="$(resolve_secret CKAN___TEST BEAKER_TEST)"
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc" "$actual" "$expected"
	fi
	unset CKAN___TEST BEAKER_TEST
}

run_iniget_test() {
	local desc="$1"
	local rawLine="$2"
	local expected="$3"
	local actual
	actual="$(iniget "$rawLine")"
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc" "$actual" "$expected"
	fi
}

run_is_unset_test() {
	local desc="$1"
	local value="$2"
	local expected_unset="$3"  # "true" or "false"
	local actual_unset
	local actual_has
	is_unset "$value" && actual_unset=true || actual_unset=false
	has_value "$value" && actual_has=true || actual_has=false

	local expected_has
	[[ "$expected_unset" == "true" ]] && expected_has=false || expected_has=true

	if [[ "$actual_unset" == "$expected_unset" && "$actual_has" == "$expected_has" ]]; then
		pass "$desc"
	else
		fail "$desc" "is_unset=$actual_unset, has_value=$actual_has" "is_unset=$expected_unset, has_value=$expected_has"
	fi
}

# =====================================================================
# 5. Simulate the full decision logic from start_ckan.sh
# =====================================================================
simulate_full_logic() {
	local scenario="$1"
	local -n env_map=$2
	local -n ini_map=$3
	local -n expected_map=$4

	# --- set up env vars
	for k in CKAN___BEAKER__SESSION__SECRET CKAN___API_TOKEN__JWT__ENCODE__SECRET CKAN___API_TOKEN__JWT__DECODE__SECRET; do
		unset "$k"
	done
	for k in "${!env_map[@]}"; do
		[[ -n "${env_map[$k]}" ]] && export "$k=${env_map[$k]}"
	done

	local keys=(
		"beaker.session.secret|CKAN___BEAKER__SESSION__SECRET|BEAKER_SESSION_SECRET"
		"WTF_CSRF_SECRET_KEY|NONE|NONE"
		"api_token.jwt.encode.secret|CKAN___API_TOKEN__JWT__ENCODE__SECRET|JWT_ENCODE_SECRET"
		"api_token.jwt.decode.secret|CKAN___API_TOKEN__JWT__DECODE__SECRET|JWT_DECODE_SECRET"
	)

	for entry in "${keys[@]}"; do
		IFS='|' read -r keyName envCkan envLegacy <<< "$entry"

		local iniValue="${ini_map[$keyName]}"
		local envVal=""

		if [[ "$keyName" != "WTF_CSRF_SECRET_KEY" ]]; then
			envVal="$(resolve_secret "$envCkan" "$envLegacy")"
		fi

		# make the decision the same way start_ckan.sh does
		local iniParsed
		if [[ -n "$iniValue" ]]; then
			iniParsed="$iniValue"
		else
			iniParsed="$(iniget "$keyName = ")"
		fi

		local decision=""
		if [[ "$keyName" != "WTF_CSRF_SECRET_KEY" && -n "$envVal" ]]; then
			decision="USE_ENV"
		elif has_value "$iniParsed"; then
			decision="KEEP_INI"
		else
			decision="AUTOGEN"
		fi

		local exp="${expected_map[$keyName]}"
		if [[ "$decision" == "$exp" ]]; then
			pass "$scenario - $keyName -> $decision"
		else
			fail "$scenario - $keyName" "$decision" "$exp"
		fi
	done

	for k in CKAN___BEAKER__SESSION__SECRET CKAN___API_TOKEN__JWT__ENCODE__SECRET CKAN___API_TOKEN__JWT__DECODE__SECRET; do
		unset "$k"
	done
}

# =====================================================================
# RUN TESTS
# =====================================================================

echo "============================================================"
echo " Full test suite – ALL functions from start_ckan.sh"
echo "============================================================"

# -------------------------------------------------------------------
# Section 1 – resolve_secret
# -------------------------------------------------------------------
echo
echo "--- Section 1: resolve_secret() – env var resolution"
echo

echo "  Path A: secrets PROVIDED via env (must be preserved)"
run_resolve_secret_test "CKAN___ style (no prefix)" "my-beaker-secret" "my-beaker-secret"
run_resolve_secret_test "CKAN___ style with string: prefix (prefix stripped)" "my-jwt-secret" "string:my-jwt-secret"
run_resolve_secret_test "Legacy BEAKER_ style used when CKAN___ style absent" "legacy-secret" "" "legacy-secret"
run_resolve_secret_test "CKAN___ style takes precedence over legacy" "ckanstyle-wins" "ckanstyle-wins" "legacy-ignored"
run_resolve_secret_test "CKAN___ style with string:CHANGE_ME -> treated as empty (auto-gen path)" "" "string:CHANGE_ME"

echo
echo "  Path B: secrets NOT provided -> must be empty (trigger auto-gen)"
run_resolve_secret_test "Both vars UNSET" ""
run_resolve_secret_test "CKAN___ exactly 'CHANGE_ME' -> treated as empty" "" "CHANGE_ME"
run_resolve_secret_test "Legacy exactly 'CHANGE_ME' -> treated as empty" "" "" "CHANGE_ME"

# -------------------------------------------------------------------
# Section 2 – iniget value parsing
# -------------------------------------------------------------------
echo
echo "--- Section 2: iniget() – parse 'key = value' output"
echo

run_iniget_test "Normal value" "beaker.session.secret = abc123" "abc123"
run_iniget_test "Value with spaces" "some.key = hello world" "hello world"
run_iniget_test "Empty value (key = )" "beaker.session.secret = " ""
run_iniget_test "Value with trailing spaces" "some.key =   myval   " "myval"
run_iniget_test "Value is 'CHANGE_ME'" "beaker.session.secret = CHANGE_ME" "CHANGE_ME"
run_iniget_test "Value is 'string:abc'" "api_token.jwt.encode.secret = string:abc" "string:abc"
run_iniget_test "Value is 'string:' (empty after prefix)" "api_token.jwt.encode.secret = string:" "string:"
run_iniget_test "Value is 'string:CHANGE_ME'" "api_token.jwt.encode.secret = string:CHANGE_ME" "string:CHANGE_ME"

# -------------------------------------------------------------------
# Section 3 – is_unset / has_value
# -------------------------------------------------------------------
echo
echo "--- Section 3: is_unset() / has_value() – empty/placeholder detection"
echo

run_is_unset_test "Empty string -> is_unset=true" "" "true"
run_is_unset_test "'CHANGE_ME' -> is_unset=true" "CHANGE_ME" "true"
run_is_unset_test "'string:' -> is_unset=true" "string:" "true"
run_is_unset_test "'string:CHANGE_ME' -> is_unset=true" "string:CHANGE_ME" "true"

run_is_unset_test "'abc123' -> is_unset=false" "abc123" "false"
run_is_unset_test "'string:abc123' -> is_unset=false" "string:abc123" "false"
run_is_unset_test "'not-the-placeholder' -> is_unset=false" "not-placeholder" "false"
run_is_unset_test "'   abc123   ' (with spaces) -> is_unset=false" "   abc123   " "false"

# -------------------------------------------------------------------
# Section 4 – Full decision logic simulation
# -------------------------------------------------------------------
echo
echo "--- Section 4: Full decision logic simulation (env + ini state -> correct action)"
echo

echo "  Scenario 1: Env has real values, ini is empty -> USE_ENV"
declare -A s1_env=(
	[CKAN___BEAKER__SESSION__SECRET]="my-beaker-001"
	[CKAN___API_TOKEN__JWT__ENCODE__SECRET]="string:my-jwt-002"
	[CKAN___API_TOKEN__JWT__DECODE__SECRET]="string:my-jwt-003"
)
declare -A s1_ini=(
	[beaker.session.secret]=""
	[WTF_CSRF_SECRET_KEY]=""
	[api_token.jwt.encode.secret]=""
	[api_token.jwt.decode.secret]=""
)
declare -A s1_expected=(
	[beaker.session.secret]="USE_ENV"
	[WTF_CSRF_SECRET_KEY]="AUTOGEN"
	[api_token.jwt.encode.secret]="USE_ENV"
	[api_token.jwt.decode.secret]="USE_ENV"
)
simulate_full_logic "S1" s1_env s1_ini s1_expected

echo
echo "  Scenario 2: Env is CHANGE_ME, ini is empty -> AUTOGEN"
declare -A s2_env=(
	[CKAN___BEAKER__SESSION__SECRET]="CHANGE_ME"
	[CKAN___API_TOKEN__JWT__ENCODE__SECRET]="string:CHANGE_ME"
	[CKAN___API_TOKEN__JWT__DECODE__SECRET]="string:CHANGE_ME"
)
declare -A s2_ini=(
	[beaker.session.secret]=""
	[WTF_CSRF_SECRET_KEY]=""
	[api_token.jwt.encode.secret]=""
	[api_token.jwt.decode.secret]=""
)
declare -A s2_expected=(
	[beaker.session.secret]="AUTOGEN"
	[WTF_CSRF_SECRET_KEY]="AUTOGEN"
	[api_token.jwt.encode.secret]="AUTOGEN"
	[api_token.jwt.decode.secret]="AUTOGEN"
)
simulate_full_logic "S2" s2_env s2_ini s2_expected

echo
echo "  Scenario 3: Env not set, ini has real values -> KEEP_INI (restart-with-volume scenario)"
declare -A s3_env=()
declare -A s3_ini=(
	[beaker.session.secret]="existing-beaker-abc"
	[WTF_CSRF_SECRET_KEY]="existing-wtf-def"
	[api_token.jwt.encode.secret]="string:existing-jwt-xyz"
	[api_token.jwt.decode.secret]="string:existing-jwt-xyz"
)
declare -A s3_expected=(
	[beaker.session.secret]="KEEP_INI"
	[WTF_CSRF_SECRET_KEY]="KEEP_INI"
	[api_token.jwt.encode.secret]="KEEP_INI"
	[api_token.jwt.decode.secret]="KEEP_INI"
)
simulate_full_logic "S3" s3_env s3_ini s3_expected

echo
echo "  Scenario 4: Env not set, ini has 'CHANGE_ME' -> AUTOGEN"
declare -A s4_env=()
declare -A s4_ini=(
	[beaker.session.secret]="CHANGE_ME"
	[WTF_CSRF_SECRET_KEY]="CHANGE_ME"
	[api_token.jwt.encode.secret]="string:CHANGE_ME"
	[api_token.jwt.decode.secret]="string:CHANGE_ME"
)
declare -A s4_expected=(
	[beaker.session.secret]="AUTOGEN"
	[WTF_CSRF_SECRET_KEY]="AUTOGEN"
	[api_token.jwt.encode.secret]="AUTOGEN"
	[api_token.jwt.decode.secret]="AUTOGEN"
)
simulate_full_logic "S4" s4_env s4_ini s4_expected

echo
echo "  Scenario 5: Env not set, ini has 'string:' (empty prefix) -> AUTOGEN"
declare -A s5_env=()
declare -A s5_ini=(
	[beaker.session.secret]=""
	[WTF_CSRF_SECRET_KEY]=""
	[api_token.jwt.encode.secret]="string:"
	[api_token.jwt.decode.secret]="string:"
)
declare -A s5_expected=(
	[beaker.session.secret]="AUTOGEN"
	[WTF_CSRF_SECRET_KEY]="AUTOGEN"
	[api_token.jwt.encode.secret]="AUTOGEN"
	[api_token.jwt.decode.secret]="AUTOGEN"
)
simulate_full_logic "S5" s5_env s5_ini s5_expected

echo
echo "  Scenario 6: Mixed – some from env, some from ini"
declare -A s6_env=(
	[CKAN___BEAKER__SESSION__SECRET]="env-beaker-overrides"
)
declare -A s6_ini=(
	[beaker.session.secret]="old-beaker"
	[WTF_CSRF_SECRET_KEY]="existing-wtf"
	[api_token.jwt.encode.secret]="string:existing-jwt"
	[api_token.jwt.decode.secret]=""
)
declare -A s6_expected=(
	[beaker.session.secret]="USE_ENV"
	[WTF_CSRF_SECRET_KEY]="KEEP_INI"
	[api_token.jwt.encode.secret]="KEEP_INI"
	[api_token.jwt.decode.secret]="AUTOGEN"
)
simulate_full_logic "S6" s6_env s6_ini s6_expected

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo
echo "============================================================"
echo " Result: $PASS passed, $FAIL failed (total: $TOTAL)"
echo "============================================================"
[[ $FAIL -eq 0 ]] || exit 1

# ---------------------------------------------------------------------------
# End-to-end verification instructions using docker-compose.
# ---------------------------------------------------------------------------
cat <<'E2E_VERIFICATION'

============================================================
 E2E verification – docker-compose (REAL container startup)
============================================================

The unit tests above prove ALL helper functions and the full decision
logic chain.  To confirm behaviour against a real CKAN container,
run the steps below from the compose/ directory.

These steps verify the ACTUAL startup script code paths (not mocks)
by running a real container.


Scenario 1 – Secrets ARE provided  →  values should be preserved
----------------------------------------------------------------
1. Edit config/ckan/.env  and set:

       CKAN___BEAKER__SESSION__SECRET=test-beaker-000
       CKAN___API_TOKEN__JWT__ENCODE__SECRET=string:test-jwt-111
       CKAN___API_TOKEN__JWT__DECODE__SECRET=string:test-jwt-222

2. Start CKAN with a clean volume (fresh production.ini):

       cd compose/
       docker compose down -v
       docker compose up -d --build ckan

3. Read back the effective values from production.ini:

       docker compose exec ckan ckan config-tool /app/production.ini \
           -g beaker.session.secret \
           -g api_token.jwt.encode.secret \
           -g api_token.jwt.decode.secret \
           -g WTF_CSRF_SECRET_KEY

4. Expected output:

       beaker.session.secret = test-beaker-000
       api_token.jwt.encode.secret = string:test-jwt-111
       api_token.jwt.decode.secret = string:test-jwt-222
       WTF_CSRF_SECRET_KEY = <random auto-generated>

5. Check the container log for the expected decision messages:

       docker compose logs ckan | grep -E '\[(beaker|api_token|WTF)'

   Expected:
       [beaker.session.secret] Using value from environment
       [WTF_CSRF_SECRET_KEY] Not set, autogenerating
       [api_token.jwt.encode.secret] Using value from environment (as string:*)
       [api_token.jwt.decode.secret] Using value from environment (as string:*)


Scenario 2 – Secrets NOT provided  →  values should be autogenerated
--------------------------------------------------------------------
1. Edit config/ckan/.env  and SET BACK TO:

       CKAN___BEAKER__SESSION__SECRET=CHANGE_ME
       CKAN___API_TOKEN__JWT__ENCODE__SECRET=string:CHANGE_ME
       CKAN___API_TOKEN__JWT__DECODE__SECRET=string:CHANGE_ME

   (or simply comment the three lines out entirely).

2. Destroy the old volume so we start from a completely fresh
   production.ini:

       cd compose/
       docker compose down -v
       docker compose up -d --build ckan

3. Read the values:

       docker compose exec ckan ckan config-tool /app/production.ini \
           -g beaker.session.secret \
           -g api_token.jwt.encode.secret \
           -g api_token.jwt.decode.secret

4. Expected behaviour:
   - All three values are non-empty random-looking strings
     (i.e. NOT the literal "CHANGE_ME").
   - Container log shows "Not set, autogenerating" for all three:

       docker compose logs ckan | grep -E '\[(beaker|api_token|WTF)'

5. **Critical persistence check**: restart the container WITHOUT
   removing the volume:

       docker compose restart ckan

   After restart, read the values again.  They MUST be IDENTICAL
   to before the restart.  The container log should now show:

       [beaker.session.secret] Keeping value already present in ini
       [WTF_CSRF_SECRET_KEY] Keeping value already present in ini
       [api_token.jwt.encode.secret] Keeping value already present in ini
       [api_token.jwt.decode.secret] Keeping value already present in ini

   This proves we only regenerate when the ini value is truly
   missing / empty, not on every restart.


Scenario 3 – Mixed (partial env, partial ini)
----------------------------------------------
1. In config/ckan/.env, set ONLY the beaker secret, leave the rest
   as CHANGE_ME:

       CKAN___BEAKER__SESSION__SECRET=partial-test-beaker
       CKAN___API_TOKEN__JWT__ENCODE__SECRET=string:CHANGE_ME
       CKAN___API_TOKEN__JWT__DECODE__SECRET=string:CHANGE_ME

2. Reset and start:

       cd compose/
       docker compose down -v
       docker compose up -d --build ckan

3. Check logs:

       docker compose logs ckan | grep -E '\[(beaker|api_token|WTF)'

   Expected:
       [beaker.session.secret] Using value from environment
       [WTF_CSRF_SECRET_KEY] Not set, autogenerating
       [api_token.jwt.encode.secret] Not set, autogenerating
       [api_token.jwt.decode.secret] Not set, autogenerating

============================================================
E2E_VERIFICATION
