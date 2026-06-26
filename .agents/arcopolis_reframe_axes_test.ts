import { assert, assertEquals } from "@std/assert"
import { dirname, fromFileUrl, join } from "@std/path"

// Mechanical FLOOR for the canonical orthogonal-reframe axis set.
//
// The set is defined ONCE in AGENTS.md between sentinel comments (the single source of
// truth). Each arcopolis-* governance skill restates the same set in its own canonical
// list. Dropping or renaming an axis in a skill copy is the PR #79 / Spike-25
// class-drift failure (a build-skill copy silently dropped "native-authority class guess"
// and only a cross-model reviewer caught it). This test fails deterministically when a
// skill's list drifts from the AGENTS.md anchor.
//
// What it CANNOT do: judge whether the anchor set itself is correct (complete,
// non-redundant, well-named). That is a framing question owed to a cross-author seal —
// see docs/arcopolis/reframe_axis_external_seal_prompt.md. This is the floor, not the seal.

const agentsDir = dirname(fromFileUrl(import.meta.url))
const repoRoot = join(agentsDir, "..")

const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
const collapse = (s: string) => s.replace(/\s+/g, " ")

// Parse the canonical axes from the AGENTS.md sentinel block.
const agents = await Deno.readTextFile(join(repoRoot, "AGENTS.md"))
const block = agents.match(
  /<!-- canonical-reframe-axes:start -->\s*([\s\S]*?)\s*<!-- canonical-reframe-axes:end -->/,
)
assert(block, "AGENTS.md is missing the canonical-reframe-axes sentinel block")

const axes = collapse(block[1]).trim()
  .split(",")
  .map((a) => a.replace(/^(?:or|and)\s+/i, "").trim())
  .filter((a) => a.length > 0)

assertEquals(
  axes.length,
  7,
  `expected 7 canonical axes in AGENTS.md, parsed ${axes.length}: ${JSON.stringify(axes)}`,
)

// Ordered, connector-tolerant match: axes in order, separated by commas / whitespace and an
// optional "or"/"and". Tolerates line wrapping and a "different route ..." / trailing-clause
// extension (build's labelled-consequence add); fails if any axis is missing or reordered.
const sep = "[\\s,]+(?:or\\s+|and\\s+)?"
const orderedAxes = new RegExp(axes.map(escapeRegExp).join(sep), "i")

const governanceSkills = [
  "arcopolis-design-explore",
  "arcopolis-design-interrogate",
  "arcopolis-claim-plan",
  "arcopolis-build-from-approved-plan",
  "arcopolis-red-team-review",
]

for (const skill of governanceSkills) {
  Deno.test(`canonical reframe-axis set intact in ${skill}`, async () => {
    const text = collapse(await Deno.readTextFile(join(agentsDir, "skills", skill, "SKILL.md")))
    assert(
      orderedAxes.test(text),
      `${skill}/SKILL.md canonical reframe-axis list drifted from the AGENTS.md anchor.\n` +
        `Expected ordered set: ${axes.join(", ")}.\n` +
        `A dropped or renamed axis is the PR #79 / Spike-25 class-drift failure.`,
    )
  })
}
