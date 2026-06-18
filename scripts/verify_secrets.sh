#!/bin/bash
#
# verify_secrets.sh
#
# Comprehensive test suite for the CKAN secret-handling logic in
# images/ckan/*/setup/app/start_ckan.sh.
#
# All testing uses REAL implementations (actual file I/O for `iniget`,
# real environment-variable resolution, real ini parsing via the SAME
# grep/sed algorithm used in the bash startup script) rather than mocks.
#
# Coverage:
#   1. resolve_secret  – env var resolution (CKAN___* priority, CHANGE_ME
#                        sentinel, string: prefix stripping)
#   2. iniget          – production.ini value extraction using the EXACT
#                        same grep/sed logic as start_ckan.sh
#   3. is_unset / has_value – empty/placeholder detection
#   4. Full E2E simulation:
#      – "Cold start" with CHANGE_ME env vars + blank ini => AUTOGEN
#      – "Restart" with the same ini file => KEEP_INI (no re-gen)
#      – "Env override" with real CKAN___* values => USE_ENV
#
# The script also prints step-by-step instructions for end-to-end
# verification inside a real docker container at the bottom.
#
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
fail() { echo "  [FAIL] $1  (got: '$2', expected: '$3')"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

# =====================================================================
# 1. resolve_secret – EXACT copy from start_ckan.sh
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
# 2. iniget – EXACT copy from start_ckan.sh
# =====================================================================
iniget() {
	local key="$1"
	local inifile="${2:-$APP_DIR/production.ini}"
	local line
	line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$inifile" 2>/dev/null | tail -n 1 || true)"
	[[ -z "$line" ]] && { echo ""; return 0; }
	local val="${line#*=}"
	val="${val#"${val%%[![:space:]]*}"}"
	val="${val%"${val##*[![:space:]]}"}"
	val="${val%%#*}"
	val="${val%"${val##*[![:space:]]}"}"
	echo "$val"
}

# =====================================================================
# 3. is_unset / has_value – EXACT copy from start_ckan.sh
# =====================================================================
is_unset() {
	local val="$1"
	[[ -z "$val" ]] && return 0
	[[ "$val" == "CHANGE_ME" ]] && return 0
	[[ "$val" == "string:" ]] && return 0
	[[ "$val" == "string:CHANGE_ME" ]] && return 0
	return 1
}
has_value() { ! is_unset "$1"; }

# =====================================================================
# Test helpers
# =====================================================================
run_resolve_test() {
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
	local key="$2"
	local expected="$3"
	shift 3
	# Remaining args are lines of the ini file
	local tmp
	tmp="$(mktemp)"
	printf '%s\n' "$@" > "$tmp"
	local actual
	actual="$(iniget "$key" "$tmp")"
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc" "$actual" "$expected"
	fi
	rm -f "$tmp"
}

run_is_unset_test() {
	local desc="$1"
	local value="$2"
	local expected_unset="$3"
	local actual_unset actual_has
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
# 4. E2E simulation – REAL ini files, REAL env vars, REAL iniget()
# =====================================================================

# Simulate a single "startup run" – exactly mirrors start_ckan.sh order.
# Modifies the ini file in-place (simulates ckan config-tool writes).
simulate_run() {
	local label="$1"
	local inifile="$2"
	# Remaining args: alternating "ENV_VAR_NAME" "VALUE" pairs
	shift 2

	# --- Set env vars from the passed pairs
	local env_pairs=()
	while [[ $# -gt 0 ]]; do
		local k="$1" v="$2"; shift 2
		# shellcheck disable=SC2086
		env_pairs+=("$k")
		# Clean slate first
		unset "$k"
		if [[ -n "$v" ]]; then
			export "$k=$v"
		fi
	done

	# --- Resolve env secrets (just like the real script does first)
	local BEAKER_SECRET_VAL JWT_ENCODE_VAL JWT_DECODE_VAL
	BEAKER_SECRET_VAL="$(resolve_secret CKAN___BEAKER__SESSION__SECRET BEAKER_SESSION_SECRET)"
	JWT_ENCODE_VAL="$(resolve_secret CKAN___API_TOKEN__JWT__ENCODE__SECRET JWT_ENCODE_SECRET)"
	JWT_DECODE_VAL="$(resolve_secret CKAN___API_TOKEN__JWT__DECODE__SECRET JWT_DECODE_SECRET)"

	local decision=""
	local result_file
	result_file="$(mktemp)"

	# --- beaker.session.secret
	if [[ -n "$BEAKER_SECRET_VAL" ]]; then
		decision="USE_ENV"
		sed -i -E "s|^[[:space:]]*beaker\.session\.secret[[:space:]]*=.*|beaker.session.secret = $BEAKER_SECRET_VAL|" "$inifile"
		echo "beaker.session.secret|$decision|$BEAKER_SECRET_VAL" >> "$result_file"
	else
		local iv
		iv="$(iniget beaker.session.secret "$inifile")"
		if has_value "$iv"; then
			decision="KEEP_INI"
			echo "beaker.session.secret|$decision|$iv" >> "$result_file"
		else
			decision="AUTOGEN"
			local auto
			auto="AUTO_$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $$RANDOM$RANDOM$RANDOM)"
			sed -i -E "s|^[[:space:]]*beaker\.session\.secret[[:space:]]*=.*|beaker.session.secret = $auto|" "$inifile"
			echo "beaker.session.secret|$decision|$auto" >> "$result_file"
		fi
	fi

	# --- WTF_CSRF_SECRET_KEY
	{
		local iv
		iv="$(iniget WTF_CSRF_SECRET_KEY "$inifile")"
		if has_value "$iv"; then
			decision="KEEP_INI"
			echo "WTF_CSRF_SECRET_KEY|$decision|$iv"
		else
			decision="AUTOGEN"
			local auto
			auto="AUTO_$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $$RANDOM$RANDOM$RANDOM)"
			if grep -qE "^[[:space:]]*WTF_CSRF_SECRET_KEY[[:space:]]*=" "$inifile"; then
				sed -i -E "s|^[[:space:]]*WTF_CSRF_SECRET_KEY[[:space:]]*=.*|WTF_CSRF_SECRET_KEY = $auto|" "$inifile"
			else
				echo "WTF_CSRF_SECRET_KEY = $auto" >> "$inifile"
			fi
			echo "WTF_CSRF_SECRET_KEY|$decision|$auto"
		fi
	} >> "$result_file"

	# --- api_token.jwt.encode.secret
	{
		if [[ -n "$JWT_ENCODE_VAL" ]]; then
			decision="USE_ENV"
			sed -i -E "s|^[[:space:]]*api_token\.jwt\.encode\.secret[[:space:]]*=.*|api_token.jwt.encode.secret = string:$JWT_ENCODE_VAL|" "$inifile"
			echo "api_token.jwt.encode.secret|$decision|string:$JWT_ENCODE_VAL"
		else
			local iv
			iv="$(iniget api_token.jwt.encode.secret "$inifile")"
			if has_value "$iv"; then
				decision="KEEP_INI"
				echo "api_token.jwt.encode.secret|$decision|$iv"
			else
				decision="AUTOGEN"
				local auto
				auto="AUTO_$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $$RANDOM$RANDOM$RANDOM)"
				sed -i -E "s|^[[:space:]]*api_token\.jwt\.encode\.secret[[:space:]]*=.*|api_token.jwt.encode.secret = string:$auto|" "$inifile"
				echo "api_token.jwt.encode.secret|$decision|string:$auto"
				JWT_ENCODE_VAL="$auto"
			fi
		fi
	} >> "$result_file"

	# --- api_token.jwt.decode.secret
	{
		if [[ -n "$JWT_DECODE_VAL" ]]; then
			decision="USE_ENV"
			sed -i -E "s|^[[:space:]]*api_token\.jwt\.decode\.secret[[:space:]]*=.*|api_token.jwt.decode.secret = string:$JWT_DECODE_VAL|" "$inifile"
			echo "api_token.jwt.decode.secret|$decision|string:$JWT_DECODE_VAL"
		else
			local iv
			iv="$(iniget api_token.jwt.decode.secret "$inifile")"
			if has_value "$iv"; then
				decision="KEEP_INI"
				echo "api_token.jwt.decode.secret|$decision|$iv"
			else
				decision="AUTOGEN"
				if [[ -z "$JWT_DECODE_VAL" && -n "$JWT_ENCODE_VAL" ]]; then
					JWT_DECODE_VAL="$JWT_ENCODE_VAL"
				fi
				if [[ -z "$JWT_DECODE_VAL" ]]; then
					JWT_DECODE_VAL="AUTO_$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $$RANDOM$RANDOM$RANDOM)"
				fi
				sed -i -E "s|^[[:space:]]*api_token\.jwt\.decode\.secret[[:space:]]*=.*|api_token.jwt.decode.secret = string:$JWT_DECODE_VAL|" "$inifile"
				echo "api_token.jwt.decode.secret|$decision|string:$JWT_DECODE_VAL"
			fi
		fi
	} >> "$result_file"

	# --- Cleanup env
	for k in "${env_pairs[@]}"; do unset "$k"; done

	cat "$result_file"
	rm -f "$result_file"
}

# Check an E2E decision row
check_e2e() {
	local scenario="$1"
	local key="$2"
	local expected_decision="$3"
	local value_regex="$4"
	local actual_decision actual_value
	actual_decision="$(echo "$E2E_RESULT" | grep "^$key|" | cut -d'|' -f2)"
	actual_value="$(echo "$E2E_RESULT" | grep "^$key|" | cut -d'|' -f3)"
	local dec_ok=false
	[[ "$actual_decision" == "$expected_decision" ]] && dec_ok=true
	local val_ok=true
	if [[ -n "$value_regex" ]]; then
		if echo "$actual_value" | grep -qE "$value_regex"; then
			val_ok=true
		else
			val_ok=false
		fi
	fi
	if $dec_ok && $val_ok; then
		pass "$scenario - $key => $actual_decision"
	else
		fail "$scenario - $key" "dec=$actual_decision val='$actual_value'" "dec=$expected_decision val=~/$value_regex/"
	fi
}

# =====================================================================
# RUN TESTS
# =====================================================================

echo "============================================================"
echo " FULL test suite – real file I/O, no mocks"
echo "  start_ckan.sh secret-handling logic"
echo "============================================================"

# --- Section 1
echo
echo "--- Section 1: resolve_secret() – env var resolution"
echo

run_resolve_test "CKAN___ style normal value" "my-beaker-secret" "my-beaker-secret"
run_resolve_test "CKAN___ style with string: prefix stripped" "my-jwt-secret" "string:my-jwt-secret"
run_resolve_test "Legacy BEAKER_ style used when CKAN___ absent" "legacy-secret" "" "legacy-secret"
run_resolve_test "CKAN___ beats legacy" "ckanstyle-wins" "ckanstyle-wins" "legacy-ignored"
run_resolve_test "CKAN___=string:CHANGE_ME => empty" "" "string:CHANGE_ME"
run_resolve_test "Both unset => empty" ""
run_resolve_test "CKAN___=CHANGE_ME => empty" "" "CHANGE_ME"
run_resolve_test "Legacy=CHANGE_ME => empty" "" "" "CHANGE_ME"

# --- Section 2
echo
echo "--- Section 2: iniget() – parse real temp ini files"
echo

run_iniget_test "Normal key = value" "beaker.session.secret" "abc123" \
	"[app:main]" "beaker.session.secret = abc123"
run_iniget_test "key =  (empty value)" "beaker.session.secret" "" \
	"[app:main]" "beaker.session.secret = "
run_iniget_test "key with indent + spaced =" "beaker.session.secret" "spacedval" \
	"  beaker.session.secret   =   spacedval  "
run_iniget_test "key=CHANGE_ME" "beaker.session.secret" "CHANGE_ME" \
	"beaker.session.secret = CHANGE_ME"
run_iniget_test "key=string:abc123 (JWT format)" "api_token.jwt.encode.secret" "string:abc123" \
	"api_token.jwt.encode.secret = string:abc123"
run_iniget_test "key=string: (empty prefix)" "api_token.jwt.encode.secret" "string:" \
	"api_token.jwt.encode.secret = string:"
run_iniget_test "key=string:CHANGE_ME" "api_token.jwt.decode.secret" "string:CHANGE_ME" \
	"api_token.jwt.decode.secret = string:CHANGE_ME"
run_iniget_test "key not present => empty" "beaker.session.secret" "" \
	"[app:main]" "other.key = val"
run_iniget_test "Last duplicate wins (tail -n 1)" "a" "second" \
	"a = first" "# comment" "a = second"
run_iniget_test "Inline comment after value stripped" "key" "val" \
	"key = val#notrelevant"

# --- Section 3
echo
echo "--- Section 3: is_unset() / has_value()"
echo

run_is_unset_test "empty string => unset" "" "true"
run_is_unset_test "CHANGE_ME => unset" "CHANGE_ME" "true"
run_is_unset_test "string: => unset" "string:" "true"
run_is_unset_test "string:CHANGE_ME => unset" "string:CHANGE_ME" "true"
run_is_unset_test "plain value => set" "abc123" "false"
run_is_unset_test "string:value => set" "string:abc123" "false"
run_is_unset_test "value with spaces => set" "  myval  " "false"
run_is_unset_test "looks-like placeholder but isn't => set" "CHANGE_ME_PLEASE" "false"

# --- Section 4 – E2E simulation
echo
echo "--- Section 4: Full E2E simulation (real ini, real env, multiple runs)"
echo

TMP_INI="$(mktemp)"
cat > "$TMP_INI" <<'EOF'
[app:main]
beaker.session.secret =
WTF_CSRF_SECRET_KEY =
api_token.jwt.encode.secret =
api_token.jwt.decode.secret =
EOF

# === Scenario 1: Cold start with CHANGE_ME ===
echo "  [E2E Scenario 1] Cold start – env has CHANGE_ME, ini empty"
E2E_RESULT="$(simulate_run "ColdStart" "$TMP_INI" \
	CKAN___BEAKER__SESSION__SECRET "CHANGE_ME" \
	CKAN___API_TOKEN__JWT__ENCODE__SECRET "string:CHANGE_ME" \
	CKAN___API_TOKEN__JWT__DECODE__SECRET "string:CHANGE_ME" \
)"

check_e2e "ColdStart" "beaker.session.secret" "AUTOGEN" "^AUTO_[0-9a-f]+$"
check_e2e "ColdStart" "WTF_CSRF_SECRET_KEY" "AUTOGEN" "^AUTO_[0-9a-f]+$"
check_e2e "ColdStart" "api_token.jwt.encode.secret" "AUTOGEN" "^string:AUTO_[0-9a-f]+$"
check_e2e "ColdStart" "api_token.jwt.decode.secret" "AUTOGEN" "^string:AUTO_[0-9a-f]+$"

E1="$(echo "$E2E_RESULT" | grep "^api_token.jwt.encode.secret|" | cut -d'|' -f3)"
D1="$(echo "$E2E_RESULT" | grep "^api_token.jwt.decode.secret|" | cut -d'|' -f3)"
if [[ "$E1" == "$D1" ]]; then
	pass "ColdStart - jwt.decode matches jwt.encode"
else
	fail "ColdStart - jwt.decode matches jwt.encode" "$D1" "$E1"
fi

SNAP_BEAKER="$(iniget beaker.session.secret "$TMP_INI")"
SNAP_WTF="$(iniget WTF_CSRF_SECRET_KEY "$TMP_INI")"
SNAP_ENCODE="$(iniget api_token.jwt.encode.secret "$TMP_INI")"
SNAP_DECODE="$(iniget api_token.jwt.decode.secret "$TMP_INI")"

# === Scenario 2: RESTART – same ini ===
echo
echo "  [E2E Scenario 2] Restart – same ini, env still CHANGE_ME => all KEEP_INI"
E2E_RESULT="$(simulate_run "Restart" "$TMP_INI" \
	CKAN___BEAKER__SESSION__SECRET "CHANGE_ME" \
	CKAN___API_TOKEN__JWT__ENCODE__SECRET "string:CHANGE_ME" \
	CKAN___API_TOKEN__JWT__DECODE__SECRET "string:CHANGE_ME" \
)"

check_e2e "Restart" "beaker.session.secret" "KEEP_INI" ""
check_e2e "Restart" "WTF_CSRF_SECRET_KEY" "KEEP_INI" ""
check_e2e "Restart" "api_token.jwt.encode.secret" "KEEP_INI" ""
check_e2e "Restart" "api_token.jwt.decode.secret" "KEEP_INI" ""

R_BEAKER="$(iniget beaker.session.secret "$TMP_INI")"
R_WTF="$(iniget WTF_CSRF_SECRET_KEY "$TMP_INI")"
R_ENCODE="$(iniget api_token.jwt.encode.secret "$TMP_INI")"
R_DECODE="$(iniget api_token.jwt.decode.secret "$TMP_INI")"
if [[ "$R_BEAKER" == "$SNAP_BEAKER" ]]; then pass "Restart – beaker unchanged in ini"; else fail "Restart – beaker unchanged" "$R_BEAKER" "$SNAP_BEAKER"; fi
if [[ "$R_WTF" == "$SNAP_WTF" ]]; then pass "Restart – WTF unchanged in ini"; else fail "Restart – WTF unchanged" "$R_WTF" "$SNAP_WTF"; fi
if [[ "$R_ENCODE" == "$SNAP_ENCODE" ]]; then pass "Restart – encode unchanged in ini"; else fail "Restart – encode unchanged" "$R_ENCODE" "$SNAP_ENCODE"; fi
if [[ "$R_DECODE" == "$SNAP_DECODE" ]]; then pass "Restart – decode unchanged in ini"; else fail "Restart – decode unchanged" "$R_DECODE" "$SNAP_DECODE"; fi

# === Scenario 3: Env override with real values ===
echo
echo "  [E2E Scenario 3] Env override – explicit CKAN___* values => USE_ENV"
E2E_RESULT="$(simulate_run "Override" "$TMP_INI" \
	CKAN___BEAKER__SESSION__SECRET "OVERRIDE-beaker-777" \
	CKAN___API_TOKEN__JWT__ENCODE__SECRET "string:OVERRIDE-jwt-888" \
	CKAN___API_TOKEN__JWT__DECODE__SECRET "string:OVERRIDE-jwt-999" \
)"

check_e2e "Override" "beaker.session.secret" "USE_ENV" "^OVERRIDE-beaker-777$"
check_e2e "Override" "api_token.jwt.encode.secret" "USE_ENV" "^string:OVERRIDE-jwt-888$"
check_e2e "Override" "api_token.jwt.decode.secret" "USE_ENV" "^string:OVERRIDE-jwt-999$"

F_BEAKER="$(iniget beaker.session.secret "$TMP_INI")"
F_ENCODE="$(iniget api_token.jwt.encode.secret "$TMP_INI")"
F_DECODE="$(iniget api_token.jwt.decode.secret "$TMP_INI")"
if [[ "$F_BEAKER" == "OVERRIDE-beaker-777" ]]; then pass "Override – beaker written correctly"; else fail "Override – beaker written" "$F_BEAKER" "OVERRIDE-beaker-777"; fi
if [[ "$F_ENCODE" == "string:OVERRIDE-jwt-888" ]]; then pass "Override – encode written correctly"; else fail "Override – encode written" "$F_ENCODE" "string:OVERRIDE-jwt-888"; fi
if [[ "$F_DECODE" == "string:OVERRIDE-jwt-999" ]]; then pass "Override – decode written correctly"; else fail "Override – decode written" "$F_DECODE" "string:OVERRIDE-jwt-999"; fi

rm -f "$TMP_INI"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo
echo "============================================================"
echo " Result: $PASS passed, $FAIL failed (total: $TOTAL)"
echo "============================================================"
[[ $FAIL -eq 0 ]] || exit 1

echo
echo "Notes:"
echo "  - Section 2 & 4 use REAL temp files, no mocks (uses the actual"
echo "    grep/sed iniget() from start_ckan.sh, line-for-line identical)."
echo "  - E2E proves: AUTOGEN (cold) -> KEEP_INI (restart) -> USE_ENV (override)."
echo "  - For REAL container verification, run the steps below."

# -------------------------------------------------------------------
# Real container E2E verification (docker compose)
# -------------------------------------------------------------------
cat <<'E2E_DOCKER'

============================================================
 REAL CONTAINER E2E – docker-compose instructions
============================================================

Inside a container, you can verify secrets using grep (not ckan CLI),
because that is exactly what the startup script itself does:

  docker compose exec ckan grep -E 'beaker\.session\.secret|WTF_CSRF_SECRET_KEY|api_token\.jwt' /app/production.ini


Scenario 1 – Cold start with explicit env vars → USE_ENV
---------------------------------------------------------
1. In compose/config/ckan/.env set:
       CKAN___BEAKER__SESSION__SECRET=test-beaker-000
       CKAN___API_TOKEN__JWT__ENCODE__SECRET=string:test-jwt-111
       CKAN___API_TOKEN__JWT__DECODE__SECRET=string:test-jwt-222

2. Clean volume + start:
       cd compose/
       docker compose down -v
       docker compose up -d --build ckan

3. Verify:
       docker compose logs ckan | grep -E '\[(beaker|api_token|WTF)'
   Expected:
       [beaker.session.secret] Using value from environment
       [api_token.jwt.encode.secret] Using value from environment (as string:*)
       [api_token.jwt.decode.secret] Using value from environment (as string:*)

4. Check actual ini values:
       docker compose exec ckan grep -E 'beaker\.session\.secret|WTF_CSRF_SECRET_KEY|api_token\.jwt' /app/production.ini
   Expected:
       beaker.session.secret = test-beaker-000
       api_token.jwt.encode.secret = string:test-jwt-111
       api_token.jwt.decode.secret = string:test-jwt-222


Scenario 2 – CHANGE_ME env vars → AUTOGEN, then KEEP_INI on restart
-------------------------------------------------------------------
1. Set back to CHANGE_ME (and drop volume so ini is blank):
       CKAN___BEAKER__SESSION__SECRET=CHANGE_ME
       CKAN___API_TOKEN__JWT__ENCODE__SECRET=string:CHANGE_ME
       CKAN___API_TOKEN__JWT__DECODE__SECRET=string:CHANGE_ME

2. cd compose/
   docker compose down -v
   docker compose up -d --build ckan

3. Expected logs:
       docker compose logs ckan | grep -E '\[(beaker|api_token|WTF)'
       → all 4 lines say "Not set, autogenerating"

4. Snapshot values using grep:
       docker compose exec ckan grep -E 'beaker\.session\.secret|WTF_CSRF_SECRET_KEY|api_token\.jwt' /app/production.ini
   → all non-empty, non-CHANGE_ME, non-"string:" values

5. Restart WITHOUT dropping volume:
       docker compose restart ckan

6. Expected logs after restart:
       → all 4 lines say "Keeping value already present in ini"

7. Grep snapshot again → MUST be byte-identical to step 4.


Scenario 3 – Legacy env var names work too (BEAKER_SESSION_SECRET etc.)
-----------------------------------------------------------------------
You can also test backward compatibility by commenting out the CKAN___*
lines in .env and instead passing the legacy names as compose
environment variables (via services/ckan/ckan.yaml).  Use the same
verification steps above.  The only difference is the source of the
values; the USE_ENV code path is exercised identically.
============================================================
E2E_DOCKER
