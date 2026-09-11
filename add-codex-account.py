#!/usr/bin/env python3
"""Add a second Codex (ChatGPT) login and wire it into the panel.

The login itself is a browser OAuth flow against your own ChatGPT account, so
this has to be run by you — there is no headless path, and an API key will not
substitute: the usage endpoint needs the ChatGPT access token and account id
that only the browser flow stores, so `codex login --with-api-key` leaves a
card stuck on AUTH.

Everything either side of that step is automatic — it reports which account
each home already holds, refuses a login that would duplicate one, verifies
the result, writes accounts.json, and proves the panel picked both up.

    ./add-codex-account.py                      # ~/.codex-work, labelled "work"
    ./add-codex-account.py --home ~/.codex-alt --label alt

Re-running is safe: a home that is already signed in is left alone and only
the wiring is redone.
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys

CONFIG_DIR = os.path.dirname(os.path.abspath(__file__))
ACCOUNTS_FILE = os.path.join(CONFIG_DIR, "accounts.json")
COLLECTOR = os.path.join(CONFIG_DIR, "collect.py")
DEFAULT_HOME = "~/.codex"


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def codex_binary():
    """The real binary, never the shell function that wraps it.

    `codex` is a zsh function on this machine (session-halo claims a colour
    before delegating), and functions are not inherited by a child process.
    """
    found = shutil.which("codex", path="/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", ""))
    if not found:
        fail("codex is not on PATH — install it, or run this from a shell that has it")
    return found


def identity(home):
    """-> (email, plan) for a Codex home, or (None, None) if not signed in.

    Read from the id_token's own claims, which sit in the file already; no
    token is printed and nothing leaves the machine. `codex login status`
    reports only that a login exists, not which account it is — and *which*
    is the whole question when a second one is being added.
    """
    path = os.path.join(os.path.expanduser(home), "auth.json")
    try:
        with open(path) as handle:
            tokens = json.load(handle).get("tokens") or {}
    except Exception:
        return None, None
    raw = tokens.get("id_token") or ""
    if raw.count(".") != 2:
        return None, None
    try:
        payload = raw.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except Exception:
        return None, None
    plan = (claims.get("https://api.openai.com/auth") or {}).get("chatgpt_plan_type")
    return claims.get("email"), plan


def has_chatgpt_tokens(home):
    path = os.path.join(os.path.expanduser(home), "auth.json")
    try:
        with open(path) as handle:
            data = json.load(handle)
    except Exception:
        return False
    tokens = data.get("tokens") or {}
    return bool(tokens.get("access_token") and tokens.get("account_id"))


def describe(home):
    email, plan = identity(home)
    if not has_chatgpt_tokens(home):
        return "not signed in"
    return f"{email or 'unknown account'}" + (f" · {plan}" if plan else "")


def write_accounts(default_label, new_id, new_label, new_home):
    """Add the codex block, leaving the claude block exactly as it was."""
    config = {}
    if os.path.exists(ACCOUNTS_FILE):
        with open(ACCOUNTS_FILE) as handle:
            config = json.load(handle)
        shutil.copy(ACCOUNTS_FILE, ACCOUNTS_FILE + ".bak")
    config["codex"] = [
        {"id": "codex", "label": default_label, "codex_home": DEFAULT_HOME},
        {"id": new_id, "label": new_label, "codex_home": new_home},
    ]
    with open(ACCOUNTS_FILE, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", default="~/.codex-work",
                        help="CODEX_HOME for the second account (default: ~/.codex-work)")
    parser.add_argument("--label", default="work",
                        help="what the panel prints for it (default: work)")
    parser.add_argument("--default-label", default="personal",
                        help="what the panel prints for ~/.codex (default: personal)")
    args = parser.parse_args()

    home = args.home
    if os.path.expanduser(home).rstrip("/") == os.path.expanduser(DEFAULT_HOME).rstrip("/"):
        fail("--home must differ from ~/.codex, or the second login overwrites the first")

    print(f"~/.codex        {describe(DEFAULT_HOME)}")
    print(f"{home:<15} {describe(home)}")
    print()

    if has_chatgpt_tokens(home):
        print(f"{home} is already signed in; leaving it alone and redoing the wiring.")
    else:
        expanded = os.path.expanduser(home)
        os.makedirs(expanded, mode=0o700, exist_ok=True)
        print(f"Opening a browser to sign in to {home}.")
        print("Pick the OTHER ChatGPT account — signing in as the same one leaves you")
        print("with two identical cards.\n")
        env = dict(os.environ, CODEX_HOME=expanded)
        result = subprocess.run([codex_binary(), "login"], env=env)
        if result.returncode != 0:
            fail(f"codex login exited {result.returncode}; nothing was changed")
        if not has_chatgpt_tokens(home):
            fail(f"{home} has no ChatGPT tokens after login — an API key login cannot "
                 "report usage; re-run and use the browser flow")

    default_email, _ = identity(DEFAULT_HOME)
    new_email, _ = identity(home)
    if default_email and new_email and default_email == new_email:
        fail(f"both homes are signed in as {new_email}; sign {home} in as the other "
             "account, or the panel will show the same usage twice")

    new_id = "codex-" + "".join(c for c in args.label.lower() if c.isalnum() or c == "-")
    config = write_accounts(args.default_label, new_id or "codex-second", args.label, home)
    print("\naccounts.json:")
    print(json.dumps(config.get("codex"), indent=2))

    # Proof, not assumption: the panel renders whatever this prints.
    print("\nasking the collector for both cards...")
    out = subprocess.run([sys.executable, COLLECTOR, "--force"],
                         capture_output=True, text=True)
    try:
        cards = json.loads(out.stdout)["cards"]
    except Exception:
        fail(f"collector produced no usable JSON: {out.stderr.strip()[:200]}")
    for card in cards:
        if card.get("provider") == "codex":
            meters = ", ".join(f"{m['name']} {m['remaining']}%" for m in card.get("meters") or [])
            print(f"  {card['label']:<10} {card['state']:<8} {meters or '—'}")
    print("\nThe panel picks this up on its next 30s tick.")


if __name__ == "__main__":
    main()
