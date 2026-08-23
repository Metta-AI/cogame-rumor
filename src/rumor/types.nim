import std/[json, strutils]

const
  ## Seats are fixed at ten; the config may not vary it.
  ConfiguredSeats* = 10
  TopologyNames* = ["random", "ring", "smallworld", "clusters", "hub"]

type
  RumorError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int          ## talk rounds before the sealed ballot
    topology*: string     ## "random" | ring | smallworld | clusters | hub
    saboteurs*: int       ## -1 = seeded draw of 2 or 3
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  SeatRecord* = object
    ## One seat's public act in one talk round.
    claim*: string        ## "A" | "B" | "none"
    confidence*: int      ## 0..100
    belief*: int          ## 0..100, the seat's private P(answer is A) in percent
    message*: string

  Inbox* = object
    ## One neighbour's message, as delivered at the start of the next round.
    fromSeat*: int
    claim*: string
    confidence*: int
    message*: string

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evSay = "say"
    evVote = "vote"
    evTally = "tally"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int          ## round/say: the talk round; vote/tally: rounds; end: rounds played
    seat*: int           ## say/vote: the acting seat; -1 otherwise
    claim*: string       ## say: "A"|"B"|"none"
    vote*: string        ## vote: "A"|"B"
    confidence*: int     ## say: 0..100; -1 otherwise
    belief*: int         ## say/vote: 0..100; -1 otherwise
    text*: string        ## say: the message; vote: the reason; end/round/tally: a line
    notes*: string       ## say/vote: the seat's notes after the reply
    scripted*: bool      ## say/vote: decided by a scripted baseline
    votes*: seq[string]  ## tally: all ten votes, seat order
    roles*: seq[int]     ## tally: all ten roles, 0 honest / 1 saboteur
    clues*: seq[string]  ## tally: all ten clues
    truth*: string       ## tally: "A"|"B"
    accuracy*: float     ## tally: honest accuracy
    honestCorrect*: int  ## tally: honest seats that voted the truth
    verdict*: string     ## tally: "A"|"B"|"split", display only

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 5,
    topology: "random",
    saboteurs: -1,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 120,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 25
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(RumorError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("topology"):
    config.topology = node["topology"].getStr().strip().toLowerAscii()
  if node.hasKey("saboteurs"):
    config.saboteurs = node["saboteurs"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.rounds < 3:
    raise newException(RumorError, "rounds must be at least 3")
  if config.players.len > 0 and config.players.len != ConfiguredSeats:
    raise newException(RumorError,
      "rumor needs exactly " & $ConfiguredSeats & " players")
  if config.topology notin TopologyNames:
    raise newException(RumorError, "unknown topology: " & config.topology)
  if node.hasKey("saboteurs") and config.saboteurs notin [2, 3]:
    raise newException(RumorError, "saboteurs must be 2 or 3")
