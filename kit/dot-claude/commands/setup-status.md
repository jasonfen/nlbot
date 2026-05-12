Probe the actual state of every setup phase on this box, compare to `setup-state.md` Current phase, and recommend where setup should be picked up.

This is read-only — it never edits `setup-state.md`. The recommendation is for the human (or `setup-runner`) to apply.

Useful when:
- You want a snapshot of "where am I in setup."
- Something looks out of sync between `setup-state.md` and reality (manual edit, mid-phase crash, vault moved to a new box).
- You're debugging why `setup-runner` keeps deferring or looping.

Run it:

```bash
<KIT>/runtime/setup-status.sh
```

The script prints a column-aligned table of prereqs + phase probes, then a `=== Recommendation ===` block:

```
setup-state.md says:  Current phase: step-5-cron
Reality reached:      step-6-silverbullet
Recommended next:     step-7-web-shell

! Declared phase (step-5-cron) doesn't match reality (step-7-web-shell).
  To resync: edit /home/nlbot/nlbot/setup-state.md → 'Current phase: step-7-web-shell' → run /setup.
```

Exit codes:
- `0` → aligned, no action needed (or setup is `done`)
- `1` → discrepancy or pending work; recommendation printed
- `2` → can't find `setup-state.md` (no vault detected)

Display the script's output verbatim.
