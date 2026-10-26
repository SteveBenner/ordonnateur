# TODO

## Backlog

- Web app: edit Codex hooks once Codex sequencing exists.
- Web app: `ordonnateur web` prints its one-time launch link on startup even when a supervisor runs it, so the link lands in the supervisor's log (single use, 120 seconds); add a flag that leaves it out.
- Web app: show recorded timings for native hooks.
- Web app: show paths as `~/...` once `/config` answers the home directory.
- Web app: control borders in the shared themes measure below 3:1 against control fills (1.60:1 in apple-austere); the fix belongs in the rStack theme tokens.
- Port kit fixes between ordonnateur's and polispec's web apps, or move the shared kit to one source.
- Codex sequencing once ordonnateur can ask Codex for a hook's trust status.
- Project scope (`.claude/settings.json`).
- SessionEnd within its 1.5-second budget.
- PermissionRequest and the other events.
- Timings for native hooks.
- Release restores each member at its original group position when that position still exists, so a git-tracked settings file shows no reordering diff.
