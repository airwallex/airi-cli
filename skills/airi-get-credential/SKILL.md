---
name: airi-get-credential
description: Get a one-time payment credential (tokenized PAN, expiry, CVV) from the user's Airi wallet so an agent can safely complete checkout in a browser without ever handling the user's real card details. Use when the user wants to pay for something on a merchant website with a card saved in their Airi wallet.
---

# Get Credential

## Overview

Use the `airi-cli` tool to obtain a single-use payment credential from the user's Airi wallet and complete a browser checkout on their behalf. The credential is filled into a merchant's checkout form like a normal card. Work through the steps below in order.

## Prerequisites

Make sure a proper `airi-cli` is installed before authenticating the user.

- **Confirm it is installed.** Run `airi-cli --help` yourself — do not rely on the user. If it is not found, install it (see *Installing* below).

- **Check for updates.** Run `airi-cli version --check`.
  - If the `--check` flag is not recognized (the command errors on the unknown flag), the installed build predates this feature — reinstall it (see *Installing* below), then re-run.
  - Otherwise, if the response has `"update_available":true`, run its `install_command` to upgrade and tell the user. `false` → continue. The check never blocks.

**Installing.**

- **If npm is available**, use it:
  ```bash
  npm install -g @airwallex/airi-cli@beta
  ```
  Then run `which -a airi-cli`. If an old `install.sh` copy (under `~/.local/bin`) also appears and would shadow the npm one, remove it:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh -s -- uninstall
  ```
- **If npm is not available**, use the install script:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh
  ```

## Your agent name

Several commands take an agent name (`--client-name` at login, `--source` when creating a mandate). Use **your own** clear, recognizable, and unique name — the name of the agent that is running this skill (e.g. the assistant's product name). Do not copy the `<agent-name>` placeholder verbatim, and use the same name consistently across all commands.

## Security rules

- The credential is single-use and scoped to one checkout. Never reuse, log, or store it beyond the current transaction.
- This credential covers a **single charge only**. If the user is paying for a subscription or anything that rebills, let them know this one-time credential will not auto-renew future billing cycles. Still complete the current one-time payment if they want to proceed.
- Never ask the user for their raw card number — using Airi is what avoids that.
- Only create a mandate for the exact merchant, amount, and items the user is checking out.
- Always report the result (Step 5) after checkout, whatever the outcome.

## Step 1 — Authenticate the user

Check whether the user is logged in:

```bash
airi-cli auth whoami
```

Decide what to do next from the **`authenticated`** field in the result:

- `"authenticated": true` — the user is signed in. Skip the rest of this step. (`whoami` refreshes the token automatically when it is close to expiring, so a still-usable session always reports `true`.)
- `"authenticated": false` — the user is not signed in, or the session expired and could not be refreshed. Continue with login below.

To start login, pass your own agent name as `--client-name` (see "Your agent name" above):

```bash
airi-cli auth login --client-name <agent-name>
```

When called by an agent (a non-interactive, non-TTY caller), `auth login` is **non-blocking**: it returns immediately as JSON, e.g. `{"status":"awaiting_authorization","verification_uri":"...","user_code":"...","expires_in":900,"interval":2}`.

**Before polling, you MUST first present the login to the user.** Read `verification_uri` and `user_code` verbatim from that JSON and show them prominently — URL on its own line, code on its own line — and ask the user to open the URL and approve.

Then poll until login completes:

```bash
airi-cli auth poll
```

Start polling **immediately** after showing the URL — do **not** wait for the user to tell you they have finished. A single `auth poll` call blocks and polls for a few minutes, then returns.

Run them with a tool timeout of **at least 5 minutes**, and do not pipe them through `head`/`tail` (it can drop output). If your own call is killed by a tool timeout, treat it as *still pending* — run `airi-cli auth poll` again. Do **not** treat a tool-level timeout as a login failure.

- While it keeps returning `"status": "authorization_pending"`, the user simply has not approved yet — run `airi-cli auth poll` **again** to keep waiting (tell the user you are still waiting). Do **not** re-run `airi-cli auth login`; that issues a new code and invalidates the one the user is approving.
- On **signed in**, continue.
- On **anything else** (an error such as the login code expiring or the user denying the request), show the result to the user and let them decide whether to keep polling or log in again.

### Re-authentication (applies to every step)

Every `airi-cli` command refreshes the access token automatically — proactively before each call when it is close to expiring, and reactively if the server rejects it — so you never need to refresh it yourself. Because of this, if a command still fails with an authentication or token error (for example the token is expired or has been revoked for this device, or a command reports the session as unauthenticated), the token could not be refreshed and the user must sign in again: repeat Step 1 (run `airi-cli auth login --client-name <agent-name>`, show the returned login URL to the user, then run `airi-cli auth poll` until authenticated), then retry the command that failed.

## Step 2 — List and select a payment method

```bash
airi-cli payment-methods list
```

If the list is **empty** (the user has no agent-enabled cards), do **not** proceed. Tell the user to open the Airi portal (`https://app.airi.com`) and either add a new card or edit an existing card to make it available to agents ("agentic"). Once they confirm they have done so, run `airi-cli payment-methods list` again. Only continue when at least one payment method is returned.

Otherwise, format the result into a clean, readable list and present it to the user (e.g. card brand, last 4 digits, expiry, nickname). Ask which payment method to use and keep its `payment-method-id` for the next step.

## Step 3 — Create a payment mandate

Once the user has chosen a payment method, gather the checkout details from the merchant page (merchant name, URL, country, total amount, currency, and each line item) and create a mandate. Pass your own agent name (the same one used at login) as `--source`:

```bash
airi-cli mandate create \
  --source "<agent-name>" \
  --payment-method-id "<id>" \
  --merchant-name "<name>" \
  --merchant-url "<url>" \
  --merchant-country "<country>" \
  --total-amount "<amount>" \
  --currency "<currency>" \
  --item "name:<product>,unit_price:<price>,quantity:<n>" \
  --description "<description>"
```

- Repeat `--item` once per line item on the order.
- Make sure `--total-amount` and `--currency` match what the merchant page shows.

The response contains a `mandate_id` and a `passkey_url`. **Before continuing to Step 4, you MUST present the passkey URL to the user** . Read `passkey_url` verbatim and show it prominently on its own line, and ask the user to open it and confirm the transaction. Keep the `mandate_id` for the next steps. This passkey confirmation is the user's approval of the payment.

## Step 4 — Get the payment credential

**Immediately** after presenting the passkey URL, run the get-credential command — do **not** wait for the user to tell you they have finished. Pass `--file <path>` so the credential is written to a local file instead of being printed:

```bash
airi-cli mandate get-credential \
  --mandate-id "<mandate-id>" \
  --file /tmp/airi-cred.json
```

This command **blocks and polls** while the user confirms in their browser, returning as soon as they have confirmed. Run it with a tool timeout of **at least 5 minutes** and do not pipe it through `head`/`tail`.

**Always use `--file`.** It is the safe way to handle the one-time credential:

- The full credential — the **tokenized PAN**, **expiry**, and **CVV** — is written to the file you name, created with `0600` (owner-only) permissions. The command refuses to overwrite an existing file (pass `--force` to replace it) and refuses to write through a symlink.
- To fill the merchant's checkout form, read the raw values **from the file** at the moment you need them. Do **not** echo them back to the user or copy them into your memory, notes, or a summary.
- **Delete the file** (e.g. `rm /tmp/airi-cred.json`) once the checkout has been submitted.

A timeout means the user has not confirmed yet — not a failure. This covers both the command's own timeout (`Timed out after …s waiting for credential authorization.`) and your own call being killed by a tool timeout; nothing is written to `--file` in either case. On a timeout, tell the user you are still waiting and run the same command again. On **any other error**, surface it to the user rather than retrying blindly.

## Step 5 — Report the transaction result

After the checkout has been submitted on the merchant site, read the final state of the page and report the outcome back to Airi. This step is mandatory regardless of the result:

```bash
airi-cli mandate result \
  --mandate-id "<mandate-id>" \
  --result "<result>" \
  --reason "<reason>"
```

- `--result` must be one of `SUCCEEDED`, `CANCELLED`, or `DECLINED`.
- `--reason` is optional; use it to explain why a result is `DECLINED`.

