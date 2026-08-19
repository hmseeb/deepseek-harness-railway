# DSH Coding Agent on Railway

DeepSeek's own coding agent, `dsh`, running as a persistent web app on Railway
behind a password you set.

Deploy: https://railway.com/deploy/dsh-coding-agent

## What you get

One container. Inside it:

- **DeepSeek Harness** (`dsh web`), the agent harness DeepSeek publishes at
  [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness),
  pinned to `0.1.0-rc.7`. Full coding agent: file editing, shell, file and web
  search, skills, planning, goals, subagents, workflows.
- **Caddy**, holding the public port with HTTP basic auth and forwarding to the
  harness on loopback.
- A **volume** at `/data` holding the harness home (sessions, settings, the
  credential store) and your workspace, so a redeploy does not lose your work.

Your DeepSeek API key is read from the environment, so the Models page is
already configured the first time you open it.

## Why there is a password on it

This is the part worth reading before you deploy.

`dsh`'s web API drives an agent that runs bash. Upstream is explicit about what
that means: the harness **refuses** to bind a public address at all. Ask it to
and it stops with

```
error: --host 0.0.0.0 is intentionally not supported yet for safety:
it would expose remote code execution to the network; use 127.0.0.1 instead
```

and its own architecture docs state that "the Web carrier provides no
authentication layer".

This template does not patch that out. The harness still binds `127.0.0.1`
exactly as upstream intends, and Caddy is the only process on the public port.
Everything reaching the harness has already passed basic auth.

That makes the password the entire security boundary. Treat it accordingly:

- Keep the generated one. It is 32 random characters. If you replace it, replace
  it with something equally unguessable.
- Anyone who has it can run arbitrary commands in this container and read your
  DeepSeek API key.
- Do not put a shared or reused password here.

## One patched line

The harness gates its entire configuration UI on the client side, by reading the
page's own hostname:

```js
isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)
```

There is no setting for it. Served from any real domain that flag is false, the
settings scope silently falls back to an in-memory store, and Settings > Models
fails with "settings are unavailable in this browser". The image rewrites that
one expression to `isLoopback: true`.

Upstream's reason for the gate is that these methods stay loopback-only "until a
real authentication layer exists". This deployment has one in front of it, and
the page URL is not the security signal here; the password is. The build asserts
the expression before and after rewriting, so a version bump that reshapes it
fails the build rather than shipping a dead Settings page.

Nothing that needs a desktop is switched on by this. `host.describe` reports
`canOpenPath: false` on this container, so the file-open affordances stay hidden.

## Variables

| Variable | Required | What it does |
|---|---|---|
| `DEEPSEEK_API_KEY` | yes | Your key from [platform.deepseek.com](https://platform.deepseek.com/). Injected into the harness's credential store as the read-only `env` layer, which outranks anything stored in the UI. |
| `DSH_UI_PASSWORD` | yes | Basic auth password. Generated for you. |
| `DSH_UI_USERNAME` | no | Basic auth user, defaults to `admin`. |
| `DSH_WORKSPACE` | no | Directory the agent works in, defaults to `/data/workspace`. |
| `DSH_HOME` | no | Harness home, defaults to `/data/.dsh`. |

## First run

1. Open the deployment URL. The browser asks for the username and password.
2. Dismiss DeepSeek's testing notice.
3. Click **Choose workspace**, pick `workspace`, and click **Open**.
4. Type a task and send it.

Step 3 uses an in-app directory browser rather than an OS file dialog. The
harness picks that automatically on a headless host, so it works here and would
not have on a desktop.

## Using another provider

The Models page in **Settings** accepts keys for other providers and custom
OpenAI-compatible endpoints. A key stored there wins over `.env` layers but not
over `DEEPSEEK_API_KEY` in the environment, which is deliberate upstream
behaviour: an environment key is read-only and always effective. To make the UI
the source of truth for DeepSeek specifically, clear the `DEEPSEEK_API_KEY`
service variable.

## Persistence

The volume mounts at `/data`:

- `/data/.dsh` is the harness home: sessions, settings, `.credentials.yaml`.
- `/data/workspace` is what the agent edits.

Both survive redeploys. Files written anywhere else in the container do not.

## Getting your code in

There is no git remote wired up for you. From a session, ask the agent to clone
what you want into the workspace, or use the shell it already has. Credentials
for private repositories are yours to add, and anything you add lands in the
volume.

## Upgrading

The image pins `0.1.0-rc.7`. DeepSeek Harness is in developer preview and its
own README warns of compatibility-breaking changes, which is why this is pinned
rather than tracking latest. To move, change the service image tag to a newer
`0.1.0-rc.N-rN` build and redeploy.

## Build

Image source: [hmseeb/deepseek-harness-railway](https://github.com/hmseeb/deepseek-harness-railway).
Built to `ghcr.io/hmseeb/deepseek-harness-railway` by GitHub Actions on push.

## License

DeepSeek Harness is MIT, by DeepSeek AI. This packaging is MIT too.
