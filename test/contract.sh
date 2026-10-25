#!/usr/bin/env bash
# Contract: usage test/contract.sh <image>. Boots the image and checks the auth
# shape end to end: healthz open, everything else behind basic auth, and a
# basic-authed browser lands on a working UI with upstream's own cookie.
set -euo pipefail
IMAGE="$1"; NAME="dsh-contract-$$"; PORT=18080; U=admin; P=contract-pass-123
J="$(mktemp)"; trap 'docker rm -f "$NAME" >/dev/null 2>&1; rm -f "$J"' EXIT
fail() { echo "FAIL: $*"; docker logs "$NAME" 2>&1 | tail -30; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

docker run -d --name "$NAME" -p "$PORT:8080" -e DSH_UI_USERNAME=$U -e DSH_UI_USERPASS=$P "$IMAGE" >/dev/null
for _ in $(seq 1 120); do [ "$(code "http://127.0.0.1:$PORT/healthz")" = 200 ] && break; sleep 1; done
B="http://127.0.0.1:$PORT"
[ "$(code "$B/healthz")" = 200 ] || fail "healthz not 200"
[ "$(code "$B/")" = 401 ] || fail "/ without basic auth not 401"
[ "$(code "$B/api/remote.mux")" = 401 ] || fail "/api without basic auth not 401"
[ "$(code -u $U:wrong "$B/")" = 401 ] || fail "wrong password not 401"
[ "$(code -u $U:$P -c "$J" -b "$J" -L "$B/")" = 200 ] || fail "basic-authed browser did not reach the UI"
grep -q dsh-auth- "$J" || fail "no upstream session cookie issued"
[ "$(code -u $U:$P -b "$J" "$B/")" = 200 ] || fail "cookie not honoured on /"
docker restart "$NAME" >/dev/null
for _ in $(seq 1 120); do [ "$(code "$B/healthz")" = 200 ] && break; sleep 1; done
[ "$(code -u $U:$P -b "$J" "$B/")" = 200 ] || fail "cookie lost across restart"
echo PASS
