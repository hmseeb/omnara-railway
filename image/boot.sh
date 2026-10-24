#!/bin/bash
# Boot order: migrate, claim/lock signup, api on loopback, worker + maintenance, and nginx on
# $PORT only once the api answers, so a green healthcheck means the api itself is up.
set -euo pipefail

: "${PORT:=8080}"
API=127.0.0.1:8090

# Railway mounts the volume root-owned with a lost+found, so memory lives in a subdirectory.
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$OMNARA_MEMORY_DIR"
  [ "$(stat -c %u "$OMNARA_MEMORY_DIR")" = 65532 ] || chown -R 65532:65532 "$OMNARA_MEMORY_DIR"
  exec setpriv --reuid=65532 --regid=65532 --init-groups -- "$0" "$@"
fi

die() { echo "FATAL: $*" >&2; sleep 30; exit 1; }

for v in OMNARA_DATABASE_URL OMNARA_REDIS_URL OMNARA_PUBLIC_URL OMNARA_ADMIN_EMAIL OMNARA_SETUP_TOKEN \
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

# Single-tenant lock. Until someone holds a verified account, the only way in is the setup
# link: the token row below, for OMNARA_ADMIN_EMAIL. Signup stays on (its verify page is
# what redeems the link), but signup mail goes to a loopback port nothing listens on, so a
# stranger who signs up never receives a link and no mail leaves the box. Once claimed,
# signup is switched off entirely.
mint_setup_link() {
  local email norm hash
  email=$(printf %s "$OMNARA_ADMIN_EMAIL" | tr -d '[:space:]')
  norm=${email,,}
  hash=$(printf %s "$OMNARA_SETUP_TOKEN" | sha256sum | cut -c1-64)
  sql -v email="$email" -v norm="$norm" -v hash="$hash" <<'SQL' >/dev/null
BEGIN;
-- OMNARA_ADMIN_EMAIL was edited: drop the pending account the old link pointed at.
WITH t AS (DELETE FROM user_auth_tokens t USING user_emails e
           WHERE t.token_hash = :'hash' AND e.id = t.user_email_id AND e.normalized_email <> :'norm'
           RETURNING t.user_id, t.user_email_id),
     e AS (DELETE FROM user_emails WHERE id IN (SELECT user_email_id FROM t) RETURNING user_id)
DELETE FROM users WHERE id IN (SELECT user_id FROM e);
UPDATE user_auth_tokens SET expires_at = statement_timestamp() + interval '7 days'
WHERE token_hash = :'hash' AND consumed_at IS NULL;
WITH u AS (INSERT INTO users(display_name, created_at, updated_at)
           SELECT '', now(), now() WHERE NOT EXISTS (SELECT 1 FROM user_auth_tokens WHERE token_hash = :'hash')
           RETURNING id),
     e AS (INSERT INTO user_emails(user_id, email, normalized_email, is_primary, created_at, updated_at)
           SELECT id, :'email', :'norm', true, now(), now() FROM u RETURNING id, user_id)
INSERT INTO user_auth_tokens(user_id, user_email_id, purpose, token_hash, created_at, expires_at)
SELECT user_id, id, 'email_verification', :'hash', statement_timestamp(), statement_timestamp() + interval '7 days' FROM e;
COMMIT;
SQL
}

configure_auth() {
  export OMNARA_AUTH_SIGNUP_ENABLED OMNARA_AUTH_PASSWORD_RESET_ENABLED OMNARA_EMAIL_DRIVER \
         OMNARA_EMAIL_FROM OMNARA_SMTP_ADDR
  if claimed; then
    # no mail provider: signup, password reset and their mail stay off for good
    OMNARA_AUTH_SIGNUP_ENABLED=0 OMNARA_AUTH_PASSWORD_RESET_ENABLED=0
    OMNARA_EMAIL_DRIVER=none OMNARA_SMTP_ADDR= OMNARA_EMAIL_FROM=
    echo "==> claimed: signup is off"
  else
    mint_setup_link
    OMNARA_AUTH_SIGNUP_ENABLED=1 OMNARA_AUTH_PASSWORD_RESET_ENABLED=0
    OMNARA_EMAIL_DRIVER=smtp OMNARA_SMTP_ADDR=127.0.0.1:1 OMNARA_EMAIL_FROM=noreply@localhost.invalid
    echo "==> not claimed yet. Create the admin account ($OMNARA_ADMIN_EMAIL) at:"
    echo "    $OMNARA_PUBLIC_URL/verify-email?token=$OMNARA_SETUP_TOKEN"
  fi
}

sed -e "s/__PORT__/$PORT/" -e "s/__PUBLIC_HOST__/$PUBLIC_HOST/" /etc/omnara/nginx.conf.in > /tmp/nginx.conf

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' TERM INT
while :; do
  configure_auth
  pids=() watcher=
  omnara-api & pids+=($!)
  omnara-worker & pids+=($!)
  omnara-maintenance & pids+=($!)
  health() { curl -fsS -m 3 -H "Host: $PUBLIC_HOST" "http://$API/healthz" >/dev/null 2>&1; }
  for _ in $(seq 1 120); do health && break; sleep 0.5; done
  health || die "api did not answer on $API within 60s"
  nginx -c /tmp/nginx.conf -e stderr -g 'daemon off;' & pids+=($!)
  if [ "$OMNARA_AUTH_SIGNUP_ENABLED" = 1 ]; then
    (until claimed 2>/dev/null; do sleep 5; done) & watcher=$! pids+=($!)
  fi

  # Any process ending ends the container (Railway's restart policy brings it back), except
  # the claim watcher: that restarts everything in place with signup off.
  status=0
  wait -n -p done "${pids[@]}" || status=$?
  kill "${pids[@]}" 2>/dev/null || true
  wait || true
  [ -n "$watcher" ] && [ "$done" = "$watcher" ] && continue
  exit "$status"
done
