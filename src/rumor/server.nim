## Rumor game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (rumor.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"role":...}
##                   {"type":"state",...} after every event (redacted to
##                   the seat's own private view: clue, neighbourhood,
##                   inbox, own history, notes)
##                   {"type":"final","scores":[...],"votes":[...],...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"gossip"}
##                   (max 4000 runes; scripted plays a built-in baseline
##                   for that seat: "gossip" / "1", or "herd")

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1
  ## The certifier keeps probing /healthz and /global for a moment after
  ## the artifacts land; keep answering for a bounded grace rather than
  ## dropping the socket the instant results.json is written.
  ShutdownGraceMs = 20_000

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    jev: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"rumor"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerFrameJson(gs: GameState, slot: int): JsonNode =
  ## Redacted to the seat's own private view: it never carries the seed,
  ## the truth, another seat's clue or belief, a message from a
  ## non-neighbour, any role beyond its own crew's, or any vote.
  result = gs.sim.playerStateJson(slot)
  result["started"] = %gs.started

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get
  ## the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerFrameJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## Self-sufficient bytes: aliases, policy names, the fitted round count,
  ## the SEED (from which the proposition, truth, roles, graph and clues
  ## are re-derived by this same Nim code), the resolved topology and
  ## saboteur count, every event and the results. Nothing else is fetched.
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "rumor.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "rounds": gs.config.rounds,
      "seed": gs.config.seed,
      "topology": gs.sim.topology,
      "saboteurs": gs.sim.saboteurSeats.len,
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame
    ## goes to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "roles": results["roles"],
      "names": aliasNames,
      "votes": results["votes"],
      "clues": results["clues"],
      "truth": results["truth"],
      "accuracy": results["accuracy"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "rumor: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## A bounded grace so /healthz and /global keep answering while the
  ## platform collects logs and the certifier finishes its probes.
  sleep(ShutdownGraceMs)
  echo "rumor: episode complete, shutting down"
  quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "rumor: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing.
    ## Play inside a fraction of it so results and the replay are written
    ## with room to spare. The hosted dispatcher hands the timeout only to
    ## its own worker sidecar, NOT to the game container, so when the env
    ## is silent assume the configured platform default rather than
    ## playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "rumor: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      var jev: seq[bool]
      var ballot = false
      withLock stateLock:
        if state.sim.done:
          break
        ## Checked BEFORE the batch, never mid-turn: past the deadline the
        ## ballot is forced, the table is tallied and unmasked, and the
        ## episode settles with reason "deadline". A short honest episode
        ## always beats a long one that never lands.
        if playDeadline > 0.0 and epochTime() > playDeadline:
          echo "rumor: episode deadline reached in round ",
            state.sim.round, "/", config.rounds, "; calling the vote early"
          state.sim.forceBallot()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        jev = state.jev
        ballot = state.sim.phase == phBallot
        echo "rumor: ", (if ballot: "sealed vote" else:
            "round " & $(state.sim.round + 1) & " of " & $config.rounds),
          " at ", (epochTime() - gameStart).int, "s"

      ## The slow part (Claude, ONE parallel batch of ten) runs outside the
      ## lock on a snapshot; only this thread mutates the sim, so the
      ## snapshot cannot go stale.
      let decisions = client.decideAll(simCopy, seats, prompts, scripted, jev)

      withLock stateLock:
        ## Applied in ascending seat order — deterministic, and the order
        ## cannot matter because nothing a seat does this round is visible
        ## to any other seat this round.
        for index, seat in seats:
          let decision = decisions[index]
          ## Provenance comes from the decision itself, so a seat whose LLM
          ## reply failed and fell back to the baseline is recorded as
          ## scripted too, not just a seat registered as one.
          let wasScripted = decision.scripted or
            scripted[seat] != skNone or (client.disabled and not jev[seat])
          try:
            if ballot:
              state.sim.applyVote(seat, decision.vote, decision.belief,
                decision.reason, decision.notes, wasScripted)
            else:
              state.sim.applyMessage(seat, decision.claim,
                decision.confidence, decision.belief, decision.message,
                decision.notes, wasScripted)
          except RumorError as error:
            echo "rumor: reply rejected (", error.msg,
              "); using scripted fallback"
            ## The fallback is applied inside its own guard: it is
            ## unreachable after the pre-checks, but if it ever did raise
            ## (the seat has already acted this turn) the escape would kill
            ## the game thread while mummy kept serving. Skipping the seat
            ## costs at most one turn; the play deadline still bounds the
            ## episode.
            try:
              let fallback = scriptedAction(state.sim, seat, skGossip)
              if ballot:
                state.sim.applyVote(seat, fallback.vote, fallback.belief,
                  "", "", true)
              else:
                state.sim.applyMessage(seat, fallback.claim,
                  fallback.confidence, fallback.belief, fallback.message,
                  "", true)
            except RumorError as fallbackError:
              echo "rumor: scripted fallback rejected for seat ", seat,
                " (", fallbackError.msg, "); skipping the seat"
        state.broadcastLocked()

      ## Pace between turns so spectators can read the graph.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    ## Let the tally land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "rumor: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "rumor.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "role": state.sim.roleName(slot),
        "rounds": state.config.rounds
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skGossip
              else: skNone)
            else: parseScriptKind(node.getStr())
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.jev[slot] = payload{"jev"}.getBool()
          echo "rumor: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted != skNone: ", scripted " & $scripted else: ""), ")"
      except CatchableError as error:
        echo "rumor: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.rounds = payload["config"]{"rounds"}.getInt(5)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.topology = payload["config"]{"topology"}.getStr("random")
  result.saboteurs = payload["config"]{"saboteurs"}.getInt(-1)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## whole scenario is re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("rumor.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "rumor: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(RumorError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  state.jev = newSeq[bool](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "rumor: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
