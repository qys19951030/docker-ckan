#!/bin/bash
set -e

echo "Starting CKAN..."
# Run any startup scripts provided by images extending this one
if [[ -d "${APP_DIR}/docker-entrypoint.d" ]]; then
	echo "Found entrypoint scripts, initializing:"
	for f in ${APP_DIR}/docker-entrypoint.d/*; do
		case "$f" in
		*.sh)
			echo "$0: Running init file $f"
			. "$f"
			;;
		*.py)
			echo "$0: Running init file $f"
			python "$f"
			echo
			;;
		*) echo "$0: Ignoring $f (not an sh or py file)" ;;
		esac
		echo
	done
fi

# Resolve each secret from environment variables.
# Supports both naming conventions:
#   - ckanext-envvars style (preferred, used in compose):
#       CKAN___BEAKER__SESSION__SECRET
#       CKAN___API_TOKEN__JWT__ENCODE__SECRET
#       CKAN___API_TOKEN__JWT__DECODE__SECRET
#   - legacy shell style (kept for backward compatibility):
#       BEAKER_SESSION_SECRET
#       JWT_ENCODE_SECRET
#       JWT_DECODE_SECRET
# Strips the "string:" prefix if present (ckanext-envvars convention).

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

BEAKER_SECRET_VAL="$(resolve_secret CKAN___BEAKER__SESSION__SECRET BEAKER_SESSION_SECRET)"
JWT_ENCODE_VAL="$(resolve_secret CKAN___API_TOKEN__JWT__ENCODE__SECRET JWT_ENCODE_SECRET)"
JWT_DECODE_VAL="$(resolve_secret CKAN___API_TOKEN__JWT__DECODE__SECRET JWT_DECODE_SECRET)"

# Extract just the value portion from "key = value" output of `ckan config-tool -g`.
# Strips leading/trailing whitespace around the value.
iniget() {
	local key="$1"
	local line
	line="$(ckan config-tool $APP_DIR/production.ini -g "$key" 2>/dev/null || true)"
	# Output format from ckan config-tool -g is:  "key = value"
	# Strip everything up to and including " = " to get just the value.
	local val="${line#* = }"
	# Trim leading/trailing whitespace
	val="${val#"${val%%[![:space:]]*}"}"
	val="${val%"${val##*[![:space:]]}"}"
	echo "$val"
}

# Check if a value from the ini is "empty/unset" for the purposes of secret
# auto-generation. Returns 0 (true) if the value should be treated as "not
# set" (i.e. empty string, placeholder, or empty string: prefix).
is_unset() {
	local val="$1"
	[[ -z "$val" ]] && return 0
	[[ "$val" == "CHANGE_ME" ]] && return 0
	[[ "$val" == "string:" ]] && return 0
	[[ "$val" == "string:CHANGE_ME" ]] && return 0
	return 1
}

# Check if a value from the ini is "already set" (i.e. has a usable non-empty
# non-placeholder value). This is the inverse of is_unset().
has_value() {
	! is_unset "$1"
}

# ---- beaker.session.secret ----
if [[ -n "$BEAKER_SECRET_VAL" ]]; then
	echo "[beaker.session.secret] Using value from environment"
	ckan config-tool $APP_DIR/production.ini "beaker.session.secret=$BEAKER_SECRET_VAL"
else
	INI_BEAKER="$(iniget beaker.session.secret)"
	if has_value "$INI_BEAKER"; then
		echo "[beaker.session.secret] Keeping value already present in ini"
	else
		echo "[beaker.session.secret] Not set, autogenerating"
		BEAKER_SECRET_VAL="$(python -c 'import secrets; print(secrets.token_urlsafe())')"
		ckan config-tool $APP_DIR/production.ini "beaker.session.secret=$BEAKER_SECRET_VAL"
	fi
fi

# ---- WTF_CSRF_SECRET_KEY (always regenerate alongside beaker if not set) ----
INI_WTF="$(iniget WTF_CSRF_SECRET_KEY)"
if has_value "$INI_WTF"; then
	echo "[WTF_CSRF_SECRET_KEY] Keeping value already present in ini"
else
	echo "[WTF_CSRF_SECRET_KEY] Not set, autogenerating"
	ckan config-tool $APP_DIR/production.ini "WTF_CSRF_SECRET_KEY=$(python -c 'import secrets; print(secrets.token_urlsafe())')"
fi

# ---- api_token.jwt.encode.secret ----
if [[ -n "$JWT_ENCODE_VAL" ]]; then
	echo "[api_token.jwt.encode.secret] Using value from environment (as string:*)"
	ckan config-tool $APP_DIR/production.ini "api_token.jwt.encode.secret=string:$JWT_ENCODE_VAL"
else
	INI_JWT_ENCODE="$(iniget api_token.jwt.encode.secret)"
	if has_value "$INI_JWT_ENCODE"; then
		echo "[api_token.jwt.encode.secret] Keeping value already present in ini"
	else
		echo "[api_token.jwt.encode.secret] Not set, autogenerating"
		JWT_ENCODE_VAL="$(python -c 'import secrets; print(secrets.token_urlsafe())')"
		ckan config-tool $APP_DIR/production.ini "api_token.jwt.encode.secret=string:$JWT_ENCODE_VAL"
	fi
fi

# ---- api_token.jwt.decode.secret ----
if [[ -n "$JWT_DECODE_VAL" ]]; then
	echo "[api_token.jwt.decode.secret] Using value from environment (as string:*)"
	ckan config-tool $APP_DIR/production.ini "api_token.jwt.decode.secret=string:$JWT_DECODE_VAL"
else
	INI_JWT_DECODE="$(iniget api_token.jwt.decode.secret)"
	if has_value "$INI_JWT_DECODE"; then
		echo "[api_token.jwt.decode.secret] Keeping value already present in ini"
	else
		echo "[api_token.jwt.decode.secret] Not set, autogenerating"
		if [[ -z "$JWT_DECODE_VAL" ]]; then
			JWT_DECODE_VAL="$JWT_ENCODE_VAL"
		fi
		if [[ -z "$JWT_DECODE_VAL" ]]; then
			JWT_DECODE_VAL="$(python -c 'import secrets; print(secrets.token_urlsafe())')"
		fi
		ckan config-tool $APP_DIR/production.ini "api_token.jwt.decode.secret=string:$JWT_DECODE_VAL"
	fi
fi

# Run the prerun script to init CKAN and create the default admin user
echo "Starting prerun.py to configure CKAN backends..."
python prerun.py || {
	echo '[CKAN prerun] FAILED. Exiting...'
	exit 1
}

# Update config for xloader API, use sysadmin API key
# Check if xloader api token is set
if ! grep -q ckanext.xloader.api_token $APP_DIR/production.ini; then
	# Generate API key for sysadmin user
	echo "Generating an API key for sysadmin user $CKAN_SYSADMIN_NAME to use for xloader..."
	SYSADMIN_XLOADER_API_TOKEN=$(ckan -c $APP_DIR/production.ini user token add $CKAN_SYSADMIN_NAME xloader -q)
	ckan config-tool $APP_DIR/production.ini "ckanext.xloader.api_token=$SYSADMIN_XLOADER_API_TOKEN"
fi

# Check if we are in maintenance mode and if yes serve the maintenance pages
if [ "$MAINTENANCE_MODE" = true ]; then PYTHONUNBUFFERED=1 python maintenance/serve.py; fi

# Run any after prerun/init scripts provided by images extending this one
if [[ -d "${APP_DIR}/docker-afterinit.d" ]]; then
	echo "Found afterinit scripts, initializing:"
	for f in ${APP_DIR}/docker-afterinit.d/*; do
		case "$f" in
		*.sh)
			echo "$0: Running after prerun init file $f"
			. "$f"
			;;
		*.py)
			echo "$0: Running after prerun init file $f"
			python "$f"
			echo
			;;
		*) echo "$0: Ignoring $f (not an sh or py file)" ;;
		esac
		echo
	done
fi

# Check whether http basic auth password protection is enabled and enable basicauth routing on uwsgi respecfully
if [ $? -eq 0 ]; then
	if [ "$PASSWORD_PROTECT" = true ]; then
		if [ "$HTPASSWD_USER" ] || [ "$HTPASSWD_PASSWORD" ]; then
			# Generate htpasswd file for basicauth
			htpasswd -d -b -c $APP_DIR/.htpasswd $HTPASSWD_USER $HTPASSWD_PASSWORD
			# Start uwsgi with basicauth
			uwsgi --ini $APP_DIR/uwsgi.conf --pcre-jit $UWSGI_OPTS
		else
			echo "Missing HTPASSWD_USER or HTPASSWD_PASSWORD environment variables. Exiting..."
			exit 1
		fi
	else
		# Start uwsgi
		echo "Starting UWSGI with '${UWSGI_PROC_NO:-2}' workers"
		uwsgi $UWSGI_OPTS
	fi
else
	echo "Failed...not starting CKAN."
fi
