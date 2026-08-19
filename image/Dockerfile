# DeepSeek Harness (dsh) for Railway.
#
# Upstream ships no container image and REFUSES to bind a non-loopback address:
# `--host 0.0.0.0` errors with "it would expose remote code execution to the
# network". That refusal is correct - the /api surface drives an agent that runs
# bash and there is no authentication layer in the product (see
# packages/client/connection/README.md upstream).
#
# So this image does not fight it. dsh keeps binding 127.0.0.1 exactly as
# upstream intends, and Caddy owns the public port with HTTP basic auth in
# front. Caddy rewrites Host to the loopback authority, which is what makes the
# whole thing work at all: upstream pins the privileged RPC plane (settings,
# credentials, directory picker) to a loopback Host, so a proxy that forwarded
# the Railway domain verbatim would serve a UI whose Settings page 403s.
FROM node:22-bookworm-slim

# caddy is a static Go binary; copying it out of the official image beats
# pinning a tarball URL that moves every release.
COPY --from=caddy:2.10 /usr/bin/caddy /usr/local/bin/caddy

# git and ripgrep are what the agent's own tools shell out to; curl is the
# entrypoint's readiness probe; procps/less are what a coding agent expects a
# shell to have.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep less procps tini python3 \
    && rm -rf /var/lib/apt/lists/*

ARG DSH_VERSION=0.1.0-rc.7
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" && npm cache clean --force

# Re-enable the settings plane for a non-loopback browser.
#
# The harness gates its whole configuration UI - Settings > Models, the
# credential store, the General settings document - on the CLIENT side, by
# reading the page's own hostname:
#
#   isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)
#
# There is no config knob for it. Served from any real domain the flag is
# false, the settings scope silently falls back to an in-memory store, and the
# Models page fails with "settings are unavailable in this browser".
#
# Upstream's stated reason for the gate is that these methods are pinned to a
# loopback caller "until a real authentication layer exists". This deployment
# has one in front of it, and the page URL is not a security signal here - the
# basic-auth password is. The server-side half of the same pin is already
# satisfied by the proxy's loopback Host rewrite, so this flag is the only
# thing left standing between the deployer and their own settings.
#
# Deliberately NOT a blanket patch: canOpenPath stays false on this host (the
# container advertises no native path-open capability), so nothing that needs a
# desktop is switched on by this.
#
# Both greps are assertions. If a version bump reshapes this expression the
# build fails here rather than shipping an image with a dead Settings page.
RUN F=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/client.js \
    && GATE='isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)' \
    && grep -qF "$GATE" "$F" \
    && python3 -c "import sys,pathlib; f=pathlib.Path(sys.argv[1]); t=f.read_text(); g=sys.argv[2]; assert t.count(g)==1, t.count(g); f.write_text(t.replace(g, 'isLoopback: true'))" "$F" "$GATE" \
    && grep -qF 'isLoopback: true' "$F"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Both live on the volume: DSH_HOME holds sessions, settings and the credential
# store; the workspace is what the agent actually edits.
ENV DSH_HOME=/data/.dsh \
    HOME=/data \
    DSH_WORKSPACE=/data/workspace \
    DSH_INTERNAL_PORT=3080 \
    DSH_UI_USERNAME=admin \
    PORT=8080

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
