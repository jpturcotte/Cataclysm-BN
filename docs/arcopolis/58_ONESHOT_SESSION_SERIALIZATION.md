# 58 — One-shot session-serialization fix (avatar.damage_taken[] in `--arcopolis-export-current-view`)

**Status:** built, validated. Equivalence **level 1 (observation only)**, native-authority class **S** (raw
simulation state). Fixes a silent-empty defect in the Spike 27B field; adds two guards (a lexical purity
floor + a runtime drain tripwire). No engine-behaviour change — confined to serialization-capture plumbing.
Stacked on the Spike 27B PR (#90).

## The bug (confirmed at the leaf)

In **one-shot** mode (`--arcopolis-export-current-view <path> --world <w> --arcopolis-command <file>`),
`src/arcopolis_export.cpp:export_current_view` ran in this order:

```
begin_backend_session(...) -> g->do_turn() [tap records into session.avatar_damage]
  -> backend_session_failure() captured -> end_backend_session() -> write_current_view()
```

`end_backend_session()` does `session = backend_session{}` (`arcopolis_backend_input.cpp`), wiping the
buffer. `write_damage_taken` then **drained the now-empty buffer** (the drain ran _after_ teardown). So
`avatar.damage_taken[]` was **structurally always empty in one-shot mode**, even when the command dealt the
avatar attributed damage. The existing `prompt_failure` value is deliberately captured _before_
`end_backend_session()`; the Spike 27B damage buffer was not given the same capture.

## The audit (what is and isn't affected)

A 12-agent audit (workflow `wf_b7d19cf3-384`) + leaf verification established:

- **`avatar.damage_taken[]` is the ONLY session-coupled serialization field.** Of the 60+ snapshot fields,
  every other one reads engine globals / the avatar / the map / per-call locals — never the mutable
  `backend_session`. The serializer's only `backend_take_*` drain was at `write_damage_taken`
  (`arcopolis_export.cpp`); the other two `backend_take_*` accessors are live-loop control reads
  (`arcopolis_live.cpp`), not serialization.
- **One-shot is the ONLY divergent run mode.** Run-script (per-export and final-on-exit) and live
  (per-request and final) write each snapshot **while the session is still active** — run-script final at
  `arcopolis_script.cpp:456` _before_ `end` at `:466`; live final at `arcopolis_live.cpp:1034` _before_ `end`
  at `:1040`. Only one-shot calls `end_backend_session()` before it serializes.

So this was a single field × single mode defect today. But the **mechanism is a latent class**: the
safeguard was unenforced manual discipline (capture-before-end by hand), and the next session-buffered
serialization field would forget it the same way.

## The general invariant

> **Snapshot serialization must be a pure function of state captured while the backend session is active.**
> No session-scoped drain (`backend_take_*`) or `session.*` read that feeds a serialized field may execute
> after `end_backend_session()` has wiped the session.

## The fix

**A — capture-before-end + pure serializer.** `snapshot_ctx` gains a `damage_taken` vector; `write_damage_taken`
reads `ctx.damage_taken` and **never drains the live session** (it is now PURE). The drain moves to the two
capture sites, both while the session is active: `write_session_snapshot` (run-script/live/final) and
`export_current_view` (one-shot, _before_ `end_backend_session()`), threaded into `write_current_view`. Because
the drained set is identical and nothing consumes `session.avatar_damage` between the new and old drain points,
**run-script/live output is byte-identical** — the non-goal ("preserve engine behaviour / faithful exports") is
held. This single change both fixes one-shot and removes the bug's root coupling.

**G1 — lexical serializer-purity FLOOR.** `.agents/arcopolis_serializer_purity_test.ts` (a `deno test` in the
mechanical-floor style of `arcopolis_reframe_axes_test.ts`) asserts that no `write_*` serializer in
`arcopolis_export.cpp` calls `backend_take_*`, and that the one-shot capture still exists (non-vacuous). It is a
**lexical floor, NOT a seal** — a future buffer drained via an indirection (`writer → helper → drain`) slips
past it.

**G2 — runtime drain tripwire (relocated).** `backend_assert_event_buffers_drained()` debugmsg-fail-louds if any
registered session event buffer (today `{avatar_damage}`) is non-empty right _after_ a snapshot's capture/drain
step. It is called at the **drain sites** (`write_session_snapshot`, `export_current_view`), **not** at
`end_backend_session()`. This placement is deliberate: a teardown-sited check gated on `!session.failure` would
**false-fire** on legitimate avatar-death-by-attacker and stall teardowns (`arcopolis_script.cpp:428/439`,
`arcopolis_live.cpp` — those reach `end_backend_session()` with `session.failure` unset and the lethal-hit
damage undrained, because game-over/stall use `session_log_error`, not `session.failure`). Game-over/stall write
no snapshot, so they never reach the drain-sited assertion. It is a **runtime FLOOR**, complementing G1: it
catches the aliased-drain case G1's lexical scan misses, but it only sees buffers that are registered.

## Floor / seal honesty

Neither G1 nor G2 is a **seal**. Per `AGENTS.md` and `.agents/arcopolis_reframe_axes_test.ts:15` ("the floor,
not the seal"), a _seal_ is a mechanical Class-C witness exercising an engine predicate's own result — which
does not exist for "serialization purity." The closest thing here is the RNG-free **Catch2 tripwire** test, and
even that mechanically seals only the `avatar_damage` field, not "any future session-buffered field."
**Generality is carried by the structural purity pattern (read `ctx`, never `session`) + code-review
discipline, not a mechanical guarantee.** A future agent must not read G1/G2 as "the class is sealed."

## Witness

- **Deterministic seal (RNG-free):** the Catch2 test
  `tests/arcopolis_backend_input_test.cpp` — `backend_assert_event_buffers_drained` fires on an undrained
  buffer and is silent once drained. Run against the _pre-fix_ ordering it fires on the one-shot bug itself.
  **Green** (`[arcopolis]`, 1042 assertions / 159 cases).
- **Lexical floor:** `deno test --allow-read .agents/arcopolis_serializer_purity_test.ts`. **Green.**
- **Empirical smoke (FLAKY-RED-PRONE, not the seal):**
  [`oneshot_damage_regression.ps1`](oneshot_damage_regression.ps1) drives K one-shot runs against a hostile
  `mon_zombie` placed **adjacent** (offset `0,1,0`) to the avatar (generated at runtime from `ArcopolisTest`),
  and requires ≥1 run to emit a populated, `mon_zombie`-attributed `avatar.damage_taken[]`. A single bootstrap
  `do_turn` is the **fewest** melee rolls in the suite, so an all-miss across K runs is structurally possible —
  this closes vacuous-green but is _not_ deterministic; the swarm/seed count is the robustness knob.
- **No-behaviour-change:** the run-script reference `attacker_damage_regression.ps1` and
  `world_tick_liveness_regression.ps1` stay green.

## Scope — what this does NOT change (do not let docs widen it)

- Still **L1 observation, class S** — the funnel fact, **not** a hit/miss / damage-type / ranged-vs-melee /
  LOS-perception / NPC-attacker surface (only melee `mon_zombie` is witnessed). The fix restores **parity**
  across run modes, not scope.
- The control-flow drains (`backend_take_unexpected_prompt_error` / `backend_take_pickup_outcome`) are **not**
  in this class and are deliberately not guarded — they are consumed per-request by design.
- The G2 registry checks `avatar_damage` only; adding a future session event buffer means registering it here
  **and** wiring its drain into both capture sites.

## Reproduce

```powershell
# Deterministic gate (no fixture):
& .\out\build\win-rel-deb\tests\cata_test-tiles.exe "[arcopolis]"
deno test --allow-read .agents\arcopolis_serializer_purity_test.ts
# Empirical one-shot smoke (generates its own adjacent-attacker fixture):
pwsh docs\arcopolis\oneshot_damage_regression.ps1 -Exe .\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe
```
