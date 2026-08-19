#!/usr/bin/env bash
# Boot order matters: dsh first on loopback, Caddy only once dsh answers.
# Caddy is the only thing on the public port, so "Caddy is up" must never be
# true while dsh is down - that is the difference between a healthcheck that
# means something and a green tick over a dead app.
set -euo pipefail

: "${PORT:=8080}"
: "${DSH_INTERNAL_PORT:=3080}"
: "${DSH_UI_USERNAME:=${DSH_UI_USER:-}}"
: "${DSH_UI_USER_PASSWORD:=${DSH_UI_PASSWORD:-}}"
: "${DSH_HOME:=/data/.dsh}"
: "${DSH_WORKSPACE:=/data/workspace}"
export DSH_HOME
export HOME="${HOME:-/data}"

# The pairing is DSH_UI_USERNAME / DSH_UI_USER_PASSWORD, and the password's
# name is the longer one on purpose. Railway orders the deploy form's fields by
# variable-name LENGTH and then alphabetically, ignoring the order the template
# config lists them in. At 15 characters each, DSH_UI_USERNAME and
# DSH_UI_PASSWORD tied and P beat U, so the form asked for a password before it
# asked whose. Twenty characters puts the password below the username it
# belongs to. DSH_UI_USER and DSH_UI_PASSWORD are still honoured as fallbacks
# for anything already deployed under the earlier names.
if [ -z "${DSH_UI_USERNAME:-}" ]; then
  echo "FATAL: DSH_UI_USERNAME is empty. Set it to the username you want to log in with." >&2
  exit 1
fi

if [ -z "${DSH_UI_USER_PASSWORD:-}" ]; then
  echo "FATAL: DSH_UI_USER_PASSWORD is empty. This UI can run bash on this container;" >&2
  echo "       refusing to serve it to the internet without a password." >&2
  exit 1
fi

# The deployer chooses this password, so the floor is enforced here rather than
# hoped for. It is the ONLY barrier between the public internet and an agent
# with a shell: a guessed one is a stranger running commands on this container,
# with the deployer's provider key sitting in it. Twelve characters is a low
# bar deliberately - it stops "test123", not a considered choice.
if [ "${#DSH_UI_USER_PASSWORD}" -lt 12 ]; then
  echo "FATAL: DSH_UI_USER_PASSWORD is ${#DSH_UI_USER_PASSWORD} characters. Use at least 12." >&2
  echo "       This password is the only thing stopping a stranger from running" >&2
  echo "       shell commands on this container. Set a longer one and redeploy." >&2
  exit 1
fi

# An EMPTY DEEPSEEK_API_KEY is worse than an absent one. The harness treats the
# process environment as a read-only credential layer that outranks everything
# stored, so an empty string left behind by a deployer who skipped the optional
# variable would shadow the key they later type into Settings > Models and the
# save would look like it did nothing. Unset it instead.
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  unset DEEPSEEK_API_KEY || true
  echo "==> no DEEPSEEK_API_KEY set; add one in Settings > Models after opening the UI"
fi

mkdir -p "$DSH_HOME" "$DSH_WORKSPACE"
chmod 700 "$DSH_HOME"

# git refuses to operate in a directory it thinks belongs to someone else, and
# a volume restored under a different uid is exactly that case.
git config --global --add safe.directory '*' >/dev/null 2>&1 || true
git config --global init.defaultBranch main >/dev/null 2>&1 || true
[ -n "$(git config --global user.email || true)" ] || git config --global user.email "agent@dsh.local"
[ -n "$(git config --global user.name  || true)" ] || git config --global user.name  "DeepSeek Harness"

# The hash is computed per boot rather than stored: the deployer sets a
# plaintext variable, and a bcrypt hash in the Railway UI would be a variable
# nobody could read back or change.
PASSWORD_HASH="$(caddy hash-password --plaintext "$DSH_UI_USER_PASSWORD")"

cat > /tmp/Caddyfile <<CADDY
{
	admin off
	auto_https off
	persist_config off
	servers {
		trusted_proxies static private_ranges
	}
}

:${PORT} {
	# Unauthenticated on purpose and deliberately NOT proxied: it answers for
	# Railway's healthcheck only. Caddy is not started until dsh is serving and
	# this process exits when either half dies, so Caddy answering at all is
	# already the statement that dsh came up.
	handle /healthz {
		respond "ok" 200
	}

	handle {
		basic_auth {
			${DSH_UI_USERNAME} ${PASSWORD_HASH}
		}

		reverse_proxy 127.0.0.1:${DSH_INTERNAL_PORT} {
			# REQUIRED, not cosmetic. Upstream's /api fence refuses any request
			# whose Host is neither loopback nor a declared trustedHost, and it
			# pins settings/credentials/pickDirectory to a LOOPBACK Host
			# specifically. Forwarding the Railway domain here (even with
			# --trusted-host) yields a UI that loads and then 403s on the
			# Settings page, which is the shape this line exists to avoid.
			header_up Host 127.0.0.1:${DSH_INTERNAL_PORT}

			# With Host rewritten to loopback, a forwarded browser Origin of
			# https://<app>.up.railway.app no longer equals the Host authority
			# and upstream's origin fence would reject every request. Absent
			# Origin is explicitly accepted by that fence, so strip it.
			# sec-fetch-site is deliberately left intact: upstream still refuses
			# an explicit cross-site marker, and Caddy answers no CORS preflight,
			# so cross-site POSTs remain blocked even though basic-auth
			# credentials would ride along.
			header_up -Origin

			# WebSocket downlinks (/api/events.mux, /api/events.host) are
			# ordinary upgrades to Caddy; no extra config, but they are the first
			# thing to break if this block is edited.
		}
	}
}
CADDY

cleanup() {
  trap - TERM INT
  [ -n "${DSH_PID:-}" ] && kill "$DSH_PID" 2>/dev/null || true
  [ -n "${CADDY_PID:-}" ] && kill "$CADDY_PID" 2>/dev/null || true
}
trap cleanup TERM INT

echo "==> starting dsh on 127.0.0.1:${DSH_INTERNAL_PORT} (workspace ${DSH_WORKSPACE})"
cd "$DSH_WORKSPACE"
dsh web --no-open --port "$DSH_INTERNAL_PORT" &
DSH_PID=$!

for attempt in $(seq 1 180); do
  if curl -sf -o /dev/null "http://127.0.0.1:${DSH_INTERNAL_PORT}/"; then
    echo "==> dsh is serving after ${attempt}s"
    break
  fi
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "FATAL: dsh exited during startup" >&2
    exit 1
  fi
  sleep 1
done

if ! curl -sf -o /dev/null "http://127.0.0.1:${DSH_INTERNAL_PORT}/"; then
  echo "FATAL: dsh did not answer on 127.0.0.1:${DSH_INTERNAL_PORT} within 180s" >&2
  cleanup
  exit 1
fi

echo "==> starting caddy on :${PORT} (basic auth user ${DSH_UI_USERNAME})"
caddy run --config /tmp/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Either half dying takes the container down so Railway restarts the pair
# together. A surviving Caddy in front of a dead dsh is the exact false-green
# this avoids.
wait -n
status=$?
echo "==> a supervised process exited (status ${status}); shutting down"
cleanup
exit "$status"
