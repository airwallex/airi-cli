---
name: airi-get-credential
description: Get a one-time payment credential (tokenized PAN, expiry, CVV) from the user's Airi wallet so an agent can safely complete checkout in a browser without ever handling the user's real card details. Use when the user wants to pay for something on a merchant website with a card saved in their Airi wallet.
---

# Get Credential

## Overview

Use the `airi-cli` tool to obtain a single-use payment credential from the user's Airi wallet and complete a browser checkout on their behalf. The credential is filled into a merchant's checkout form like a normal card. Work through the steps below in order.

## Prerequisites

- `airi-cli` is installed and available on the `PATH`. Always run `airi-cli --help` yourself to confirm this — do not rely on the user's statement about whether it is installed. If the command is not found, help the user install it before continuing:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh
  ```

  The installer downloads the binary to `~/.local/bin` and updates the shell's PATH — after it finishes, the user may need to restart their shell (or `source` their rc file) before `airi-cli` is available.

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

If `whoami` already shows the user as authenticated, skip the rest of this step.

Otherwise, start login. Pass your own agent name as `--client-name` (see "Your agent name" above):

```bash
airi-cli auth login --client-name <agent-name>
```

When called by an agent (a non-interactive, non-TTY caller), `auth login` is **non-blocking**: it returns immediately with a login URL (`verification_uri`) and a `user_code`. Present the login URL and code to the user and ask them to open it and approve the connection.

Then poll until login completes:

```bash
airi-cli auth poll
```

Start polling **immediately** after showing the URL — do **not** wait for the user to tell you they have finished. `auth poll` blocks and polls until the user has approved (or the poll window elapses).

- If it returns `"status": "authorization_pending"` (`timeout: true`), the login is still pending — run `airi-cli auth poll` again to keep waiting, and let the user know you are still waiting.
- If it returns any other error, surface it to the user.

When the user is authenticated, continue.

### Re-authentication (applies to every step)

If any `airi-cli` command fails with an authentication or token error — for example the token has expired or has been revoked for this device — repeat Step 1 (run `airi-cli auth login --client-name <agent-name>`, show the returned login URL to the user, then run `airi-cli auth poll` until authenticated), then retry the command that failed.

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

The response contains a `mandate_id` and a `passkey_url`. Prompt the user to open the `passkey_url` in their browser and confirm the transaction. This passkey confirmation is the user's approval of the payment — there is no need to ask the user to confirm the purchase again later.

## Step 4 — Get the payment credential

**Immediately** after presenting the passkey URL, run the get-credential command — do **not** wait for the user to tell you they have finished. Pass `--file <path>` so the credential is written to a local file instead of being printed:

```bash
airi-cli mandate get-credential \
  --mandate-id "<mandate-id>" \
  --file /tmp/airi-cred.json
```

This command **blocks and polls periodically**, waiting while the user confirms in their browser, and returns as soon as the user has confirmed (or fails if it times out).

**Always use `--file`.** It is the safe way to handle the one-time credential:

- The full credential — the **tokenized PAN**, **expiry**, and **CVV** — is written to the file you name, created with `0600` (owner-only) permissions. The command refuses to overwrite an existing file (pass `--force` to replace it) and refuses to write through a symlink.
- To fill the merchant's checkout form, read the raw values **from the file** at the moment you need them. Do **not** echo them back to the user or copy them into your memory, notes, or a summary.
- **Delete the file** (e.g. `rm /tmp/airi-cred.json`) once the checkout has been submitted.

- If it times out, tell the user and ask whether to keep waiting; if yes, run the same command again.
- If it returns any other error, surface it to the user rather than retrying blindly.

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

