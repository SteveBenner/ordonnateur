# AGENTS.md: ordonnateur

ordonnateur is a plugin built on rplugin, the SDK for agent-harness plugins.
`CLAUDE.md` links to this file, so every harness reads the same text.

## Using it for someone

- It is installed with `~/.rplugin/bin/rplugin install ordonnateur` and checked with
  `~/.rplugin/bin/rplugin doctor ordonnateur`, which must report zero findings. Read
  rplugin's own `~/.rplugin/AGENTS.md` for installing, configuring and
  troubleshooting any plugin.
- What ordonnateur does, the credentials it needs and its settings in `config.yml`
  are described in `README.md`.
- Its skill is `skills/ordonnateur/SKILL.md`; its command, when installed, is `ordonnateur`
  on the user's `PATH`.
- If it owns a corpus, rplugin created it for the plugin. Read and write it
  only through the plugin or `rcorpus`, never by editing its files.

## Changing it

- The manifest is `ordonnateur.rplugin.yml` (schema `rplugin/v1`,
  `~/.rplugin/specs/plugin.yml`). `VERSION`, the manifest's `version` and
  `.codex-plugin/plugin.json` must agree.
- Code reaches every capability (secrets, events, state, registry, schedule,
  corpus) through `Rplugin::Ports.for("ordonnateur", root: <plugin root>)`. Never
  call a host's service or read its files directly, and never copy rplugin's
  runtime or catalogue into this plugin.
- Before calling a change done, run `rplugin check ordonnateur`, `rplugin install
  ordonnateur` and `rplugin doctor ordonnateur`, all at zero findings, and run the plugin
  for real.
- Guide: `~/.rplugin/docs/guides/writing-a-plugin.md`.

## Hot path and Codex

- `ordonnateur run` is the hook hot path. `lib/ordonnateur/runner.rb` and every file it requires must never load
  rplugin; `bin/ordonnateur` dispatches `run` before the runtime loads. Everything else loads rplugin and reaches
  capabilities through `Rplugin::Ports.for("ordonnateur", root: <plugin root>)`.
- ordonnateur never writes to a Codex file. Codex is read-only: inventory, lint, timings and fire only.
- Hermes: ordonnateur writes `$HERMES_HOME/config.yaml` only to permute the entries of one event, only through a plan
  (`HermesOrder`), with a backup. It never writes `shell-hooks-allowlist.json`, never passes `--accept-hooks`, and has
  no `run hermes` dispatcher.

## The web app

- `ordonnateur web` is `lib/ordonnateur/web.rb` and `lib/ordonnateur/web/`; its contract is `specs/web.yml`, and the
  browser code in `web/public` is plain ES modules with no build step, no CDN and no web fonts. `vendor/webrick` is
  loaded only by `lib/ordonnateur/web.rb`; the hot path and every other command never load it.
- It changes hook order only through plans. The web builds each plan with `Takeover` (`HermesOrder` for Hermes), the
  same code as the command line, and `apply` rebuilds the plan, compares its id and writes through `Takeover#apply`
  (`HermesOrder#apply`). Never add a route that
  writes a harness file without a plan, and never apply a policy warn or deny from the web.
- It is for the person at the browser. An agent never calls its API or starts it to make a change: it gives the user
  the `ordonnateur order` plan or points them to `ordonnateur web`.
- Changing `web/public`: all five themes and the one switcher change in the same change.
