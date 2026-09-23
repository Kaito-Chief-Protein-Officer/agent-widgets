#!/usr/bin/env python3
"""Collect Claude Code + Codex usage into a sanitized cache for desktop widgets.

Prints only the sanitized cache JSON on stdout. Diagnostics go to stderr.
Never writes tokens or refresh tokens to the cache file.

The cache does carry the local part of each account's address, because with
several accounts per provider it is the only thing that tells two of them
apart — a role like "personal" is worn by more than one. It is derived from
the provider rather than configured, so accounts.json (which is committed)
stays free of it. Domains are dropped; cache.json is git-ignored.
"""

import argparse
import base64
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timedelta, timezone

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
ANTHROPIC_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
ANTHROPIC_BETA = "oauth-2025-04-20"
KEYCHAIN_SERVICE = "Claude Code-credentials"
# One Claude card per signed-in account. Claude Code keeps one login per
# config dir, so a second subscription is a second CLAUDE_CONFIG_DIR with its
# own keychain entry. accounts.json lists them; without it, the panel reads the
# default login exactly as it always has.
ACCOUNTS_FILE = os.path.join(CONFIG_DIR, "accounts.json")
DEFAULT_CLAUDE_CONFIG_DIR = "~/.claude"
DEFAULT_CLAUDE_ACCOUNTS = [
    {"id": "claude", "label": "Claude Code", "config_dir": DEFAULT_CLAUDE_CONFIG_DIR}
]

CODEX_URL = "https://chatgpt.com/backend-api/codex/usage"
# Codex keeps one login per CODEX_HOME, the same shape as Claude Code's
# per-config-dir logins, so a second ChatGPT account is a second home dir.
DEFAULT_CODEX_HOME = "~/.codex"
DEFAULT_CODEX_ACCOUNTS = [
    {"id": "codex", "label": "Codex", "codex_home": DEFAULT_CODEX_HOME}
]
PS = "/bin/ps"


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


def claude_accounts():
    """Accounts from accounts.json, validated; the default login if absent.

    Each entry: {"id", "label", "config_dir", "keychain_service"?}. The id is
    the card id (so `--simulate reauth:<id>` works) and the label is the role
    the panel prints — "personal", "team". Leave the address out: the
    collector appends it from the provider, so this file (which is committed)
    never has to hold one, and a typo here cannot mislabel an account.
    """
    config = read_json(ACCOUNTS_FILE) or {}
    accounts = []
    seen = set()
    for raw in config.get("claude") or []:
        if not isinstance(raw, dict):
            continue
        account_id = str(raw.get("id") or "").strip()
        if not account_id or account_id in seen or ":" in account_id:
            continue
        seen.add(account_id)
        accounts.append(
            {
                "id": account_id,
                "label": str(raw.get("label") or account_id),
                "config_dir": str(raw.get("config_dir") or DEFAULT_CLAUDE_CONFIG_DIR),
                "keychain_service": raw.get("keychain_service"),
            }
        )
    return accounts or [dict(account) for account in DEFAULT_CLAUDE_ACCOUNTS]


def keychain_claude_services():
    """Every `Claude Code-credentials*` service in the login keychain.

    `dump-keychain` lists item attributes only — no secrets, no prompt.
    """
    try:
        proc = subprocess.run(
            ["security", "dump-keychain"], capture_output=True, text=True, timeout=10
        )
    except Exception:
        return []
    import re

    found = re.findall(r'"svce"<blob>="(Claude Code-credentials[^"]*)"', proc.stdout)
    return sorted(set(found))


# Services handed out to non-default accounts during this run, so two of them
# never read the same entry. Reset by providers().
_claimed_services = set()


def claude_keychain_services(account):
    """Keychain service names to try for one account's config dir.

    The default config dir uses the bare service name. Claude Code keys any
    other CLAUDE_CONFIG_DIR to its own entry, suffixing the service name — the
    documented behaviour, but not the documented rule — so the first guess is
    the obvious hash and the fallback is whatever suffixed entries exist that
    no other account has claimed. With one extra account that always resolves;
    with more, set `keychain_service` in accounts.json explicitly.
    """
    if account.get("keychain_service"):
        return [str(account["keychain_service"])]
    config_dir = os.path.expanduser(account["config_dir"]).rstrip("/")
    if config_dir == os.path.expanduser(DEFAULT_CLAUDE_CONFIG_DIR).rstrip("/"):
        return [KEYCHAIN_SERVICE]
    import hashlib

    digest = hashlib.sha256(config_dir.encode("utf-8")).hexdigest()[:8]
    guesses = [f"{KEYCHAIN_SERVICE}-{digest}"]
    for service in keychain_claude_services():
        if service == KEYCHAIN_SERVICE or service in guesses or service in _claimed_services:
            continue
        guesses.append(service)
    return guesses


def claude_credentials(account):
    """-> the `claudeAiOauth` block for one account, or None."""
    for service in claude_keychain_services(account):
        try:
            proc = subprocess.run(
                ["security", "find-generic-password", "-s", service, "-w"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                oauth = json.loads(proc.stdout.strip()).get("claudeAiOauth") or {}
                if oauth.get("accessToken"):
                    _claimed_services.add(service)
                    return oauth
        except Exception:
            pass
    # Non-macOS / no-keychain fallback used by Claude Code itself.
    try:
        cred_file = os.path.join(os.path.expanduser(account["config_dir"]), ".credentials.json")
        with open(cred_file) as handle:
            oauth = json.load(handle).get("claudeAiOauth") or {}
            return oauth if oauth.get("accessToken") else None
    except Exception:
        return None


def claude_plan(oauth):
    """Plan tier from the credential block: "max 20x", "team", "pro". No identity."""
    plan = str(oauth.get("subscriptionType") or "").strip().lower()
    tier = str(oauth.get("rateLimitTier") or "").strip().lower()
    multiplier = tier.rsplit("_", 1)[-1] if tier else ""
    if plan and multiplier[:-1].isdigit() and multiplier.endswith("x"):
        return f"{plan} {multiplier}"
    return plan or None


def codex_accounts():
    """Codex logins from accounts.json, validated; the default one if absent.

    Each entry: {"id", "label", "codex_home"}. Mirrors claude_accounts() —
    same id/label rules, and the id is the card id so `--simulate` can name it.
    """
    config = read_json(ACCOUNTS_FILE) or {}
    accounts = []
    seen = set()
    for raw in config.get("codex") or []:
        if not isinstance(raw, dict):
            continue
        account_id = str(raw.get("id") or "").strip()
        if not account_id or account_id in seen or ":" in account_id:
            continue
        seen.add(account_id)
        accounts.append(
            {
                "id": account_id,
                "label": str(raw.get("label") or account_id),
                "codex_home": str(raw.get("codex_home") or DEFAULT_CODEX_HOME),
            }
        )
    return accounts or [dict(account) for account in DEFAULT_CODEX_ACCOUNTS]


def codex_email(account):
    """-> the address in this home's id_token, or None. Local only; the token
    is already on disk and nothing leaves the machine to read it."""
    path = os.path.join(os.path.expanduser(account["codex_home"]), "auth.json")
    try:
        with open(path) as handle:
            raw = (json.load(handle).get("tokens") or {}).get("id_token") or ""
        payload = raw.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return claims.get("email")
    except Exception:
        return None


def codex_credentials(account):
    """-> (access token, ChatGPT account id) for one login, or (None, None)."""
    path = os.path.join(os.path.expanduser(account["codex_home"]), "auth.json")
    try:
        with open(path) as handle:
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


# Org uuids already claimed this run. Two config dirs can hold tokens for the
# same org — signing in twice picks up whatever session the browser already
# had — and the usage endpoint cannot tell them apart, because it reports
# windows and no identity at all. Without this the panel draws the same
# account twice and looks like two.
_claimed_orgs = {}


def claude_identity(oauth):
    """-> (email, org uuid, org name) for one token, or (None, None, None).

    The usage response carries no identity, so the label a card prints and any
    duplicate check both have to come from here.
    """
    try:
        data = get_json(
            ANTHROPIC_PROFILE_URL,
            {"Authorization": f"Bearer {oauth['accessToken']}",
             "anthropic-beta": ANTHROPIC_BETA},
        )
    except Exception:
        return None, None, None
    org = data.get("organization") or {}
    return (data.get("account") or {}).get("email"), org.get("uuid"), org.get("name")


def fetch_claude(account):
    oauth = claude_credentials(account)
    if not oauth:
        raise HttpError(401)
    data = get_json(
        ANTHROPIC_URL,
        {"Authorization": f"Bearer {oauth['accessToken']}", "anthropic-beta": ANTHROPIC_BETA},
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
    email, org_uuid, _ = claude_identity(oauth)
    # The address is what separates two accounts wearing the same role, so it
    # rides in the label rather than sitting in accounts.json, where it would
    # be a hand-typed string nobody can verify.
    label = account["label"]
    if email:
        label = f"{label} · {email.split('@')[0]}@"
    note = None
    if org_uuid:
        first = _claimed_orgs.setdefault(org_uuid, account["id"])
        if first != account["id"]:
            note = f"same org as {first}"
            warn(f"{account['id']}: duplicate of {first} (org {org_uuid})")

    return {
        "id": account["id"],
        "provider": "claude",
        "label": label,
        "note": note,
        # Anthropic's usage response carries no plan field; the tier comes
        # from the credential block Claude Code stores alongside the token.
        "sub": claude_plan(oauth),
        "kind": "meters",
        "meters": meters,
        "state": "ok",
    }


# Codex account ids already claimed this run. `codex login` with no CODEX_HOME
# writes to ~/.codex whatever home you meant, so one careless login silently
# points two entries at the same account and the panel draws it twice.
_claimed_codex = {}


def fetch_codex(account):
    token, account_id = codex_credentials(account)
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
    # Banked resets: each one clears a hit rate limit early. Report what is
    # held, not what is spendable this second — `applicable` drops to 0 while
    # the window is under its limit, because there is nothing to clear yet,
    # and showing that as "no resets" loses a credit you still own.
    resets = data.get("rate_limit_reset_credits") or {}
    banked = resets.get("available_count") or 0
    applicable = resets.get("applicable_available_count")
    email = data.get("email") or codex_email(account)
    label = account["label"]
    if email:
        label = f"{label} · {email.split('@')[0]}@"
    note = None
    claimed = data.get("account_id") or account_id
    first = _claimed_codex.setdefault(claimed, account["id"])
    if first != account["id"]:
        note = f"same account as {first}"
        warn(f"{account['id']}: duplicate of {first} ({email or claimed})")
    return {
        "id": account["id"],
        "provider": "codex",
        "label": label,
        "note": note,
        "sub": str(plan) if plan else None,
        "kind": "meters",
        "meters": meters,
        "stats": (
            [{"label": "resets", "value": str(banked)},
             {"label": "resets_applicable", "value": str(applicable if applicable is not None else banked)}]
            if banked else []
        ),
        "state": "ok",
    }


# --- active local agents ----------------------------------------------------
# A process name alone is not enough: both desktop apps spawn helpers named
# after the product, and Codex/OpenCode both keep management and server
# infrastructure alive under the same executable name as the CLI agent.

NON_AGENT_CODEX_COMMANDS = {
    "app-server", "sandbox", "mcp-server", "cloud", "completion",
}

# Everything opencode's CLI does besides starting or attaching to a live
# session: shell completion, protocol/MCP servers, credential and plugin
# management, headless serve/web hosting, and read-only inspection commands.
NON_AGENT_OPENCODE_COMMANDS = {
    "completion", "acp", "mcp", "attach", "debug", "providers", "auth",
    "agent", "upgrade", "uninstall", "serve", "web", "models", "stats",
    "export", "import", "github", "session", "plugin", "plug", "db",
}


def process_table():
    """One `ps` per run, shared by the agent count and the CPU reading.

    Spawning it twice would have two cards disagree about the same instant,
    and this is the most expensive local call the collector makes.
    """
    if "ps" in _run_cache:
        return _run_cache["ps"]
    proc = subprocess.run(
        [PS, "-axo", "%cpu=,comm=,args="], capture_output=True, text=True, timeout=5
    )
    if proc.returncode != 0:
        raise RuntimeError("process inspection failed")
    _run_cache["ps"] = proc.stdout
    return proc.stdout


def active_agent_counts(ps_output=None):
    if ps_output is None:
        ps_output = process_table()

    counts = {"claude": 0, "codex": 0, "opencode": 0}
    for line in ps_output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) < 2:
            continue
        executable = os.path.basename(fields[1])
        if executable not in counts:
            continue
        argv = fields[2].split() if len(fields) > 2 else []
        command = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else None
        if executable == "codex" and command in NON_AGENT_CODEX_COMMANDS:
            continue
        if executable == "opencode" and command in NON_AGENT_OPENCODE_COMMANDS:
            continue
        counts[executable] += 1
    return counts


def fetch_agents():
    counts = active_agent_counts()
    return {
        "id": "agents", "kind": "agents", "label": "Active Agents",
        "active_total": sum(counts.values()),
        "stats": [
            {"label": "claude", "value": str(counts["claude"])},
            {"label": "codex", "value": str(counts["codex"])},
            {"label": "opencode", "value": str(counts["opencode"])},
        ],
        "meters": [], "state": "ok",
    }


def gpu_percent():
    """Busy percent of the integrated GPU, or None if it cannot be read.

    `ioreg` exposes IOAccelerator's PerformanceStatistics without sudo; the
    "Device Utilization %" field is the same number Activity Monitor's GPU
    History draws. Costs ~20ms. A machine can list more than one accelerator,
    so the busiest wins rather than the first found.
    """
    try:
        out = subprocess.run(["/usr/sbin/ioreg", "-r", "-c", "IOAccelerator", "-d1"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    values = [int(m) for m in re.findall(r'"Device Utilization %"=(\d+)', out)]
    return max(values) if values else None


def cpu_percent(ps_output=None):
    """Busy percent across all cores.

    Summing ps's per-process %cpu and dividing by core count lands within a
    point of `top -l 2 -n 0 -s 1`'s user+sys (measured 27.0 against 26.9) at
    a fraction of the cost: top has to take two samples a second apart, and
    spends ~2.7s of a 30s tick — plus its own CPU — to do it.
    """
    ps_output = process_table() if ps_output is None else ps_output
    total = 0.0
    for line in ps_output.splitlines():
        head = line.strip().split(None, 1)
        if not head:
            continue
        try:
            total += float(head[0])
        except ValueError:
            continue
    return max(0, min(100, int(round(total / (os.cpu_count() or 1)))))


def memory_usage():
    """-> (used bytes, total bytes), counted the way Activity Monitor does.

    Used is active + wired + compressed. `top`'s PhysMem line calls everything
    that is not free "used", which counts reclaimable file cache and reads as
    94% on a machine with plenty of headroom — true, but nothing you can act
    on, and alarming on a gauge.
    """
    out = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True,
                         timeout=5).stdout
    match = re.search(r"page size of (\d+)", out)
    page = int(match.group(1)) if match else 4096
    pages = {}
    for line in out.splitlines():
        # The header carries a colon too ("...Statistics: (page size of N
        # bytes)"), so match on the value being a count rather than on the
        # separator.
        name, sep, value = line.partition(":")
        value = value.strip().rstrip(".")
        if sep and value.isdigit():
            pages[name.strip()] = int(value)
    used = page * (
        pages.get("Pages active", 0)
        + pages.get("Pages wired down", 0)
        + pages.get("Pages occupied by compressor", 0)
    )
    total = int(subprocess.run(["/usr/sbin/sysctl", "-n", "hw.memsize"],
                               capture_output=True, text=True, timeout=5).stdout or 0)
    return used, total


NET_SAMPLE_FILE = os.path.join(CONFIG_DIR, "net-sample.json")
PING_HOST = "1.1.1.1"


def ping_ms():
    """Round trip to a fixed resolver, or None when it does not answer.

    A fixed IP rather than a hostname on purpose: resolving one would fold DNS
    latency into a number meant to describe the link.
    """
    try:
        out = subprocess.run(["/sbin/ping", "-c", "1", "-W", "1500", PING_HOST],
                             capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return None
    match = re.search(r"time=([\d.]+) ms", out)
    return int(round(float(match.group(1)))) if match else None


def net_rates():
    """-> (down bytes/s, up bytes/s) since the previous poll, or (None, None).

    Interface byte counters differenced across ticks, which costs nothing and
    describes real traffic. A speed test would have to move real data to answer
    the same question, every 30 seconds, forever.
    """
    try:
        out = subprocess.run(["/usr/sbin/netstat", "-ib"], capture_output=True,
                             text=True, timeout=5).stdout
    except Exception:
        return None, None
    seen, inbound, outbound = set(), 0, 0
    for line in out.splitlines()[1:]:
        fields = line.split()
        # One row per address family per interface; count each interface once,
        # and skip loopback so local traffic is not reported as link traffic.
        if len(fields) > 10 and fields[0] not in seen and not fields[0].startswith("lo"):
            seen.add(fields[0])
            try:
                inbound += int(fields[6])
                outbound += int(fields[9])
            except ValueError:
                continue

    now = time.time()
    previous = read_json(NET_SAMPLE_FILE) or {}
    sample = {"at": now, "in": inbound, "out": outbound}
    try:
        with open(NET_SAMPLE_FILE, "w") as handle:
            json.dump(sample, handle)
    except Exception:
        pass

    elapsed = now - (previous.get("at") or 0)
    # Counters reset on reboot or an interface bounce, and a stale sample makes
    # an average over hours rather than a current rate.
    if not previous or elapsed <= 0 or elapsed > 600:
        return None, None
    down = inbound - (previous.get("in") or 0)
    up = outbound - (previous.get("out") or 0)
    if down < 0 or up < 0:
        return None, None
    return down / elapsed, up / elapsed


def compact_rate(value):
    if value is None:
        return None
    if value >= 1 << 20:
        return f"{value / (1 << 20):.1f}M"
    return f"{value / 1024:.0f}K"


def fetch_system():
    used, total = memory_usage()
    down, up = net_rates()
    cores = os.cpu_count() or 1
    stats = [
        {"label": "cpu", "value": str(cpu_percent())},
        {"label": "ram", "value": str(int(round(100 * used / total)) if total else 0)},
        {"label": "ram_used", "value": compact_bytes(used)},
        {"label": "ram_total", "value": compact_bytes(total)},
    ]
    gpu = gpu_percent()
    if gpu is not None:
        stats.append({"label": "gpu", "value": str(gpu)})
    latency = ping_ms()
    if latency is not None:
        stats.append({"label": "ping", "value": str(latency)})
    for name, rate in (("net_down", down), ("net_up", up)):
        if compact_rate(rate):
            stats.append({"label": name, "value": compact_rate(rate)})
    return {
        "id": "system",
        "kind": "system",
        "label": "System",
        "sub": f"{cores} cores",
        "stats": stats,
        "meters": [],
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
MODEL_SLOTS = 7  # categorical colour slots before a model gets the "Other" grey
# The mix card shows four named models and the local card three, and they share
# one palette. Splitting it keeps a quiet local model from being crowded out by
# cloud traffic three orders of magnitude larger.
CLOUD_SLOTS = 5

MODEL_LABELS = {
    "claude-opus-5": "Opus 5",
    "claude-sonnet-5": "Sonnet 5",
    "claude-fable-5": "Fable 5",
    "claude-haiku-4-5": "Haiku 4.5",
}

# --- local models ------------------------------------------------------------
#
# "Local" means served from this machine, so the tokens cost no subscription
# quota. That is why local burn is a card of its own rather than a slice of the
# mix: against a frontier model its share rounds to 0% and disappears, and a
# percentage of somebody else's quota is the wrong reading for it anyway.
#
# Two questions, two sources. Which models exist and which is resident comes
# from the Ollama daemon. How many tokens they generated does not: Ollama's log
# records prompt-cache totals and speculative-decode stats but never an output
# count, so consumption is read from whatever drove the model.

OLLAMA_URL = "http://127.0.0.1:11434"
HERMES_LOG = os.path.expanduser("~/.hermes/logs/agent.log")
OPENCODE_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")
LOCAL_ROWS = 4

# What a client calls a local endpoint. Hermes declares its Ollama connection
# as "custom" — an OpenAI-compatible base URL — not as "ollama".
LOCAL_PROVIDERS = ("custom", "ollama", "lmstudio", "local")

# 2026-09-05 13:17:50,398 INFO [...] agent.conversation_loop: API call #24:
# model=qwen3.8:27b-mlx provider=custom in=87704 out=360 total=88064 latency=…
HERMES_CALL = re.compile(
    r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}),\d+ .*?API call #\d+: "
    r"model=(\S+) provider=(\S+) in=\d+ out=(\d+)"
)

# A trailing quantisation is noise in a model's name; a variant tag is not.
QUANT_TAG = re.compile(r"-?(?:q\d+[_a-z0-9]*|f(?:p)?\d+|bf\d+|nvfp\d+)$", re.I)

# collect.py runs once per pass and exits, so a plain dict is the right cache:
# it holds the single Ollama probe and the single log scan for that pass.
_run_cache = {}


def model_label(model_id):
    if model_id in MODEL_LABELS:
        return MODEL_LABELS[model_id]
    name = model_id
    for prefix in ("claude-", "gpt-", "anthropic."):
        if name.startswith(prefix):
            name = name[len(prefix) :]
    return name


def local_label(model_id):
    """"qwen3.8:27b-mtp-q4_K_M" -> "qwen3.8-27b-mtp".

    The tag after the colon belongs in the name when it identifies a variant
    ("27b-mlx") and does not when it only names a quantisation ("q4_K_M"),
    which every model on disk carries and none is distinguished by.
    """
    base, _, tag = model_id.partition(":")
    tag = QUANT_TAG.sub("", tag)
    return f"{base}-{tag}" if tag else base


def identity(line):
    return line


def window_cutoff(days):
    """The oldest day still inside a window, as an ISO date string."""
    return str(
        datetime.fromtimestamp(time.time() - days * 86400, tz=timezone.utc).date()
    )


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


def scan_hermes_line(line, state):
    """-> (day, model_id, output_tokens) or None.

    Hermes resolves the model, provider and token counts itself and logs one
    line per API call, so nothing has to be inferred here. It stamps local
    time while the Claude and Codex logs stamp UTC, so the day is converted
    before bucketing — otherwise an evening call lands a day early.
    """
    match = HERMES_CALL.match(line)
    if not match:
        return None
    date, clock, model, provider, output = match.groups()
    output = int(output)
    if not output:
        return None
    if provider in LOCAL_PROVIDERS:
        state.setdefault("local", set()).add(model)
    try:
        stamp = datetime.strptime(f"{date} {clock}", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return str(stamp.astimezone(timezone.utc).date()), model, output


SOURCES = [(CLAUDE_LOG_ROOT, scan_claude_line), (CODEX_LOG_ROOT, scan_codex_line)]


def scan_log(path, entry, parse, decode=json.loads):
    """Read appended bytes only. Returns True if the entry changed."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    offset = entry.get("offset", 0)
    if size < offset:
        # Truncated or rotated — reread from the top, but keep the day buckets.
        # Hermes recreates its log on every launch, and the tally it already
        # contributed is not wrong just because the evidence was replaced.
        # Session files are append-only and never rewritten, so no source
        # double-counts a day this way.
        offset, entry["offset"], entry["model"] = 0, 0, None
    if size == offset:
        return False

    with open(path, "rb") as handle:
        handle.seek(offset)
        chunk = handle.read()

    lines = chunk.split(b"\n")
    tail = lines.pop()  # incomplete final line; re-read next pass
    consumed = len(chunk) - len(tail)

    days = entry.setdefault("days", {})
    state = {"model": entry.get("model"), "local": set(entry.get("local") or [])}
    for raw in lines:
        if not raw:
            continue
        try:
            record = decode(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        result = parse(record, state)
        if result:
            day, model, output = result
            days.setdefault(day, {})
            days[day][model] = days[day].get(model, 0) + output

    entry["offset"] = offset + consumed
    entry["model"] = state.get("model")
    if state["local"]:
        entry["local"] = sorted(state["local"])
    return True


def scan_opencode(store):
    """Local-model tokens from OpenCode's message store.

    OpenCode keeps one JSON blob per message in SQLite rather than an append-
    only log, so this carries a high-water mark on `time_created` instead of a
    byte offset. Unproven on this machine: the store exists and is empty (no
    sessions, no messages), so the parse below is written to the documented
    message shape and reads nothing until a session is recorded.
    """
    days = store.setdefault("days", {})
    since = store.get("since", 0)
    local = set(store.get("local") or [])
    try:
        connection = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True)
    except Exception:
        return
    try:
        rows = connection.execute(
            "select time_created, data from message where time_created > ? "
            "order by time_created",
            (since,),
        ).fetchall()
    except Exception as exc:  # schema drift, or a WAL it cannot open read-only
        warn(f"local: opencode {type(exc).__name__}")
        rows = []
    finally:
        connection.close()

    for created, blob in rows:
        created = created or 0
        since = max(since, created)
        try:
            data = json.loads(blob)
        except Exception:
            continue
        if data.get("role") != "assistant":
            continue
        model = data.get("modelID") or data.get("model")
        provider = data.get("providerID") or data.get("provider")
        output = ((data.get("tokens") or {}).get("output")) or 0
        if not model or not output:
            continue
        if provider in LOCAL_PROVIDERS:
            local.add(model)
        # Milliseconds in the documented shape; tolerate seconds rather than
        # bucket a real message into 1970 and prune it on the same pass.
        seconds = created / 1000 if created > 1_000_000_000_000 else created
        day = str(datetime.fromtimestamp(seconds, tz=timezone.utc).date())
        days.setdefault(day, {})
        days[day][model] = days[day].get(model, 0) + output

    store["since"] = since
    if local:
        store["local"] = sorted(local)


def ollama_snapshot():
    """(installed, resident_bytes, reachable) from the Ollama daemon.

    Never raises: a daemon that is not running is a reading — nothing is
    resident — not a collection failure, and the token history stands on its
    own without it.
    """
    if "ollama" in _run_cache:
        return _run_cache["ollama"]

    installed, resident_bytes, reachable = [], 0, False
    try:
        tags = get_json(f"{OLLAMA_URL}/api/tags", {}) or {}
        reachable = True
        try:
            running = get_json(f"{OLLAMA_URL}/api/ps", {}) or {}
        except Exception:
            running = {}
        resident = {}
        for entry in running.get("models") or []:
            name = entry.get("model") or entry.get("name")
            if name:
                resident[name] = entry.get("size_vram") or 0
        resident_bytes = sum(resident.values())
        for entry in tags.get("models") or []:
            name = entry.get("model") or entry.get("name")
            if not name:
                continue
            installed.append(
                {
                    "id": name,
                    "size": entry.get("size") or 0,
                    "resident": name in resident,
                }
            )
    except Exception as exc:
        warn(f"local: ollama {type(exc).__name__}")

    _run_cache["ollama"] = (installed, resident_bytes, reachable)
    return _run_cache["ollama"]


def local_ids(index):
    """Every model id known to be served from this machine.

    The union of what the daemon has on disk and what any client reported
    against a local provider, persisted — so attribution survives the daemon
    being down, and a model deleted mid-window still explains its own tokens.
    """
    known = set(index.get("local_ids") or [])
    for store in (index.get("files") or {}, index.get("local_files") or {}):
        for entry in store.values():
            known.update(entry.get("local") or [])
    known.update((index.get("opencode") or {}).get("local") or [])
    installed, _, _ = ollama_snapshot()
    known.update(model["id"] for model in installed)
    return known


def prune(store, cutoff):
    for entry in store.values():
        days = entry.get("days") or {}
        for day in [day for day in days if day < cutoff]:
            del days[day]


def model_index():
    """Scan every session log once per pass and return the shared index.

    Both cards read this: the mix takes the cloud models out of it, the local
    card takes the local ones, and neither rescans.
    """
    if "index" in _run_cache:
        return _run_cache["index"]

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

    cutoff_keep = window_cutoff(MODEL_RETENTION_DAYS)
    for path in list(files):
        if path not in seen:
            del files[path]
    prune(files, cutoff_keep)

    # Local clients keep their tallies in their own stores, so a client that
    # also talks to a cloud model can never leak that burn into the mix.
    local_files = index.setdefault("local_files", {})
    scan_log(
        HERMES_LOG,
        local_files.setdefault(HERMES_LOG, {}),
        scan_hermes_line,
        decode=identity,
    )
    prune(local_files, cutoff_keep)
    scan_opencode(index.setdefault("opencode", {}))
    prune({"opencode": index["opencode"]}, cutoff_keep)

    index["local_ids"] = sorted(local_ids(index))

    # Colour follows the model, not its rank or its card: once a model holds a
    # slot it keeps it, so a reshuffle never repaints the others and a model
    # keeps its hue wherever it appears. What changed is who gets one first.
    # Assigning on first sight in name order spent the scarce slots on models
    # that had run once, and left models charting every day grey.
    cutoff = window_cutoff(MODEL_WINDOW_DAYS)

    def windowed(stores):
        totals = {}
        for store in stores:
            for entry in store.values():
                for day, models in (entry.get("days") or {}).items():
                    if day < cutoff:
                        continue
                    for model, tokens in models.items():
                        totals[model] = totals.get(model, 0) + (tokens or 0)
        return sorted(totals, key=lambda model: (-totals[model], model))

    taken = set(palette.values())

    def grant(models, slots):
        for model in models:
            if model in palette:
                continue
            free = next((slot for slot in slots if slot not in taken), None)
            # No slot is recorded when none is free, so a model that goes quiet
            # and frees one later can still be coloured. Unassigned reads grey.
            if free is None:
                return
            palette[model] = free
            taken.add(free)

    grant(windowed([files]), range(CLOUD_SLOTS))
    grant(windowed([local_files, {"opencode": index["opencode"]}]),
          range(CLOUD_SLOTS, MODEL_SLOTS))

    write_json(MODELS_INDEX_FILE, index)
    _run_cache["index"] = index
    return index


def slot_for(index, model):
    slot = (index.get("palette") or {}).get(model, MODEL_SLOTS)
    return slot if slot < MODEL_SLOTS else MODEL_SLOTS


def fetch_models():
    index = model_index()
    local = local_ids(index)
    cutoff = window_cutoff(MODEL_WINDOW_DAYS)

    totals = {}
    for entry in (index.get("files") or {}).values():
        for day, models in (entry.get("days") or {}).items():
            if day < cutoff:
                continue
            for model, output in models.items():
                if model in local:
                    continue  # costs no quota; it has its own card
                totals[model] = totals.get(model, 0) + output

    if not totals:
        return {"id": "models", "kind": "models", "label": "Models",
                "sub": f"{MODEL_WINDOW_DAYS}d", "rows": [], "meters": [], "state": "ok"}

    grand = sum(totals.values())
    ranked = sorted(totals.items(), key=lambda item: -item[1])
    rows = []
    for model, output in ranked[:MODEL_ROWS]:
        rows.append(
            {
                "label": model_label(model),
                "value": output,
                "share": round(100 * output / grand),
                "slot": slot_for(index, model),
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


def local_totals(index):
    """7-day output tokens per local model, from every client that ran one."""
    cutoff = window_cutoff(MODEL_WINDOW_DAYS)
    local = local_ids(index)
    totals = {}
    stores = [
        index.get("files") or {},
        index.get("local_files") or {},
        {"opencode": index.get("opencode") or {}},
    ]
    for store in stores:
        for entry in store.values():
            for day, models in (entry.get("days") or {}).items():
                if day < cutoff:
                    continue
                for model, output in models.items():
                    if model in local:
                        totals[model] = totals.get(model, 0) + output
    return totals


def physical_memory():
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (ValueError, OSError, AttributeError):
        return 0


def fetch_local():
    """Local models: what is on disk, what is resident, what it has generated.

    Rows are every model on disk plus any that generated tokens inside the
    window, so a model that has never been run still reads as available — the
    card answers "what can run here" as well as "what has run".
    """
    installed, resident_bytes, reachable = ollama_snapshot()
    index = model_index()
    totals = local_totals(index)

    on_disk = {model["id"]: model for model in installed}
    rows = []
    for model_id in set(on_disk) | set(totals):
        entry = on_disk.get(model_id) or {}
        rows.append(
            {
                "label": local_label(model_id),
                "value": totals.get(model_id, 0),
                "share": 0,
                "slot": slot_for(index, model_id),
                "size": entry.get("size", 0),
                "resident": bool(entry.get("resident")),
            }
        )
    rows.sort(key=lambda row: (-row["value"], row["label"]))

    grand = sum(row["value"] for row in rows)
    for row in rows:
        row["share"] = round(100 * row["value"] / grand) if grand else 0

    if len(rows) > LOCAL_ROWS:
        rest = rows[LOCAL_ROWS:]
        rows = rows[:LOCAL_ROWS]
        rows.append(
            {
                "label": f"+{len(rest)} more",
                "value": sum(row["value"] for row in rest),
                "share": sum(row["share"] for row in rest),
                "slot": MODEL_SLOTS,
                "size": sum(row["size"] for row in rest),
                "resident": any(row["resident"] for row in rest),
            }
        )

    stats = [
        {"label": "resident", "value": compact_bytes(resident_bytes)},
        {"label": "of", "value": compact_bytes(physical_memory())},
    ]

    return {
        "id": "local",
        "kind": "local",
        "label": "Local",
        # The title rail says where the reading came from, and says so loudly
        # when the daemon is not answering — nothing is resident then, and a
        # blank column would otherwise read as "nothing is loaded".
        "sub": "ollama" if reachable else "offline",
        "rows": rows,
        "meters": [],
        "stats": stats,
        "state": "ok",
    }


def compact_bytes(value):
    """Memory, in binary units — the ones a machine's RAM is sold and reported
    in, so the resident figure and the 128G it is measured against share a
    scale. Weights on disk are quoted decimally instead, matching `ollama
    list`; that formatting lives in the panel, next to the row that shows it.
    """
    if value >= 1 << 30:
        return f"{value / (1 << 30):.0f}G"
    if value >= 1 << 20:
        return f"{value / (1 << 20):.0f}M"
    return str(value)


# --- merged pull requests ----------------------------------------------------
#
# One search call answers both questions the card asks: the rolling 24h count
# and the daily histogram. Buckets are built from the returned items rather
# than from `total_count`, because a count cannot be split into days.

GITHUB_SEARCH_URL = "https://api.github.com/search/issues"
GITHUB_API_VERSION = "2022-11-28"
# Scope of "merged". The rest of the panel is personal instruments, so this is
# too: PRs this account authored. Change to `org:foo` or `repo:foo/bar` for a
# team reading — nothing else in the card depends on the scope.
PR_SCOPE = "author:@me"
PR_WINDOW_DAYS = 7
PR_PAGE_SIZE = 100
# 300 merges inside the query window. Ordered newest-first, so overflowing
# drops the oldest days and never the 24h figure — and it warns rather than
# quietly reading low.
PR_MAX_PAGES = 3
# gh stores the token in the login keychain; PATH is not inherited from the
# shell when launchd starts the panel, so the binary is looked up by hand.
GH_CANDIDATES = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]


def github_token():
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        token = os.environ.get(name)
        if token:
            return token.strip()
    for path in GH_CANDIDATES:
        if not os.path.exists(path):
            continue
        try:
            proc = subprocess.run([path, "auth", "token"], capture_output=True,
                                  text=True, timeout=10)
        except Exception:
            continue
        token = proc.stdout.strip()
        if proc.returncode == 0 and token:
            return token
    return None


def zulu_to_epoch(value):
    """GitHub stamps times as `...Z`, which 3.9's fromisoformat rejects."""
    if not value:
        return None
    return iso_to_epoch(value[:-1] + "+00:00" if value.endswith("Z") else value)


def fetch_prs():
    token = github_token()
    if not token:
        raise HttpError(401)

    # The query window is UTC dates but the buckets are local days, because the
    # chart's columns have to be the user's days. One extra day of slack covers
    # the offset in either direction.
    since = datetime.fromtimestamp(
        time.time() - (PR_WINDOW_DAYS + 1) * 86400, tz=timezone.utc
    ).date()
    query = urllib.parse.quote(f"is:pr is:merged {PR_SCOPE} merged:>={since}")
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
    }

    stamps = []
    truncated = False
    for page in range(1, PR_MAX_PAGES + 1):
        data = get_json(
            f"{GITHUB_SEARCH_URL}?q={query}&advanced_search=true"
            f"&sort=updated&order=desc&per_page={PR_PAGE_SIZE}&page={page}",
            headers,
        )
        items = data.get("items") or []
        for item in items:
            merged_at = (item.get("pull_request") or {}).get("merged_at")
            epoch = zulu_to_epoch(merged_at) or zulu_to_epoch(item.get("closed_at"))
            if epoch:
                stamps.append(epoch)
        if len(items) < PR_PAGE_SIZE:
            break
        if page == PR_MAX_PAGES and (data.get("total_count") or 0) > PR_MAX_PAGES * PR_PAGE_SIZE:
            truncated = True
    if truncated:
        warn(f"prs: capped at {PR_MAX_PAGES * PR_PAGE_SIZE}; older days read low")

    now = time.time()
    merged_24h = sum(1 for epoch in stamps if epoch >= now - 86400)

    # Local calendar days, oldest first, today last. Days with no merges are
    # kept as zeros — a gap in the chart is the reading, not missing data.
    today = datetime.fromtimestamp(now).date()
    per_day = {}
    for epoch in stamps:
        day = datetime.fromtimestamp(epoch).date()
        per_day[day] = per_day.get(day, 0) + 1
    days = []
    for offset in range(PR_WINDOW_DAYS - 1, -1, -1):
        day = today - timedelta(days=offset)
        days.append({"label": day.strftime("%a").lower(), "count": per_day.get(day, 0)})

    return {
        "id": "prs",
        "kind": "prs",
        "label": "PRs Merged",
        "sub": f"{PR_WINDOW_DAYS}d",
        "merged_24h": merged_24h,
        "merged_window": sum(day["count"] for day in days),
        "days": days,
        "last_merged_at": max(stamps) if stamps else None,
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


def providers():
    """Card order. Claude then Codex accounts, in accounts.json order."""
    _claimed_services.clear()
    _claimed_orgs.clear()
    _claimed_codex.clear()
    cards = [("agents", fetch_agents)]
    for account in claude_accounts():
        cards.append((account["id"], (lambda acct: lambda: fetch_claude(acct))(account)))
    for account in codex_accounts():
        cards.append((account["id"], (lambda acct: lambda: fetch_codex(acct))(account)))
    cards += [
        ("system", fetch_system),
        ("garmin", fetch_garmin),
        ("models", fetch_models),
        ("local", fetch_local),
        ("prs", fetch_prs),
    ]
    return cards


NON_QUOTA_CARDS = ("agents", "system", "models", "local", "garmin", "prs")


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
        labels = {"agents": "Active Agents", "codex": "Codex", "garmin": "Health",
                  "models": "Models", "local": "Local", "prs": "PRs Merged",
                  "system": "System"}
        kinds = {"agents": "agents", "models": "models", "local": "local",
                 "garmin": "health", "prs": "prs", "system": "system"}
        provider = None
        for account in claude_accounts():
            if account["id"] == card_id:
                labels[card_id] = account["label"]
                provider = "claude"
        for account in codex_accounts():
            if account["id"] == card_id:
                labels[card_id] = account["label"]
                provider = "codex"
        card = {"id": card_id, "label": labels.get(card_id, card_id), "sub": None,
                "kind": kinds.get(card_id, "meters"),
                "meters": [], "rows": [], "stats": [], "days": [], "state": state}
        if provider:
            card["provider"] = provider
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
            try:
                agent_card = fetch_agents()
            except Exception as exc:
                warn(f"agents: {type(exc).__name__}")
                agent_card = stale_card(cache, "agents", "stale")
            cards = [card for card in cache.get("cards", []) if card.get("id") != "agents"]
            cache = dict(cache, cards=[agent_card] + cards)
            write_json(CACHE_FILE, cache)
            return cache

    cards = []
    for card_id, fetch in providers():
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
        # "stale" means the quota numbers may be out of date. The models,
        # health and PR cards read other sources entirely, so their failures say
        # nothing about quota freshness.
        "stale": any(
            card["state"] != "ok" for card in cards if card["id"] not in NON_QUOTA_CARDS
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
        "(card ids are the accounts.json ids plus codex/garmin/models/local/prs; "
        "does not write the cache)",
    )
    args = parser.parse_args()
    payload = collect(force=args.force, simulate=parse_simulate(args.simulate))
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
