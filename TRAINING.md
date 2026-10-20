# Rumor training

Export complete games through the native simulator and hosted reply parser:

```bash
nim r --path:src tools/export_posttrain.nim /tmp/rumor-standard 10 1 standard mixed 0
nim r --path:src tools/export_posttrain.nim /tmp/rumor-bridged 10 1 bridged mixed 0
```

Exports contain `train.jsonl`, `validation.jsonl`, and `manifest.json`.
Every fifth scenario seed belongs to validation. Mixed wording cycles separately
within each split so training receives all five presentations. The `rumor-SEED`
family groups the same scenario across variants and wording selections. Episode IDs
include selected wording and prompt seed so matched exports remain distinguishable.
Rows retain exact message hashes and scripted gossip/herd responses. Each reply
passes the hosted parser before advancing the game. Existing output directories
are rejected. These are scripted imitation examples, not measured model strength.

## Wording and evaluation

`promptVariant` defaults to `canonical`, preserving original messages.
The `rumor-rules-v2` bank varies the explanation of private evidence, its
reliability, the collective majority guarantee, and deceptive seats.
Role-specific rules, strategy guidance, scoring, action syntax, operator
instructions, and retry budgets remain fixed. Hidden roles and clues remain
private; wording selection does not consume simulation randomness.

Training choices are `canonical`, `plain`, `numbered`, `questions`, and
`reordered`. `mixed` requires a nonnegative `promptSeed`, selecting one of
those five once per episode. `heldout-briefing` and `heldout-reference` are
reserved for evaluation. Source exports reject both; bridge resets require
`split: "validation"` or `split: "test"`.

```bash
nim c -d:release --parallelBuild:1 --path:src -o:/tmp/rumor-bridge tools/train_bridge.nim
python3 tools/test_prompt_games.py /tmp/rumor-bridge
```

The persistent JSONL command is `["/tmp/rumor-bridge", "<source>/coworld_manifest_template.json", "standard"]`
with ten players. Use `bridged` for the other variant. `teacher` returns the
scripted response; `step` parses it through the native game. All ten responses
are collected before resolving a simultaneous turn.

Complete-game comparisons check mechanics and provenance, not learned robustness.
A learning comparison must freeze policies and inference settings, match game
seeds, report incomplete games and fallbacks, and reserve held-out wording
until training choices are frozen.
