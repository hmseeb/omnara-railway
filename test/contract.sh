#!/bin/bash
# Contract for the image: what Railway and a deployer rely on. Runs postgres, redis and an
# S3 server in one network namespace with the image (upstream refuses a non-HTTPS S3
# endpoint unless it is localhost), then drives the claim and the signup lock.
#   test/contract.sh [image]   (default: builds image/ as omnara-railway:test)
set -uo pipefail
cd "$(dirname "$0")/.."
IMG=${1:-omnara-railway:test}
[ -n "${1:-}" ] || docker build -q -t "$IMG" image >/dev/null || { echo "build failed"; exit 1; }

N=omnara-contract-$$; PORT=18080; ORIGIN=http://localhost:$PORT
ADMIN=Admin@Example.com; TOKEN=setuptoken0123456789abcdefghijklmnopqrstuvwxyzAB; PW='Long-Test-Passphrase-42!'
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
cleanup() { docker rm -f $N-app $N-pg $N-redis $N-s3 >/dev/null 2>&1; docker volume rm $N-data >/dev/null 2>&1; }
trap cleanup EXIT

docker run -d --name $N-s3 -p 127.0.0.1:$PORT:8080 -e RUSTFS_ACCESS_KEY=omnara -e RUSTFS_SECRET_KEY=omnara-blobs \
  rustfs/rustfs:1.0.0 /data >/dev/null
docker run -d --name $N-pg --network container:$N-s3 -e POSTGRES_USER=omnara -e POSTGRES_PASSWORD=omnara \
  -e POSTGRES_DB=omnara postgres:18-alpine >/dev/null
docker run -d --name $N-redis --network container:$N-s3 valkey/valkey:9-alpine >/dev/null

app() {
  docker run -d --name $N-app --network container:$N-s3 -v $N-data:/data \
    -e OMNARA_DATABASE_URL=postgres://omnara:omnara@127.0.0.1:5432/omnara?sslmode=disable \
    -e OMNARA_REDIS_URL=redis://127.0.0.1:6379/0 -e OMNARA_PUBLIC_URL=$ORIGIN \
    -e OMNARA_BLOB_S3_BUCKET=omnara -e OMNARA_BLOB_S3_REGION=us-east-1 -e OMNARA_BLOB_S3_ENDPOINT=http://localhost:9000 \
    -e OMNARA_BLOB_S3_ACCESS_KEY_ID=omnara -e OMNARA_BLOB_S3_SECRET_ACCESS_KEY=omnara-blobs -e OMNARA_BLOB_S3_USE_PATH_STYLE=1 \
    -e OMNARA_ADMIN_EMAIL="${1:-$ADMIN}" -e OMNARA_SETUP_TOKEN=$TOKEN \
    -e OMNARA_ENCRYPTION_KEY_HEX=$(printf 'ab%.0s' $(seq 32)) -e OMNARA_SKILL_SIGNING_KEY_HEX=$(printf 'cd%.0s' $(seq 32)) \
    "$IMG" >/dev/null
  up
}
up() { for _ in $(seq 1 90); do curl -fs -o /dev/null -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/healthz" && return; sleep 1; done; }
post() { local path=$1; shift; curl -s -H "Host: localhost:$PORT" -H "Origin: $ORIGIN" -H 'Content-Type: application/json' "$@" "http://127.0.0.1:$PORT$path"; }
code() { post "$@" -o /dev/null -w '%{http_code}'; }

for _ in $(seq 1 30); do docker exec $N-s3 sh -c 'exit 0' 2>/dev/null && break; sleep 1; done
sleep 3
docker run --rm --network container:$N-s3 curlimages/curl -fsS -o /dev/null -X PUT --aws-sigv4 'aws:amz:us-east-1:s3' \
  --user omnara:omnara-blobs http://localhost:9000/omnara || no "bucket create"

app
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: healthcheck.railway.app" "http://127.0.0.1:$PORT/healthz")
[ "$c" = 200 ] && ok "Railway healthcheck host gets 200 on /healthz" || { no "healthcheck host got $c"; docker logs $N-app 2>&1 | tail -30; exit 1; }

c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example.com" "http://127.0.0.1:$PORT/api/auth/login")
[ "$c" = 404 ] && ok "unknown Host refused on the api" || no "unknown Host got $c"

p=$(curl -s -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/agents")
[[ $p == *'<div id="root"'* || $p == *'<script'* ]] && ok "web app served (SPA fallback)" || no "web app: ${p:0:200}"

docker logs $N-app 2>&1 | grep -q "/verify-email?token=$TOKEN" && ok "logs print the setup link" || no "no setup link in logs"

# a stranger can start a signup, but its mail goes nowhere: no token, no account
c=$(code /api/auth/signup --data '{"email":"stranger@example.com"}')
[ "$c" = 202 ] && ok "stranger signup accepted without a reachable mailer" || no "stranger signup got $c"
c=$(code /api/auth/email/verify --data "{\"token\":\"guess\",\"password\":\"$PW\"}")
[ "$c" != 200 ] && ok "a guessed token is refused ($c)" || no "guessed token accepted"

# the deployer redeems the setup link
h=$(post /api/auth/email/verify -D - -o /dev/null --data "{\"token\":\"$TOKEN\",\"password\":\"$PW\"}")
grep -q '^HTTP/1.1 200' <<<"$h" && grep -qi '^set-cookie:' <<<"$h" && ok "setup link creates the admin and signs in" || no "claim: $h"

# the watcher restarts everything in place with signup off
for _ in $(seq 1 30); do docker logs $N-app 2>&1 | grep -q 'claimed: signup is off' && break; sleep 1; done
up
c=$(code /api/auth/signup --data '{"email":"late@example.com"}')
[ "$c" = 404 ] && ok "signup is off once claimed" || no "signup after claim got $c"
c=$(code /api/auth/login --data "{\"email\":\"admin@example.com\",\"password\":\"$PW\"}")
[ "$c" = 200 ] && ok "admin logs in (email matched case-insensitively)" || no "login got $c"
c=$(code /api/auth/login --data "{\"email\":\"admin@example.com\",\"password\":\"wrong password here\"}")
[ "$c" = 401 ] && ok "wrong password refused" || no "wrong password got $c"

u=$(docker exec $N-app sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = omnara-api ] && stat -c %u $p && break; done')
[[ $u == 65532 || $u == nonroot ]] && ok "api runs as nonroot" || no "api runs as '$u'"

# same volume and database, new container: what a Railway redeploy does
docker rm -f $N-app >/dev/null; app
c=$(code /api/auth/signup --data '{"email":"late@example.com"}')
[ "$c" = 404 ] && ok "signup stays off after a redeploy" || no "signup after redeploy got $c"
c=$(code /api/auth/login --data "{\"email\":\"admin@example.com\",\"password\":\"$PW\"}")
[ "$c" = 200 ] && ok "admin survives a redeploy" || no "login after redeploy got $c"

[ $fail = 0 ] && echo "all green" || { docker logs $N-app 2>&1 | tail -40; exit 1; }
