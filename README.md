# airi-cli

![Version](https://img.shields.io/badge/version-0.1.0--beta.2-orange)

Command-line tool for the Airi wallet. Authenticate with OAuth, inspect your
session, and drive an **agentic checkout** — list payment methods, create a
payment mandate, fetch the single-use checkout credential, and report the
result — from your terminal or an AI agent.

Results are printed to stdout as JSON, so they are easy to consume from scripts
and agents.

## Installation

airi-cli is available for macOS and Linux as a single self-contained binary.

### npm

```bash
npm install -g @airwallex/airi-cli@beta
```

This installs the `@airwallex/airi-cli` package, which downloads the prebuilt
binary for your platform, verifies its SHA256 checksum, and puts `airi-cli` on
your `PATH`.

To run it once without installing globally, use npx:

```bash
npx @airwallex/airi-cli@beta
```

#### Switching from a `curl | sh` install

If you previously installed with the `install.sh` script (via `curl`), remove
that copy first — otherwise it may stay ahead of the npm one on your `PATH` and
keep shadowing it, so `airi-cli` keeps running the old binary.

Check for more than one `airi-cli` on your `PATH`:

```bash
which -a airi-cli
```

If an entry under `~/.local/bin` (the `install.sh` default) shows up alongside
the npm one, remove the old install:

```bash
curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh -s -- uninstall
```

Then reopen your shell and re-check with `which -a airi-cli`.

### install.sh (fallback)

If npm is not available, install the binary directly with the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh
```

To uninstall (removes the binary and local state):

```bash
curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh -s -- uninstall
```

### Install-time environment variables

Both install methods honour the same variables and behave identically, except
where noted:

| Variable | Description |
|----------|-------------|
| `AIRI_CLI_VERSION` | Install a specific release tag (e.g. `v0.1.0`) instead of the default. With npm the pinned checksum only matches the package's own version, so overriding it there also requires `AIRI_CLI_SKIP_CHECKSUM=1`. |
| `AIRI_CLI_INSTALL_DIR` | install.sh only: where to install (default: `$HOME/.local/bin`). npm always installs inside the package and ignores this. |
| `AIRI_CLI_SKIP_CHECKSUM` | **Local development only.** Set to `1` to bypass SHA256 verification. Never use this in production or CI. |
| `AIRI_CLI_SKIP_SKILLS` | Set to `1` to skip deploying the bundled agent skills. |

Both methods deploy the bundled agent skills at install time. You can also
deploy them to a specific project with:

```bash
npx skills add airwallex/airi-cli
```

or re-run deployment any time with `airi-cli skills install` (see
[Skills](#skills)).

### Checking for updates

`airi-cli version` prints the installed version; `airi-cli version --check` also
asks GitHub for the latest published release and reports whether an update is
available:

```bash
airi-cli version            # e.g. 0.1.0
airi-cli version --check     # reports whether a newer release exists
```

In JSON mode (the default for non-interactive callers) `--check` returns:

```json
{"current":"0.1.0","latest":"0.2.0","update_available":true,
 "install_command":"npm install -g @airwallex/airi-cli"}
```

To update, run the `install_command` from that response to replace the binary
with the latest release. The check is best-effort and never
fails the command: if GitHub can't be reached it reports
`update_available: false` with a `check_error` field, so it is safe to run as a
pre-flight step.

## Quick start

Sign in:

```bash
airi-cli auth login
```

`login` shows a verification URL and a code:

```
╭─ Sign in to Airi ─────────────────────────────────╮
│ Open this URL and enter the code to sign in:      │
│                                                   │
│   https://app.airi.com/device                     │
│   Code: WXYZ-1234                                 │
│                                                   │
│ Expires in 10 min. Press Enter to open it in your │
│ browser.                                          │
│ Waiting for authorization…                        │
╰───────────────────────────────────────────────────╯
```

Open the URL in a browser (or press Enter to open it for you), enter the code,
and approve. The command confirms once you're signed in:

```
╭─ airi-cli ──────────────────────────────────────────────╮
│ ✓  Signed in                                             │
│    Session expires: 2026-08-12 18:00 +08 (in 29 days)    │
╰──────────────────────────────────────────────────────────╯
```

Check your status at any time:

```bash
airi-cli auth whoami
```

`whoami` reports the current sign-in status and refreshes the session token
when it is close to expiring, so the reported expiry reflects the renewed
session. In JSON output (`-o json`, the default for scripts and agents) the
expiry is the `session_expires` field as an RFC3339 timestamp.

Every command refreshes the access token automatically — proactively before
each call when it is close to expiring, and reactively if the server rejects
it — so you never have to refresh it manually. If a command still reports an
expired or unauthenticated session, the token could not be refreshed: sign in
again with `airi-cli auth login` and retry.

List the payment methods available for agentic checkout (a quick way to confirm
your access token works):

```bash
airi-cli payment-methods list
```

## Agentic checkout

The `mandate` commands drive a checkout on the user's behalf. The typical flow,
after `auth login`, is:

1. **Pick a payment method** — `airi-cli payment-methods list` returns the cards
   available for agentic checkout; keep the `paymentMethodId` you want to use.
2. **Create a mandate** — `airi-cli mandate create` records the merchant, order
   total, currency, and line items. The response includes a `mandate_id` and a
   passkey/verification URL for the user to approve the payment.

   ```bash
   airi-cli mandate create \
     --source "<agent-name>" \
     --payment-method-id "<payment-method-id>" \
     --merchant-name "Acme" --merchant-url "https://acme.example" \
     --merchant-country "US" \
     --total-amount "42.00" --currency "USD" \
     --item "name:Widget,unit_price:21.00,quantity:2" \
     --description "Order #1234"
   ```

3. **Fetch the credential** — after the user approves in their browser,
   `airi-cli mandate get-credential --mandate-id <id>` polls until the mandate is
   authorized and returns a single-use credential (tokenized PAN, expiry, CVV).
   Prefer `--file <path>`: the full credential is written to a `0600` file and
   stdout shows only a receipt (`status`, `tokenType`, and `tokenExpiration`),
   so the secret stays out of your terminal, logs, and an agent's transcript.

   ```bash
   airi-cli mandate get-credential --mandate-id "<mandate-id>" --file /tmp/airi-cred.json
   ```

4. **Report the result** — after submitting the checkout, always report the
   outcome with `airi-cli mandate result --mandate-id <id> --result <SUCCEEDED|CANCELLED|DECLINED>`.

## Commands

| Command | Description |
| --- | --- |
| `airi-cli auth login` | Sign in via the OAuth device flow. |
| `airi-cli auth poll` | Wait for a non-blocking login to be approved. |
| `airi-cli auth whoami` | Print the current sign-in status. |
| `airi-cli auth logout` | Sign out by removing the stored session (local only). |
| `airi-cli payment-methods list` | List payment methods available for agentic checkout. |
| `airi-cli mandate create` | Create a payment mandate for a checkout. |
| `airi-cli mandate get-credential` | Poll for and fetch the single-use checkout credential. |
| `airi-cli mandate result` | Report the transaction outcome for a mandate. |
| `airi-cli skills install` | Deploy the bundled agent skills into local AI-agent skill directories. |
| `airi-cli skills list` | List the agent skills bundled in the binary. |
| `airi-cli version` | Print the CLI version (add `--check` to check for a newer release). |

Flags for `airi-cli version`:

| Flag | Default | Description |
| --- | --- | --- |
| `--check` | `false` | Check GitHub for the latest release and report whether an update is available. |

Flags for `airi-cli auth login`:

| Flag | Default | Description |
| --- | --- | --- |
| `--client-name` | `CLI` | Name to register this client under. |

Flags for `airi-cli auth whoami`:

| Flag | Default | Description |
| --- | --- | --- |
| `--verbose` | `false` | Include device details (name, platform, device id). |

Flags for `airi-cli mandate create` (all required):

| Flag | Description |
| --- | --- |
| `--source` | Agent source identifier (use the calling agent's name). |
| `--payment-method-id` | Payment method ID from `payment-methods list`. |
| `--merchant-name` | Merchant name. |
| `--merchant-url` | Merchant URL. |
| `--merchant-country` | Merchant country code. |
| `--total-amount` | Total order amount. |
| `--currency` | Order currency code. |
| `--item` | Line item as `name:<product>,unit_price:<price>,quantity:<n>` (repeat `--item` per item). |
| `--description` | Mandate description. |

Flags for `airi-cli mandate get-credential`:

| Flag | Default | Description |
| --- | --- | --- |
| `--mandate-id` | — | Mandate ID (required). |
| `--interval` | `2` | Poll interval while waiting for authorization (seconds). |
| `--timeout` | `300` | Stop polling after this many seconds. |
| `--file` | — | Write the credential to this file (`0600`) instead of printing it; stdout shows only a receipt with `status`, `tokenType`, and the token `tokenExpiration` (no sensitive values). |
| `--force` | `false` | Overwrite the `--file` target if it already exists. |

Flags for `airi-cli mandate result`:

| Flag | Description |
| --- | --- |
| `--mandate-id` | Mandate ID (required). |
| `--result` | Transaction result: `SUCCEEDED`, `CANCELLED`, or `DECLINED` (required). |
| `--reason` | Optional reason, e.g. when the result is `DECLINED`. |

Global flags:

| Flag | Description |
| --- | --- |
| `-o`, `--output` | Output format: `auto` (default), `text`, or `json`. |
| `--pretty` | Pretty-print JSON output (JSON mode only). |
| `--no-telemetry` | Disable anonymous usage telemetry for the invocation. |
| `-V`, `--version` | Print the CLI version. |

### Output

`--output auto` (the default) renders human-friendly boxed **text** on an
interactive terminal and machine-readable **JSON** when the output is piped or
redirected — so scripts and agents get JSON automatically without any flag.
Force a mode with `-o text` or `-o json`. In JSON mode, `--pretty` indents the
output. `auth whoami` and `auth login` omit device diagnostics
(`name`/`platform`/`device_id`) by default; `auth whoami --verbose` includes
them.

Times are reported in your **local timezone** (from the environment's `TZ` /
host setting). In text mode the expiry carries the local offset (e.g.
`2026-08-12 18:00 +08`); in JSON mode timestamps such as `session_expires` and
the credential's `tokenExpiration` are RFC3339 values with the local offset.

## Telemetry

The CLI sends anonymous usage events — command name, exit code, duration,
platform, and runtime/agent context — to help improve the tool. Events contain
no tokens, no account information, and no command arguments, and are keyed by a
random per-install identifier.

Disable telemetry with any of:

- the `--no-telemetry` flag,
- `AIRI_TELEMETRY_DISABLED=1` (or `DISABLE_TELEMETRY=1`),
- an empty `telemetryUrl` in your config.

## Skills

airi-cli bundles agent skill definitions that describe how an AI agent uses the
tool. They are embedded into the binary, so every install carries the skills for
its version. The install script deploys them for you; you can also (re)deploy
them at any time:

```bash
airi-cli skills install                     # canonical dir + detected agents
airi-cli skills install --all               # every known agent, detected or not
airi-cli skills install --dir ./my-skills   # explicit destination(s)
airi-cli skills list                        # show which skills the binary carries
```

`skills install` **auto-detects** installed agents. It always writes the
canonical `~/.agents/skills` (the open Agent Skills standard location), and
additionally writes each known agent whose config directory already exists:

| Agent | Detected via | Skills dir |
| --- | --- | --- |
| Claude Code | `~/.claude/` | `~/.claude/skills` |
| opencode | `~/.config/opencode/` | `~/.config/opencode/skills` |
| Codex | `~/.codex/` | `~/.codex/skills` |
| Cursor | `~/.cursor/` | `~/.cursor/skills` |
| Windsurf | `~/.codeium/windsurf/` | `~/.codeium/windsurf/skills` |
| GitHub Copilot | `~/.copilot/` | `~/.copilot/skills` |
| Gemini CLI | `~/.gemini/` | `~/.gemini/skills` |

Use `--all` to write every known agent dir regardless of detection, or `--dir`
to pick your own. Skills are copied (not symlinked), so re-running
`skills install` after an upgrade re-syncs every target.
