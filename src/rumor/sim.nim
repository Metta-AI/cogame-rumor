## Pure game rules for Rumor. No IO, no networking, no LLM — the server,
## the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the hidden proposition and its truth, the
## seeded social graph, each seat's private clue and role, the live round's
## messages, the sealed ballot, and the append-only event log. Everything
## random is drawn once at `initSim` from a single rng stream in a fixed
## order, so a replay re-derives the whole scenario from the seed alone.

import std/[algorithm, json, math, random, sequtils, strutils, unicode], types

export types

const
  Seats* = 10
  MinRounds* = 3
  MaxRounds* = 6
  SignalReliabilityPercent* = 60
  TallyMarginsAllowed* = [2, 4, 6]
  ClueDrawAttempts* = 200
  MinSaboteurs* = 2
  MaxSaboteurs* = 3
  ## Hard wall-clock ceiling for one turn (rate-governor spacing + batch +
  ## an optional retry). Six turns of it fit inside the play budget.
  TurnBudgetSeconds* = 80
  ## The Bedrock sidecar caps an episode at 30 requests/minute; ten seats
  ## per batch at this spacing is 23/minute.
  MinBatchSpacingSeconds* = 26
  ## Share of the platform's episode timeout spent playing.
  PlayBudgetFraction* = 0.6
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 20_000
  MaxMessageLen* = 240
  MaxReasonLen* = 200
  MaxNotesLen* = 600
  RoleNames* = ["Honest", "Saboteur"]
  Topologies* = ["ring", "smallworld", "clusters", "hub"]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## Eight hidden facts, each a question and two mutually exclusive
  ## one-word answers. Every answer word is disjoint from CogNames so the
  ## viewer's alias -> policy-name rewriter can never rewrite an answer.
  Propositions*: array[8, tuple[question, optionA, optionB: string]] = [
    ("The relay tower on Ash Hill is…", "BROKEN", "SOUND"),
    ("The night shipment was…", "STOLEN", "DELAYED"),
    ("The east gate was left…", "OPEN", "BARRED"),
    ("The foreman's ledger is…", "FORGED", "GENUINE"),
    ("The water in the cistern is…", "FOULED", "CLEAN"),
    ("The signal fire on the ridge was…", "LIT", "DARK"),
    ("The mine's lower gallery is…", "FLOODED", "DRY"),
    ("The courier who left at dawn was…", "FOLLOWED", "ALONE")
  ]
  ## ln(0.6/0.4): the weight of a seat's own 60%-reliable clue.
  ClueLogOdds* = 0.4054651081081644
  ## ln(0.56/0.44): the weight of one neighbour's first claim, once about a
  ## quarter of neighbours are saboteurs.
  ClaimLogOdds* = 0.2411620568168881

type
  Phase* = enum
    phTalk = "talk"
    phBallot = "ballot"
    phTally = "tally"
    phDone = "done"

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## anonymous cog aliases per seat
    roleOf*: array[Seats, int]       ## 0 honest | 1 saboteur
    saboteurSeats*: seq[int]
    honestSeats*: seq[int]
    topology*: string                ## the RESOLVED family
    edges*: seq[(int, int)]          ## seat pairs, ascending, deduped
    adj*: array[Seats, seq[int]]     ## neighbour seats, ascending
    question*, optionA*, optionB*: string
    truth*: string                   ## "A" | "B" — HIDDEN until phTally
    clue*: array[Seats, string]      ## "A" | "B"
    say*: array[Seats, SeatRecord]   ## this round
    inbox*: array[Seats, seq[Inbox]] ## last round's messages, neighbours only
    history*: seq[array[Seats, SeatRecord]] ## one entry per resolved round
    notes*: seq[string]              ## latest private notes per seat
    votes*: array[Seats, string]     ## "" until cast; SEALED until phTally
    voteReasons*: array[Seats, string]
    ballotBelief*: array[Seats, int] ## belief at the ballot; shown at the tally
    acted*: array[Seats, bool]       ## this turn
    scriptedSeat*: array[Seats, bool] ## last action came from a baseline
    round*, roundsPlayed*: int
    phase*: Phase
    accuracy*: float                 ## -1.0 until the tally
    honestCorrect*: int              ## -1 until the tally
    verdict*: string                 ## "A" | "B" | "split"; display only
    deadlineStop*: bool              ## the ballot was forced by the clock
    done*: bool
    reason*: string                  ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the talk-round count into the episode's play budget. Idempotent:
  ## a config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  let budget = PlayBudgetFraction * result.episodeTimeoutSeconds.float -
    result.playerConnectTimeoutSeconds
  let maxTurns = int(budget / TurnBudgetSeconds.float)
  let cap = max(MinRounds, min(MaxRounds, maxTurns - 1))
  result.rounds = max(MinRounds, min(config.rounds, cap))
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div (result.rounds + 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, seat: -1, confidence: -1, belief: -1,
    accuracy: -1.0, honestCorrect: -1)

proc other(option: string): string =
  if option == "A": "B" else: "A"

proc hasEdge(edges: seq[(int, int)], a, b: int): bool =
  let pair = (min(a, b), max(a, b))
  pair in edges

proc addEdge(edges: var seq[(int, int)], a, b: int): bool {.discardable.} =
  if a == b or edges.hasEdge(a, b):
    return false
  edges.add((min(a, b), max(a, b)))
  true

proc adjacency(edges: seq[(int, int)]): array[Seats, seq[int]] =
  for edge in edges:
    result[edge[0]].add(edge[1])
    result[edge[1]].add(edge[0])
  for seat in 0 ..< Seats:
    result[seat].sort()

proc graphConnected*(edges: seq[(int, int)]): bool =
  let adj = adjacency(edges)
  var seen: array[Seats, bool]
  var queue = @[0]
  seen[0] = true
  var reached = 1
  while queue.len > 0:
    let node = queue.pop()
    for next in adj[node]:
      if not seen[next]:
        seen[next] = true
        inc reached
        queue.add(next)
  reached == Seats

proc graphMinDegree*(edges: seq[(int, int)]): int =
  let adj = adjacency(edges)
  result = Seats
  for seat in 0 ..< Seats:
    result = min(result, adj[seat].len)

proc buildRing(rng: var Rand, order: seq[int]): seq[(int, int)] =
  for index in 0 ..< Seats:
    result.addEdge(order[index], order[(index + 1) mod Seats])
  var added = 0
  var attempts = 0
  while added < 3 and attempts < 200:
    inc attempts
    let a = order[rng.rand(Seats - 1)]
    let b = order[rng.rand(Seats - 1)]
    if result.addEdge(a, b):
      inc added

proc buildSmallworld(rng: var Rand, order: seq[int]): seq[(int, int)] =
  for index in 0 ..< Seats:
    result.addEdge(order[index], order[(index + 1) mod Seats])
    result.addEdge(order[index], order[(index + 2) mod Seats])
  for rewire in 0 ..< 2:
    var attempts = 0
    while attempts < 50:
      inc attempts
      let dropAt = rng.rand(result.high)
      var probe = result
      probe.delete(dropAt)
      let a = order[rng.rand(Seats - 1)]
      let b = order[rng.rand(Seats - 1)]
      if not probe.addEdge(a, b):
        continue
      if probe.graphConnected():
        result = probe
        break
      # A rewire that cuts the graph is rejected and redrawn; when the
      # attempts run out the dropped edge simply stays where it was.
      discard

proc buildClusters(rng: var Rand, order: seq[int]): seq[(int, int)] =
  for group in 0 ..< 2:
    let g = order[group * 5 ..< group * 5 + 5]
    for index in 0 ..< 5:
      result.addEdge(g[index], g[(index + 1) mod 5])
    result.addEdge(g[0], g[2])
  let left = order[rng.rand(4)]
  let right = order[5 + rng.rand(4)]
  discard result.addEdge(left, right)

proc buildHub(rng: var Rand, order: seq[int]): seq[(int, int)] =
  let hubs = order[0 ..< 3]
  result.addEdge(hubs[0], hubs[1])
  result.addEdge(hubs[1], hubs[2])
  result.addEdge(hubs[0], hubs[2])
  for index in 3 ..< Seats:
    let node = order[index]
    let links = 1 + rng.rand(1)
    var joined = 0
    var attempts = 0
    while joined < links and attempts < 20:
      inc attempts
      if result.addEdge(node, hubs[rng.rand(2)]):
        inc joined
    if joined == 0:
      result.addEdge(node, hubs[0])

proc buildEdges(rng: var Rand, family: string, order: seq[int]):
    seq[(int, int)] =
  ## Builds the family's graph, redrawing its random parts until the result
  ## is connected with no isolated seat. Falls back to a plain ring.
  for attempt in 0 ..< 100:
    result =
      case family
      of "smallworld": buildSmallworld(rng, order)
      of "clusters": buildClusters(rng, order)
      of "hub": buildHub(rng, order)
      else: buildRing(rng, order)
    if result.graphConnected() and result.graphMinDegree() >= 1:
      result.sort()
      return
  result = @[]
  for index in 0 ..< Seats:
    result.addEdge(order[index], order[(index + 1) mod Seats])
  result.sort()

proc drawClues(rng: var Rand, truth: string): array[Seats, string] =
  ## i.i.d. 60%-reliable clues, redrawn until the ten together split
  ## 6-4, 7-3 or 8-2 in favour of the truth: the one public rule that makes
  ## perfect aggregation always right.
  for attempt in 0 ..< ClueDrawAttempts:
    var margin = 0
    for seat in 0 ..< Seats:
      if rng.rand(99) < SignalReliabilityPercent:
        result[seat] = truth
        inc margin
      else:
        result[seat] = other(truth)
        dec margin
    if margin in TallyMarginsAllowed:
      return
  ## Unreachable in practice (measured mean 1.70 attempts, max 14).
  var order = toSeq(0 ..< Seats)
  rng.shuffle(order)
  for index, seat in order:
    result[seat] = if index < 6: truth else: other(truth)

proc clearSay(sim: var Sim) =
  for seat in 0 ..< Seats:
    sim.say[seat] = SeatRecord(claim: "none", confidence: 50, belief: 50,
      message: "")
    sim.acted[seat] = false

proc speaks(record: SeatRecord): bool =
  record.message.len > 0 or record.claim != "none"

proc deliverInboxes(sim: var Sim) =
  ## Last round's messages travel one hop along the graph, and no further.
  var next: array[Seats, seq[Inbox]]
  for speaker in 0 ..< Seats:
    let record = sim.say[speaker]
    if not record.speaks():
      continue
    for listener in sim.adj[speaker]:
      next[listener].add(Inbox(fromSeat: speaker, claim: record.claim,
        confidence: record.confidence, message: record.message))
  sim.inbox = next

proc openRound(sim: var Sim) =
  sim.deliverInboxes()
  sim.clearSay()
  sim.phase = phTalk
  var event = blankEvent(evRound)
  event.round = sim.round
  if sim.round == sim.config.rounds - 1:
    event.text = "final round"
  sim.addEvent(event)

proc openBallot(sim: var Sim) =
  sim.deliverInboxes()
  sim.clearSay()
  sim.phase = phBallot
  var event = blankEvent(evRound)
  event.round = sim.config.rounds
  event.text = "sealed vote"
  sim.addEvent(event)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(RumorError,
      "rumor needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(RumorError,
      "rounds must be at least " & $MinRounds)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides, in this fixed order:
  ## proposition, truth, saboteur count, roles, topology, node order,
  ## edges, clues. Pinned config values override a draw AFTER it happens,
  ## so pinning can never shift the stream.
  var rng = initRand(int64(config.seed) * 7919 + 17)

  let proposition = Propositions[rng.rand(Propositions.high)]
  result.question = proposition.question
  result.optionA = proposition.optionA
  result.optionB = proposition.optionB

  result.truth = if rng.rand(1) == 0: "A" else: "B"

  var saboteurs = MinSaboteurs + rng.rand(MaxSaboteurs - MinSaboteurs)
  if config.saboteurs in [MinSaboteurs, MaxSaboteurs]:
    saboteurs = config.saboteurs

  var roleOrder = toSeq(0 ..< Seats)
  rng.shuffle(roleOrder)
  for index, seat in roleOrder:
    if index < saboteurs:
      result.roleOf[seat] = 1
    else:
      result.roleOf[seat] = 0
  for seat in 0 ..< Seats:
    if result.roleOf[seat] == 1:
      result.saboteurSeats.add(seat)
    else:
      result.honestSeats.add(seat)

  var family = Topologies[rng.rand(Topologies.high)]
  if config.topology in Topologies:
    family = config.topology
  result.topology = family

  var order = toSeq(0 ..< Seats)
  rng.shuffle(order)
  result.edges = buildEdges(rng, family, order)
  result.adj = adjacency(result.edges)

  result.clue = drawClues(rng, result.truth)

  result.notes = newSeq[string](Seats)
  result.accuracy = -1.0
  result.honestCorrect = -1
  result.round = 0
  result.clearSay()
  result.addEvent(blankEvent(evStart))
  result.openRound()

# ---- Queries ----------------------------------------------------------------

proc roleName*(sim: Sim, seat: int): string =
  RoleNames[sim.roleOf[seat]]

proc neighbours*(sim: Sim, seat: int): seq[int] =
  sim.adj[seat]

proc pendingSeats*(sim: Sim): seq[int] =
  ## Every seat acts every turn: decisions are simultaneous.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    case sim.phase
    of phTalk:
      if not sim.acted[seat]:
        result.add(seat)
    of phBallot:
      if sim.votes[seat].len == 0:
        result.add(seat)
    else:
      discard

proc word*(sim: Sim, option: string): string =
  ## Everything a spectator or a seat reads is the answer WORD, never "A".
  case option
  of "A": sim.optionA
  of "B": sim.optionB
  else: "no answer"

proc score*(sim: Sim, seat: int): float =
  ## Higher is better for both roles, and both ranges are [-1, +1] because
  ## the same policy plays honest in one episode and saboteur in the next.
  if sim.honestCorrect < 0:
    return 0.0
  let accuracy = sim.accuracy
  if sim.roleOf[seat] == 0:
    result = 0.6 * (2.0 * accuracy - 1.0) +
      0.4 * (if sim.votes[seat] == sim.truth: 1.0 else: -1.0)
  else:
    var honestNeighbours = 0
    var wrong = 0
    for neighbour in sim.adj[seat]:
      if sim.roleOf[neighbour] == 0:
        inc honestNeighbours
        if sim.votes[neighbour] != sim.truth:
          inc wrong
    let localWrong =
      if honestNeighbours == 0: 1.0 - accuracy
      else: wrong.float / honestNeighbours.float
    result = 0.6 * (1.0 - 2.0 * accuracy) + 0.4 * (2.0 * localWrong - 1.0)

# ---- The gossip baseline's arithmetic (pure, shared with llm.nim) -----------

proc firstClaims*(sim: Sim, seat: int): seq[tuple[source: int, claim: string]] =
  ## Each NEIGHBOUR's first non-`none` claim, in neighbour order. Later
  ## repeats are ignored: an echo is not new evidence, and counting echoes
  ## is how a small lie becomes a landslide.
  for neighbour in sim.adj[seat]:
    for record in sim.history:
      if record[neighbour].claim != "none":
        result.add((source: neighbour, claim: record[neighbour].claim))
        break

proc gossipLogOdds*(sim: Sim, seat: int): float =
  ## Log-odds for option A: the seat's own clue plus one vote per
  ## neighbour, counted once ever.
  result = if sim.clue[seat] == "A": ClueLogOdds else: -ClueLogOdds
  for entry in sim.firstClaims(seat):
    result += (if entry.claim == "A": ClaimLogOdds else: -ClaimLogOdds)

proc logistic(value: float): int =
  int(round(100.0 / (1.0 + exp(-value))))

proc gossipClaim*(sim: Sim, seat: int): string =
  ## The honest gossip verdict; a tie falls back to the seat's own clue.
  let odds = sim.gossipLogOdds(seat)
  if odds > 0.0: "A"
  elif odds < 0.0: "B"
  else: sim.clue[seat]

proc gossipBelief*(sim: Sim, seat: int): int =
  clamp(logistic(sim.gossipLogOdds(seat)), 0, 100)

proc gossipConfidence*(sim: Sim, seat: int): int =
  clamp(logistic(abs(sim.gossipLogOdds(seat))), 0, 100)

proc herdClaim*(sim: Sim, seat: int): string =
  ## The majority of what the seat heard LAST round; ties (and round 0)
  ## fall back to its own clue.
  var forA = 0
  var forB = 0
  for entry in sim.inbox[seat]:
    if entry.claim == "A": inc forA
    elif entry.claim == "B": inc forB
  if forA > forB: "A"
  elif forB > forA: "B"
  else: sim.clue[seat]

# ---- Play -------------------------------------------------------------------

proc trimRunes(text: string, limit: int): string =
  ## Cut on a RUNE boundary: a byte slice through a multi-byte character
  ## would leave invalid UTF-8 in the replay and break its JSON.
  result = text.strip()
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit)

proc oneLine(text: string): string =
  text.replace("\r\n", " ").replace('\n', ' ').replace('\r', ' ')
    .replace('\t', ' ')

proc settle(sim: var Sim) =
  sim.done = true
  sim.reason = if sim.deadlineStop: "deadline" else: "complete"
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.text = sim.reason
  sim.addEvent(event)

proc resolveBallot(sim: var Sim) =
  ## The tenth vote lands: count, score, and take the masks off. This is
  ## the first moment `truth` or any role appears in an event or a frame.
  var correct = 0
  for seat in sim.honestSeats:
    if sim.votes[seat] == sim.truth:
      inc correct
  sim.honestCorrect = correct
  sim.accuracy =
    if sim.honestSeats.len == 0: 0.0
    else: correct.float / sim.honestSeats.len.float
  var forA = 0
  var forB = 0
  for seat in 0 ..< Seats:
    if sim.votes[seat] == "A": inc forA
    elif sim.votes[seat] == "B": inc forB
  sim.verdict =
    if forA > forB: "A"
    elif forB > forA: "B"
    else: "split"
  sim.phase = phTally

  var saboteurNames: seq[string]
  for seat in sim.saboteurSeats:
    saboteurNames.add(sim.names[seat])
  var event = blankEvent(evTally)
  event.round = sim.config.rounds
  event.truth = sim.truth
  event.accuracy = sim.accuracy
  event.honestCorrect = correct
  event.verdict = sim.verdict
  for seat in 0 ..< Seats:
    event.votes.add(sim.votes[seat])
    event.roles.add(sim.roleOf[seat])
    event.clues.add(sim.clue[seat])
  event.text = sim.question & " " & sim.word(sim.truth) & ". " &
    saboteurNames.join(" and ") &
    (if saboteurNames.len == 1: " was the saboteur. "
     else: " were the saboteurs. ") &
    "Honest cogs: " & $correct & " of " & $sim.honestSeats.len & " right."
  sim.addEvent(event)
  sim.settle()

proc resolveTalkRound(sim: var Sim) =
  sim.history.add(sim.say)
  inc sim.roundsPlayed
  inc sim.round
  if sim.round < sim.config.rounds:
    sim.openRound()
  else:
    sim.openBallot()

proc applyMessage*(sim: var Sim, seat: int, claim: string,
    confidence, belief: int, message, notes: string, scripted: bool) =
  ## `seat` speaks in the live talk round. Raises RumorError on anything
  ## illegal; the server falls back to the scripted baseline on rejection.
  ## The tenth message resolves the round.
  if sim.done:
    raise newException(RumorError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(RumorError, "bad seat: " & $seat)
  if sim.phase != phTalk:
    raise newException(RumorError, "not a talk round")
  if sim.acted[seat]:
    raise newException(RumorError,
      sim.names[seat] & " has already spoken this round")
  let normalised = if claim == "A" or claim == "B": claim else: "none"
  let text = trimRunes(oneLine(message), MaxMessageLen)
  sim.say[seat] = SeatRecord(
    claim: normalised,
    confidence: clamp(confidence, 0, 100),
    belief: clamp(belief, 0, 100),
    message: text
  )
  sim.acted[seat] = true
  sim.scriptedSeat[seat] = scripted
  if notes.len > 0:
    sim.notes[seat] = trimRunes(notes, MaxNotesLen)
  var event = blankEvent(evSay)
  event.round = sim.round
  event.seat = seat
  event.claim = normalised
  event.confidence = sim.say[seat].confidence
  event.belief = sim.say[seat].belief
  event.text = text
  event.notes = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.resolveTalkRound()

proc applyVote*(sim: var Sim, seat: int, vote: string, belief: int,
    reason, notes: string, scripted: bool) =
  ## `seat` casts its sealed ballot. The tenth vote unmasks the table.
  if sim.done:
    raise newException(RumorError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(RumorError, "bad seat: " & $seat)
  if sim.phase != phBallot:
    raise newException(RumorError, "the ballot is not open")
  if sim.votes[seat].len > 0:
    raise newException(RumorError, sim.names[seat] & " has already voted")
  if vote != "A" and vote != "B":
    raise newException(RumorError, "a vote is A or B: " & vote)
  sim.votes[seat] = vote
  sim.voteReasons[seat] = trimRunes(oneLine(reason), MaxReasonLen)
  sim.ballotBelief[seat] = clamp(belief, 0, 100)
  sim.scriptedSeat[seat] = scripted
  if notes.len > 0:
    sim.notes[seat] = trimRunes(notes, MaxNotesLen)
  var event = blankEvent(evVote)
  event.round = sim.config.rounds
  event.seat = seat
  event.vote = vote
  event.belief = sim.ballotBelief[seat]
  event.text = sim.voteReasons[seat]
  event.notes = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.resolveBallot()

proc gossipVoteFor(sim: Sim, seat: int): tuple[vote: string, belief: int] =
  ## The universal fallback ballot: the gossip baseline's verdict, mirrored
  ## for a saboteur.
  if sim.roleOf[seat] == 0:
    (vote: sim.gossipClaim(seat), belief: sim.gossipBelief(seat))
  else:
    (vote: other(sim.clue[seat]), belief: sim.gossipBelief(seat))

proc forceBallot*(sim: var Sim) =
  ## The play deadline hit before the ballot resolved. Seats that already
  ## voted keep their votes; every other seat is given the scripted gossip
  ## vote, and the tally, reveal and scores are produced normally. A short
  ## honest episode always beats a long one that never lands.
  if sim.done:
    return
  sim.deadlineStop = true
  if sim.phase == phTalk:
    sim.history.add(sim.say)
    sim.openBallot()
  for seat in 0 ..< Seats:
    if sim.votes[seat].len == 0:
      let fallback = sim.gossipVoteFor(seat)
      sim.applyVote(seat, fallback.vote, fallback.belief,
        "the vote was called early", "", true)

proc endEarly*(sim: var Sim) =
  ## Stop now: settle the ballot from wherever play has reached.
  if sim.done:
    return
  sim.forceBallot()

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var roles = newJArray()
  var votes = newJArray()
  var clues = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    roles.add(%sim.roleName(seat))
    votes.add(%sim.votes[seat])
    clues.add(%sim.clue[seat])
  %*{
    "names": names,
    "scores": scores,
    "roles": roles,
    "votes": votes,
    "clues": clues,
    "truth": sim.truth,
    "question": sim.question,
    "optionA": sim.optionA,
    "optionB": sim.optionB,
    "verdict": sim.verdict,
    "accuracy": max(sim.accuracy, 0.0),
    "honestCorrect": max(sim.honestCorrect, 0),
    "honestSeats": sim.honestSeats.len,
    "saboteurSeats": sim.saboteurSeats.len,
    "topology": sim.topology,
    "edgeCount": sim.edges.len,
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc unmasked*(sim: Sim): bool =
  sim.phase == phTally or sim.done

proc beliefSeries(sim: Sim, seat: int): JsonNode =
  result = newJArray()
  for record in sim.history:
    result.add(%record[seat].belief)
  if sim.unmasked():
    result.add(%sim.ballotBelief[seat])

proc tableStateJson*(sim: Sim): JsonNode =
  let pending = sim.pendingSeats()
  let reveal = sim.unmasked()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    var neighbourList = newJArray()
    for neighbour in sim.adj[seat]:
      neighbourList.add(%neighbour)
    let record = sim.say[seat]
    let shownBelief =
      if reveal: sim.ballotBelief[seat]
      elif sim.acted[seat]: record.belief
      elif sim.history.len > 0: sim.history[^1][seat].belief
      else: 50
    ## Masks stay on until the tally: every pre-tally frame says "cog".
    var roleLabel = "cog"
    if reveal:
      roleLabel = if sim.roleOf[seat] == 1: "saboteur" else: "honest"
    var voteNode = newJNull()
    if reveal and sim.votes[seat].len > 0:
      voteNode = %sim.votes[seat]
    let voteReason = if reveal: sim.voteReasons[seat] else: ""
    let shownScore = if reveal: sim.score(seat) else: 0.0
    seats.add(%*{
      "name": sim.names[seat],
      "seat": seat,
      "degree": sim.adj[seat].len,
      "neighbours": neighbourList,
      "clue": sim.clue[seat],
      "claim": record.claim,
      "confidence": record.confidence,
      "belief": shownBelief,
      "message": record.message,
      "role": roleLabel,
      "vote": voteNode,
      "voteReason": voteReason,
      "notes": sim.notes[seat],
      "score": shownScore,
      "pending": (seat in pending),
      "scripted": sim.scriptedSeat[seat]
    })
  var edges = newJArray()
  for edge in sim.edges:
    edges.add(%[edge[0], edge[1]])
  var pulses = newJArray()
  for speaker in 0 ..< Seats:
    if not sim.say[speaker].speaks():
      continue
    for listener in sim.adj[speaker]:
      pulses.add(%*{
        "from": speaker,
        "to": listener,
        "claim": sim.say[speaker].claim,
        "confidence": sim.say[speaker].confidence
      })
  var beliefs = newJArray()
  for seat in 0 ..< Seats:
    beliefs.add(sim.beliefSeries(seat))
  var votes = newJArray()
  for seat in 0 ..< Seats:
    if reveal and sim.votes[seat].len > 0:
      votes.add(%sim.votes[seat])
    else:
      votes.add(newJNull())
  %*{
    "question": sim.question,
    "optionA": sim.optionA,
    "optionB": sim.optionB,
    "topology": sim.topology,
    "edgeCount": sim.edges.len,
    "edges": edges,
    "seats": seats,
    "round": sim.round,
    "rounds": sim.config.rounds,
    "roundsPlayed": sim.roundsPlayed,
    "phase": $sim.phase,
    "pulses": pulses,
    "beliefs": beliefs,
    "votes": votes,
    "sealed": not reveal,
    "truth": (if reveal: sim.truth else: ""),
    "verdict": (if reveal: sim.verdict else: ""),
    "accuracy": (if reveal: sim.accuracy else: -1.0),
    "honestCorrect": (if reveal: sim.honestCorrect else: -1),
    "saboteurCount": (if reveal: sim.saboteurSeats.len else: 0),
    "gameDone": sim.done,
    "reason": sim.reason
  }

proc playerStateJson*(sim: Sim, slot: int): JsonNode =
  ## The redacted per-seat frame: its own alias, role and clue, its
  ## neighbourhood, its inbox, its own history, its notes — and nothing
  ## else. Decisions are server-side, so the redaction loses nothing.
  var neighbourNames = newJArray()
  for neighbour in sim.adj[slot]:
    neighbourNames.add(%sim.names[neighbour])
  var inbox = newJArray()
  for entry in sim.inbox[slot]:
    inbox.add(%*{
      "from": sim.names[entry.fromSeat],
      "claim": entry.claim,
      "confidence": entry.confidence,
      "message": entry.message
    })
  var sent = newJArray()
  for index, record in sim.history:
    sent.add(%*{
      "round": index,
      "claim": record[slot].claim,
      "confidence": record[slot].confidence,
      "message": record[slot].message
    })
  var crew = newJArray()
  if sim.roleOf[slot] == 1:
    for seat in sim.saboteurSeats:
      if seat != slot:
        crew.add(%sim.names[seat])
  %*{
    "type": "state",
    "slot": slot,
    "name": sim.names[slot],
    "role": sim.roleName(slot),
    "clue": sim.word(sim.clue[slot]),
    "question": sim.question,
    "optionA": sim.optionA,
    "optionB": sim.optionB,
    "neighbours": neighbourNames,
    "degree": sim.adj[slot].len,
    "edgeCount": sim.edges.len,
    "inbox": inbox,
    "sent": sent,
    "crew": crew,
    "notes": sim.notes[slot],
    "round": sim.round,
    "rounds": sim.config.rounds,
    "phase": $sim.phase,
    "done": sim.done,
    "reason": sim.reason
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart, evRound, evEnd:
    discard
  of evSay:
    result["seat"] = %event.seat
    result["claim"] = %event.claim
    result["confidence"] = %event.confidence
    result["belief"] = %event.belief
    result["scripted"] = %event.scripted
  of evVote:
    result["seat"] = %event.seat
    result["vote"] = %event.vote
    result["belief"] = %event.belief
    result["scripted"] = %event.scripted
  of evTally:
    result["votes"] = %event.votes
    result["roles"] = %event.roles
    result["clues"] = %event.clues
    result["truth"] = %event.truth
    result["accuracy"] = %event.accuracy
    result["honestCorrect"] = %event.honestCorrect
    result["verdict"] = %event.verdict
  if event.text.len > 0:
    result["text"] = %event.text
  if event.notes.len > 0:
    result["notes"] = %event.notes

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    claim: node{"claim"}.getStr(""),
    vote: node{"vote"}.getStr(""),
    confidence: node{"confidence"}.getInt(-1),
    belief: node{"belief"}.getInt(-1),
    text: node{"text"}.getStr(""),
    notes: node{"notes"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    truth: node{"truth"}.getStr(""),
    accuracy: node{"accuracy"}.getFloat(-1.0),
    honestCorrect: node{"honestCorrect"}.getInt(-1),
    verdict: node{"verdict"}.getStr("")
  )
  if node.hasKey("votes"):
    for vote in node["votes"]:
      result.votes.add(vote.getStr())
  if node.hasKey("roles"):
    for role in node["roles"]:
      result.roles.add(role.getInt())
  if node.hasKey("clues"):
    for clue in node["clues"]:
      result.clues.add(clue.getStr())

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the say and vote events through the rules (the whole scenario comes
  ## from the seed). frames[i] = state after events[0..<i]; the replayed
  ## sim's own event log mirrors the prefix so the feed lines up.
  var sim = initSim(config)
  ## initSim already logged the start and the first round event; the
  ## recorded log opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evRound:
      if sim.phase == phTalk and event.round >= sim.config.rounds:
        ## A forced ballot is not derivable from the say events alone.
        sim.history.add(sim.say)
        sim.deadlineStop = true
        sim.openBallot()
      let expected =
        if sim.phase == phTalk: sim.round else: sim.config.rounds
      if event.round != expected:
        raise newException(RumorError,
          "round " & $event.round & " does not match the seeded re-derivation")
      if sim.events.len == 0 or sim.events[^1].kind != evRound:
        sim.events.add(event)
    of evSay:
      sim.applyMessage(event.seat, event.claim, event.confidence,
        event.belief, event.text, event.notes, event.scripted)
    of evVote:
      sim.applyVote(event.seat, event.vote, event.belief, event.text,
        event.notes, event.scripted)
    of evTally:
      if event.truth.len > 0 and event.truth != sim.truth:
        raise newException(RumorError,
          "the recorded truth does not match the seeded re-derivation")
      for seat in 0 ..< min(event.clues.len, Seats):
        if event.clues[seat] != sim.clue[seat]:
          raise newException(RumorError,
            "the recorded clues do not match the seeded re-derivation")
      for seat in 0 ..< min(event.roles.len, Seats):
        if event.roles[seat] != sim.roleOf[seat]:
          raise newException(RumorError,
            "the recorded roles do not match the seeded re-derivation")
    of evEnd:
      if not sim.done:
        sim.deadlineStop = event.text == "deadline"
        sim.settle()
      elif event.text.len > 0 and event.text != sim.reason:
        sim.reason = event.text
        if sim.events.len > 0 and sim.events[^1].kind == evEnd:
          sim.events[^1].text = event.text
    result.add(sim)
