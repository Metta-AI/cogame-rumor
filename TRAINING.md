# Rumor training

Rumor exports complete private candidate games using the same seat prompts
and reply parser as the hosted player. Export requires a clean commit:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/rumor-standard 10 1 standard mixed 3
nim r --path:src tools/export_posttrain.nim /tmp/rumor-bridged 10 1 bridged mixed 3
```

The exporter reads the selected certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded games per variant, and writes
`trajectories.jsonl` and `manifest.json`. The shared Coworld SDK and application
importer own review and dataset splits. The `rumor-SEED` family groups each
scenario across variants and wording selections. The teacher
alternates the published gossip and herd scripts by seat. Each assistant reply
passes through the hosted parser before its action advances the simulator.
The exporter refuses an existing output directory.

Each private decision records exact messages and hashes, teacher response,
selected attempt, and the normalized action recorded by the simulator.
Completed episode events carry outcomes. Candidates require independent review
before training admission; they are not ready-to-train datasets.

The `standard` and `bridged` variants each produce 600 examples from ten
games. These are imitation examples from scripted play; loss on this dataset
does not measure competitive strength. The native game has text replies with
free-form claims and notes. Its text bridge preserves that action space and
collects all ten responses before resolving a simultaneous turn.

## Wording and evaluation

`promptVariant` defaults to `canonical`, preserving the original messages.
`plain`, `numbered`, `questions`, and `reordered` paraphrase the introduction.
`mixed` requires a nonnegative `promptSeed` and selects among those five once
per episode, independently of scenario randomness. Private roles, clues,
neighbours, strategic hints, scoring, schemas, operator instructions, and
retry budgets remain fixed.

`heldout-briefing` and `heldout-reference` are evaluation-only wordings.
Source exports reject them. Bridge resets require `split: "validation"` or
`split: "test"` to use them.

```bash
nim c -d:release --parallelBuild:1 --path:src -o:/tmp/rumor-bridge tools/train_bridge.nim
python3 tools/test_prompt_games.py /tmp/rumor-bridge
```

The persistent JSONL command is `["/tmp/rumor-bridge", "<source>/coworld_manifest_template.json", "standard"]`
with ten players. Use `bridged` for the second variant. Reset accepts the
wording fields; `teacher` returns the published scripted action; `step` parses
and executes text actions through the native simulator.

For private native evidence, set `RUMOR_HOST_TRACE_PATH` outside published
artifact directories and set `RUMOR_SOURCE_REVISION` to the qualified commit.
The host creates an exclusive owner-only file containing actual HTTP requests,
responses, prompt hashes, retries, selected attempts, and applied events.
This file includes operator instructions and must remain private.

Deterministic fixtures verify mechanics and provenance, not model robustness.
A learning comparison must freeze policies and inference settings, match game
seeds, report incomplete games and fallbacks, and reserve held-out wordings
until training choices are frozen.
