## Persistent text bridge using the complete native simultaneous-turn game.
import std/[json, os, strutils]
import rumor/[llm, sim, prompts]

const OperatorPrompt = "Use your private clue and neighbour messages to maximize your score in the final vote."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value: hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc action(decision: Decision, ballot: bool): JsonNode =
  if ballot:
    %*{"vote": decision.vote, "belief": decision.belief,
      "reason": decision.reason, "notes": decision.notes}
  else:
    %*{"claim": decision.claim, "confidence": decision.confidence,
      "belief": decision.belief, "message": decision.message, "notes": decision.notes}

proc observation(game: Sim, seat, id: int): JsonNode =
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, OperatorPrompt)
  let view = game.playerStateJson(seat)
  view["prompt_template"] = promptMetadata(game.config.promptSelection, system, user)
  let schema = if game.phase == phBallot:
      %*{"type": "object", "required": ["vote"], "properties": {
        "vote": {"enum": ["A", "B"]}, "belief": {"type": "integer", "minimum": 0, "maximum": 100},
        "reason": {"type": "string"}, "notes": {"type": "string"}}}
    else:
      %*{"type": "object", "required": ["claim", "message"], "properties": {
        "claim": {"enum": ["A", "B", "none"]}, "confidence": {"type": "integer", "minimum": 0, "maximum": 100},
        "belief": {"type": "integer", "minimum": 0, "maximum": 100},
        "message": {"type": "string"}, "notes": {"type": "string"}}}
  %*{"kind": "decision", "game": "rumor", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.round,
    "semantic_view": view, "inbox": [], "speech_messages": [],
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "action_schema": schema, "typed_question": newJNull(), "inference_mode": "text_action"}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: rumor-train-bridge MANIFEST VARIANT", 1)
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for variant in manifest["variants"]:
    if variant["id"].getStr() == args[1]: variantConfig = variant["game_config"]
  doAssert not variantConfig.isNil, "unknown variant"
  var game: Sim
  var seats: seq[int]
  var decisions: seq[Decision]
  var index, id: int
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      let selection = promptSelection(request)
      let split = request{"split"}.getStr("train")
      if split notin ["train", "validation", "test"]: raise newException(ValueError, "unknown split")
      if split == "train" and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        raise newException(ValueError, "held-out wording cannot enter training")
      let runtime = copy(variantConfig)
      runtime["seed"] = %seedOf(request["seed"].getStr())
      runtime["tokens"] = newJArray()
      for seat in 0 ..< Seats: runtime["tokens"].add(%("t" & $seat))
      var config = defaultGameConfig()
      config.update($runtime)
      config.promptSelection = selection
      game = initSim(sampleEpisode(config))
      seats = game.pendingSeats()
      decisions = @[]
      index = 0
      id = 0
      response = game.observation(seats[index], id)
    of "teacher":
      doAssert not game.done
      let seat = seats[index]
      let proposal = scriptedAction(game, seat, if seat mod 2 == 0: skGossip else: skHerd)
      response = %*{"response": $action(proposal, game.phase == phBallot)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      let ballot = game.phase == phBallot
      let parsed = if ballot: game.parseVoteReply(candidate) else: game.parseTalkReply(candidate)
      decisions.add(parsed)
      inc index
      inc id
      if index == seats.len:
        for offset, seat in seats:
          let selected = decisions[offset]
          if ballot:
            game.applyVote(seat, selected.vote, selected.belief, selected.reason, selected.notes, false)
          else:
            game.applyMessage(seat, selected.claim, selected.confidence,
              selected.belief, selected.message, selected.notes, false)
        seats = game.pendingSeats()
        decisions = @[]
        index = 0
      var next: JsonNode
      if game.done:
        var scores = newJObject()
        for seat in 0 ..< Seats: scores[$seat] = %game.score(seat)
        next = %*{"kind": "terminal", "scores": scores}
      else:
        next = game.observation(seats[index], id)
      response = %*{"kind": "accepted", "action": action(parsed, ballot), "observation": next}
    else:
      raise newException(ValueError, "unknown request kind")
    stdout.writeLine($response)
    stdout.flushFile()
