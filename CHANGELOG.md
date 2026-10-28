# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.9] - 2026-10-27

### Fixed

- The release check runs `rplugin check` through a temporary link named after the plugin id, and the test
  environment's deploy runs only `scripts/release.rb check`. Why: `rplugin check .` requires the plugin directory to
  be named after the plugin's id, the test checkout is named `test`, and so the first test deploy of 0.2.8 failed.
  0.2.8 was tagged but never published; 0.2.9 is the first published release that carries the 0.2.8 changes below.

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
- Releases go through polispec environment control (`specs/polispec/environments.yml`): main is development, a
  promotion to test tags the release and checks it in its own checkout (`rplugin check`, then `scripts/release.rb
  check`, which compares `ordonnateur version` with `VERSION` and runs lint for every harness), and only the operator
  promotes to stable. The stable deploy pins the tag on the host (`rplugin install . --ref vX.Y.Z`, then `rplugin
  doctor`), refreshes the Antigravity copy when Antigravity lists ordonnateur, and publishes the tag's tree to the
  manifest's GitHub remote as one commit and tag (`scripts/release.rb publish`), refusing an untagged or dirty
  checkout and a tag GitHub already holds with a different tree; `ORDONNATEUR_PUBLISH_DISABLED=1` stops it. Why: a
  release was copied to GitHub by hand from a working tree that held another session's uncommitted work, nothing
  checked it first, and the host ran the development tree instead of a release.
- `.gitattributes` marks `.rproject`, `.agents/directives`, `FEATURES.md`, `scripts`, `specs/implementation` and
  `specs/polispec` export-ignore, so `git archive` of a tag is the public tree. Why: the exclusion list was retyped by
  hand for each publication.

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
