## Export complete Rumor games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import rumor/[llm, sim, prompts]

const OperatorPrompt = "Use your private clue and neighbour messages to maximize your score in the final vote."
const Variants = ["standard", "bridged"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let configured = promptSelection(promptConfig)
  if configured.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  var wordingCounts: array[2, int]
  for seed in firstSeed ..< firstSeed + games:
    var selection = configured
    let splitIndex = ord(seed mod 5 == 0)
    if selection.variant == pvMixed: selection.seed += wordingCounts[splitIndex]
    inc wordingCounts[splitIndex]
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["turnDelayMs"] = %0
    config.update($runtimeConfig)
    config.promptSelection = selection
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let ballot = sim.phase == phBallot
      for seat in sim.pendingSeats():
        let teacher = scriptedAction(sim, seat,
          if seat mod 2 == 0: skGossip else: skHerd)
        let completion =
          if ballot:
            %*{"vote": teacher.vote, "belief": teacher.belief,
              "reason": teacher.reason, "notes": teacher.notes}
          else:
            %*{"claim": teacher.claim, "confidence": teacher.confidence,
              "belief": teacher.belief, "message": teacher.message,
              "notes": teacher.notes}
        let parsed =
          if ballot: parseVoteReply(sim, completion)
          else: parseTalkReply(sim, completion)
        if ballot:
          doAssert parsed.vote == teacher.vote and
            parsed.belief == teacher.belief and
            parsed.reason == teacher.reason and parsed.notes == teacher.notes
        else:
          doAssert parsed.claim == teacher.claim and
            parsed.confidence == teacher.confidence and
            parsed.belief == teacher.belief and
            parsed.message == teacher.message and
            parsed.notes == teacher.notes
        let system = systemPrompt(sim, seat)
        let user = userPrompt(sim, seat, OperatorPrompt)
        rows.add($(%*{
          "episode_id": "rumor-" & variant & "-" & $seed,
          "seed": "rumor-" & $seed,
          "scenario_family": "rumor-" & $seed,
          "prompt_template": promptMetadata(selection, system, user),
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "rumor",
          "action_schema_revision": "rumor-talk-vote-v1"
        }))
        if ballot:
          sim.applyVote(seat, parsed.vote, parsed.belief,
            parsed.reason, parsed.notes, true)
        else:
          sim.applyMessage(seat, parsed.claim, parsed.confidence,
            parsed.belief, parsed.message, parsed.notes, true)
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "rounds_played": sim.roundsPlayed})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "rumor",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-gossip-and-herd",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
