---
name: ordonnateur
description: >
  Puts each agent-harness event's hooks in the order you choose, and lists, lints, times and test-fires every hook.
  Use it for "hook order", "reorder hooks", "which hooks run", "hook priority", "why is this hook slow" and
  "test a hook". Claude Code and Codex start every matching hook at once, so ordonnateur installs one dispatcher
  hook per carded event and runs the ordered members itself, one after another. Every changing command is planned
  first and applied only after the user says yes. Guards are never sequenced. Codex is read-only. Hermes hooks are
  reordered in place in config.yaml; its allowlist is never written. Antigravity runs hook specs in an order that
  changes every session, so ordonnateur orders them inside one spec of hooks.json; plugin files are never written.
  fire --run executes real commands. `ordonnateur web` shows the hook layout in a browser for the user.
  `ordonnateur untangle` judges hook health across eight dimensions and can heal a fixed set of flaws. Use it for
  "check my hooks", "untangle my hooks", "heal my hooks" and "why is my hook setup broken". `ordonnateur plan`
  reads the whole agent setup, interviews the user briefly and offers changes that serve their goals. Use it for
  "optimize my agent setup", "tune my settings" and "fewer permission prompts". The Régisseur agent is the agent for
  these two verbs.
---

# ordonnateur

## When to use it

Use it when the user wants to know which hooks a harness runs and where each came from, wants hooks to run in a
fixed order, asks why a hook is slow or failing, or wants to test a hook against a synthetic payload. Leave writing
a new hook to the harness's own settings.

## How to use it

- `ordonnateur list [--harness claude-code|codex|hermes|antigravity|all] [--event E] [--json]` lists every hook with its id, event,
  matcher, status, timeout and command.
- `ordonnateur lint` reports dead programs, duplicates, escaped hooks, card problems, slow hooks and Codex trust
  gaps. It exits 1 on any error or warning.
- `ordonnateur timings [--event E] [--months N]` shows p50, p95 and max milliseconds per sequenced hook.
- `ordonnateur card [--scope user|local]` shows the ordered members of a card.
- `ordonnateur order <Event> <hook>... [--scope user|local] [--stop-on-block]` sets an event's members and their
  order. Without `--apply` it prints the plan and the diff and writes nothing. Show the plan to the user and run
  it with `--apply` only after the user says yes.
- `ordonnateur move`, `release`, `unguard` and `guard` change a card the same way: plan first, `--apply` after yes.
- `ordonnateur fire <hook>` prints the command, the cwd and the payload. `fire --run` executes the real command,
  so its side effects happen; run it only with the user's yes.
- `ordonnateur watch` checks hook configuration for new findings and notifies.
- `ordonnateur untangle [--harness H] [--project DIR] [--no-model] [--json]` reports the health of every hook in eight
  dimensions (liveness, correctness, duplication, ordering, latency, safety, integrity, and freshness), asks a model to
  explain the root causes, and exits 1 on any warning or error. Measured facts and the model assessment are printed
  apart. `--no-model` prints the facts, a redacted packet, and the prompt, so you act as the model and reason from
  them yourself.
- `untangle --heal` prints the plan for each healer the finding allows. `untangle --heal --apply` applies them with a
  backup and a re-scan, and rolls back if a new failing finding appears. The `untangle.heal` setting (off, plan, or
  auto) is the user's consent. An agent never changes `untangle.heal` or the `advisor.*` settings, and applies heals
  only after the user says yes. Hooks on guard events, plugin hooks, and project or managed hooks are never healed.
- `ordonnateur plan [--project DIR] [--no-model] [--json]` reads the whole setup and proposes changes. With no
  terminal and no saved profile it prints four short questions and changes nothing: ask the user through the
  harness's question tool, put the replies in a JSON file, and run it again with `--answers FILE`. `--no-interview`
  skips the questions.
- With `plan --no-model` you are the model: write your proposals to a JSON file and run `plan --proposals
  FILE`, which validates and stores only the valid ones and reports each refusal. Show the stored proposals and their
  diffs to the user, and run `plan --apply IDS` only after the user says yes. A proposal that widens access also
  needs `--allow-widening` and a separate yes. Other harnesses get words for the user, never edits.
- `ordonnateur web` serves a browser app that shows the hook layout and changes it through plans (draft, plan,
  apply). It is for the user at the browser: never call its API, and never start it to make a change yourself.
  When the user wants a different order, show them the `order` plan, or tell them to run `ordonnateur web`. Its Health,
  Plan, and Settings sections run `untangle` and `plan` and change `untangle.heal` and `advisor.*` for that person;
  the same rule holds there, and you use the commands above instead.

A hook is named by its full id, a unique 8-hex suffix, or a unique substring of its command.

## What it needs

- Claude Code is the only harness it sequences, in the user scope and the local scope. Project settings, managed
  settings and plugin hooks are listed and linted, never changed.
- Guard hooks (PreToolUse, UserPromptSubmit and PreCompact hooks, hooks with onFailure block, and hooks the policy
  engine protects) are never sequenced unless the user runs `unguard` for a non-blocking guard event hook.
- Codex is read-only: list, lint, timings and fire work; nothing is written to a Codex file.
- Hermes: list, lint, fire and `order`/`move --harness hermes` work. A Hermes hook that is not allowlisted does not
  run until the user approves it in Hermes; ordonnateur reports that and never approves or writes the allowlist.
  Pinned hooks (`fail_closed` guards, policy-protected hooks) keep their place. Show the plan, apply after yes.
- Antigravity: list, lint, fire, `order`, `move` and `release --harness antigravity` work on `~/.gemini/config/hooks.json`
  (`--scope global`) and a project's `.agents/hooks.json` (`--scope workspace --project DIR`). Hooks inside one hook
  spec are permuted in place; hooks from several specs are gathered into a spec named `ordonnateur`, and `release`
  puts them back. Plugin hooks are listed and linted, never changed. New sessions use the new order.
- Settings: `run.record`, `lint.slow_ms`, `watch.enabled`, `alerts.failures`, `events.runs`, `untangle.heal`, the
  `advisor.*` group and the `web.*` group.
- Model use: `ORDONNATEUR_ADVISOR_DISABLED=1` runs both verbs with no model. The default `advisor.backend` runs a
  harness CLI with no tools; `extension` uses the author port when an extension backs it, and never falls back to the
  harness. Everything a model sees has secrets redacted, and a model answer is validated before anything uses it.
