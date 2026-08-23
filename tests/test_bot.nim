## The scripted baselines must play whole episodes without ever proposing
## an illegal move — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## They must also sit inside a measured accuracy band: below the floor they
## are noise, above the ceiling there is nothing for a champion to win.

import std/[json, math, monotimes, strutils, times, unicode, unittest]
import rumor/[llm, sim]

proc fixture(seed: int, rounds = 5, topology = "random"): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.topology = topology
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kind: ScriptKind,
    audit = false): Sim =
  result = initSim(config)
  while not result.done:
    let ballot = result.phase == phBallot
    for seat in result.pendingSeats():
      let decision = scriptedAction(result, seat, kind)
      if audit:
        ## Every field is legal as-is: applyMessage / applyVote raise on
        ## anything else and would fail this test.
        check decision.claim in ["A", "B", "none"]
        check decision.confidence in 0 .. 100
        check decision.belief in 0 .. 100
        check decision.vote in ["A", "B"]
        check decision.message.len > 0
        check decision.message.runeLen <= MaxMessageLen
        check decision.notes.len == 0
        check decision.reason.len == 0
      if ballot:
        result.applyVote(seat, decision.vote, decision.belief,
          decision.reason, decision.notes, true)
      else:
        result.applyMessage(seat, decision.claim, decision.confidence,
          decision.belief, decision.message, decision.notes, true)

suite "scripted baselines":
  test "both baselines play every topology legally, in both roles, fast":
    var sawHonest = false
    var sawSaboteur = false
    for kind in [skGossip, skHerd]:
      for topology in Topologies:
        for seed in [1, 7, 42, 1234]:
          let config = fixture(seed, topology = topology)
          let started = getMonoTime()
          let sim = playScripted(config, kind, audit = true)
          let elapsed = (getMonoTime() - started).inMilliseconds
          check sim.done
          check sim.reason == "complete"
          check sim.roundsPlayed == config.rounds
          check sim.honestSeats.len > 0
          check sim.saboteurSeats.len > 0
          sawHonest = true
          sawSaboteur = true
          var says = 0
          var votes = 0
          for event in sim.events:
            if event.kind == evSay: inc says
            elif event.kind == evVote: inc votes
          check says == config.rounds * Seats
          check votes == Seats
          check elapsed < 2000
    check sawHonest
    check sawSaboteur

  test "the aggregation band: gossip beats the room, herd trails it":
    var totals: array[2, float]
    let trials = 500
    for index, kind in [skGossip, skHerd]:
      for seed in 0 ..< trials:
        let sim = playScripted(fixture(seed), kind)
        totals[index] += sim.accuracy
    let gossipRate = totals[0] / trials.float
    let herdRate = totals[1] / trials.float
    echo "all-gossip honest accuracy over ", trials, " seeds: ", gossipRate
    echo "all-herd   honest accuracy over ", trials, " seeds: ", herdRate
    check gossipRate > 0.60
    check gossipRate < 0.78
    check herdRate > 0.55
    check herdRate < 0.70
    ## The whole point of the second filler: it is the seat a lie
    ## propagates through.
    check herdRate < gossipRate

  test "gossip counts a repeated claim exactly once":
    var sim = initSim(fixture(3))
    let seat = 0
    let talker = sim.neighbours(seat)[0]
    let base =
      if sim.clue[seat] == "A": ClueLogOdds else: -ClueLogOdds
    check abs(sim.gossipLogOdds(seat) - base) < 1e-9
    for round in 0 ..< 4:
      for other in sim.pendingSeats():
        if other == talker:
          sim.applyMessage(other, "A", 90, 90, "it is A, again", "", true)
        else:
          sim.applyMessage(other, "none", 50, 50, "", "", true)
      ## However many times the same neighbour repeats itself, its claim
      ## moves the log-odds once: an echo is not new evidence.
      check sim.firstClaims(seat).len == 1
      check abs(sim.gossipLogOdds(seat) - (base + ClaimLogOdds)) < 1e-9

suite "llm fallback and parsing":
  test "with no credentials every seat plays scripted, with no wait":
    let config = fixture(3, rounds = 3)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    var prompts = newSeq[string](Seats)
    prompts[0] = "be bold"
    var kinds = newSeq[ScriptKind](Seats)
    kinds[2] = skHerd
    let started = getMonoTime()
    let decisions = client.decideAll(sim, seats, prompts, kinds)
    let elapsed = (getMonoTime() - started).inMilliseconds
    check decisions.len == Seats
    ## No network call and no rate-governor sleep.
    check elapsed < 500
    for index, seat in seats:
      let kind = if seat == 2: skHerd else: skGossip
      let expected = scriptedAction(sim, seat, kind)
      check decisions[index].claim == expected.claim
      check decisions[index].message == expected.message
      ## Provenance: every baseline decision says so, and the flag reaches
      ## the event and the replay JSON.
      check decisions[index].scripted
      sim.applyMessage(seat, decisions[index].claim,
        decisions[index].confidence, decisions[index].belief,
        decisions[index].message, "", decisions[index].scripted)
    check sim.round == 1
    for event in sim.events:
      if event.kind == evSay:
        check event.scripted
        check event.eventToJson()["scripted"].getBool()

  test "PLAYER_SCRIPTED spellings":
    check parseScriptKind("1") == skGossip
    check parseScriptKind("gossip") == skGossip
    check parseScriptKind("TRUE") == skGossip
    check parseScriptKind("herd") == skHerd
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone

  test "talk replies parse tolerantly and cap every field":
    let sim = initSim(fixture(9))
    let a = sim.optionA
    let b = sim.optionB
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":72,"belief":70,"message":"hi"}""")
      ).claim == "A"
    ## A model reply is never marked scripted; only the baseline is.
    check not sim.parseTalkReply(parseJson(
      """{"claim":"A","message":"hi"}""")).scripted
    check sim.parseTalkReply(parseJson(
      """{"claim":"b","message":"hi"}""")).claim == "B"
    check sim.parseTalkReply(parseJson(
      "{\"claim\":\"" & a & "\",\"message\":\"hi\"}")).claim == "A"
    check sim.parseTalkReply(parseJson(
      "{\"claim\":\"" & b.toLowerAscii() & "\",\"message\":\"hi\"}")
      ).claim == "B"
    check sim.parseTalkReply(parseJson(
      """{"claim":"maybe","message":"hi"}""")).claim == "none"
    check sim.parseTalkReply(parseJson(
      """{"claim":null,"message":"hi"}""")).claim == "none"
    ## Numbers: strings and floats coerce, out-of-range clamps.
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":"81","message":"hi"}""")
      ).confidence == 81
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":80.6,"message":"hi"}""")
      ).confidence == 81
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":173,"message":"hi"}""")
      ).confidence == 100
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":-4,"message":"hi"}""")).confidence == 0
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":"lots","message":"hi"}""")
      ).confidence == 50
    ## A missing belief is derived from claim + confidence.
    check sim.parseTalkReply(parseJson(
      """{"claim":"A","confidence":72,"message":"hi"}""")).belief == 72
    check sim.parseTalkReply(parseJson(
      """{"claim":"B","confidence":72,"message":"hi"}""")).belief == 28
    check sim.parseTalkReply(parseJson(
      """{"claim":"none","message":"hi"}""")).belief == 50
    ## Neither a claim nor a message is the one invalid talk reply.
    expect RumorError:
      discard sim.parseTalkReply(parseJson("""{"claim":"maybe"}"""))
    expect RumorError:
      discard sim.parseTalkReply(parseJson("""{"notes":"nothing"}"""))
    ## Caps, on rune boundaries.
    let longText = "日".repeat(900)
    let capped = sim.parseTalkReply(parseJson(
      $ %*{"claim": "A", "message": longText, "notes": longText}))
    check capped.message.runeLen == MaxMessageLen
    check capped.notes.runeLen == MaxNotesLen
    check capped.message.validateUtf8() == -1
    check capped.notes.validateUtf8() == -1

  test "ballot replies require a parsable vote":
    let sim = initSim(fixture(9))
    let a = sim.optionA
    check sim.parseVoteReply(parseJson(
      """{"vote":"A","belief":85,"reason":"three to one"}""")).vote == "A"
    check not sim.parseVoteReply(parseJson("""{"vote":"A"}""")).scripted
    check sim.parseVoteReply(parseJson("""{"vote":"b"}""")).vote == "B"
    check sim.parseVoteReply(parseJson("""{"vote":1}""")).vote == "A"
    check sim.parseVoteReply(parseJson("""{"vote":"2"}""")).vote == "B"
    check sim.parseVoteReply(parseJson(
      "{\"vote\":\"" & a & "\"}")).vote == "A"
    check sim.parseVoteReply(parseJson(
      """{"vote":"A","belief":140}""")).belief == 100
    expect RumorError:
      discard sim.parseVoteReply(parseJson("""{"belief":50}"""))
    expect RumorError:
      discard sim.parseVoteReply(parseJson("""{"vote":"maybe"}"""))
    let longText = "日".repeat(900)
    let capped = sim.parseVoteReply(parseJson(
      $ %*{"vote": "A", "reason": longText, "notes": longText}))
    check capped.reason.runeLen == MaxReasonLen
    check capped.notes.runeLen == MaxNotesLen

  test "extractJsonObject tolerates fences and prose":
    check extractJsonObject("```json\n{\"vote\":\"A\"}\n```"
      ){"vote"}.getStr() == "A"
    expect RumorError:
      discard extractJsonObject("I think the answer is BROKEN.")

suite "prompts":
  test "a prompt carries the seat's own view and nothing hidden":
    var sim = initSim(fixture(7, rounds = 3))
    for seat in sim.pendingSeats():
      sim.applyMessage(seat, (if seat mod 2 == 0: "A" else: "B"), 70, 70,
        "message from seat " & $seat, "", true)
    check sim.round == 1
    for seat in 0 ..< Seats:
      let system = sim.systemPrompt(seat)
      let user = sim.userPrompt(seat, "operator says hi")
      let text = system & "\n" & user
      ## Its own view.
      check sim.word(sim.clue[seat]) in user
      check "operator says hi" in user
      check "Round 2 of 3" in user
      for neighbour in sim.neighbours(seat):
        check sim.names[neighbour] in user
        check ("message from seat " & $neighbour) in user
      ## Nothing hidden: no non-neighbour's message, and no other seat's
      ## clue or role.
      for other in 0 ..< Seats:
        if other == seat or other in sim.neighbours(seat):
          continue
        check ("message from seat " & $other) notin user
      ## The truth marker never appears; only a saboteur is told a crew,
      ## and only its own.
      check "TRUTH IS" notin text
      if sim.roleOf[seat] == 0:
        check "You are a SABOTEUR" notin system
        for other in sim.saboteurSeats:
          if other != seat:
            check ("The other saboteurs are: " & sim.names[other]) notin system
      else:
        check "You are a SABOTEUR" in system
        for other in 0 ..< Seats:
          if sim.roleOf[other] == 1 or other == seat:
            continue
          ## An honest cog is never named as a saboteur.
          check ("saboteurs are: " & sim.names[other]) notin system

  test "the ballot prompt asks for a vote, not a message":
    var sim = initSim(fixture(7, rounds = 3))
    while sim.phase != phBallot:
      for seat in sim.pendingSeats():
        sim.applyMessage(seat, "A", 60, 60, "hello", "", true)
    let user = sim.userPrompt(0, "")
    check "SEALED VOTE" in user
    check "\"vote\"" in user
    check "\"claim\"" notin user
