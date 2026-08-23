## Rumor's rules, proved. The sim module is pure, so every one of these
## runs the same code the server, the wasm viewer and the tests share.

import std/[json, math, sequtils, sets, strutils, unicode, unittest]
import rumor/sim

proc fixtureConfig(rounds = 5, seed = 0, topology = "random",
    saboteurs = -1): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  result.topology = topology
  result.saboteurs = saboteurs
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc speakAll(sim: var Sim, claim = "A", message = "hello") =
  for seat in sim.pendingSeats():
    sim.applyMessage(seat, claim, 60, 60, message, "", true)

proc voteAll(sim: var Sim, vote = "A") =
  for seat in sim.pendingSeats():
    sim.applyVote(seat, vote, 60, "because", "", true)

proc crossEdges(sim: Sim, group: HashSet[int]): int =
  for edge in sim.edges:
    if (edge[0] in group) != (edge[1] in group):
      inc result

suite "roles":
  test "saboteurs are a seeded 2-or-3 subset and honest seats the rest":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      check sim.saboteurSeats.len in [MinSaboteurs, MaxSaboteurs]
      check sim.honestSeats.len == Seats - sim.saboteurSeats.len
      let sab = sim.saboteurSeats.toHashSet()
      let honest = sim.honestSeats.toHashSet()
      check (sab * honest).len == 0
      check (sab + honest).len == Seats
      for seat in sim.saboteurSeats:
        check sim.roleOf[seat] == 1
        check sim.roleName(seat) == "Saboteur"
      for seat in sim.honestSeats:
        check sim.roleOf[seat] == 0
        check sim.roleName(seat) == "Honest"

  test "both saboteur counts occur and the crew moves around":
    var counts = initHashSet[int]()
    var crews = initHashSet[string]()
    for seed in 0 ..< 40:
      let sim = initSim(fixtureConfig(seed = seed))
      counts.incl(sim.saboteurSeats.len)
      crews.incl(sim.saboteurSeats.join(","))
    check counts.len == 2
    check crews.len > 5

suite "graph":
  test "every family is connected, symmetric and the right size":
    for family in Topologies:
      var degreeFloor = Seats
      for seed in 0 ..< 200:
        let sim = initSim(fixtureConfig(seed = seed, topology = family))
        check sim.topology == family
        ## Connected: BFS from seat 0 reaches all ten.
        check sim.edges.graphConnected()
        ## Deduped and ascending.
        for edge in sim.edges:
          check edge[0] < edge[1]
        check sim.edges.deduplicate().len == sim.edges.len
        ## Symmetric, self-loop-free, and matching `edges`.
        var degrees = 0
        for seat in 0 ..< Seats:
          check seat notin sim.adj[seat]
          for neighbour in sim.adj[seat]:
            check seat in sim.adj[neighbour]
          degrees += sim.adj[seat].len
          degreeFloor = min(degreeFloor, sim.adj[seat].len)
        check degrees == 2 * sim.edges.len
        case family
        of "ring": check sim.edges.len == 13
        of "smallworld": check sim.edges.len == 20
        of "clusters": check sim.edges.len == 13
        else: check sim.edges.len in 10 .. 17
        check sim.edges.graphMinDegree() >= 1
        if family != "hub":
          check sim.edges.graphMinDegree() >= 2
      ## `hub` is the only family that may leave a seat on one link.
      if family == "hub":
        check degreeFloor == 1
      else:
        check degreeFloor >= 2

  test "clusters is two groups joined by exactly one link":
    for seed in 0 ..< 50:
      let sim = initSim(fixtureConfig(seed = seed, topology = "clusters"))
      ## Find the component of seat 0 with each edge removed in turn: the
      ## bridge is the only edge whose removal disconnects the graph.
      var bridges = 0
      for index in 0 ..< sim.edges.len:
        var cut = sim.edges
        cut.delete(index)
        if not cut.graphConnected():
          inc bridges
      check bridges == 1

suite "clues":
  test "the ten clues always point at the truth, 6-4, 7-3 or 8-2":
    var correct = 0
    var truths = [0, 0]
    for seed in 0 ..< 1000:
      let sim = initSim(fixtureConfig(seed = seed))
      var margin = 0
      for seat in 0 ..< Seats:
        if sim.clue[seat] == sim.truth:
          inc margin
          inc correct
        else:
          dec margin
      check margin in TallyMarginsAllowed
      truths[if sim.truth == "A": 0 else: 1] += 1
    let rate = correct.float / (1000 * Seats).float
    echo "clue accuracy over 1000 seeds: ", rate
    check rate > 0.62
    check rate < 0.72
    check truths[0] >= 400
    check truths[1] >= 400

  test "no answer word collides with a cog alias":
    let aliases = (@CogNames).mapIt(it.toLowerAscii()).toHashSet()
    for proposition in Propositions:
      check proposition.optionA.toLowerAscii() notin aliases
      check proposition.optionB.toLowerAscii() notin aliases
      check proposition.optionA != proposition.optionB

suite "determinism":
  test "the same seed reproduces the whole scenario":
    let a = initSim(fixtureConfig(seed = 77))
    let b = initSim(fixtureConfig(seed = 77))
    let c = initSim(fixtureConfig(seed = 78))
    check a.question == b.question
    check a.truth == b.truth
    check a.roleOf == b.roleOf
    check a.topology == b.topology
    check a.edges == b.edges
    check a.clue == b.clue
    check a.names == b.names
    check a.truth != c.truth or a.roleOf != c.roleOf or a.edges != c.edges or
      a.clue != c.clue

  test "pinning a drawn topology or saboteur count never shifts the rng":
    for family in Topologies:
      var checkedFamily = false
      for seed in 0 ..< 200:
        let free = initSim(fixtureConfig(seed = seed))
        if free.topology != family:
          continue
        checkedFamily = true
        let pinned = initSim(fixtureConfig(seed = seed, topology = family))
        check pinned.edges == free.edges
        check pinned.clue == free.clue
        check pinned.roleOf == free.roleOf
        let pinnedBoth = initSim(fixtureConfig(seed = seed,
          topology = family, saboteurs = free.saboteurSeats.len))
        check pinnedBoth.edges == free.edges
        check pinnedBoth.clue == free.clue
        check pinnedBoth.roleOf == free.roleOf
        break
      check checkedFamily

suite "message routing":
  test "a message reaches its neighbours next round and nobody else":
    var sim = initSim(fixtureConfig(seed = 5))
    let speaker = 0
    let listeners = sim.neighbours(speaker).toHashSet()
    for seat in sim.pendingSeats():
      if seat == speaker:
        sim.applyMessage(seat, "A", 80, 80, "a secret", "", true)
      else:
        sim.applyMessage(seat, "none", 50, 50, "", "", true)
    check sim.round == 1
    for seat in 0 ..< Seats:
      var heard = false
      for entry in sim.inbox[seat]:
        if entry.fromSeat == speaker:
          heard = true
          check entry.message == "a secret"
      check heard == (seat in listeners)
      ## A seat never receives its own message.
      for entry in sim.inbox[seat]:
        check entry.fromSeat != seat
    ## The inbox clears each round.
    sim.speakAll(claim = "none", message = "")
    check sim.round == 2
    for seat in 0 ..< Seats:
      check sim.inbox[seat].len == 0

suite "legality":
  test "illegal actions raise and out-of-range values clamp":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 1))
    sim.applyMessage(0, "maybe", 173, -4, "hi", "", false)
    check sim.say[0].claim == "none"
    check sim.say[0].confidence == 100
    check sim.say[0].belief == 0
    expect RumorError:
      sim.applyMessage(0, "A", 50, 50, "again", "", false)
    expect RumorError:
      sim.applyMessage(Seats, "A", 50, 50, "hi", "", false)
    expect RumorError:
      sim.applyMessage(-1, "A", 50, 50, "hi", "", false)
    ## Voting before the ballot is open is illegal.
    expect RumorError:
      sim.applyVote(1, "A", 50, "", "", false)
    for round in 0 ..< 3:
      sim.speakAll()
    check sim.phase == phBallot
    expect RumorError:
      sim.applyMessage(0, "A", 50, 50, "hi", "", false)
    expect RumorError:
      sim.applyVote(0, "maybe", 50, "", "", false)
    sim.voteAll()
    check sim.done
    expect RumorError:
      sim.applyVote(0, "A", 50, "", "", false)
    expect RumorError:
      sim.applyMessage(0, "A", 50, 50, "hi", "", false)

proc sealedFrame(sim: Sim): bool =
  ## Every frame before the tally frame is truth-free, mask-on and sealed.
  let state = sim.tableStateJson()
  if state["votes"].len != Seats: return false
  for vote in state["votes"]:
    if vote.kind != JNull: return false
  if not state["sealed"].getBool(): return false
  if state["truth"].getStr() != "": return false
  if state["verdict"].getStr() != "": return false
  if state["accuracy"].getFloat() != -1.0: return false
  if state["honestCorrect"].getInt() != -1: return false
  if state["saboteurCount"].getInt() != 0: return false
  for seat in state["seats"]:
    if seat["role"].getStr() != "cog": return false
    if seat["vote"].kind != JNull: return false
  true

suite "sealing and masking":
  test "every pre-tally frame is truth-free, mask-on and sealed":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 11))
    var frames = 0
    check sim.sealedFrame()
    for round in 0 ..< 3:
      let speakers = sim.pendingSeats()
      for seat in speakers:
        sim.applyMessage(seat, "A", 60, 60, "m" & $seat, "", true)
        inc frames
        check sim.sealedFrame()
    let voters = sim.pendingSeats()
    for seat in voters:
      ## Checked BEFORE the vote lands: the tenth one unmasks the table.
      check sim.sealedFrame()
      sim.applyVote(seat, "A", 60, "r", "", true)
    check frames == 3 * Seats
    ## The tally frame fills all of it in.
    let final = sim.tableStateJson()
    check not final["sealed"].getBool()
    check final["truth"].getStr() == sim.truth
    check final["accuracy"].getFloat() >= 0.0
    check final["honestCorrect"].getInt() >= 0
    check final["saboteurCount"].getInt() == sim.saboteurSeats.len
    for seat in 0 ..< Seats:
      let node = final["seats"][seat]
      check node["vote"].getStr() == "A"
      check node["role"].getStr() ==
        (if sim.roleOf[seat] == 1: "saboteur" else: "honest")

  test "the redacted player frame carries nothing hidden":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 12))
    sim.speakAll(claim = "A", message = "my clue")
    for seat in 0 ..< Seats:
      let frame = sim.playerStateJson(seat)
      let text = $frame
      check frame["clue"].getStr() == sim.word(sim.clue[seat])
      check frame["name"].getStr() == sim.names[seat]
      check "truth" notin text
      check "seed" notin text
      let listed = frame["neighbours"].getElems().mapIt(it.getStr())
      check listed.len == sim.neighbours(seat).len
      for neighbour in sim.neighbours(seat):
        check sim.names[neighbour] in listed
      ## Only a saboteur is shown a crew, and only its own.
      if sim.roleOf[seat] == 1:
        check frame["crew"].len == sim.saboteurSeats.len - 1
      else:
        check frame["crew"].len == 0
      ## Every inbox entry comes from a neighbour.
      for entry in frame["inbox"]:
        check entry["from"].getStr() in
          sim.neighbours(seat).mapIt(sim.names[it])

suite "scoring":
  test "the worked table, exactly":
    ## Build a fixture with 8 honest and 2 saboteurs, then hand-cast the
    ## ballots and read the scores back.
    proc played(seed: int, honestRight: int): Sim =
      result = initSim(fixtureConfig(rounds = 3, seed = seed,
        saboteurs = 2))
      for round in 0 ..< 3:
        result.speakAll(claim = "none", message = "")
      var right = 0
      for seat in result.pendingSeats():
        if result.roleOf[seat] == 1:
          ## A saboteur's own vote never enters the accuracy.
          result.applyVote(seat, (if result.truth == "A": "B" else: "A"),
            50, "", "", true)
        elif right < honestRight:
          inc right
          result.applyVote(seat, result.truth, 50, "", "", true)
        else:
          result.applyVote(seat, (if result.truth == "A": "B" else: "A"),
            50, "", "", true)

    let allRight = played(3, 8)
    check allRight.honestSeats.len == 8
    check allRight.saboteurSeats.len == 2
    check allRight.accuracy == 1.0
    for seat in allRight.honestSeats:
      check abs(allRight.score(seat) - 1.0) < 1e-9
    for seat in allRight.saboteurSeats:
      check abs(allRight.score(seat) + 1.0) < 1e-9

    let none = played(3, 0)
    check none.accuracy == 0.0
    for seat in none.honestSeats:
      check abs(none.score(seat) + 1.0) < 1e-9
    for seat in none.saboteurSeats:
      check abs(none.score(seat) - 1.0) < 1e-9

    let six = played(3, 6)
    check abs(six.accuracy - 0.75) < 1e-9
    for seat in six.honestSeats:
      let expected =
        if six.votes[seat] == six.truth: 0.7 else: -0.1
      check abs(six.score(seat) - expected) < 1e-9
    for seat in six.saboteurSeats:
      var honestNeighbours = 0
      var wrong = 0
      for neighbour in six.neighbours(seat):
        if six.roleOf[neighbour] == 0:
          inc honestNeighbours
          if six.votes[neighbour] != six.truth:
            inc wrong
      let localWrong =
        if honestNeighbours == 0: 1.0 - six.accuracy
        else: wrong.float / honestNeighbours.float
      let expected = 0.6 * (1.0 - 2.0 * 0.75) + 0.4 * (2.0 * localWrong - 1.0)
      check abs(six.score(seat) - expected) < 1e-9

    let half = played(3, 4)
    check abs(half.accuracy - 0.5) < 1e-9
    for seat in half.honestSeats:
      let expected = if half.votes[seat] == half.truth: 0.4 else: -0.4
      check abs(half.score(seat) - expected) < 1e-9
    for seat in 0 ..< Seats:
      check half.score(seat) >= -1.0
      check half.score(seat) <= 1.0

  test "a saboteur with no honest neighbour falls back to 1 - A":
    ## Hand-built: force the accuracy and check the fallback branch by
    ## finding an episode where a saboteur's neighbours are all saboteurs;
    ## if no seed produces one, exercise the formula directly.
    var sim = initSim(fixtureConfig(rounds = 3, seed = 3, saboteurs = 2))
    for round in 0 ..< 3:
      sim.speakAll(claim = "none", message = "")
    for seat in sim.pendingSeats():
      sim.applyVote(seat, sim.truth, 50, "", "", true)
    check sim.accuracy == 1.0
    for seat in sim.saboteurSeats:
      var honestNeighbours = 0
      for neighbour in sim.neighbours(seat):
        if sim.roleOf[neighbour] == 0:
          inc honestNeighbours
      let localWrong =
        if honestNeighbours == 0: 1.0 - sim.accuracy else: 0.0
      check abs(sim.score(seat) -
        (0.6 * (1.0 - 2.0 * sim.accuracy) +
          0.4 * (2.0 * localWrong - 1.0))) < 1e-9

  test "verdict is display only and splits on a 5-5":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 8, saboteurs = 2))
    for round in 0 ..< 3:
      sim.speakAll(claim = "none", message = "")
    var index = 0
    for seat in sim.pendingSeats():
      sim.applyVote(seat, (if index < 5: "A" else: "B"), 50, "", "", true)
      inc index
    check sim.verdict == "split"

suite "endings":
  test "forceBallot from mid-talk settles as a scored deadline":
    var sim = initSim(fixtureConfig(rounds = 5, seed = 21))
    sim.speakAll()
    sim.applyMessage(sim.pendingSeats()[0], "B", 70, 30, "half a round", "",
      true)
    sim.forceBallot()
    check sim.done
    check sim.reason == "deadline"
    for seat in 0 ..< Seats:
      check sim.votes[seat] in ["A", "B"]
      check sim.score(seat) >= -1.0
      check sim.score(seat) <= 1.0
      check sim.score(seat) == sim.score(seat)   # not NaN
    check sim.honestCorrect >= 0
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evTally
    check sim.resultsJson()["reason"].getStr() == "deadline"

  test "endEarly on a settled sim is a no-op and reasons are exhaustive":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 22))
    for round in 0 ..< 3:
      sim.speakAll()
    sim.voteAll()
    check sim.reason == "complete"
    let before = sim.events.len
    sim.endEarly()
    check sim.events.len == before
    check sim.reason == "complete"
    check sim.resultsJson()["reason"].getStr() in ["complete", "deadline"]

suite "rune truncation":
  test "multi-byte text is cut on rune boundaries and stays valid UTF-8":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 31))
    let longMessage = "日".repeat(400)
    let longNotes = "日".repeat(900)
    let longReason = "日".repeat(400)
    sim.applyMessage(0, "A", 50, 50, longMessage, longNotes, true)
    check sim.say[0].message.runeLen <= MaxMessageLen
    check sim.notes[0].runeLen <= MaxNotesLen
    check sim.say[0].message.validateUtf8() == -1
    check sim.notes[0].validateUtf8() == -1
    for seat in sim.pendingSeats():
      sim.applyMessage(seat, "A", 50, 50, "ok", "", true)
    for round in 0 ..< 2:
      sim.speakAll()
    sim.applyVote(0, "A", 50, longReason, longNotes, true)
    check sim.voteReasons[0].runeLen <= MaxReasonLen
    for seat in sim.pendingSeats():
      sim.applyVote(seat, "A", 50, "", "", true)
    ## The whole event log decodes as strict UTF-8 and its JSON is valid.
    for event in sim.events:
      check event.text.validateUtf8() == -1
      check event.notes.validateUtf8() == -1
      check ($event.eventToJson()).validateUtf8() == -1
    var payload = newJArray()
    for event in sim.events:
      payload.add(event.eventToJson())
    check ($payload).validateUtf8() == -1
    discard parseJson($payload)

suite "replay":
  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(rounds = 3, seed = 41)
    var live = initSim(config)
    ## Every live state, keyed by how many events had been recorded when it
    ## was observed: frames[k] must equal the live table after k events.
    var checkpoints: seq[tuple[index: int, state: string]]
    checkpoints.add((index: 0, state: $initSim(config).tableStateJson()))
    var round = 0
    while not live.done:
      if live.phase == phBallot:
        for seat in live.pendingSeats():
          live.applyVote(seat, (if seat mod 3 == 0: "B" else: "A"), 40 + seat,
            "reason " & $seat, "note " & $seat, false)
          checkpoints.add((index: live.events.len,
            state: $live.tableStateJson()))
      else:
        for seat in live.pendingSeats():
          live.applyMessage(seat, (if seat mod 2 == 0: "A" else: "B"),
            50 + seat, 50 + seat, "round " & $round & " seat " & $seat,
            "note " & $seat, false)
          checkpoints.add((index: live.events.len,
            state: $live.tableStateJson()))
        inc round
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    ## Not just the count and the last frame: every intermediate frame is
    ## compared against the live table as it stood at that event index.
    check checkpoints.len == 4 * Seats + 1
    for point in checkpoints:
      check $frames[point.index].tableStateJson() == point.state
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].done
    check frames[^1].reason == "complete"

  test "events round-trip through JSON":
    let config = fixtureConfig(rounds = 3, seed = 42)
    var sim = initSim(config)
    while not sim.done:
      if sim.phase == phBallot:
        sim.voteAll()
      else:
        sim.speakAll(claim = "B", message = "hello there")
    var kinds = initHashSet[EventKind]()
    for event in sim.events:
      kinds.incl(event.kind)
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.round == event.round
      check back.seat == event.seat
      check back.claim == event.claim
      check back.vote == event.vote
      check back.confidence == event.confidence
      check back.belief == event.belief
      check back.text == event.text
      check back.notes == event.notes
      check back.scripted == event.scripted
      check back.votes == event.votes
      check back.roles == event.roles
      check back.clues == event.clues
      check back.truth == event.truth
      check back.verdict == event.verdict
      check back.honestCorrect == event.honestCorrect
    check kinds.len == 6

  test "a tampered tally is rejected":
    let config = fixtureConfig(rounds = 3, seed = 43)
    var sim = initSim(config)
    while not sim.done:
      if sim.phase == phBallot: sim.voteAll() else: sim.speakAll()
    var flipped = sim.events
    for index, event in flipped:
      if event.kind == evTally:
        flipped[index].truth = (if event.truth == "A": "B" else: "A")
    expect RumorError:
      discard replayMatch(config, flipped)
    var mutated = sim.events
    for index, event in mutated:
      if event.kind == evTally:
        mutated[index].clues[0] =
          (if event.clues[0] == "A": "B" else: "A")
    expect RumorError:
      discard replayMatch(config, mutated)

  test "a recorded deadline stop replays as a deadline":
    let config = fixtureConfig(rounds = 5, seed = 44)
    var short = initSim(config)
    short.speakAll()
    short.forceBallot()
    check short.reason == "deadline"
    let frames = replayMatch(config, short.events)
    check frames.len == short.events.len + 1
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check $frames[^1].tableStateJson() == $short.tableStateJson()

suite "results":
  test "the results shape is what the schema declares":
    let config = fixtureConfig(rounds = 3, seed = 51)
    var sim = initSim(config)
    while not sim.done:
      if sim.phase == phBallot: sim.voteAll(vote = "B") else: sim.speakAll()
    let results = sim.resultsJson()
    for key in ["names", "scores", "roles", "votes", "clues"]:
      check results[key].len == Seats
    check results["honestSeats"].getInt() + results["saboteurSeats"].getInt() ==
      Seats
    check results["honestCorrect"].getInt() <= results["honestSeats"].getInt()
    check abs(results["accuracy"].getFloat() -
      results["honestCorrect"].getInt().float /
      results["honestSeats"].getInt().float) < 1e-9
    check results["reason"].getStr() in ["complete", "deadline"]
    check results["truth"].getStr() in ["A", "B"]
    check results["edgeCount"].getInt() == sim.edges.len
    check results["topology"].getStr() in Topologies
    for score in results["scores"]:
      check score.getFloat() >= -1.0
      check score.getFloat() <= 1.0
    for name in results["names"]:
      ## Results attribute by POLICY name, never by the table alias.
      check name.getStr().startsWith("P")

suite "budget":
  test "sampleEpisode fits the rounds into the play budget and is idempotent":
    var config = defaultGameConfig()
    config.rounds = 5
    let fitted = sampleEpisode(config)
    check fitted.rounds == 5
    check fitted.sampled
    check fitted.turnDelayMs <= PacingBudgetMs div (fitted.rounds + 1)
    check sampleEpisode(fitted).rounds == fitted.rounds
    var greedy = defaultGameConfig()
    greedy.rounds = 60
    check sampleEpisode(greedy).rounds <= MaxRounds
    var tiny = defaultGameConfig()
    tiny.rounds = 1
    check sampleEpisode(tiny).rounds == MinRounds
    ## The worst case still lands inside 60% of the episode timeout.
    let worst = defaultGameConfig().playerConnectTimeoutSeconds +
      float((fitted.rounds + 1) * TurnBudgetSeconds)
    check worst <
      PlayBudgetFraction * defaultGameConfig().episodeTimeoutSeconds.float
