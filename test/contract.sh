#!/bin/bash
# Contract for the image: what Railway and a deployer rely on. Runs postgres, redis and an
# S3 server in one network namespace with the image (upstream refuses a non-HTTPS S3
# endpoint unless it is localhost), then drives the admin account and the signup lock.
#   test/contract.sh [image]   (default: builds image/ as omnara-railway:test)
set -uo pipefail
cd "$(dirname "$0")/.."
IMG=${1:-omnara-railway:test}
[ -n "${1:-}" ] || docker build -q -t "$IMG" image >/dev/null || { echo "build failed"; exit 1; }

N=omnara-contract-$$; PORT=18080; ORIGIN=http://localhost:$PORT
ADMIN=Admin@Example.com; PW='Omnara-Gen3rated"Pass\word-9!'
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
cleanup() { docker rm -f $N-app $N-pg $N-redis $N-s3 >/dev/null 2>&1; docker volume rm $N-data >/dev/null 2>&1; rm -f /tmp/$N.jar; }
trap cleanup EXIT

docker run -d --name $N-s3 -p 127.0.0.1:$PORT:8080 -e RUSTFS_ACCESS_KEY=omnara -e RUSTFS_SECRET_KEY=omnara-blobs \
  rustfs/rustfs:1.0.0 /data >/dev/null
docker run -d --name $N-pg --network container:$N-s3 -e POSTGRES_USER=omnara -e POSTGRES_PASSWORD=omnara \
  -e POSTGRES_DB=omnara postgres:18-alpine >/dev/null
docker run -d --name $N-redis --network container:$N-s3 valkey/valkey:9-alpine >/dev/null

app() {  # $1 = OMNARA_ADMIN_PASSWORD
  docker rm -f $N-app >/dev/null 2>&1
  docker run -d --name $N-app --network container:$N-s3 -v $N-data:/data \
    -e OMNARA_DATABASE_URL=postgres://omnara:omnara@127.0.0.1:5432/omnara?sslmode=disable \
    -e OMNARA_REDIS_URL=redis://127.0.0.1:6379/0 -e OMNARA_PUBLIC_URL=$ORIGIN \
    -e OMNARA_BLOB_S3_BUCKET=omnara -e OMNARA_BLOB_S3_REGION=us-east-1 -e OMNARA_BLOB_S3_ENDPOINT=http://localhost:9000 \
    -e OMNARA_BLOB_S3_ACCESS_KEY_ID=omnara -e OMNARA_BLOB_S3_SECRET_ACCESS_KEY=omnara-blobs -e OMNARA_BLOB_S3_USE_PATH_STYLE=1 \
    -e OMNARA_ADMIN_EMAIL="$ADMIN" -e OMNARA_ADMIN_PASSWORD="$1" \
    -e OMNARA_ENCRYPTION_KEY_HEX=$(printf 'ab%.0s' $(seq 32)) -e OMNARA_SKILL_SIGNING_KEY_HEX=$(printf 'cd%.0s' $(seq 32)) \
    "$IMG" >/dev/null
  for _ in $(seq 1 90); do curl -fs -o /dev/null -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/healthz" && return; sleep 1; done
}
logs() { docker logs $N-app 2>&1; }
post() { local path=$1; shift; curl -s -H "Host: localhost:$PORT" -H "Origin: $ORIGIN" -H 'Content-Type: application/json' "$@" "http://127.0.0.1:$PORT$path"; }
code() { post "$@" -o /dev/null -w '%{http_code}'; }
json() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
login() { code /api/auth/login --data "{\"email\":\"admin@example.com\",\"password\":$(json "$1")}"; }

sleep 3
docker run --rm --network container:$N-s3 curlimages/curl -fsS -o /dev/null -X PUT --aws-sigv4 'aws:amz:us-east-1:s3' \
  --user omnara:omnara-blobs http://localhost:9000/omnara || no "bucket create"

app "$PW"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: healthcheck.railway.app" "http://127.0.0.1:$PORT/healthz")
[ "$c" = 200 ] && ok "Railway healthcheck host gets 200 on /healthz" || { no "healthcheck host got $c"; logs | tail -30; exit 1; }

c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example.com" "http://127.0.0.1:$PORT/api/auth/login")
[ "$c" = 404 ] && ok "unknown Host refused on the api" || no "unknown Host got $c"

p=$(curl -s -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/agents")
[[ $p == *'<div id="root"'* || $p == *'<script'* ]] && ok "web app served (SPA fallback)" || no "web app: ${p:0:200}"

grep -q "admin account created: $ADMIN" <<<"$(logs)" && ok "first boot creates the admin account" || no "no account created: $(logs | grep -i warn | tail -3)"
[ "$(login "$PW")" = 200 ] && ok "admin logs in with OMNARA_ADMIN_PASSWORD (quotes and backslash survive)" || no "login failed"
[ "$(login 'Wrong-Password-1!')" = 401 ] && ok "wrong password refused" || no "wrong password not refused"
grep -qF "$PW" <<<"$(logs)" && no "password printed in logs" || ok "password never printed in logs"

c=$(code /api/auth/signup --data '{"email":"stranger@example.com"}')
[ "$c" = 404 ] && ok "signup is off" || no "signup got $c"
c=$(code /api/auth/password/reset --data '{"token":"x","password":"Whatever-Pass-1!"}')
[ "$c" = 404 ] && ok "password reset is off" || no "reset got $c"

u=$(docker exec $N-app sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = omnara-api ] && stat -c %u $p && break; done')
[ "$u" = 65532 ] && ok "api runs as nonroot" || no "api runs as '$u'"

# a password changed in the app survives redeploys while the variable is unchanged
post /api/auth/login -c /tmp/$N.jar -o /dev/null --data "{\"email\":\"admin@example.com\",\"password\":$(json "$PW")}"
csrf=$(awk '$6 ~ /omnara_csrf$/ {print $7}' /tmp/$N.jar)
c=$(code /api/auth/password/change -b /tmp/$N.jar -H "X-Omnara-Csrf: $csrf" \
      --data "{\"current_password\":$(json "$PW"),\"new_password\":\"Changed-In-App-42!\"}")
[ "$c" = 200 ] && ok "password changed in the app" || no "in-app change got $c"
app "$PW"
[ "$(login 'Changed-In-App-42!')" = 200 ] && ok "in-app password kept while the variable is unchanged" || no "in-app password lost on redeploy"
grep -q "password updated" <<<"$(logs)" && no "unchanged variable re-applied" || ok "unchanged variable not re-applied"

# editing the variable replaces the password on the next deploy
app 'Edited-In-Railway-77!'
[ "$(login 'Edited-In-Railway-77!')" = 200 ] && [ "$(login 'Changed-In-App-42!')" = 401 ] \
  && ok "an edited OMNARA_ADMIN_PASSWORD replaces the password" || no "variable edit not applied: $(logs | grep -i warn | tail -2)"
c=$(code /api/auth/password/reset --data '{"token":"x","password":"Whatever-Pass-1!"}')
[ "$c" = 404 ] && ok "reset route off again after applying" || no "reset after apply got $c"

# a value upstream refuses keeps the deploy healthy and the old password working
app short
[ "$(login 'Edited-In-Railway-77!')" = 200 ] && grep -q 'WARNING: OMNARA_ADMIN_PASSWORD was not applied' <<<"$(logs)" \
  && ok "a refused OMNARA_ADMIN_PASSWORD is skipped with a warning" || no "refused password: $(logs | tail -3)"

[ $fail = 0 ] && echo "all green" || { logs | tail -40; exit 1; }
