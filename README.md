# agent-widgets

A desktop panel showing how much Claude Code and Codex budget is left.

```
collect.py         fetches both APIs, writes sanitized JSON (stdlib only)
cache.json         what the panel renders. Never contains tokens/email/ids.
lock.json          per-provider backoff state (429 / auth errors)
models-index.json  incremental scan state for the model breakdown
garmin.py          fetches the Garmin health snapshot (runs under venv/)
garmin-login.py    one-time interactive Garmin Connect sign-in
garmin.json        latest health snapshot
garth/             Garmin OAuth tokens, mode 700. No password is ever stored.
venv/              python venv holding garminconnect, the only dependency
AgentWidgets.swift the panel: borderless AppKit window at desktop-icon level
agent-widgets      the compiled binary
panel.json         placement (screen / corner / margin)
build.sh           rebuild + restart
```

Started at login by `~/Library/LaunchAgents/ai.boringstack.agent-widgets.plist`.
The panel shells out to `collect.py` every 30s; the collector's own 180s TTL
means the APIs see roughly one call every 3 minutes.

The window is click-through, joins all Spaces, has no Dock icon, and sits at the
desktop-icon level — so it lives on the wallpaper and never steals focus. It is
therefore covered by any window in front of it. Nothing here needs Screen
Recording, Accessibility, or any other TCC permission.

## What the numbers mean

Neither product exposes a credit balance. Both expose **percent of a rolling
window consumed** plus a reset time, so the panel shows **% remaining** and a
countdown. Codex's `credits.balance` exists but is `0` on this plan and is not
rendered.

## The health card (Garmin)

Sign in once:

```sh
~/.config/agent-widgets/venv/bin/python ~/.config/agent-widgets/garmin-login.py
```

It prompts for the Garmin Connect email, password and MFA code. The password is
never written anywhere; only Garmin's OAuth tokens are saved, to `garth/` at
mode 700, and they refresh themselves for about a year. Until that runs, the
card shows `run garmin-login`. Re-run it if the card ever says that again.

Garmin Express on this Mac only stores device registration (a Forerunner 570) —
no health data — so the numbers come from Garmin Connect over the network via
`garminconnect`. That library is the reason for `venv/`: `garmin.py` runs under
it and writes `garmin.json`; `collect.py` only reads that file, which is what
keeps the collector itself stdlib-only. Health data moves slowly, so the
snapshot has a 15-minute TTL of its own; a snapshot older than 30 minutes marks
the card stale.

Layout follows the units:

- **Meters** for things with a real 0-100 ratio — Body Battery, sleep score,
  and steps (bar = progress to the daily goal). Body Battery and sleep are
  *scores*, so they print bare (`72`, `84`) rather than with a `%`.
- **A 2-column grid** for readings with no natural 0-100 scale — training
  readiness, resting HR, HRV, stress. Drawing `48 bpm` as a meter would imply a
  ceiling that does not exist.

Sleep and HRV describe last night and Garmin only files them under today's date
after the watch syncs, so both fall back to yesterday rather than showing blank
first thing in the morning. Any metric the watch didn't record is dropped from
the card rather than shown as zero. Like the models card, a health failure is
excluded from the top-level `stale` flag.

## The model breakdown

The third card ranks models by **output tokens over the last 7 days** — tokens
the model actually generated. Total-token counts were rejected deliberately:
they are dominated by cache reads, so one long session buries everything else.

Sources are the local session logs, not an API:

- **Claude** — `~/.claude/projects/**/*.jsonl`, `type: "assistant"` records:
  `message.model` + `message.usage.output_tokens`, dated by `timestamp`.
  `<synthetic>` models are skipped.
- **Codex** — `~/.codex/sessions/**/*.jsonl`. The model is declared in
  `turn_context` / `session_meta`; token counts arrive afterwards in
  `event_msg` → `token_count` → `info.last_token_usage.output_tokens`. Each
  file carries the last-seen model forward, so attribution survives a
  mid-session model switch.

That is ~250MB across 200+ files, so it is scanned **incrementally**: the index
stores a byte offset per file and each pass reads only appended bytes. First
pass ~6s, every pass after ~0.1s. Daily buckets are kept for 30 days; the card
window is the last 7.

Colours come from the dataviz categorical dark steps, validated as a 5-set
against this surface (adjacent CVD ΔE 8.4, normal-vision ΔE 19.3, contrast
≥ 3:1). **A slot is assigned to a model on first sight and persisted** in
`models-index.json` under `palette` — colour follows the model, never its rank,
so a reshuffle in the ranking never repaints the other rows. Models past the
top 4 fold into a grey "Other" row, which is hidden below 1%.

Codex's `output_tokens` already includes `reasoning_output_tokens` — verified
against records where `total_tokens == input_tokens + output_tokens` with
reasoning nonzero — so the two tools are counted the same way.

A models failure is deliberately excluded from the top-level `stale` flag: that
flag means "the quota numbers may be out of date," and a local log scan says
nothing about quota freshness.

To re-scan from scratch (e.g. after changing the metric), delete
`models-index.json`. It is also safe to delete if it grows — one entry per
session file, and entries only leave when the file does, so heavy
worktree-per-task churn accumulates them.

## Endpoints

**Claude Code** — `GET https://api.anthropic.com/api/oauth/usage`
`Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20`.
Token: Keychain service `Claude Code-credentials` → `.claudeAiOauth.accessToken`.
Claude Code refreshes that token itself, so it is read fresh every poll and
never cached. The response has no plan/tier field — hence no subtitle on the
Claude card. Only `five_hour` and `seven_day` are used; `seven_day_opus` and
`seven_day_sonnet` are null on this account. Per-model data, if ever wanted,
is in `limits[]` (`kind: "weekly_scoped"`, `scope.model.display_name`).

**Codex** — `GET https://chatgpt.com/backend-api/codex/usage`
`Authorization: Bearer <tokens.access_token>` **and**
`chatgpt-account-id: <tokens.account_id>`, both from `~/.codex/auth.json`.
Without the account-id header the endpoint returns 403.

## Why /usr/bin/curl and not urllib

chatgpt.com's edge returns a bare 403 — which reads like an auth failure but
isn't — for two request shapes that were hit while building this:

- **HTTP/2 is rejected.** Isolated cleanly: same curl binary, same headers,
  `--http2` → 403, `--http1.1` → 200. The request is pinned to HTTP/1.1.
- **The macOS system Python's HTTPS path is rejected**, even over HTTP/1.1.
  Python 3.9 at `/usr/bin/python3` links LibreSSL 2.8.3; `/usr/bin/curl`
  (LibreSSL 3.3.6) works. The exact discriminator between the two was not
  isolated — curl is simply the known-good transport.

Headers go in over stdin (`curl -H @-`) so bearer tokens never land in argv
where `ps` could show them.

## Failure states

Each provider is fetched independently — one failing never blanks the other.
`ok` · `stale` (network/other error; last-known values, dimmed) · `reauth`
(401/403) · `blocked` (429, honors `Retry-After`, default 300s backoff).

## Handy commands

```sh
/usr/bin/python3 ~/.config/agent-widgets/collect.py --force      # bypass TTL
/usr/bin/python3 ~/.config/agent-widgets/collect.py \
    --simulate reauth:claude,blocked:codex                        # test states
~/.config/agent-widgets/agent-widgets --snapshot /tmp/panel.png  # render to PNG
~/.config/agent-widgets/build.sh                                 # rebuild + restart
launchctl kickstart -k gui/$(id -u)/ai.boringstack.agent-widgets  # just restart
```

`--simulate` never writes the cache.

## Themes

Two looks, same data. Switch by editing `panel.json` — it is re-read every 30s
tick, so the panel swaps in place with no restart:

```json
{ "theme": "hud" }        // default: 236pt portrait, translucent blur
{ "theme": "cluster" }    // 700 × 340pt landscape JDM digital dash
```

Each theme owns its own dimensions, backdrop and corner radius; `ThemeView.make`
picks the class and `PanelController.applyTheme` swaps the whole view when the
name changes. Adding a third theme means subclassing `ThemeView` and adding one
case.

Render either to a PNG without touching the live panel:

```sh
~/.config/agent-widgets/agent-widgets --snapshot /tmp/p.png cluster
/tmp/p.png
rev 2382b2a3  62431 bytes
```

The second line is a revision marker — the hash of the source that produced the
image. A render is only meaningful against the build behind it; without this, a
design review of one build lands after the next has shipped and its findings
cite line numbers that have already moved.

### The cluster theme

Modelled on 80s VFD instrument clusters — the boxed hairline panels and
cyan-teal phosphor of the Nissan/Toyota digital dashes, with the segmented bar
gauges and blanked leading digits of a Fiat Uno Turbo.

Five boxes. The left column is budget; the right side is body and model mix.

| Instrument | Data | Why it earns it |
|---|---|---|
| Hero 7-seg + bar | Claude 5h remaining | The one figure that changes what you do in the next hour. Bar carries the same number as a shape, for when the digits are too far to read. |
| Tacho ramp | 7-day model mix | Ticks-per-model *and* tick height both encode share — redundant on purpose, so the silhouette alone says whether you're mono-model or spread. Sorted descending, which is what makes a rank-ordered bar chart look like a tacho wedge. |
| Week windows | Claude week, Codex week | Long-horizon totals, read deliberately rather than glanced — the odometer's job. |
| Vertical bar gauges | Body battery, sleep, steps | Three 0–100 tanks that drain, on one shared rail because all three share a scale. |
| Trip-computer block | Readiness, resting HR, HRV, stress | No 0–100 scale exists, so no bar is drawn. These four **never** traffic-light: low resting HR is good and high HRV is good, so any colour rule would be backwards half the time. |
| Warning lamps | `CC` `CDX` `GRM` per source, plus a derived `LOW` | Real clusters put failure in lamps, not in the gauges. `LOW` is the fuel light — amber at ≤20% on any quota meter, magenta at ≤8%. |

Numerals are drawn as bezier paths (`SevenSegment`), not set in a font — macOS
ships no segmented face, and paths let unlit segments stay faintly visible the
way a real VFD does.

**Segment geometry is the thing most likely to break if retuned**, and it has
two opposite failure modes, both of which this code has had:

- Inset the verticals by a whole thickness and they become stubs — a
  *subtractive* fault that makes digits look emptier than they are.
- Run them past `mid − t/2` and their lit tips paint *inside* the middle
  segment's rectangle, giving an unlit middle bar lit-coloured ends — an
  *additive* fault that welds `0` into `8`.

`midGap = t / 2` is the butt joint between the two: the tapered tip lands exactly
on segment `g`'s edge, painting nothing inside it and giving away the least
length. That correct geometry costs a small digit most of its vertical to the
taper, so the small metrics were **grown** rather than having the clearance
fudged back.

Both faults were present here at once, which is the trap: they cancel enough
through the middle of the range that fixing either one alone looks like it
worked while the other survives. If digits misread after a retune, check for
both — an emptier-looking digit and a fuller-looking one have opposite causes.

A blank cell draws **nothing** — no glyph entry at all. It previously mapped to
an all-unlit mask, and since the draw loop paints unlit ink for every dark
segment, a leading blank rendered a full ghost `8` next to the value. Blank now
means "nothing to say"; a dash means "no data".

Failure states follow cluster logic rather than web logic: a dead sensor shows
an unlit gauge reading `--` and lights a warning lamp; it does not blank the
panel. A source failing never removes its neighbours — Codex keeps its gauge
when Garmin needs a new sign-in.

**Test the failure state with every lamp lit at once.** Two lamps resolving to
the same colour is invisible in any fixture that lights only one of them, and
that is exactly how `LOW` and `GRM` both ended up magenta, adjacent, in the same
row. To fake a state: edit `cache.json`, and stamp `fetched_at` to now — the
snapshot path shells the collector, which will otherwise refetch straight over
your edits.

**The colour rule, which everything else follows:** an instrument's colour
encodes its *datum*; source *state* is carried by the dim, the state word, and
the lamp — never by the instrument's colour. Mixing those is what produced the
original magenta collision.

Three palettes, kept strictly apart:

- **Quota level** (instruments) — `#3FF0DC` cyan, `#FFB000` amber below 40,
  `#FF4A3D` red below 15.
- **Source state** (lamps and state words) — amber degraded (`stale` /
  `blocked`), `#FF3DA5` magenta needs-your-hands (`reauth`). Critical quota is
  red rather than magenta specifically because the `LOW` lamp sits *beside* the
  source lamps — magenta for both would collide on the same surface.
- A **missing** metric is never amber. Absence is not degradation; the dashes
  carry that message and the colour stays neutral.
- **Model mix** — `#3BE8D8` cyan, `#9BE84F` lime, `#5A8CFF` blue, `#40B0A0`
  teal, `#D9A8FF` lilac. **Deliberately contains no amber and no magenta**: a
  model colour that looks like an alarm is a bug, and the first version had
  exactly that. Validated all-pairs on the `#050505` face (runs are ordered by
  rank, so any two can end up adjacent): CVD ΔE 8.2, normal-vision 15.7, all
  ≥ 3:1, with legend names as the secondary encoding.

Teal sits at index 3 on purpose. Slots are assigned on first sight and
persisted, and this machine's slot 3 holds a model that never charts — so the
four hues that actually appear together are the widely-separated ones.

Both palettes sit above the dataviz lightness band on purpose: a VFD is a lamp,
not ink on paper, and dimming them into the band kills the glow.

Ghost (unlit) alpha scales with digit height — `0.13` at H≥52 down to `0.055`
at H≤24. A single constant cannot work: lit and unlit share a hue, so the value
that makes a big numeral read as an unlit display closes the gaps on a small
one and turns it into a blob.

## Moving the panel

Edit `panel.json` — it is re-read on every 30s tick, no restart needed.

```json
{ "screen": 0, "corner": "topRight", "margin": 24 }
```

`screen` indexes `NSScreen.screens` (0 is the display with the menu bar — the
built-in laptop screen here. It is the default because `NSScreen.main` follows
keyboard focus and would drift between displays). Set `"screen": 1` to put the
panel on the external display. `corner` is one of `topRight` `topLeft`
`bottomRight` `bottomLeft`.

`panel.log` collects the panel's stderr. It should stay empty; if it starts
growing, that is where the errors are. Safe to delete at any time.

## Adding another source

Write a function in `collect.py` returning
`{"id", "label", "sub", "meters": [{"name", "remaining", "resets_at"}], "state"}`
and add it to `PROVIDERS`. The panel renders whatever cards it finds and resizes
itself. A menu-bar consumer (SwiftBar/xbar) could read the same `cache.json`.

## Note on Übersicht

The first attempt used Übersicht as the host. It does not work on macOS 26.6:
its bundled Node (`node-arm64`, Dec 2023) hangs in `_dyld_start`, so the widget
server never listens and the app exits. The cask was uninstalled. The Swift
panel replaces it with no third-party runtime.
