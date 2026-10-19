## Export complete private Rumor candidates; shared review owns admission.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import rumor/[llm, sim, prompts, evidence]

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
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
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
    let family = "rumor-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var rows = newJArray()
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
        let observation = sim.playerStateJson(seat)
        observation["prompt_template"] = promptMetadata(selection, system, user)
        let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
        let eventIndex = sim.events.len
        if ballot:
          sim.applyVote(seat, parsed.vote, parsed.belief,
            parsed.reason, parsed.notes, true)
        else:
          sim.applyMessage(seat, parsed.claim, parsed.confidence,
            parsed.belief, parsed.message, parsed.notes, true)
        let executed = actionFromEvent(sim.events[eventIndex])
        let attemptId = $rows.len & "-teacher"
        rows.add(%*{"schema_version": "1", "event_type": "decision",
          "episode_id": episode, "decision_id": $rows.len, "decision_index": rows.len,
          "game": "rumor", "game_version": "source-" & sourceRevision,
          "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
          "observation": observation, "prompt": messages,
          "attempts": [{"attempt_id": attemptId, "policy": "scripted-gossip-and-herd",
            "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
            "response": $completion, "parsed_action": executed, "accepted": true,
            "request": newJNull(), "platform_call_id": newJNull(),
            "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
          "selected_attempt_id": attemptId, "executed_action": executed,
          "action_status": "accepted", "fallback_origin": newJNull(), "terminal": ballot})
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    for row in rows: stream.writeLine($row)
    var participants = newJObject()
    for seat in 0 ..< Seats: participants[$seat] = %*{"score": outcome["scores"][seat]}
    stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "rumor", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed", "outcome": outcome,
      "participant_outcomes": participants}))
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "rounds_played": sim.roundsPlayed})
  stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "rumor",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-gossip-and-herd",
    "operator_prompt": OperatorPrompt,
    "prompt_configuration": selectionMetadata(selection),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", games
