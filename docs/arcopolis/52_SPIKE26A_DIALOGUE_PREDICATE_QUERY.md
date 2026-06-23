# Spike 26A — L1 on-person possession query (dialogue-predicate observation)

> **Goal claim (verbatim — load-bearing labeling guard):**
>
> Observation of the on-person possession predicate as used by BN's DIALOGUE consumer
> (`condition.cpp` `set_has_items`). It does NOT answer `MGOAL_FIND_ITEM` mission completion (the
> mission consumer uses `crafting_inventory()`, broader scope — see Spike 26B).

This sentence is repeated VERBATIM in:

1. the section header (above),
2. the new `ARCOPOLIS_STATE.md` row (this spike),
3. the live response payload's `scope` field (the literal `"on_person_dialogue_predicate"`),
4. the Catch2 test name (`tests/arcopolis_live_test.cpp` — `arcopolis op:query observes on-person
   dialogue predicate; does NOT answer MGOAL_FIND_ITEM mission completion`),
5. the regression's PASS-line text (`docs/arcopolis/spike26a_dialogue_predicate_regression.ps1`).

A future doc-or-code drift cannot silently re-claim mission-completion scope without changing every
coordinated site — five places — in lockstep.

## Status and scope

- **Built.** Adds a new live-protocol scalar op `op:"query", kind:"has_item"` that forwards verbatim to
  BN's dialogue-predicate disjunction `has_charges(id, count) || has_amount(id, count)` (`condition.cpp`
  `set_has_items`, multi-form) on `get_avatar()` and returns the boolean as
  `{ok:true, op:"query", kind:"has_item", has:<bool>, scope:"on_person_dialogue_predicate"}`.
- **Equivalence level 1 — observation.** No engine action runs, no `input_context` is consulted, no
  per-transaction backend-input gate is armed, no transcript engine event is emitted. This is the
  postmortem's corrected primitive for the engine-computed-predicate consumer category, NOT a proxy
  for `MGOAL_FIND_ITEM` mission completion.
- **No engine change.** `condition.cpp`, `visitable.cpp`, `character.cpp`, `mission.cpp` are
  untouched — the handler **delegates verbatim**.

## Why this spike exists — the Spike 25 correction one notch narrower

Spike 25 added a flat `avatar.carried_items[]` snapshot export and was logged as a process-failed spike
([51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md)) because it shipped
a DISPLAY primitive while citing the POSSESSION-validation goal — BN's actual answer to "does the
character have item X?" is a container-recursing predicate (`has_amount` recurses via
`visit_internal` → `contents.visit_contents`), and a flat export structurally cannot mirror it.

The user's red-team on the first version of THIS spike caught a second-order version of the same trap:
the original Spike 26 plan re-picked SCOPE for witness convenience — observing the dialogue predicate
(on-person, `Character::visit_items`) while still being framed against the Stage-A return-package goal,
whose actual predicate is `mission::is_complete`'s `crafting_inventory().has_amount(...)` (broader:
`PICKUP_RANGE` + on-person — `crafting.cpp:601-619`). The three-way split this spike opens (26A / 26B /
26C) carries the consumer/mechanism discipline EXPLICITLY:

- **Spike 26A (this one)** — observes the DIALOGUE predicate on-person. Does NOT answer mission
  completion.
- **Spike 26B** — observes the MISSION predicate via `crafting_inventory()` (broader scope). Does NOT
  drive any NPC interaction.
- **Spike 26C** — drives the actual dialogue → mission completion at L4.

This spike is the smallest of the three: parser branch + handler + formatter + Catch2 + fixture
generator + regression + STATE row + this doc. No new per-transaction gate, no new served prompt
category, no engine touch.

## Public API (the wire shape)

Request:

```json
{ "id": 7, "op": "query", "kind": "has_item", "item": "<itype_id>", "count": 1 }
```

`count` defaults to `1` when omitted (matches the single-form `u_has_item` at `condition.cpp:266-275`);
`kind` is required (v0 accepts only `"has_item"`); `item` must be a non-empty itype_id string.

Success response:

```json
{
  "type": "response",
  "id": 7,
  "ok": true,
  "op": "query",
  "kind": "has_item",
  "has": true,
  "scope": "on_person_dialogue_predicate"
}
```

Fail-loud response (recoverable; the session keeps serving):

```json
{
  "type": "response",
  "id": 7,
  "ok": false,
  "op": "query",
  "error": { "code": "bad_request", "message": "unknown itype_id: '<id>'" }
}
```

The `scope` field is the LOAD-BEARING LABELING GUARD. Future Spike 26B reuses the same `op:"query"`
parser shape additively with `kind:"crafting_has_item"` and `scope:"crafting_inventory"` — extensible
by `kind`, not by an orthogonal `scope` parameter (the alternative shape was considered and rejected
per the Spike 26B plan, "Rejected alternative shape: single op with a `scope` parameter").

## Engine predicate consulted

The handler in `arcopolis_live.cpp` calls, verbatim:

```cpp
const itype_id item_id( req->query_item );
if( !item_id.is_valid() ) { /* bad_request -- recoverable */ }
const auto &av = get_avatar();
const bool has = av.has_charges( item_id, req->query_count ) ||
                 av.has_amount( item_id, req->query_count );
```

This mirrors `condition.cpp` `set_has_items` (multi-form) and `set_has_item` (single-form, when
`count == 1`). The **recursion property** that makes the worn-pocket witness pass is:

- `visitable<T>::has_amount` = `amount_of(...) == qty` (capped, "at least N") —
  `visitable.cpp` near :1244.
- `visitable<Character>::amount_of` → `amount_of_internal` → `self.visit_items(lambda)` — :1215.
- `Character::visit_items` iterates wielded + worn + inv; each item via `visit_internal(func, item*)` —
  :518 region.
- `visit_internal` recurses on NEXT via `contents.visit_contents` — :442 region. Depth-agnostic.
- `has_charges` descends the same way — :1026 region.

**Scope: on-person but container-deep.** The `Character::amount_of` override adds NO off-person source
(only bionic pseudo-tools / voltmeter / apparatus, under `pseudo`); ground items at the avatar's tile
are NOT visited. This is the Spike 26B scope divergence the witness pins below.

## Witness

### Fixture: `ArcopolisCarriedNestedTest`

A clone of `ArcopolisBackpackTest` (GUI-created — its committed save shape is INHERITED by cloning,
NOT regenerated by this spike). The avatar:

- **wears the existing backpack** (worn[6]) with one nested witness item save-edited into its pocket
  via the engine's `item_contents` serialize shape (`{"items": [{"typeid": "glass_shard", ...}]}` on
  the backpack JSON — mirrors `item_contents::serialize` at `savegame_json.cpp:180`);
- **wields `rock`** via the top-level `player.weapon` field (mirrors `Character::store` at
  `savegame_json.cpp:894`);
- **stands on a `feather`** dropped on the avatar's own tile via the submap `items` field (so it
  shows up to `crafting_inventory()` but NOT to `Character::visit_items`).

Built reproducibly by [`make_carried_nested_fixture.py`](make_carried_nested_fixture.py): stdlib-only,
no GUI, no build. The generator validates that the source fixture has a worn backpack at the expected
worn index before cloning, fails loud on drift, and prints the witness placements on success.

### Regression: [`spike26a_dialogue_predicate_regression.ps1`](spike26a_dialogue_predicate_regression.ps1)

Run with **pwsh** (PowerShell 7), not powershell 5.1 (memory doc 26: UTF-8 / BOM gotcha). The
regression drives the live driver
[`spike26a_query_driver.py`](spike26a_query_driver.py) — ONE persistent backend process serving the
seven witness cases plus the clean-quit invariant — and asserts seven hard gates:

| Case | Request                                     | Expected                                          | Pins                                                                                             |
| ---- | ------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| (1)  | `query has_item glass_shard count=1`        | `has:true, scope:"on_person_dialogue_predicate"`  | **container recursion** through the worn backpack pocket                                         |
| (2)  | `query has_item rock count=1`               | `has:true, scope:"on_person_dialogue_predicate"`  | wielded source enumerated                                                                        |
| (3)  | `query has_item hairpin count=1`            | `has:false, scope:"on_person_dialogue_predicate"` | valid-but-absent: a stable BN id absent from the avatar entirely                                 |
| (4)  | `query has_item feather count=1`            | `has:false, scope:"on_person_dialogue_predicate"` | **load-bearing anti-`crafting_inventory()` scope-pin**: the avatar's own ground tile is excluded |
| (5)  | `query has_item GARBAGE_UNKNOWN_ID count=1` | `ok:false, code:"bad_request"`                    | fail-loud unknown-id rejection (recoverable, distinct from has:false)                            |
| (6)  | `query has_item glass_shard count=2`        | `has:false, scope:"on_person_dialogue_predicate"` | cap-to-qty semantics (`has_amount == qty`); only one shard in the pocket                         |
| (7)  | `query has_item glass_shard count=1`        | `has:true, scope:"on_person_dialogue_predicate"`  | **recovery** after the bad-id rejection: the session keeps serving                               |
| quit | `quit`                                      | `ok:true, status:"session_end"`                   | clean exit (backend exit code 0)                                                                 |

### What this witness proves

- The handler forwards to the dialogue-predicate disjunction verbatim — the parity of the worn-pocket
  case (1) against a fixture whose top-level `carried_items[]` export would MISS the item.
- The labeling-guard string is carried by every successful query response, asserted byte-for-byte by
  Gate 5.
- The query op itself consumes no backend-input gate and opens no prompt — Spike 21's unarmed-prompt
  guards remain unchanged.
- The mid-prompt input-ordering invariant is preserved at **both** levels: parser-level (Catch2 — the
  existing `parse_prompt_answer` rejection at `arcopolis_live.cpp:644-646`) and live-transcript level
  (Gate 8 in the pwsh regression, which drives a real Spike 12A pickup PICKUP menu, submits a
  mid-prompt `op:"query"`, asserts `bad_request` while leaving the prompt OPEN, `prompt_cancel`s
  cleanly, and proves the session is recoverable). See §"Where the mid-prompt witness lives" below
  for the cross-link table.
- The script-mode rejection of `op:"query"` is pinned at the parser level — see §"Where the
  script-mode rejection is witnessed" below.

### Where the mid-prompt witness lives — at TWO levels

The plan called for the pwsh regression to open an existing prompt and submit `op:"query"`
mid-prompt as a transcript witness. The build places the witness at **both** levels:

1. **Parser level (Catch2).** `tests/arcopolis_live_test.cpp` — the "wrong-op" cluster of
   `arcopolis parse_prompt_answer rejects bad/missing prompt_id, out-of-range, duplicate, wrong-op
   and malformed` submits the LITERAL string `op:"query"` and asserts `bad_request`. This pins the
   structural rejection at `parse_prompt_answer` (`arcopolis_live.cpp:644-646`) — the same code path
   the prompt-source readers (`arcopolis_live.cpp:281/:355/:442`) forward to.
2. **Transcript level (pwsh regression Gate 8).** `spike26a_dialogue_predicate_regression.ps1` —
   the driver issues a live `pickup direction=here` on `ArcopolisCarriedNestedTest`'s ground feather
   to OPEN the Spike 12A PICKUP menu, submits `op:"query"` mid-prompt, asserts `bad_request` (the
   prompt stays open), `prompt_cancel`s the prompt cleanly, reads the command's success response,
   and then runs a final query that returns `has:true` — proving the session survives the
   mid-prompt rejection.

The companion-witness shape is symmetric to the Spike 12A/15/16 pattern: a structural rejection in
the pure layer plus a live transcript witness on a real fixture. Future spikes that touch the
mid-prompt input-ordering invariant should keep both levels pinned (regressing either is the visible
signal of an architectural change).

### Where the script-mode rejection is witnessed

`op:"query"` is **live-only** by design — `arcopolis_script.cpp`'s step parser (~:178-182) accepts
`op == "export"` and `op == "command"` only and rejects every other op string as `bad_schema` at
parse time. `tests/arcopolis_script_test.cpp` has a dedicated case (`arcopolis parse_script rejects
op:"query" as bad_schema`) that submits a scripted `query` step and asserts the `bad_schema` kind.
No script-side code change is needed; the rejection is symmetric to the Catch2 mid-prompt witness
above (parser-level structural rejection).

### What this witness does NOT prove

- It does NOT prove `MGOAL_FIND_ITEM` mission completion — Spike 26B observes the broader predicate
  (`crafting_inventory()`), Spike 26C drives the dialogue to completion at L4.
- It does NOT prove that a `set_has_items`-gated dialogue response is selectable — no `dialogue::opt`
  loop runs.
- It does NOT prove NPC-subject parity — avatar-only v0 is a witness-convenience scope choice (the
  engine handles NPCs via `npc_has_items` / the `is_npc` fork in `condition.cpp` `set_has_items`,
  deferred to a later follow-up — NOT Spike 26B, NOT Spike 26C).
- It does NOT prove vehicle-cargo / nearby-ground reach — the ground-negative case (4) PROVES THE
  OPPOSITE: that this op excludes them by construction.
- It does NOT prove charge-counted items in isolation — the disjunction's `has_charges` half is wired
  by source delegation, but the witness items are non-charge. A charge-counted-item witness is
  deferred to a future follow-up.

## Files

### Source (additive)

- `src/arcopolis_live.h` — `live_request` gains `query_kind` / `query_item` / `query_count` fields
  (optional / empty for every other op); new `live_query_response` struct and
  `write_query_response_line` formatter declaration.
- `src/arcopolis_live.cpp` — `parse_live_request` gains the `op == "query"` branch (validates kind,
  item, count); `run_live` gains the `op == "query"` arm calling the predicate on `get_avatar()` and
  writing the response; `write_query_response_line` implementation. Adds `#include "avatar.h"` and
  `#include "type_id.h"`.
- **No change** to `arcopolis_command.{h,cpp}` (this op is not a verb — it does not flow through
  `handle_action`).
- **No change** to `arcopolis_script.cpp` (script step parser at `:178-182` already rejects unknown
  `op` strings as `bad_schema`, so a scripted `query` step is rejected by EXISTING code).
- **No change** to `arcopolis_backend_input.{h,cpp}` — no new per-transaction gate, no new served
  category. The served-category invariant block at the top of `arcopolis_backend_input.h` is
  unchanged.

### Tests / regressions / fixtures

- `tests/arcopolis_live_test.cpp` — new TEST_CASEs for the `query` parser (well-formed, defaults,
  missing kind / unknown kind / missing item / empty item / non-int count / count <= 0) and the
  `write_query_response_line` formatter (success / has:false / labeling-guard string).
- `docs/arcopolis/make_carried_nested_fixture.py` — new generator (clones `ArcopolisBackpackTest`).
- `docs/arcopolis/spike26a_query_driver.py` — new Python live driver (stdlib only).
- `docs/arcopolis/spike26a_dialogue_predicate_regression.ps1` — new pwsh regression (seven hard
  gates).
- `docs/arcopolis/fixtures/arcopolis_user/save/ArcopolisCarriedNestedTest/...` — committed fixture
  pack.

### Docs

- This doc (`52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md`).
- New row in `ARCOPOLIS_STATE.md` "Capabilities by spike".
- New section in `TEST_FIXTURES.md` for `ArcopolisCarriedNestedTest`.
- The Spike 25 postmortem already correctly demoted `carried_items[]` to display-only; no change
  needed there.

## Proposed labeling-guard discipline — additive to PR #68 and doc 51's §"Recommended governance fix"

The Spike 25 postmortem ([51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md))
named a **consumer/mechanism rule** — _"for any observation claim, classify the real consumer ... and
expose the native mechanism for that category, never a convenient JSON proxy"_. **PR #68** has ported that
rule verbatim into [`arcopolis-claim-plan/SKILL.md`](../../.agents/skills/arcopolis-claim-plan/SKILL.md)
(new §4 "Consumer + native mechanism (observation claims)") and into
[`arcopolis-red-team-review/SKILL.md`](../../.agents/skills/arcopolis-red-team-review/SKILL.md) (new
reject bullet: _"the capability is only CONSISTENT WITH the cited goal, not SUFFICIENT FOR it"_). The
consumer/mechanism rule catches **wrong consumer named at plan time**.

Spike 26A operationalizes a **complementary** discipline that catches a different failure mode: **right
consumer named, but doc-or-code drifts the scope label later**. Both layer cleanly — #68's plan-time rule
sits above doc-and-code drift in the witnessed artifacts.

**Proposed text (suggested for a future arcopolis-skill update parallel to PR #68's shape — NOT applied
in this PR; Spike 26A demonstrates the pattern in place first):**

> **Labeling-guard discipline (proposed for observation/contract claims that risk scope drift).**
> When a spike's claim is sensitive to a scope-confusion failure mode (the Spike 25 trap and its
> narrower variants — observing the wrong predicate, the wrong actor, the wrong reach), pin the
> scope as a verbatim literal string repeated in **at least four coordinated sites**:
>
> 1. the spike's doc — the goal claim sentence, in the header;
> 2. the ARCOPOLIS_STATE.md row — verbatim;
> 3. the protocol response payload (or transcript field, or test fixture key) the consumer reads —
>    a `scope`/`kind` field that the regression asserts BYTE-FOR-BYTE;
> 4. the Catch2 test case name — so the test name is the labeling guard.
>
> A scope drift cannot then re-claim broader territory silently: it has to change every coordinated
> site simultaneously, and one missed site fails a hard gate. Spike 26A's
> `"on_person_dialogue_predicate"` is the first instance; future scope-sensitive observation/contract
> spikes (Spike 26B's `"crafting_inventory"` for the mission predicate; Spike 26C's not-yet-named
> dialogue acceptance string) should adopt the same pattern.
>
> This is NOT a blanket requirement for every spike. It applies when the postmortem's
> consumer/mechanism rule alone is insufficient to surface a scope-confusion drift at review time —
> typically observation claims where the proxy and the real predicate could disagree under future
> code changes.

## Standardization note — regression script PASS lines (going-forward, not retrofit)

Spike 26A's regression PASS lines log the labeling-guard string verbatim (Gate 5: `every successful
query response carries scope='on_person_dialogue_predicate'`). This is **going-forward guidance** for
new regression scripts that adopt the labeling-guard discipline above — not a retrofit requirement
for the existing regressions (`movement_regression.ps1`, `monster_export_regression.ps1`,
`prompt_menu_regression.ps1`, `query_popup_regression.ps1`, `script_prompt_regression.ps1`,
`examine_regression.ps1`, `live_protocol_regression.ps1`, `client_harness_regression.ps1`,
`frontend_prototype_regression.ps1`, `vertical_movement_regression.ps1`,
`stairs_fixture_regression.ps1`, `item_export_regression.ps1`, `npc_export_regression.ps1`), which
predate this discipline and have their own scope-pinning mechanisms (witness fixtures, message
stream cross-checks, message text assertions). Retrofitting them is not required and not part of
Spike 26A.

A new regression for a scope-sensitive observation/contract claim SHOULD log the labeling-guard
literal in at least one PASS line, so a regression-log reader can confirm the scope without reading
the response payload directly.

## Out of scope (deferred — explicit so the scope drift trap can't recur)

- NPC-subject query (the `is_npc` fork — would need an actor parameter; future follow-up, not Spike
  26B and not Spike 26C).
- `crafting_inventory()` scope query — **Spike 26B**.
- Mission completion via dialogue drive — **Spike 26C**.
- Quality / category / charges-only query (`has_quality`, `u_has_item_category`, `charges_of`) —
  deferred behind future `kind` discriminators.
- Any new prompt-class support, any new per-transaction gate, any engine source edit.
