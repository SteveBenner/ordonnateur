# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-11-06

### Changed

- **`ordonnateur optimize` is now `ordonnateur plan`.** Options are unchanged. The old name is gone. State moves with
  it to `plan-profile`, `plan-proposals`, and `plan-applied`, the event is `ordonnateur.plan.applied`, and the contract
  is `specs/untangle-plan.yml`. Answers and proposals saved under the old name are not carried over, so `plan` asks
  again.

### Added

- **`ordonnateur web` now has Health, Plan, and Settings beside Hooks.** Press 1 to 4 to switch, or open a section
  with `?section=`.
  - **Health** shows the eight dimensions, which filter the findings table, and the model's assessment, labeled as
    judged. You can preview each heal's diff and apply it yourself. Opening the page never heals, even under `auto`,
    and Run says Run and heal when it will.
  - **Plan** takes your goals, which are all optional, and runs with a model or facts only. Each proposal shows its
    diff or instructions and has its own Apply. One that widens access is marked and needs its id typed. Facts only
    gives you the prompt to copy for an agent, and a field to paste what it writes.
  - **Settings** changes `untangle.heal` and the `advisor.*` settings, shows where each value comes from, and resets
    them. Turning on `auto` needs the word typed, and a kill switch locks its row and says which switch.
  - Model runs happen in the background, so the page stays usable and finds its run again after a reload.

### Fixed

- **Applying one proposal no longer blocks the rest of that run.** The others were refused as changed, even though
  ordonnateur itself had made the change, so you had to run the model again. They now update against the new settings
  and show the new diff. A change from outside ordonnateur still refuses them.
- `advisor.model` is checked before any model call, so a value can never be read as a command-line flag.

## [0.3.0] - 2026-11-06

### Added

- **`ordonnateur untangle` checks the health of your hook setup.** It reports every harness's hooks in eight
  dimensions (liveness, correctness, duplication, ordering, latency, safety, integrity, and freshness) and adds checks
  that `lint` leaves out, such as a hook program someone else can write to, or a guard-event hook that can't block. A
  model then explains the likely root causes, printed apart from the measured facts. `lint` and `watch` output is
  unchanged.
- **`untangle` can heal a fixed set of flaws.** The new `untangle.heal` setting is `off` by default. `plan` shows heal
  plans and applies them with `--heal --apply`. `auto` also applies the built-in safe healers on each `untangle` run,
  which changes the earlier rule that nothing is written without `--apply`, and only because you opted in. A model
  never chooses a heal. Each heal has a diff, a policy judgment, and a backup, and it's rolled back if a re-scan finds
  a new failing finding. Guard-event, plugin, project, and managed hooks are never healed, and neither are Codex files
  or Hermes's allowlist.
- **`ordonnateur optimize` tunes your agent setup to your goals.** It asks up to four short questions, reads your
  settings across harnesses, and offers changes that serve your answers. Allowlisted Claude Code settings can be
  applied with `--apply` and a diff, a policy judgment, and a backup. A change that widens access also needs
  `--allow-widening`, and it never turns off a plugin that holds a guard. Other harnesses get exact instructions.
- **The model is configurable.** By default both verbs run a harness CLI (`claude` or `codex`) with no tools and none of
  your hooks. `advisor.backend: extension` uses the new `author` port, which is rLLM on rStack hosts. `--no-model` lets
  the agent running the command act as the model. Secrets are redacted before any model sees your setup. If the model
  is off or fails, you still get every measured finding.
- **The Régisseur agent** runs these two verbs for you, working from evidence and applying only what you approve.

## [0.2.18] - 2026-11-05

### Fixed

- **A tab that could not store its `ordonnateur web` session gave no warning.** With `sessionStorage` blocked or full,
  the session lived only in memory and the storage error was discarded, so a reload ended the session with no
  explanation. The page now shows an error toast once the app opens, and the sign-out screen says to close the tab if
  it could not clear the stored token. Measured in Chromium with storage forced to fail: no toast before, the toast
  after, and none on a tab whose storage works.

### Changed

- The README's pinning example names `<tag>` rather than a version that goes stale with each release.

## [0.2.17] - 2026-11-04

### Fixed

- **`ordonnateur web`'s session cookie reached every service on the same hostname.** Browsers scope cookies by hostname
  and ignore the port, so another service on `127.0.0.1` or on a shared public name received it. The session is now a
  token the page keeps in `sessionStorage` and sends as a header, which replaces the cookie and the CSRF token. A reload
  keeps the session, a new tab now needs a new link from `ordonnateur web url`, and signing out ends only that tab's
  session. Measured in Chromium with a second service on another port: it received the session cookie before, and nothing
  after.

## [0.2.16] - 2026-11-04

### Changed

- **Published releases carried notes about how this project is developed.** `AGENTS.md`, `specs/app.yml`, and this
  changelog now describe the plugin, and the published `AGENTS.md` leaves out rows whose targets are not published. Tags
  v0.2.9, v0.2.10, and v0.2.12 were re-created with the same code and those texts reworded, so a clone that already holds
  them needs `git fetch --tags --force`. Measured on the rewritten tags: only `AGENTS.md`, `specs/app.yml`, and
  `CHANGELOG.md` differ from the originals.

## [0.2.15] - 2026-11-04

### Fixed

- **A dispatcher crash on a guard event let the action go ahead.** An event the dispatcher could not process raised out
  of `ordonnateur run`, and its exit 1 is non-blocking, so no member ran. Any failure while dispatching a guard event now
  exits 2 with the reason. Measured on two such events: exit 1 with no member run before, exit 2 after.
- **A hook that timed out could still grant permission.** Claude Code discards a timed-out hook's output, but the
  dispatcher kept it. A timed-out member can now block but cannot allow, rewrite input, or add context, and plain stdout
  counts only on exit 0. Measured: `allow` emitted after a timeout before, none after; stdout of an exit 1 hook passed on
  as context before, dropped after.
- **A guard's deny could be lost when the dispatcher could not parse the hook's output.** Output that failed to parse
  counted as plain text with exit 0. On a guard event such output now blocks, which is stricter than Claude Code. This
  includes output cut at the 1 MiB cap. Measured: nothing enforced before, deny after.
- **A hook that set `shell` to `bash` ran under `/bin/sh`.** `Member.argv` ignored the field, so where `/bin/sh` is dash
  a guard using bash syntax failed with a non-blocking error instead of blocking. The field is now honoured, and hooks
  without it still run under `/bin/sh`, as Claude Code does on Linux and macOS. Measured on a guard with `shell` set to
  `bash`: error with exit 127 before, deny after.
- **A hook's `if` filter was lost once it was on a card.** Only Claude Code evaluates that filter, so the hook ran on
  every event its matcher accepted. Hooks with an `if` field are no longer sequenced; a member already on a card is
  unchanged, so `release` any that use one. Measured: status `native`, which can be sequenced, before, and
  `not-sequenceable` after.
- **Editing a member's matcher hid the edit.** The matcher was checked before the digest, so an entry edited to stop
  matching was skipped as unmatched. The digest now comes first. Measured: nothing enforced before, deny after.
- **Previewing an Antigravity workspace plan could run a program the repository configured.** A preview no longer runs
  repository-configured commands. Measured in a scratch repository: the program ran during a preview before, and did not
  after.
- **A new card could be readable by other accounts.** `Takeover#apply` gave a new card the default mode, though it holds
  hook commands copied from the settings file. Every card write now sets 0600. Measured from a 0600 settings file: card
  mode 664 before, 600 after. An existing card tightens on its next write.
- **`ordonnateur list` printed raw terminal control bytes from hook commands**, so a project's settings could rewrite
  what the terminal showed. Command-line output and watch notifications now replace them. Measured: ESC and BEL present
  before, absent after.
- **A longer command could be listed as a dispatcher.** Only the exact generated shape qualifies now. Measured: status
  `dispatcher` before, `not-sequenceable` after.
- **Chunked requests were refused only on some routes.** Every route now answers 411 first and closes the connection.
  Measured: 405 and 403 with the connection open before, 411 and closed after.
- **Simultaneous starts could run more than one server for a state home**, because the single-instance check tested a
  file that was only written once the server was listening. A server now holds a lock on `server.lock`. Measured over 12
  rounds of 6 simultaneous starts: 35 servers before, exactly 1 per round after.

## [0.2.14] - 2026-11-04

### Fixed

- **An interrupted first start of `ordonnateur web` could leave an empty launch secret that later starts accepted.** The
  secret file was created first and filled second, and nothing refused an empty one. It is now written and synced to a
  private temporary file and hard-linked into place, so the file is complete whenever it exists and the first of several
  simultaneous starts wins. Startup refuses an empty launch secret with exit 2 `secret_empty` and leaves the file in
  place; delete it and start again to create a new one. Measured: a kill during the write left a 0-byte file that the
  next start served from before, and left no file and a clean restart after. Over 12 rounds of 6 simultaneous first
  starts, 1 of 14 servers held a secret the file did not contain before, and 0 of 35 after.

## [0.2.13] - 2026-10-28

### Fixed

- `rplugin check` passes again under rplugin 1.19.5, which refused ordonnateur with two findings (root `plugin.json`
  stale, and Codex ignoring the plugin's hooks). Codex prefers the root Agent Plugins `plugin.json` over
  `.codex-plugin/plugin.json` and reads no hooks from it, and rplugin renders that file only when a claimed harness
  needs it, here Antigravity's skill install. The manifest now marks Antigravity `unsupported` and leaves it out of
  `extensions.enabled` and `extensions.only`, `rplugin package` removed the root `plugin.json`, and Codex can run the
  session-start `watch` hook once it is trusted in `/hooks`.

### Removed

- The Antigravity skill install. The Antigravity skill copy that 0.2.12 refreshed stays installed and is no longer
  updated. `list`, `lint`, `fire`,
  `watch`, `order`, `move` and `release` keep reading and ordering Antigravity's hooks.

## [0.2.12] - 2026-10-28

### Fixed

- The dispatcher fails closed on a guard event. On PreToolUse, UserPromptSubmit and PreCompact, a card that cannot be
  read, an event the card has no entry for, a payload that is not a JSON object, or a member whose digest no longer
  matches its entry now ends the event with exit 2 and the reason (`lib/ordonnateur/runner.rb`). Why: these cases
  exited 1, or ran the remaining members with an empty payload, and Claude Code treats exit 1 as non-blocking, so a
  guard hook sequenced into a card could be skipped by breaking the card or editing one entry by hand. On every other
  event the same faults still exit 1 and the event goes on. The run record carries `decision: deny` and `blocked: true`
  for these cases.

## [0.2.11] - 2026-10-28

### Fixed

- `bin/ordonnateur` reads and writes text as UTF-8 whatever the locale (`Encoding.default_external`). Why: with no
  `LANG` or `LC_ALL`, Ruby read the harness settings as US-ASCII and `list` and `lint` stopped with "invalid byte
  sequence in US-ASCII" at `claude_code.rb` on any settings file holding a non-ASCII character.

## [0.2.10] - 2026-10-28

### Fixed

- Release checks no longer depend on the caller's PATH to find the installed command or Antigravity's `agy`.

## [0.2.9] - 2026-10-27

### Fixed

- The release check runs `rplugin check` through a temporary link named after the plugin id. Why: `rplugin check .`
  requires the plugin directory to be named after the plugin's id. 0.2.8 was tagged but never published; 0.2.9 is the
  first published release that carries the 0.2.8 changes below.

## [0.2.8] - 2026-10-27

### Added

- Antigravity support (the `agy` CLI, the IDE and the 2.0 app share one hook format, observed with agy 1.4.7):
  `list`, `lint`, `fire` and `watch` read the global `~/.gemini/config/hooks.json`, every `.agents`, `.agent`,
  `_agents` and `_agent` directory from the project up to the repository root, and the plugins under them with their
  on/off state from `~/.gemini/config/config.json` (`RPLUGIN_ANTIGRAVITY_HOME` reads another home). Ids start with
  `ag:`. Statuses are active, member, disabled, disabled-plugin, file-skipped, ignored-event and prompt. Why:
  Antigravity runs hooks from five kinds of place, and a hook nobody can see cannot be ordered or trusted.
- `order`, `move` and `release` take `--harness antigravity` (chosen automatically for `ag:` ids) with `--scope global`
  or `--scope workspace --project DIR`, and `release --file PATH`. Hooks inside one hook spec are permuted in place;
  hooks from several specs of one file are gathered into a spec named `ordonnateur`, and a ledger under ordonnateur's
  state (`ordonnateur.antigravity-ledger/v1`) records where each came from so `release` puts each back at its index.
  Every write goes through a plan (`AntigravityOrder`) with a policy judgment and a backup; plugin files are never
  written. Why: Antigravity runs the array inside one spec in order but changes the order between specs and files
  every session, so one spec is the only place an order holds; verified with three live agy sessions.
- Lint codes ORD-AG-SKIPPED, NOTJSON, EVENT, MATCHER, CLAUDE-TOOL, NOHOOKS, MATCHER-IGNORED, RANDOM-ORDER, DISABLED,
  TIMEOUT, DUPNAME, PROMPT and LEDGER, each with a fix that names `--project` and `--scope` where they apply. Why:
  Antigravity skips a whole file for one wrong type, a trailing comma or a group on a flat event, without saying so.
- `fire` builds Antigravity's camelCase payload and environment (`ANTIGRAVITY_CONVERSATION_ID`) and runs from the
  hooks.json directory, as Antigravity does; `fire --event` refuses PreInvocation and PostInvocation. Why: a test-fire
  that differs from the real run tests the wrong thing.
- The web app shows Antigravity as its own table: Global hooks, each workspace file, each plugin and Disabled plugins.
  Inside a cell the hooks group by hook spec, the `ordonnateur` spec is a numbered frame, and a cell with hooks from two
  or more specs is marked as running in an order that changes every session. Drag inside a spec, or Move up and Move
  down, reorders it in place on one click; gathering a hook into the `ordonnateur` spec (`s`) or releasing it (`r`)
  needs the plan id typed. Plugin rows are read-only. Why: the user asked for full reorder in the web, built through
  the same `AntigravityOrder` plans as the command line.
- Releases are tagged `vX.Y.Z` on GitHub, so `rplugin install <clone> --ref v0.2.8` pins one read-only. Why: no
  public release carried a tag, so nobody could pin or roll back to a version.
- Each published release is one commit and one tag on GitHub, checked before it is published. Why: a release could
  reach GitHub without being checked first.
- `.gitattributes` decides what a release leaves out, so `git archive` of a tag is the public tree.

### Changed

- `--harness` accepts `antigravity`, and the invalid-harness message names claude-code, hermes and antigravity.
  `guard`, `unguard` and `card` refuse `ag:` hooks. Why: Antigravity has no card and no guard list.
- The map's Read-only marker carries its name as `role="img"` with an `aria-label` instead of clipped hidden text.
  Why: the ratelier render audit flagged the clipped text (LAY-24) once Antigravity's plugin rows showed the marker.
- An applied Antigravity plan emits `ordonnateur.card.applied` with `harness: antigravity`, its scope and mode, one
  event per event it changed or released. Why: rLogs records every order change, whichever harness it went to.

### Fixed

- A Claude Code source switched off in the source bar now hides every one of its rows in the list: `projected()` in
  `od-list.js` re-added the members and natives of the user and local scopes from the full layout. Why: with User
  settings off, its sequenced members still showed in the list, against `specs/web.yml`, which already promised the
  fix.
- Hovering or focusing a source button marks that source's list rows (`data-hot`, a `--src` outline and tint in every
  theme), as it already did for map cards. Why: the list gave no way to see which rows a source owned.
- Map row names wrap instead of ending in an ellipsis, breaking first after `@` and ` · `. Why: long plugin ids such
  as `harness-memory@harness-memory` were cut off at the row header's width.

## [0.2.7] - 2026-10-26

### Added

- The README shows the web app's map view under its opening paragraph (`assets/ordonnateur-web.png`, the original
  2040×1291 screenshot, linked to itself at full size). Why: the layout of hooks by source and event shows what
  ordonnateur does faster than the command list does.
- ordonnateur is published on GitHub at `SteveBenner/ordonnateur` under the MIT license (`LICENSE`). The README's
  install steps start with the `git clone` into `~/.rplugins/ordonnateur`. Why: the install steps assumed a copy was
  already on disk, and without a license nobody could legally reuse the published code.
- The manifest declares `license: MIT`, and `rplugin package` writes it into `plugin.json`,
  `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`. Why: the license then has one source, and `rplugin
  check` holds the three files to it.

### Changed

- The manifest and the native plugin packages name `https://github.com/SteveBenner/ordonnateur` as the repository.
  Why: the repository link in each harness's plugin page has to open for anyone who installs the plugin.

## [0.2.6] - 2026-10-26

### Added

- The project selector opens with Global Shelf (no project), pinned at the top with an accent tint and rail and the
  default text when nothing is selected, and Select a Folder... in the warn colour under it. Select a Folder... opens a
  themed folder picker (`web/public/js/components/od-folder-picker.js`, `selectable=folder`, following the rui-hub
  `composite.form.file-picker` props); confirming pins the folder, selects it and loads its hooks. Why: the dropdown was
  empty until Claude Code had discovered a project, so a directory could not be opened from the page.
- `GET /api/v1/folders` lists the sub-folders of a directory for the picker, and `/config` reports `folder_picker`.
- A declared `folder_picker` port (`lib/ordonnateur/folder_picker/standalone.rb`) and a plugin-local `rui-hub`
  extension (`extensions/rui-hub`) that reports rui-hub's own component once rui-hub serves it. Why: the picker comes
  through an extension rather than a direct call to the rui-hub host; today rui-hub holds the module as a reservation
  with no built component, so the standalone picker answers.

### Changed

- The project combobox accepts fixed rows (`kind: shelf|action`) that are never filtered out, and an action row that
  fires `od-combo-action` instead of changing the selection.

## [0.2.4] - 2026-10-26

### Added

- Every list column but Actions is a sort button (`web/public/js/core/sort.js`). A sort reorders rows inside each
  event group and never moves the groups; `#` returns to execution order, the default. Hook, Source and Status start
  ascending, Findings (severity, then count), p95 and Timeout start descending; missing values sort last and ties keep
  execution order. Order badges keep showing execution positions. The active header carries `aria-sort`, the change is
  announced, and the choice is remembered in the browser under the pref `sort`. Why: finding the slowest hook or the
  hooks with findings meant scanning every event by eye.
- Page parameters `?sort=<key>:<asc|desc>` and `?view=list|map` start the page in that sort or view without storing
  it, read through one helper (`web/public/js/core/query.js`). Why: a sorted list view is shareable, and the rendered
  audit can only vary the URL.

### Changed

- List headers have no block padding and are centred, so the 24px sort buttons sit in the 28px header row. Numeric
  columns are 104px wide from 600px up (`--list-col-num-wide`) and the order column is 8px wider, so `Findings`,
  `p95 ms`, `Timeout s` and `#` are not cut off beside the sort glyph.

### Fixed

- List cells are all centred: `p95` and the order badge no longer sit on a baseline of their own, so `n/a` no longer
  rides about 4px above the rest of its row.

## [0.2.3] - 2026-10-26

### Added

- The source bar has a Hide all button, shown while any source is showing, that switches every source off; Show all
  still appears while any source is off. Both can show together. Why: isolating one source meant switching off every
  other one by hand.
- Hovering or focusing a source button highlights that source's hook cards and its row header in the map with a
  stronger outline, glow and tint in the source's color.

### Changed

- Map columns now size to their widest hook card, in the detailed and compact densities alike, so no program name,
  matcher or timing on a card is cut off; the map scrolls sideways when the columns outgrow the window. The matcher
  chip shows the whole matcher, and a card never wraps its text. Why: fixed-width columns clipped long program names
  and matchers with an ellipsis, which hid the value the card exists to show.

## [0.2.2] - 2026-10-26

### Added

- The web app has a bar of colored source toggles under the title. A source is one row of one harness (Claude Code
  user settings, each plugin, Codex's config, Hermes's profile config). Each has a fixed color per theme, drawn as an
  outline and rail on its hooks and as a dot in the list. Switching a source off hides its hooks in the map and the
  list; drafts, plans and order numbers still read the full layout. The choice is kept in the browser, and
  `?off=<source>,<source>` or `?off=*` opens a view with sources off.

## [0.2.1] - 2026-10-26

### Added

- Hermes Agent is a supported harness. `list`, `lint`, `fire` and `watch` read the `hooks:` block of
  `$HERMES_HOME/config.yaml` and the consent allowlist (`shell-hooks-allowlist.json`), so each hook shows as
  allowlisted, not-allowlisted or auto-accepted. Hermes already runs an event's hooks in config order and keys its
  consent on the command, so there is no dispatcher: `order` and `move` take `--harness hermes` and permute the
  named unpinned hooks of one event in place, keeping `fail_closed` and policy-protected hooks where they are. The
  rewrite is textual, proved equal to the planned order by re-parsing the YAML, backed up, and refused when the
  layout cannot be reordered safely. The allowlist is never written.
- Hermes lint findings: `ORD-HERMES-UNALLOWLISTED`, `-STALE-CONSENT`, `-MATCHER-IGNORED`, `-FAILCLOSED-IGNORED`,
  `-TIMEOUT`, `-ENV`, `-DUP`, `-BADENTRY`, `-EVENT` and `-ALLOWLIST`.
- `fire` builds the payload Hermes sends and, with `--run`, runs the command the way Hermes does and reports a block.
- The web app lists Hermes hooks in a Profile config row, shows consent status, reorders by drag or from the hook
  menu, and plans, diffs and applies Hermes reorders; plan bodies gain `orders`, and `/config` gains Hermes events.
- `compatibility.harnesses.hermes` is now supported, so `rplugin install` links the skill and merges the
  session-start watch hook into Hermes.

### Changed

- The harness control in the web app reads Claude Code, Codex, Hermes and All; `Both` is now `All`.

## [0.2.0] - 2026-10-22

### Added

- `ordonnateur web`, a local web app that shows every Claude Code and Codex hook as a layout (one table per harness,
  events in lifecycle order, sources as rows, sequenced events as numbered frames) and changes hook order only through
  plans. A draft becomes a plan with the exact diff, the policy verdict for each file, lint before and after and the
  effect; apply rebuilds the plan and writes nothing when the settings moved. A reorder inside a carded event applies
  on one click; sequencing a hook, releasing an event, and guard or unguard need the plan id typed. Warn and deny
  verdicts are never applied from the web, and Codex stays read-only. The contract is `specs/web.yml`.
- `ordonnateur web url` prints a fresh one-time link for the running server.
- Seven `web.*` settings (`enabled`, `bind`, `port`, `public_origin`, `theme`, `projects`, `discover`), the kill switch
  `ORDONNATEUR_WEB_DISABLED`, and the `--read-only` flag.
- The app ships rStack's five canonical themes behind one switcher, and drag, keyboard and menu ways to reorder.

### Security

- One-time launch codes in the URL fragment (120 seconds, single use), an HttpOnly SameSite=Strict session cookie, a
  CSRF header, `Origin` and `Host` checks that stop DNS rebinding, a limit of 30 changes a minute per session, a
  Content-Security-Policy with no inline script or style, and refusal of chunked request bodies. A bind address that is
  not loopback needs `--expose`, a terminal and a typed phrase.

### Changed

- `lib/ordonnateur/web.rb` loads WEBrick 1.9.2 from `vendor/webrick`. This relaxes the 0.1 rule of Ruby standard
  library only for the web server: no other command loads it, and the hot path never does.
- The reason a hook cannot be sequenced for a non-sequenceable event now reads as a predicate like the others ("is on
  PermissionRequest, which cannot be sequenced: ..."), so `list --json` and the web app can show `<hook> <reason>`.
- `Takeover` takes `cwd:`, `via:` and `at:`, so the web builds the same plan as the command line; the applied-card
  event records `via: "web"`.

### Known hazards

- The web app's kit (`web/public/css/components`, `web/public/js/components`) is copied from polispec's web app with
  the `ps-` prefix renamed to `od-`. The two copies drift: a fix in one is not in the other until someone ports it.

## [0.1.0] - 2026-10-22

### Added

- Inventory of every hook Claude Code and Codex will run, with its source, trust status and absorbability.
- Cards that order a Claude Code event's hooks, with `order`, `move`, `release`, `unguard` and `guard`, planned
  first and applied only with `--apply`.
- A hot-path dispatcher that runs card members one after another and merges their output per event.
- `fire` test-firing of a hook or a card against a synthetic payload, `timings` from recorded runs, and `lint`.
- A declared `policy` port with a polispec extension that judges writes and real fires and names protected hooks.
- `watch` with a session-start trigger, failure alerts through rnotify, and run, fire and lint events.
