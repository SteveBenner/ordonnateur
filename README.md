# ordonnateur

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first.

A plugin built on [rplugin](https://github.com/SteveBenner/rplugin). ordonnateur puts each harness event's hooks in
the order you choose, and lists, lints, times and test-fires every hook.

## Why order needs a dispatcher

Claude Code runs matching hooks concurrently: "When an event fires, its matching hooks run in parallel." Codex does
the same: `execute_handlers` pushes every non-async handler into a `FuturesUnordered`, awaits them together, then
sorts results by configured order. So no hook is guaranteed to run before another. ordonnateur gives an event a
card, an ordered list of hooks it runs itself, one after another, from a single dispatcher hook it installs in
place of those hooks.

Hermes Agent differs: it already runs an event's shell hooks one after another in the order of its `config.yaml`, so
ordonnateur needs no dispatcher there. It lists, lints and test-fires Hermes hooks, shows which are allowlisted, and
reorders the entries of one event in place.

## Install

ordonnateur needs Ruby 3.3 or later and [rplugin](https://github.com/SteveBenner/rplugin) 1.19.0 or later.

```
git clone https://github.com/SteveBenner/ordonnateur ~/.rplugins/ordonnateur
~/.rplugin/bin/rplugin install ~/.rplugins/ordonnateur
~/.rplugin/bin/rplugin doctor ordonnateur
```

Codex users must trust the session-start watch hook once in Codex's /hooks view. Hermes users must approve the
session-start watch hook once (`hermes hooks`); ordonnateur never writes Hermes's allowlist.

## Commands

- `ordonnateur list [--harness H] [--event E] [--project DIR] [--json]` lists every hook with id, event, matcher,
  status, timeout and command. Claude Code statuses are native, member#n, dispatcher, guard, not-sequenceable and
  disabled-plugin; Codex statuses are trust-recorded, untrusted, disabled, managed and unknown; Hermes statuses are
  allowlisted, not-allowlisted and auto-accepted.
- `ordonnateur lint [--harness H] [--project DIR] [--json]` reports findings and exits 1 on any error or warning.
- `ordonnateur card [--scope user|local] [--project DIR] [--json]` shows a card.
- `ordonnateur order <Event> <hook>... [--scope] [--stop-on-block|--no-stop-on-block] [--apply]` sets the members.
- `ordonnateur move <Event> <hook> (--first|--last|--before <hook>|--after <hook>) [--scope] [--apply]`.
- `ordonnateur release (<Event>|--all) [--scope] [--apply]` returns members to native hooks.
- `order` and `move` take `--harness claude-code|hermes`. For Hermes (chosen automatically for `hm:` ids) they
  permute the named unpinned hooks of one event among the list slots those hooks already occupy in
  `$HERMES_HOME/config.yaml`; pinned hooks (`fail_closed` on `pre_tool_call`, or policy-protected) keep their place.
  `release`, `card`, `guard` and `unguard` do not apply to Hermes, which has no cards.
- `ordonnateur unguard <hook>` and `ordonnateur guard <hook>` change the card's unguarded list.
- `ordonnateur fire (<hook>|--event <Event>) [--payload FILE] [--set key=json]... [--cwd DIR] [--run] [--json]`
  prints what it would run; `--run` executes the real commands.
- `ordonnateur timings [--event E] [--months N] [--json]` shows p50, p95 and max per sequenced hook.
- `ordonnateur watch [--quiet] [--json]` reports new findings since the last run and notifies.
- `ordonnateur run claude-code <Event> --card <path>` is the dispatcher hook; `ordonnateur record` stores a run.
- `ordonnateur web [--bind ADDR] [--port N] [--public-origin URL] [--expose] [--open] [--read-only] [--json]` serves
  the web app; `ordonnateur web url` prints a fresh one-time link for the running server.

Every changing command prints the plan, every refusal and a unified diff, and writes nothing without `--apply`.
With `--apply` the policy port judges a write of each target file first, a backup goes to
`${XDG_STATE_HOME:-~/.local/state}/rplugin/ordonnateur/backups/`, and the write aborts with exit 3 when the
settings file changed meanwhile.

## The card

A card is YAML (`specs/card.yml`). The user card is `${CLAUDE_CONFIG_DIR:-~/.claude}/ordonnateur.yml`; a local card
lives under `${XDG_STATE_HOME:-~/.local/state}/rplugin/ordonnateur/cards/`, never inside a repository. Members run
in list order, with the digest of each checked before it runs. With `stop_on_block`, a member that blocks ends the
sequence.

## The web app

`ordonnateur web` serves a local web app that shows every hook as a layout and changes Claude Code hook order only
through plans. It reads the same files the command line reads and writes through the same code as `order`, `move`,
`release`, `guard` and `unguard`; it has no database. The contract is `specs/web.yml`.

- **The layout.** The map has one table per harness. Its columns are the harness's events in lifecycle order and its
  rows are where hooks come from: managed settings, user settings, project settings, local settings for the project
  you pick, each enabled plugin, and Codex's files. A sequenced event shows its members as one numbered frame; hooks
  left native sit beside it, marked as starting at once. Guards, hooks the policy engine protects and events that
  cannot be sequenced are locked, with the reason. Each hook shows its lint findings, its timeout and its recorded
  p95. Hovering a hook highlights the same program elsewhere. The list view shows the same hooks as a table and is
  the default on narrow screens. Click a column header to sort the rows inside each event; `#` returns to run order.
  `?view=list` and `?sort=p95:desc` in the address open the page that way.
- **Sources.** A bar under the title shows one colored toggle for each source (a row of one harness: Claude Code user
  settings, a plugin, Codex's config, Hermes's profile config). Each source keeps its color in every theme, and its
  hooks carry that color as an outline and a rail. Switch a source off and its hooks leave the map and the list; the
  button goes muted, with Alt+click or `o` to keep only that source Show all to bring everything back and Hide all to switch every source off. Hovering a button highlights that source's cards in the map. Your
  choice is remembered in the browser, and `?off=codex:user,hermes:user` opens the page with those sources off.
- **Projects.** The project selector starts on Global Shelf (no project). Select a Folder... opens a folder picker;
  the folder you choose is pinned, selected and its hooks load. It lists folders only, through `GET /api/v1/folders`.
- **Changing it.** Drag a hook, or use its actions menu or the keyboard (Alt+Arrow keys move a member, `s` sequences
  a native hook, `r` releases a member, `g` guards or unguards), and the change goes into a draft. Plan turns the
  draft into a plan: the exact diff, the policy verdict for every file it writes, the lint findings before and
  after, and when the change takes effect. Apply rebuilds the plan and writes only when nothing moved since: a
  settings file that changed after the plan, a plan that expired after an hour or a changed policy verdict answers
  409 and nothing is written. A reorder inside an event that is already sequenced applies on one click. Sequencing a
  hook, releasing an event, and guard or unguard need the plan id typed. A policy warn or deny is never applied from
  the web; Codex stays read-only.
- **Safety.** The server listens on loopback only. `ordonnateur web` prints a link that works once within 120
  seconds; the page exchanges it for a session cookie the page's scripts cannot read, and every change carries a
  CSRF token, an `Origin` that names the server and a `Host` that names the server, so a page on another site cannot
  reach it. A session may make 30 changes a minute. `--read-only` and `ORDONNATEUR_WEB_DISABLED=1` turn writing and
  the app off. A bind address that is not loopback needs `--expose`, a terminal and the typed phrase
  `expose ordonnateur web`. An agent never drives the API: it gives the user the `order` plan or points them to
  `ordonnateur web`.
- **Hosting.** Behind a reverse proxy, set `web.public_origin` to the one HTTPS origin the proxy publishes; links,
  cookies (`Secure`) and the `Host` and `Origin` checks then use it. The plugin does not start a proxy or supervise
  the server; run it from your own supervisor.
- **Themes.** The app ships rStack's five themes (Minimal Dark, Minimal Light, Apple Noir, Apple Austere and
  Tronwave) behind one switcher; `system` follows the browser's light or dark setting.

State lives under `${XDG_STATE_HOME:-~/.local/state}/rplugin/ordonnateur/web/`: the launch secret, `server.json`,
`server.log` and the pinned projects. The browser keeps only the theme, view preferences and unsent drafts.

## The guard rule

ordonnateur never absorbs a guard: a PreToolUse, UserPromptSubmit or PreCompact hook not in the card's unguarded
list, a hook with `onFailure` "block", or a hook the policy port reports as protected.

## Scopes and limits

Sequencing covers Claude Code user scope and local scope only. Project settings, managed settings and plugin hooks
are listed and linted, never changed. Codex is read-only: nothing is written to a Codex file. Hermes keeps one scope
(the profile `config.yaml`); ordonnateur rewrites only the order of one event's entries there, never a command,
matcher or timeout, never the allowlist, and a running Hermes gateway keeps its old order until it restarts.
SessionEnd,
PermissionRequest and events outside the sequenceable list are refused. Hooks that are async, not `command` type, or
that use the powershell shell are not absorbed, and neither is any hook while managed settings set
`allowManagedHooksOnly`.

## Settings

`run.record` (kill switch `ORDONNATEUR_RECORD_DISABLED`), `lint.slow_ms`, `watch.enabled` (kill switch
`ORDONNATEUR_WATCH_DISABLED`), `alerts.failures` and `events.runs`; for the web app, `web.enabled` (kill switch
`ORDONNATEUR_WEB_DISABLED`), `web.bind`, `web.port` (default 7422), `web.public_origin`, `web.theme`, `web.projects`
(colon-separated project roots) and `web.discover`. `ordonnateur web` loads the WEBrick copy in `vendor/webrick`
(Ruby and BSD-2-Clause licenses, see `vendor/VERSIONS.yml`); no other command does.

## License

MIT, see [`LICENSE`](LICENSE). `vendor/webrick` keeps its own license (`vendor/webrick/LICENSE.txt`).
