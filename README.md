# agent-widgets

A desktop panel showing how much Claude Code and Codex budget is left.

```
collect.py         fetches both APIs, writes sanitized JSON (stdlib only)
accounts.json      which Claude/Codex logins to read (one card each); optional
cache.json         what the panel renders. Never contains tokens/email/ids.
lock.json          per-provider backoff state (429 / auth errors)
models-index.json  incremental scan state for the model and local cards
garmin.py          fetches the Garmin health snapshot (runs under venv/)
garmin-login.py    one-time interactive Garmin Connect sign-in
add-codex-account.py  one-time interactive second Codex sign-in + wiring
garmin.json        latest health snapshot
garth/             Garmin OAuth tokens, mode 700. No password is ever stored.
venv/              python venv holding garminconnect, the only dependency
AgentWidgets.swift the panel + menu bar item: borderless AppKit window
agent-widgets      the compiled binary
panel.json         placement (screen / corner / margin, plus dragged x/y)
build.sh           rebuild + restart
```

Started at login by `~/Library/LaunchAgents/ai.boringstack.agent-widgets.plist`.
The panel shells out to `collect.py` every 30s. The active-agent reading is
refreshed on every poll; the collector's own 180s TTL means the APIs see
roughly one call every 3 minutes.

## Menu bar

**Click the speedometer icon** in the menu bar to open the panel in a popover.
The desktop panel lives on the wallpaper, so it is invisible whenever a window
covers it; the popover is the same widget rendered from the same snapshot, and
it stays live while open. **Right-click (or ⌃-click)** the icon for the menu:
**Unlock for Dragging** (the ⌘⇧E toggle), **Hide/Show Panel** and **Quit**.
Because the panel is click-through and the app is `.accessory` — no window
chrome, no Dock icon, no menu of its own — that icon is the only way to reach
it short of `launchctl` or Activity Monitor.

Hiding leaves the 30s refresh running, so a panel hidden for an hour is
current the moment it comes back. Quit exits 0, and the LaunchAgent's
`KeepAlive` is `SuccessfulExit: false` rather than plain `true`, so a
deliberate quit stays quit until the next login while a crash is still
restarted. Editing that plist needs a full reload to take effect —
`launchctl bootout gui/$(id -u)/ai.boringstack.agent-widgets` then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.boringstack.agent-widgets.plist`;
`build.sh`'s kickstart only re-execs the binary.

The window is click-through, joins all Spaces, has no Dock icon, and sits at
desktop-icon level — so it lives on the wallpaper next to real desktop icons
and widgets, and never covers a normal or full-screen window. That level and
click-through combination is also, empirically, why it can't be dragged from
rest: desktop-icon level is effectively Finder/Dock territory and a
third-party window placed there never reliably receives mouseDown no matter
what `ignoresMouseEvents` says.

**Press ⌘⇧E to unlock it for dragging**, drag it anywhere, then press ⌘⇧E
again to put it back down. Unlocking promotes the window to `.floating` — a
level dragging is guaranteed to work on — and re-locking drops it straight
back to the click-through desktop-icon resting state. The same toggle is in
the menu bar menu. The new position is persisted to `panel.json` (see "Moving
the panel") so it reopens where you left it.

The shortcut is a Carbon `RegisterEventHotKey`, not an `NSEvent` global
monitor: a global monitor for real keystrokes (as opposed to bare modifiers)
needs an Accessibility/Input Monitoring grant and silently does nothing until
it gets one, which is awkward for a bare launchd binary. So nothing here needs
Screen Recording, Accessibility, or any other TCC permission — but the
tradeoff is that the hotkey is **claimed system-wide**: while the panel runs,
⌘⇧E no longer reaches other apps (notably VS Code's *Show Explorer*). If
something else already owns it, registration fails with `eventHotKeyExistsErr`
and says so in `panel.log` rather than leaving a silently dead shortcut.

## What the numbers mean

Neither product exposes a credit balance. Both expose **percent of a rolling
window consumed** plus a reset time, so the panel shows **% remaining** and a
countdown. Codex's `credits.balance` exists but is `0` on this plan and is not
rendered.

## Active local agents

`ACTIVE AGENTS` is the number of live top-level Claude Code, Codex, and OpenCode
CLI agent runtimes on this Mac, with a `CC` / `OC` / `CDX` split underneath. It
comes from the local process table and deliberately excludes desktop renderers,
crash handlers, Codex sandboxes, code-mode hosts, persistent app-server
infrastructure, and OpenCode's own serve/web/mcp/management subcommands (the
OpenCode.app desktop client's Electron helpers are also excluded — they never
match the `opencode` executable name).

The reading refreshes every 30 seconds, including while network-backed cards are
served from cache. `0` is valid. If process inspection fails, the card shows
`--` / `STALE` rather than reusing a count as though it were current.

## Two Claude subscriptions

Claude Code keeps exactly one login per config directory, so a second
subscription (a Team seat next to a personal Max plan) is a second
`CLAUDE_CONFIG_DIR` with its own keychain entry. `accounts.json` lists them:

```json
{
  "claude": [
    { "id": "claude",      "label": "personal", "config_dir": "~/.claude" },
    { "id": "claude-work", "label": "work",     "config_dir": "~/.claude-enterprise" }
  ]
}
```

Sign the second one in once, picking the work organisation when asked:

```sh
CLAUDE_CONFIG_DIR=$HOME/.claude-enterprise claude auth login
```

Until that has happened the work dial reads `---`, wears `AUTH`, and the `CC`
lamp lights magenta — the needs-your-hands state, not a fault in the panel.
`CLAUDE_CONFIG_DIR=$HOME/.claude-enterprise claude auth status` reports
`loggedIn`, which separates a logged-out profile from a misconfigured one.
The first poll after the login may raise a Keychain prompt for `security`;
answer *Always Allow* so the LaunchAgent can read it unattended.

To *use* the work seat in a terminal, export the same variable before running
`claude`; the panel only reads the tokens, it never chooses which one a
session uses.

- `id` is the card id (`--simulate reauth:claude-work` works) and `label` is
  what the face prints. Keep labels free of email addresses: the cache is
  meant to stay identity-free, and the label lands in it.
- The plan tier (`max 20x`, `team`) comes from the credential block Claude
  Code stores next to the token, not from the usage response, which has none.
- The default directory uses keychain service `Claude Code-credentials`. Any
  other directory gets a suffixed service name. Anthropic documents *that* but
  not the rule, so the collector tries the obvious hash first and then any
  suffixed `Claude Code-credentials-*` entry no other account has claimed —
  which always resolves with one extra account. With two or more extra
  accounts, pin each with `"keychain_service": "Claude Code-credentials-…"`
  (find the names with `security dump-keychain | grep 'Claude Code-cred'`).
- Without `accounts.json` the panel reads the default login exactly as before,
  as a single full-width dial.

With two accounts the hero box becomes a twin speedo — one dial per
subscription, because "which one is nearly empty" is the question — and the
week-windows box goes to three odometer rows: numeral left, bar filling the
rest, bars sharing one left edge so the shapes compare down the column. The
`CC` lamp and the `LOW` fuel light read the worst of both accounts.

## Two OpenAI accounts

Codex works the same way as Claude Code: one login per home directory, keyed by
`CODEX_HOME` rather than `CLAUDE_CONFIG_DIR`. `codex login` overwrites
`$CODEX_HOME/auth.json`, so a second ChatGPT account is a second home dir —
there is no account switcher to read.

`add-codex-account.py` does the whole thing:

```sh
~/.config/agent-widgets/add-codex-account.py              # ~/.codex-work, labelled "work"
~/.config/agent-widgets/add-codex-account.py --home ~/.codex-alt --label alt
```

It prints which account each home already holds, runs the login, verifies the
result, writes `accounts.json` and asks the collector for both cards as proof.
Re-running is safe — a home that is already signed in is left alone and only
the wiring is redone.

Two things it refuses, because both produce a panel that looks broken later:
signing the second home in as the *same* account as the first (two identical
cards), and an API-key login — `codex login --with-api-key` stores no ChatGPT
access token or account id, which is what the usage endpoint reads, so the card
would sit on `AUTH` forever.

The equivalent by hand:

```sh
CODEX_HOME=$HOME/.codex-work codex login
CODEX_HOME=$HOME/.codex-work codex login status   # only says *that* a login exists
```

```json
{
  "codex": [
    { "id": "codex",      "label": "personal", "codex_home": "~/.codex" },
    { "id": "codex-work", "label": "work",     "codex_home": "~/.codex-work" }
  ]
}
```

`id`, `label` and the `--simulate` rules are the same as the Claude block above,
and `codex_home` defaults to `~/.codex`. Without a `codex` block the panel reads
the single default login exactly as before, as one `codex · week` row carrying
the plan name. With two, each row is labelled by account instead, because the
label needs the slot the plan name was using.

To *use* the second account in a terminal, export the same variable before
running `codex`; the panel only reads the tokens, it never chooses which one a
session uses.

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

Models served from this machine are **excluded** here and get their own card;
see below for why.

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

Both cards read one index, scanned once per pass by `model_index()`, so adding
the local card did not add a second walk over 250MB of logs.

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

## Local models

The fourth card answers two questions the mix cannot: **which models can run on
this machine**, and **how many tokens they have generated**. Local tokens cost
no subscription quota, so folding them into the mix would be the wrong reading
twice over — a percentage of somebody else's budget, and a share that rounds to
0% against a frontier model and vanishes into "Other".

So the numbers here are **absolute counts, not shares**, and every model on disk
gets a row whether it has ever run or not. A row with an empty track is the
answer to "what else could I run", which is half the point of the card.

Two questions, two sources, because no single one answers both:

- **Which models exist, and which is resident** — the Ollama daemon, via
  `/api/tags` and `/api/ps`. A filled lamp means resident in unified memory
  right now; a ring means on disk only. Shape, not just colour, carries this.
- **How many tokens they generated** — *not* Ollama. Its log records prompt-
  cache totals and speculative-decode stats but never an output count, so
  consumption is read from whatever drove the model:
  - **Hermes** — `~/.hermes/logs/agent.log`, one line per call, already carrying
    the model, provider and token counts (`API call #24: model=… provider=custom
    in=… out=…`). It stamps **local time** while the session logs stamp UTC, so
    the day is converted before bucketing.
  - **Claude Code** — already scanned for the mix. `claude-local` points Claude
    Code at Ollama, so those turns arrive with an Ollama tag as the model id and
    simply route to this card instead.
  - **OpenCode** — `opencode.db`, incrementally by a `time_created` high-water
    mark rather than a byte offset. **Unproven:** the store on this machine is
    empty (no sessions, no messages), so the parse is written to the documented
    message shape and reads nothing until a session exists.

A model counts as local when the daemon has it on disk, or when any client
reported it against a local provider — Hermes calls its Ollama connection
`custom`, an OpenAI-compatible base URL, not `ollama`. The union is persisted as
`local_ids`, so attribution survives the daemon being down and a model deleted
mid-window still explains its own tokens.

Local clients keep their tallies in `local_files`, separate from the session
logs in `files`. That is deliberate: a client that also talks to a cloud model
can then never leak that burn into the mix, which reads `files` only.

A daemon that is not answering is a **reading, not a failure** — the title rail
says `offline`, the token history still stands, and nothing is resident. Sizes
on disk are quoted decimally and truncated, exactly as `ollama list` quotes
them, so the panel and the CLI never disagree about the same file; memory is
quoted in binary units, because that is the unit RAM is sold in.

Both `agent.log` and the panel survive Hermes restarting: it **recreates** its
log on launch rather than rotating it, so `scan_log` keeps the day buckets when
a file shrinks and only rewinds the byte offset. The tally already contributed
is not wrong because the evidence was replaced. Session logs are append-only and
never rewritten, so no source double-counts a day this way.

## The merge card

Two instruments off one source: **PRs merged in the last rolling 24 hours**, and
a **seven-column histogram of the last seven days**. It sits under the quota
column on purpose — the budget above it is what paid for the merges below it.

One GitHub search answers both. `total_count` alone cannot, because a count
does not split into days, so the buckets are built from the returned items:

```
GET https://api.github.com/search/issues
    ?q=is:pr is:merged author:@me merged:>=<date>
    &advanced_search=true&sort=updated&order=desc&per_page=100
```

- **Scope** is `PR_SCOPE` in `collect.py`, one line. It ships as `author:@me`
  because every other instrument on this panel is personal — this account's
  quota, this account's models, this body. `org:boringstackai` reads five times
  higher and means team velocity instead; nothing else in the card cares.
- **The window is queried in UTC dates but bucketed in local days**, with a
  day of slack on the query. The columns have to be the user's days: a column
  labelled `WED` that ran 10am Wed to 10am Thu is worse than no chart.
- **Newest-first, capped at 3 pages.** 300 merges inside the window is far
  above the ~9/day this account runs at, but if it ever overflows it drops the
  *oldest* days and never the 24h figure — and it warns on stderr rather than
  quietly reading low.
- **Today is the last column and the only partial one**, so it is the only one
  marked: a cursor under its weekday label, the way a cluster marks the live
  reading. Without it the rightmost column looks like a collapse in throughput
  every morning.
- A day with no merges keeps its column and prints a dimmed `0`. A gap in the
  chart is the reading; absence of a column would be missing data.

The token comes from `gh auth token` — the same login `gh` already holds, so
there is no second credential to manage and none is written to the cache.
`PATH` is not inherited when launchd starts the panel, so the `gh` binary is
looked up by absolute path (`GH_CANDIDATES`); `GITHUB_TOKEN` / `GH_TOKEN` win
if set. No token means `reauth` — the `GIT` lamp lights and the instruments read
`--`, exactly as a dead sensor does.

Like the models and health cards, a GitHub failure is excluded from the
top-level `stale` flag: that flag means "the quota numbers may be out of date,"
and GitHub being unreachable says nothing about quota freshness.

Both `GRM` and `GIT` are magenta when both need a new sign-in, and they sit
adjacent. That is not the collision the colour rule forbids — they are the same
*state*, and the lamp legend is what separates them. The forbidden case is a
*level* wearing a *state* colour, which is why `LOW` is red.

## Endpoints

**Claude Code** — `GET https://api.anthropic.com/api/oauth/usage`
`Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20`.
Token: Keychain service `Claude Code-credentials` → `.claudeAiOauth.accessToken`
(one call per account in `accounts.json`; see "Two Claude subscriptions").
Claude Code refreshes that token itself, so it is read fresh every poll and
never cached. The response has no plan/tier field — the subtitle comes from
`.claudeAiOauth.subscriptionType` + `rateLimitTier` in the same keychain
blob. Only `five_hour` and `seven_day` are used; `seven_day_opus` and
`seven_day_sonnet` are null on this account. Per-model data, if ever wanted,
is in `limits[]` (`kind: "weekly_scoped"`, `scope.model.display_name`).

**Codex** — `GET https://chatgpt.com/backend-api/codex/usage`
`Authorization: Bearer <tokens.access_token>` **and**
`chatgpt-account-id: <tokens.account_id>`, both from `~/.codex/auth.json`.
Without the account-id header the endpoint returns 403.

**GitHub** — `GET https://api.github.com/search/issues` (see the merge card
above). `Authorization: Bearer <gh auth token>`. The search endpoint allows 30
requests/minute authenticated; the collector's 180s TTL makes at most one call
every three minutes.

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
{ "theme": "cluster" }    // 700 × 604pt landscape JDM digital dash
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

Nine boxes in four rows. The left column is budget, then merge count; the right
side is model mix, body, and merge history. The fourth row runs full width:
local models are a list of named things with a size and a count each, not a
single reading, so they get the whole width rather than a cell in the grid.

| Instrument | Data | Why it earns it |
|---|---|---|
| Hero 7-seg + bar | Claude 5h remaining | The one figure that changes what you do in the next hour. Bar carries the same number as a shape, for when the digits are too far to read. Splits into a twin speedo when two accounts are signed in. |
| Tacho ramp | 7-day model mix | Ticks-per-model *and* tick height both encode share — redundant on purpose, so the silhouette alone says whether you're mono-model or spread. Sorted descending, which is what makes a rank-ordered bar chart look like a tacho wedge. |
| Week windows | Claude week (per account), Codex week | Long-horizon totals, read deliberately rather than glanced — the odometer's job. Three rows go compact: numeral left, bar right, one shared bar edge. |
| Vertical bar gauges | Body battery, sleep, steps | Three 0–100 tanks that drain, on one shared rail because all three share a scale. |
| Trip-computer block | Readiness, resting HR, HRV, stress | No 0–100 scale exists, so no bar is drawn. These four **never** traffic-light: low resting HR is good and high HRV is good, so any colour rule would be backwards half the time. |
| Trip-meter counter | PRs merged in the last 24h | Output, next to the budget that bought it. A count has no ceiling, so no bar is drawn beside it — the histogram carries the shape. |
| Merge histogram | PRs merged per day, last 7 days | Seven segmented columns on one rail scaled to the week's own peak, so the tallest column is always full and the *shape* of the week is the reading. Exact figures print under each column, because a segment is worth more than one PR whenever the peak is above 8. |
| Local model list | Ollama models on disk, resident state, 7-day tokens | The only list on the panel, because it is the only reading that is a set of named things rather than a number. Tracks scale to the busiest model by token count, not by rounded share, so a model with 66 tokens beside one with 115k still lights a segment. Residency rides on the lamp's *shape* — filled is in memory, a ring is on disk — since the track says nothing about it. |
| Warning lamps | `CC` `CDX` `GRM` `GIT` per source, plus a derived `LOW` | Real clusters put failure in lamps, not in the gauges. `LOW` is the fuel light — amber at ≤20% on any quota meter, magenta at ≤8%. |

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

Press ⌘⇧E, drag anywhere on the panel background, press ⌘⇧E again. The new
position is written back to `panel.json` as `x`/`y` about half a second after
you let go (debounced so one drag is one write), and reopens there next launch.

Once `x`/`y` are present they win over `corner`/`margin`/`screen` below — a
drag is a stronger signal than the startup default. Delete `x`/`y` from
`panel.json` (or delete the file) to fall back to corner placement again.

**Changing monitors discards them**, because a position chosen on a display
that is no longer attached puts the panel somewhere you can neither see nor
grab. Two checks cover it: the set of attached displays is compared by display
ID on every `didChangeScreenParameters` (so a resolution tweak is *not* treated
as a monitor change and keeps your position), and a saved origin whose panel
centre lands on no screen is dropped on the next reposition — which catches a
monitor swapped while the panel was not running, where there is no
notification to observe. Either way it returns to corner placement.

Corner placement is only the *first-launch* default, before you've ever
dragged it. It's still re-read on every 30s tick, no restart needed:

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
