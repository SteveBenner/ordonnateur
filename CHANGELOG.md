# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
