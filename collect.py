#!/usr/bin/env python3
"""Collect Claude Code + Codex usage into a sanitized cache for desktop widgets.

Prints only the sanitized cache JSON on stdout. Diagnostics go to stderr.
Never writes tokens, emails or account identifiers to the cache file.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

CONFIG_DIR = os.path.expanduser("~/.config/agent-widgets")
CACHE_FILE = os.path.join(CONFIG_DIR, "cache.json")
LOCK_FILE = os.path.join(CONFIG_DIR, "lock.json")

CACHE_TTL = 180  # seconds; matches ccstatusline
REQUEST_TIMEOUT = 5
DEFAULT_BACKOFF = 300

CURL = "/usr/bin/curl"
USER_AGENT = "codex-cli"
STATUS_MARK = "__agent_widgets_status__"
HEADER_MARK = "__agent_widgets_headers__"

ANTHROPIC_URL = "https://api.anthropic.com/api/oauth/usage"
ANTHROPIC_BETA = "oauth-2025-04-20"
KEYCHAIN_SERVICE = "Claude Code-credentials"

CODEX_URL = "https://chatgpt.com/backend-api/codex/usage"
CODEX_AUTH_FILE = os.path.expanduser("~/.codex/auth.json")


def warn(msg):
    print(msg, file=sys.stderr)


# --- transport ---------------------------------------------------------------


class HttpError(Exception):
    def __init__(self, status, retry_after=None):
        super().__init__(f"HTTP {status}")
        self.status = status
        self.retry_after = retry_after


def get_json(url, headers):
    """GET via system curl.

    Not urllib: macOS's bundled Python links LibreSSL 2.8.3, whose TLS
    handshake chatgpt.com's edge rejects with a 403. That edge also 403s
    HTTP/2, so the request is pinned to HTTP/1.1. Headers go in over stdin
    (`-H @-`) so bearer tokens never appear in argv / `ps` output.
    """
    header_blob = "".join(f"{name}: {value}\n" for name, value in headers.items())
    proc = subprocess.run(
        [
            CURL,
            "-sS",
            "--http1.1",
            "-m",
            str(REQUEST_TIMEOUT),
            "-A",
            USER_AGENT,
            "-H",
            "@-",
            "-w",
            f"\n{STATUS_MARK}%{{http_code}}\n{HEADER_MARK}%{{header_json}}",
            url,
        ],
        input=header_blob,
        capture_output=True,
        text=True,
        timeout=REQUEST_TIMEOUT + 5,
    )
    out = proc.stdout
    head_at = out.rfind(HEADER_MARK)
    status_at = out.rfind(STATUS_MARK, 0, head_at if head_at >= 0 else None)
    if status_at < 0:
        raise HttpError(0)

    status = int(out[status_at + len(STATUS_MARK) : head_at].strip() or 0)
    body = out[:status_at].rstrip("\n")

    if status == 200:
        return json.loads(body)

    retry_after = None
    if status == 429 and head_at >= 0:
        try:
            resp_headers = json.loads(out[head_at + len(HEADER_MARK) :])
            values = resp_headers.get("retry-after") or []
            retry_after = parse_retry_after(values[0] if values else None)
        except Exception:
            pass
    raise HttpError(status, retry_after)


def parse_retry_after(value):
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        seconds = int(value)
        return seconds if seconds > 0 else None
    try:
        from email.utils import parsedate_to_datetime

        delta = parsedate_to_datetime(value).timestamp() - time.time()
        return int(delta) if delta > 0 else None
    except Exception:
        return None


# --- credentials (read fresh every poll, never cached) -----------------------


def claude_token():
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        return json.loads(raw).get("claudeAiOauth", {}).get("accessToken")
    except Exception:
        pass
    # Non-macOS / no-keychain fallback used by Claude Code itself.
    try:
        cred_file = os.path.expanduser("~/.claude/.credentials.json")
        with open(cred_file) as handle:
            return json.load(handle).get("claudeAiOauth", {}).get("accessToken")
    except Exception:
        return None


def codex_credentials():
    try:
        with open(CODEX_AUTH_FILE) as handle:
            tokens = json.load(handle).get("tokens", {})
        return tokens.get("access_token"), tokens.get("account_id")
    except Exception:
        return None, None


# --- providers ---------------------------------------------------------------


def pct_remaining(used):
    if used is None:
        return None
    return max(0, min(100, 100 - int(round(float(used)))))


def iso_to_epoch(value):
    if not value:
        return None
    try:
        return int(datetime.fromisoformat(value).timestamp())
    except Exception:
        return None


def fetch_claude():
    token = claude_token()
    if not token:
        raise HttpError(401)
    data = get_json(
        ANTHROPIC_URL,
        {"Authorization": f"Bearer {token}", "anthropic-beta": ANTHROPIC_BETA},
    )
    meters = []
    for name, key in (("5h", "five_hour"), ("week", "seven_day")):
        window = data.get(key) or {}
        remaining = pct_remaining(window.get("utilization"))
        if remaining is None:
            continue
        meters.append(
            {
                "name": name,
                "remaining": remaining,
                "resets_at": iso_to_epoch(window.get("resets_at")),
            }
        )
    return {
        "id": "claude",
        "label": "Claude Code",
        "sub": None,  # Anthropic's response carries no plan/tier field.
        "kind": "meters",
        "meters": meters,
        "state": "ok",
    }


def fetch_codex():
    token, account_id = codex_credentials()
    if not token or not account_id:
        raise HttpError(401)
    data = get_json(
        CODEX_URL,
        {"Authorization": f"Bearer {token}", "chatgpt-account-id": account_id},
    )
    meters = []
    window = ((data.get("rate_limit") or {}).get("primary_window")) or {}
    remaining = pct_remaining(window.get("used_percent"))
    if remaining is not None:
        seconds = window.get("limit_window_seconds") or 0
        meters.append(
            {
                "name": "5h" if seconds and seconds <= 6 * 3600 else "week",
                "remaining": remaining,
                "resets_at": window.get("reset_at"),
            }
        )
    secondary = ((data.get("rate_limit") or {}).get("secondary_window")) or {}
    remaining = pct_remaining(secondary.get("used_percent"))
    if remaining is not None:
        meters.append(
            {
                "name": "week",
                "remaining": remaining,
                "resets_at": secondary.get("reset_at"),
            }
        )
    plan = data.get("plan_type")
    return {
        "id": "codex",
        "label": "Codex",
        "sub": str(plan) if plan else None,
        "kind": "meters",
        "meters": meters,
        "state": "ok",
    }


# --- model breakdown ---------------------------------------------------------
#
# Session logs are append-only, so they are scanned incrementally: the index
# remembers a byte offset per file and each pass reads only what was appended.
# A full first pass over ~250MB takes a while; every pass after is near-free.

MODELS_INDEX_FILE = os.path.join(CONFIG_DIR, "models-index.json")
CLAUDE_LOG_ROOT = os.path.expanduser("~/.claude/projects")
CODEX_LOG_ROOT = os.path.expanduser("~/.codex/sessions")

MODEL_WINDOW_DAYS = 7
MODEL_RETENTION_DAYS = 30
MODEL_ROWS = 4  # rows rendered; the rest fold into "Other"
MODEL_SLOTS = 5  # categorical colour slots before a model gets the "Other" grey

MODEL_LABELS = {
    "claude-opus-5": "Opus 5",
    "claude-sonnet-5": "Sonnet 5",
    "claude-fable-5": "Fable 5",
    "claude-haiku-4-5": "Haiku 4.5",
}


def model_label(model_id):
    if model_id in MODEL_LABELS:
        return MODEL_LABELS[model_id]
    name = model_id
    for prefix in ("claude-", "gpt-", "anthropic."):
        if name.startswith(prefix):
            name = name[len(prefix) :]
    return name


def scan_claude_line(record, state):
    """-> (day, model_id, output_tokens) or None."""
    if record.get("type") != "assistant":
        return None
    message = record.get("message") or {}
    model = message.get("model")
    if not model or model == "<synthetic>":
        return None
    timestamp = record.get("timestamp") or ""
    output = (message.get("usage") or {}).get("output_tokens") or 0
    if not timestamp or not output:
        return None
    return timestamp[:10], model, output


def scan_codex_line(record, state):
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return None
    # The model is declared once per turn; token counts arrive afterwards.
    if record.get("type") in ("turn_context", "session_meta"):
        if payload.get("model"):
            state["model"] = payload["model"]
        return None
    if payload.get("type") != "token_count" or not state.get("model"):
        return None
    timestamp = record.get("timestamp") or ""
    usage = (payload.get("info") or {}).get("last_token_usage") or {}
    output = usage.get("output_tokens") or 0
    if not timestamp or not output:
        return None
    return timestamp[:10], state["model"], output


SOURCES = [(CLAUDE_LOG_ROOT, scan_claude_line), (CODEX_LOG_ROOT, scan_codex_line)]


def scan_log(path, entry, parse):
    """Read appended bytes only. Returns True if the entry changed."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    offset = entry.get("offset", 0)
    if size < offset:  # truncated or rotated — start over
        offset, entry["offset"], entry["days"], entry["model"] = 0, 0, {}, None
    if size == offset:
        return False

    with open(path, "rb") as handle:
        handle.seek(offset)
        chunk = handle.read()

    lines = chunk.split(b"\n")
    tail = lines.pop()  # incomplete final line; re-read next pass
    consumed = len(chunk) - len(tail)

    days = entry.setdefault("days", {})
    state = {"model": entry.get("model")}
    for raw in lines:
        if not raw:
            continue
        try:
            record = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        result = parse(record, state)
        if result:
            day, model, output = result
            days.setdefault(day, {})
            days[day][model] = days[day].get(model, 0) + output

    entry["offset"] = offset + consumed
    entry["model"] = state.get("model")
    return True


def fetch_models():
    index = read_json(MODELS_INDEX_FILE) or {}
    files = index.setdefault("files", {})
    palette = index.setdefault("palette", {})

    seen = set()
    for root, parse in SOURCES:
        for dirpath, _, names in os.walk(root):
            for filename in names:
                if not filename.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, filename)
                seen.add(path)
                scan_log(path, files.setdefault(path, {}), parse)

    cutoff_keep = str(
        datetime.fromtimestamp(
            time.time() - MODEL_RETENTION_DAYS * 86400, tz=timezone.utc
        ).date()
    )
    for path in list(files):
        if path not in seen:
            del files[path]
            continue
        days = files[path].get("days") or {}
        for day in [d for d in days if d < cutoff_keep]:
            del days[day]

    cutoff = str(
        datetime.fromtimestamp(
            time.time() - MODEL_WINDOW_DAYS * 86400, tz=timezone.utc
        ).date()
    )
    totals = {}
    for entry in files.values():
        for day, models in (entry.get("days") or {}).items():
            if day < cutoff:
                continue
            for model, output in models.items():
                totals[model] = totals.get(model, 0) + output

    # Colour follows the model, not its rank: slots are assigned on first sight
    # and persisted, so a reshuffle in the ranking never repaints the others.
    for model in sorted(totals):
        if model not in palette:
            palette[model] = len(palette)
    write_json(MODELS_INDEX_FILE, index)

    if not totals:
        return {"id": "models", "kind": "models", "label": "Models",
                "sub": f"{MODEL_WINDOW_DAYS}d", "rows": [], "meters": [], "state": "ok"}

    grand = sum(totals.values())
    ranked = sorted(totals.items(), key=lambda item: -item[1])
    rows = []
    for model, output in ranked[:MODEL_ROWS]:
        slot = palette.get(model, MODEL_SLOTS)
        rows.append(
            {
                "label": model_label(model),
                "value": output,
                "share": round(100 * output / grand),
                "slot": slot if slot < MODEL_SLOTS else MODEL_SLOTS,
            }
        )
    rest = sum(output for _, output in ranked[MODEL_ROWS:])
    if rest and round(100 * rest / grand) >= 1:
        rows.append(
            {
                "label": "Other",
                "value": rest,
                "share": round(100 * rest / grand),
                "slot": MODEL_SLOTS,
            }
        )

    return {
        "id": "models",
        "kind": "models",
        "label": "Models",
        "sub": f"{MODEL_WINDOW_DAYS}d",
        "rows": rows,
        "meters": [],
        "state": "ok",
    }


# --- garmin health -----------------------------------------------------------
#
# The heavy lifting lives in garmin.py, which runs under the venv because it
# needs garminconnect. This side only reads the JSON it leaves behind, which is
# what keeps collect.py itself stdlib-only.

GARMIN_FILE = os.path.join(CONFIG_DIR, "garmin.json")
GARMIN_SCRIPT = os.path.join(CONFIG_DIR, "garmin.py")
GARMIN_PYTHON = os.path.join(CONFIG_DIR, "venv", "bin", "python")
GARMIN_TOKENS = os.path.join(CONFIG_DIR, "garth")
GARMIN_TTL = 900  # health metrics move slowly; 15 minutes is plenty
GARMIN_TIMEOUT = 45


def refresh_garmin():
    """Run the venv fetcher. -> "ok" | "reauth" | "failed".

    Dead or missing tokens need a new sign-in rather than a retry, and garmin.py
    marks that case on stderr. The marker is checked rather than the bare exit
    code because python itself exits 2 for "can't open file".
    """
    if not os.path.exists(GARMIN_PYTHON):
        return "failed"
    try:
        proc = subprocess.run(
            [GARMIN_PYTHON, GARMIN_SCRIPT],
            capture_output=True,
            text=True,
            timeout=GARMIN_TIMEOUT,
        )
    except Exception as exc:
        warn(f"garmin: {type(exc).__name__}")
        return "failed"
    if proc.returncode == 0:
        return "ok"
    warn(f"garmin: exit {proc.returncode} {proc.stderr.strip()[:200]}")
    return "reauth" if "NEEDS_LOGIN" in proc.stderr else "failed"


def garmin_signin_card():
    return {
        "id": "garmin", "kind": "health", "label": "Health", "sub": None,
        "meters": [], "stats": [], "note": "run garmin-login", "state": "reauth",
    }


def fetch_garmin():
    if not os.path.isdir(GARMIN_TOKENS):
        return garmin_signin_card()

    snapshot = read_json(GARMIN_FILE) or {}
    age = time.time() - snapshot.get("fetched_at", 0)
    state = "ok"
    if age > GARMIN_TTL:
        status = refresh_garmin()
        if status == "ok":
            snapshot = read_json(GARMIN_FILE) or snapshot
            age = time.time() - snapshot.get("fetched_at", 0)
        elif status == "reauth":
            # Tokens are gone or expired — stale numbers would just mislead.
            return garmin_signin_card()
        elif not snapshot:
            raise HttpError(0)
        else:
            state = "stale"

    # Body Battery and the sleep score are 0-100 scores, not percentages, so
    # they carry an explicit display string; steps show the raw count with the
    # bar tracking progress towards the daily goal.
    meters = []
    for name, key in (("body battery", "body_battery"), ("sleep", "sleep_score")):
        value = snapshot.get(key)
        if value is None:
            continue
        meters.append(
            {"name": name, "remaining": value, "display": str(value), "resets_at": None}
        )
    if snapshot.get("steps_pct") is not None:
        meters.append(
            {
                "name": "steps",
                "remaining": snapshot["steps_pct"],
                "display": f"{snapshot['steps']:,}",
                "resets_at": None,
            }
        )

    stats = []
    if snapshot.get("readiness") is not None:
        stats.append({"label": "ready", "value": str(snapshot["readiness"])})
    if snapshot.get("resting_hr") is not None:
        stats.append({"label": "rest hr", "value": f"{snapshot['resting_hr']} bpm"})
    if snapshot.get("hrv_status"):
        hrv = str(snapshot["hrv_status"]).lower()
        if snapshot.get("hrv_last_night"):
            hrv = f"{snapshot['hrv_last_night']} ms"
        stats.append({"label": "hrv", "value": hrv})
    if snapshot.get("stress") is not None:
        stats.append({"label": "stress", "value": str(snapshot["stress"])})

    fetched = snapshot.get("fetched_at")
    sub = datetime.fromtimestamp(fetched).strftime("%-I:%M%p").lower() if fetched else None

    return {
        "id": "garmin",
        "kind": "health",
        "label": "Health",
        "sub": sub,
        "meters": meters,
        "stats": stats,
        "state": state,
    }


PROVIDERS = [
    ("claude", fetch_claude),
    ("codex", fetch_codex),
    ("garmin", fetch_garmin),
    ("models", fetch_models),
]


# --- cache / lock ------------------------------------------------------------


def read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return None


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as handle:
        json.dump(payload, handle)
    os.replace(tmp, path)


def previous_card(cache, card_id):
    for card in (cache or {}).get("cards", []):
        if card.get("id") == card_id:
            return card
    return None


def stale_card(cache, card_id, state):
    """Fall back to the last-known card, marked with the new state."""
    card = previous_card(cache, card_id)
    if card:
        card = dict(card, state=state)
    else:
        labels = {"claude": "Claude Code", "codex": "Codex",
                  "garmin": "Health", "models": "Models"}
        kinds = {"models": "models", "garmin": "health"}
        card = {"id": card_id, "label": labels[card_id], "sub": None,
                "kind": kinds.get(card_id, "meters"),
                "meters": [], "rows": [], "stats": [], "state": state}
    return card


def read_lock(card_id, now):
    lock = read_json(LOCK_FILE) or {}
    entry = lock.get(card_id)
    if entry and entry.get("blocked_until", 0) > now:
        return entry
    return None


def write_lock(card_id, blocked_until, state):
    lock = read_json(LOCK_FILE) or {}
    lock[card_id] = {"blocked_until": blocked_until, "state": state}
    write_json(LOCK_FILE, lock)


def clear_lock(card_id):
    lock = read_json(LOCK_FILE) or {}
    if lock.pop(card_id, None) is not None:
        write_json(LOCK_FILE, lock)


# --- main --------------------------------------------------------------------


def parse_simulate(value):
    """--simulate reauth:claude,blocked:codex -> {'claude': 'reauth', ...}"""
    out = {}
    for part in (value or "").split(","):
        part = part.strip()
        if not part:
            continue
        state, _, card_id = part.partition(":")
        if card_id:
            out[card_id] = state
    return out


def collect(force=False, simulate=None):
    now = int(time.time())
    cache = read_json(CACHE_FILE)
    simulate = simulate or {}

    if not force and not simulate and cache:
        if now - cache.get("fetched_at", 0) < CACHE_TTL:
            return cache

    cards = []
    for card_id, fetch in PROVIDERS:
        if card_id in simulate:
            cards.append(stale_card(cache, card_id, simulate[card_id]))
            continue

        lock = read_lock(card_id, now)
        if lock:
            cards.append(stale_card(cache, card_id, lock.get("state", "stale")))
            continue

        try:
            card = fetch()
            clear_lock(card_id)
            cards.append(card)
        except HttpError as exc:
            if exc.status in (401, 403):
                state = "reauth"
                write_lock(card_id, now + 60, state)
            elif exc.status == 429:
                state = "blocked"
                write_lock(card_id, now + (exc.retry_after or DEFAULT_BACKOFF), state)
            else:
                state = "stale"
                write_lock(card_id, now + 60, state)
            warn(f"{card_id}: {exc}")
            cards.append(stale_card(cache, card_id, state))
        except Exception as exc:  # network down, DNS, JSON garbage
            warn(f"{card_id}: {type(exc).__name__}")
            write_lock(card_id, now + 30, "stale")
            cards.append(stale_card(cache, card_id, "stale"))

    payload = {
        "fetched_at": now,
        # "stale" means the quota numbers may be out of date. The models card
        # reads local logs, so its failures say nothing about quota freshness.
        "stale": any(
            card["state"] != "ok"
            for card in cards
            if card["id"] not in ("models", "garmin")
        ),
        "cards": cards,
    }
    if not simulate:
        write_json(CACHE_FILE, payload)
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="ignore the cache TTL")
    parser.add_argument(
        "--simulate",
        help="comma list of state:card, e.g. reauth:claude,blocked:codex "
        "(does not write the cache)",
    )
    args = parser.parse_args()
    payload = collect(force=args.force, simulate=parse_simulate(args.simulate))
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
