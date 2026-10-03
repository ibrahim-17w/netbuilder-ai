# Teaching loop, Phase 2 (2026-09-18): verify, promote, precede, report

Phase 1 armed a correction as a one-shot override so the step could be
re-attempted without believing it. Phase 2 closes the loop.

## What changed

**Promotion only on verification** (`_settle_teach_run`, called from
`run_plan`): when a teach run finishes, its armed overrides are settled
against the run's own verdict.

- verified -> `_promote_teach_override` writes the entry into the real store
  (`PC_LEARNED`, `SRV_MEM` fields/buttons, `DEV_MEM`, `CAPABILITIES`), tagged
  with provenance (`taught`, `correctionId`, `taughtOn`), and the correction
  row flips to `verified` with a `promotionRef` (its first hit is counted).
- failed -> the correction is `rejected` with the observed reason and journalled
  as `correction_rejected`; nothing is written to any store.
- crashed or stopped before a verdict -> the row stays `proposed` (a run that
  never reached the step has no right to reject the user's answer).
- ordinary runs settle nothing (nothing is armed) - zero cost added.

**Provenance and precedence**: promoted entries are checked via
`_taught_meta_of`. A user-taught spot is served even when the strategy store
would quarantine the same spot (`_learned_spot`, `_srv_learned_field`,
`_srv_learned_button`) - the engine's verdict reflects its own guesses, not a
correction the user verified on screen.

**No silent quarantine of taught entries**: engine learn/evict paths refuse to
overwrite or delete a taught entry (`_learn_spot`, `_srv_learn_button`,
`_srv_evict_button`, `_srv_field_miss`, `remember_device`). Each refused
attempt counts a miss on the correction; at `CORRECTION_REPORT_AFTER` (2) the
row is flagged stale and journalled as `correction_stale` - reported, never
deleted. A same-spot reuse is just a metadata refresh and counts nothing.
Re-teaching the same element replaces the taught entry on purpose (the newest
user instruction wins; thrash counting already warns about ping-ponging).

**Revert reached**: `_undo_promotion` now also removes a promoted placement
(`DEV_MEM` keyed `project:device`), only if it is still taught.

**Visibility**: `/status` carries `corrections`, `teachRun`, `teachResults`;
the new journal kinds (`correction_verified`, `correction_rejected`,
`correction_stale`, `correction_protected`, `correction_reverted`) are
classified in the taxonomy (never offered as correctable steps).

## Deliberately out of scope

- `cli_fallback` / `order` / `cli_context` promotions (the CLI override
  plumbing does not exist yet - taxonomy entries are still teachable so the
  sheet does not lie, but a teach run for them will report `unknown store`).
- The Flutter UI for the stale/rejected badges (the sidecar side of
  `/corrections` and `/status` already serves the data).

## Tests

`test_teaching_loop.py` gains Phase 2 coverage: promotion on verify, rejection
with reason, crash leaves proposed, no-op settlement on ordinary runs,
precedence over a quarantined spot, re-learn protection, stale reporting with
the entry kept, SRV button/field protection and precedence, placement
promotion + protection + revert, revert frees the engine to re-learn, journal
classification of the new kinds, and `/status` exposure. Full sidecar suite:
281 passed.
