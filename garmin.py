#!/usr/bin/env python3
"""Refresh the Garmin health snapshot.

Reads the OAuth tokens written by garmin-login.py, pulls today's summary from
Garmin Connect, and writes a sanitized snapshot to garmin.json. Runs under the
venv (it needs garminconnect); collect.py only ever reads the JSON, which is
what keeps the collector itself stdlib-only.

Prints nothing on success. On missing/expired tokens it prints NEEDS_LOGIN to
stderr and exits 2 — the marker matters, because a plain exit 2 is also what
python itself returns for "can't open file".
"""

import json
import os
import sys
import time
import warnings
from datetime import date, timedelta

warnings.filterwarnings("ignore")  # urllib3 LibreSSL notice

CONFIG_DIR = os.path.expanduser("~/.config/agent-widgets")
TOKEN_DIR = os.path.join(CONFIG_DIR, "garth")
OUT_FILE = os.path.join(CONFIG_DIR, "garmin.json")
NEEDS_LOGIN = "NEEDS_LOGIN"


def clamp(value):
    if value is None:
        return None
    try:
        return max(0, min(100, int(round(float(value)))))
    except (TypeError, ValueError):
        return None


def call(fn, *args):
    """Garmin returns 404s for metrics the watch didn't record. Never fatal."""
    try:
        return fn(*args)
    except Exception as exc:
        print(f"{getattr(fn, '__name__', fn)}: {type(exc).__name__}", file=sys.stderr)
        return None


def main():
    if not os.path.isdir(TOKEN_DIR):
        print(NEEDS_LOGIN, file=sys.stderr)
        return 2

    from garminconnect import Garmin

    api = Garmin()
    try:
        api.login(TOKEN_DIR)
    except Exception as exc:
        print(f"login: {exc}", file=sys.stderr)
        print(NEEDS_LOGIN, file=sys.stderr)
        return 2

    today = date.today().isoformat()
    stats = call(api.get_stats, today) or {}

    # Sleep and HRV describe last night, and Garmin files them under today's
    # date only once the watch has synced. Fall back to yesterday so the card
    # isn't blank first thing in the morning.
    sleep = call(api.get_sleep_data, today) or {}
    if not (sleep.get("dailySleepDTO") or {}).get("sleepScores"):
        sleep = call(api.get_sleep_data, (date.today() - timedelta(days=1)).isoformat()) or {}

    hrv = call(api.get_hrv_data, today) or {}
    if not hrv:
        hrv = call(api.get_hrv_data, (date.today() - timedelta(days=1)).isoformat()) or {}

    readiness = call(api.get_training_readiness, today) or []
    if isinstance(readiness, list):
        readiness = readiness[0] if readiness else {}

    sleep_dto = sleep.get("dailySleepDTO") or {}
    sleep_score = ((sleep_dto.get("sleepScores") or {}).get("overall") or {}).get("value")
    sleep_seconds = sleep_dto.get("sleepTimeSeconds")

    hrv_summary = hrv.get("hrvSummary") or {}

    steps = stats.get("totalSteps")
    goal = stats.get("dailyStepGoal") or 0

    snapshot = {
        "fetched_at": int(time.time()),
        "body_battery": clamp(stats.get("bodyBatteryMostRecentValue")),
        "sleep_score": clamp(sleep_score),
        "sleep_seconds": sleep_seconds,
        "steps": steps,
        "step_goal": goal or None,
        "steps_pct": clamp(100 * steps / goal) if steps and goal else None,
        "resting_hr": stats.get("restingHeartRate"),
        "hrv_status": hrv_summary.get("status"),
        "hrv_last_night": hrv_summary.get("lastNightAvg"),
        "stress": clamp(stats.get("averageStressLevel")),
        "readiness": clamp(readiness.get("score")) if readiness else None,
    }

    tmp = f"{OUT_FILE}.tmp"
    with open(tmp, "w") as handle:
        json.dump(snapshot, handle)
    os.replace(tmp, OUT_FILE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
