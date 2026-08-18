#!/usr/bin/env python3
"""One-time interactive Garmin Connect login.

Run this yourself in a terminal — it prompts for your Garmin Connect email,
password, and MFA code. Nothing is stored except Garmin's own OAuth tokens,
which land in ~/.config/agent-widgets/garth/ and refresh themselves for about
a year. Your password is never written to disk.

    ~/.config/agent-widgets/venv/bin/python ~/.config/agent-widgets/garmin-login.py
"""

import getpass
import os
import sys
import warnings

warnings.filterwarnings("ignore")  # urllib3 LibreSSL notice

import garth  # noqa: E402

TOKEN_DIR = os.path.expanduser("~/.config/agent-widgets/garth")


def main():
    email = input("Garmin Connect email: ").strip()
    password = getpass.getpass("Password (not stored): ")

    try:
        garth.login(email, password)
    except Exception as exc:
        print(f"login failed: {exc}", file=sys.stderr)
        return 1

    os.makedirs(TOKEN_DIR, exist_ok=True)
    os.chmod(TOKEN_DIR, 0o700)
    garth.save(TOKEN_DIR)

    print(f"\nSigned in as {garth.client.profile.get('displayName', '?')}")
    print(f"Tokens saved to {TOKEN_DIR} (mode 700).")
    print("The health card will pick them up on the next refresh.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
