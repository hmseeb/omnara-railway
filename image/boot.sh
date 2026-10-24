#!/bin/bash
# Boot order: migrate, admin account step (loopback only), api, worker + maintenance, and nginx on
# $PORT only once the api answers, so a green healthcheck means the api itself is up.
set -euo pipefail

: "${PORT:=8080}"
API=127.0.0.1:8090

# Railway mounts the volume root-owned with a lost+found, so memory lives in a subdirectory.
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$OMNARA_MEMORY_DIR" /data/state
  for d in "$OMNARA_MEMORY_DIR" /data/state; do [ "$(stat -c %u "$d")" = 65532 ] || chown -R 65532:65532 "$d"; done
  chmod 700 /data/state
  exec setpriv --reuid=65532 --regid=65532 --init-groups -- "$0" "$@"
fi

die() { echo "FATAL: $*" >&2; sleep 30; exit 1; }

for v in OMNARA_DATABASE_URL OMNARA_REDIS_URL OMNARA_PUBLIC_URL OMNARA_ADMIN_EMAIL \
         OMNARA_ENCRYPTION_KEY_HEX OMNARA_SKILL_SIGNING_KEY_HEX; do
  [ -n "${!v:-}" ] || die "$v is empty. Set it on this service and redeploy."
done
# Railway bug: a template's bucket references can resolve empty on first deploy and stay empty.
for v in OMNARA_BLOB_S3_BUCKET OMNARA_BLOB_S3_ENDPOINT OMNARA_BLOB_S3_ACCESS_KEY_ID OMNARA_BLOB_S3_SECRET_ACCESS_KEY; do
  [ -n "${!v:-}" ] || die "$v resolved empty (a known Railway bucket-template bug). Open this service's Variables, re-save $v unchanged, then deploy again."
done
[[ $OMNARA_ADMIN_EMAIL == ?*@?* ]] || die "OMNARA_ADMIN_EMAIL '$OMNARA_ADMIN_EMAIL' is not an email address."

PUBLIC_HOST=${OMNARA_PUBLIC_URL#*://}; PUBLIC_HOST=${PUBLIC_HOST%%/*}

# Upstream wants base64 32-byte keys; Railway's secret() makes hex, so convert. Set the
# upstream variables directly to override (e.g. a rotated key ring).
b64() { printf %s "${1^^}" | basenc --base16 -d | base64 -w0; }
[ ${#OMNARA_ENCRYPTION_KEY_HEX} = 64 ] && [ ${#OMNARA_SKILL_SIGNING_KEY_HEX} = 64 ] || die "the *_KEY_HEX variables must be 64 hex characters."
[ -n "${OMNARA_SECRET_ENCRYPTION_KEYS:-}" ] || OMNARA_SECRET_ENCRYPTION_KEYS="{\"railway\":\"$(b64 "$OMNARA_ENCRYPTION_KEY_HEX")\"}"
: "${OMNARA_SECRET_ENCRYPTION_ACTIVE_KEY_ID:=railway}"
: "${OMNARA_SKILL_DOWNLOAD_SIGNING_KEY:=$(b64 "$OMNARA_SKILL_SIGNING_KEY_HEX")}"
export OMNARA_SECRET_ENCRYPTION_KEYS OMNARA_SECRET_ENCRYPTION_ACTIVE_KEY_ID OMNARA_SKILL_DOWNLOAD_SIGNING_KEY

# Everything but nginx stays on loopback; the default metrics ports would also collide.
export OMNARA_API_ADDR=$API OMNARA_API_METRICS_ADDR=127.0.0.1:9081 \
       OMNARA_WORKER_METRICS_ADDR=127.0.0.1:9082 OMNARA_MAINTENANCE_METRICS_ADDR=127.0.0.1:9083 \
       OMNARA_TRUSTED_PROXY_CIDRS=127.0.0.1/32 OMNARA_ALLOW_INSECURE_DEV_DEFAULTS=0

sql() { psql "$OMNARA_DATABASE_URL" -tAqX -v ON_ERROR_STOP=1 "$@"; }
for _ in $(seq 1 60); do sql -c 'select 1' >/dev/null 2>&1 && break; sleep 2; done
sql -c 'select 1' >/dev/null || die "Postgres is not reachable at OMNARA_DATABASE_URL."
omnara-migrate

claimed() { [ "$(sql -c 'select 1 from user_emails where verified_at is not null limit 1')" = 1 ]; }

# Single-tenant lock: signup and password reset are off whenever the app is reachable. The
# admin account is created, and its password changed, by a short step before nginx starts:
# boot mints a one-time token straight into the database and redeems it through upstream's
# own endpoint on loopback, so the password is hashed by Omnara itself. Mail from that step
# goes to a loopback port nothing listens on.
ADMIN_EMAIL=$(printf %s "$OMNARA_ADMIN_EMAIL" | tr -d '[:space:]'); ADMIN_NORM=${ADMIN_EMAIL,,}
APPLIED=/data/state/admin-password

mint_token() {  # $1 = email_verification (new account) | password_reset
  local token hash
  token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  hash=$(printf %s "$token" | sha256sum | cut -c1-64)
  if [ "$1" = email_verification ]; then
    sql -v email="$ADMIN_EMAIL" -v norm="$ADMIN_NORM" -v hash="$hash" <<'SQL' >/dev/null
BEGIN;
-- signup is never public, so every unverified account is a leftover of this step
DELETE FROM user_auth_tokens WHERE user_id IN (SELECT user_id FROM user_emails WHERE verified_at IS NULL);
WITH e AS (DELETE FROM user_emails WHERE verified_at IS NULL RETURNING user_id)
DELETE FROM users WHERE id IN (SELECT user_id FROM e);
WITH u AS (INSERT INTO users(display_name, created_at, updated_at) VALUES ('', now(), now()) RETURNING id),
     e AS (INSERT INTO user_emails(user_id, email, normalized_email, is_primary, created_at, updated_at)
           SELECT id, :'email', :'norm', true, now(), now() FROM u RETURNING id, user_id)
INSERT INTO user_auth_tokens(user_id, user_email_id, purpose, token_hash, created_at, expires_at)
SELECT user_id, id, 'email_verification', :'hash', statement_timestamp(), statement_timestamp() + interval '10 minutes' FROM e;
COMMIT;
SQL
  else
    [ "$(sql -v norm="$ADMIN_NORM" -v hash="$hash" <<'SQL'
WITH t AS (INSERT INTO user_auth_tokens(user_id, purpose, token_hash, created_at, expires_at)
           SELECT user_id, 'password_reset', :'hash', statement_timestamp(), statement_timestamp() + interval '10 minutes'
           FROM user_emails WHERE normalized_email = :'norm' AND verified_at IS NOT NULL RETURNING 1)
SELECT count(*) FROM t;
SQL
)" = 1 ] || return 1
  fi
  echo "$token"
}

password_sum() { printf '%s%s' "$1" "$OMNARA_ADMIN_PASSWORD" | sha256sum | cut -c1-64; }

# OMNARA_ADMIN_PASSWORD is applied on first boot and again whenever the variable changes.
# A change made in the app stays until the variable is edited. Only a salted hash of the
# last applied value is kept.
admin_step() {
  [ -n "${OMNARA_ADMIN_PASSWORD:-}" ] || return 0
  local salt route kind token pw out
  salt=$(cut -d' ' -f1 "$APPLIED" 2>/dev/null || true)
  if claimed; then
    [ -n "$salt" ] && [ "$(cat "$APPLIED")" = "$salt $(password_sum "$salt")" ] && return 0
    kind=password_reset route=/api/auth/password/reset
    export OMNARA_AUTH_SIGNUP_ENABLED=0 OMNARA_AUTH_PASSWORD_RESET_ENABLED=1
  else
    kind=email_verification route=/api/auth/email/verify
    export OMNARA_AUTH_SIGNUP_ENABLED=1 OMNARA_AUTH_PASSWORD_RESET_ENABLED=0
  fi
  token=$(mint_token $kind) || { echo "WARNING: no verified account for OMNARA_ADMIN_EMAIL ($ADMIN_EMAIL); password not applied" >&2; return 0; }
  OMNARA_EMAIL_DRIVER=smtp OMNARA_SMTP_ADDR=127.0.0.1:1 OMNARA_EMAIL_FROM=noreply@localhost.invalid omnara-api &
  local api=$!
  for _ in $(seq 1 120); do health && break; sleep 0.5; done
  pw=${OMNARA_ADMIN_PASSWORD//\\/\\\\}; pw=${pw//\"/\\\"}
  # body on stdin, so the password never shows in the process list
  if out=$(printf '{"token":"%s","password":"%s"}' "$token" "$pw" | curl -sS -m 30 -X POST \
             -H "Host: $PUBLIC_HOST" -H "Origin: $OMNARA_PUBLIC_URL" -H 'Content-Type: application/json' \
             --data-binary @- -w '\n%{http_code}' "http://$API$route" 2>&1) && [ "${out##*$'\n'}" = 200 ]; then
    [ -n "$salt" ] || salt=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    (umask 077; echo "$salt $(password_sum "$salt")" > "$APPLIED")
    [ $kind = password_reset ] && echo "==> admin password updated from OMNARA_ADMIN_PASSWORD" \
                               || echo "==> admin account created: $ADMIN_EMAIL"
  else
    # keep the deploy healthy; a claimed admin keeps the password it had
    echo "WARNING: OMNARA_ADMIN_PASSWORD was not applied: ${out%$'\n'*}" >&2
  fi
  kill $api; wait $api 2>/dev/null || true
}

health() { curl -fsS -m 3 -H "Host: $PUBLIC_HOST" "http://$API/healthz" >/dev/null 2>&1; }

sed -e "s/__PORT__/$PORT/" -e "s/__PUBLIC_HOST__/$PUBLIC_HOST/" /etc/omnara/nginx.conf.in > /tmp/nginx.conf

admin_step
claimed || echo "WARNING: no admin account yet. Set OMNARA_ADMIN_EMAIL and OMNARA_ADMIN_PASSWORD, then redeploy." >&2
export OMNARA_AUTH_SIGNUP_ENABLED=0 OMNARA_AUTH_PASSWORD_RESET_ENABLED=0 \
       OMNARA_EMAIL_DRIVER=none OMNARA_SMTP_ADDR= OMNARA_EMAIL_FROM=

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' TERM INT
omnara-api & pids+=($!)
omnara-worker & pids+=($!)
omnara-maintenance & pids+=($!)
for _ in $(seq 1 120); do health && break; sleep 0.5; done
health || die "api did not answer on $API within 60s"
nginx -c /tmp/nginx.conf -e stderr -g 'daemon off;' & pids+=($!)

# Any process ending ends the container; Railway's restart policy brings it back.
status=0
wait -n "${pids[@]}" || status=$?
kill "${pids[@]}" 2>/dev/null || true
exit "$status"
