import { assert } from "@std/assert"
import { dirname, fromFileUrl, join } from "@std/path"

// Mechanical FLOOR for the Arcopolis serializer-purity invariant (the one-shot session-serialization fix).
//
// INVARIANT: no JSON serializer (a `write_*` function in src/arcopolis_export.cpp) may DRAIN the live
// backend session (call backend_take_*). The drain must happen at the snapshot's capture site WHILE the
// session is active (write_session_snapshot for run-script/live; export_current_view before teardown for
// one-shot); the serializer reads the captured copy (snapshot_ctx.damage_taken). Draining inside a
// serializer is the Spike 27B one-shot bug shape: in one-shot mode write_current_view runs AFTER
// end_backend_session() wiped the session, so the drain read an empty buffer and avatar.damage_taken[] was
// structurally always-empty.
//
// What it CANNOT do: it is a LEXICAL floor (no dataflow). A future buffer drained via an indirection
// (writer -> helper -> backend_take_*) slips past it; the runtime tripwire
// backend_assert_event_buffers_drained() (Catch2-pinned) is the complementary runtime floor. NEITHER is a
// general "seal" (that would be a mechanical Class-C witness, which does not exist for this class). See
// docs/arcopolis/58_ONESHOT_SESSION_SERIALIZATION.md.

const agentsDir = dirname(fromFileUrl(import.meta.url))
const repoRoot = join(agentsDir, "..")
const src = await Deno.readTextFile(join(repoRoot, "src", "arcopolis_export.cpp"))
const lines = src.split("\n")

// Walk top-level function definitions (signatures begin at column 0 in this file) and record, for each, any
// backend_take_* drains in its body. Brace depth is counted crudely per line -- adequate here because the
// serializers emit JSON via json.* calls and never put literal `{`/`}` in string content, and designated
// initializers / lambdas keep their braces balanced within the function body.
type Fn = { name: string; drains: string[] }
const fns: Fn[] = []
let cur: Fn | null = null
let depth = 0
let entered = false
const startRe = /^auto\s+(?:arcopolis::)?(\w+)\s*\(/

for (const line of lines) {
  if (!cur) {
    const m = line.match(startRe)
    if (m) {
      cur = { name: m[1], drains: [] }
      depth = 0
      entered = false
    }
  }
  if (cur) {
    const drain = line.match(/backend_take_\w+/)
    if (drain) cur.drains.push(drain[0])
    for (const ch of line) {
      if (ch === "{") {
        depth++
        entered = true
      } else if (ch === "}") {
        depth--
      }
    }
    if (entered && depth <= 0) {
      fns.push(cur)
      cur = null
    }
  }
}

Deno.test("arcopolis_export.cpp serializers never drain the live session (one-shot session-serialization purity)", () => {
  const offenders = fns.filter((f) => f.name.startsWith("write_") && f.drains.length > 0)
  assert(
    offenders.length === 0,
    `serializer write_* function(s) drain the live session (the Spike 27B one-shot bug shape): ` +
      offenders.map((f) => `${f.name} -> ${f.drains.join(",")}`).join("; ") +
      `. Serializers must read snapshot_ctx (captured while the session was active); drain at the capture site only.`,
  )

  // Sanity: the one-shot capture itself must still exist (export_current_view drains before teardown), else
  // this purity test would pass VACUOUSLY on a file that never drains at all -- i.e. a regression that
  // dropped the capture and re-broke one-shot would slip through.
  const captured = fns.some((f) => f.name === "export_current_view" && f.drains.length > 0)
  assert(
    captured,
    "expected export_current_view to capture (backend_take_*) the one-shot damage before teardown; none found -- did the capture move or get dropped?",
  )
})
