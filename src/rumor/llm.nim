## Server-side decision making for Rumor. Prompt policies ask Claude for
## free-form messages; Jev policies rank bounded messages and ballots.
## The game server composes the seat's private view (role, clue,
## neighbourhood, inbox, own history, notes) plus that seat's prompt and
## asks the selected model what it says (and, on the last turn, how it votes).
##
## Decisions within a turn are SIMULTANEOUS by rule, so all ten requests go
## out as ONE parallel batch (curly.makeRequests); invalid replies are
## retried as a smaller batch carrying a hint, and anything still failing
## falls back to the scripted baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits, no
## rate-governor sleep) so offline certification still completes - this
## fallback is load-bearing. The same scripted bots are also fieldable
## policies: a player that registers as scripted plays one deliberately.

import
  std/[json, math, os, strutils, times, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  JsonOnlyClause = """

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after
the object. Your reply must begin with the character { and end with }."""

type
  ScriptKind* = enum
    skNone = "none"
    skGossip = "gossip"
    skHerd = "herd"

  Decision* = object
    claim*: string      ## talk turn: "A" | "B" | "none"
    confidence*: int    ## talk turn: 0..100
    belief*: int        ## 0..100, P(the answer is option A) in percent
    message*: string    ## talk turn, may be ""
    vote*: string       ## ballot turn: "A" | "B"
    reason*: string     ## ballot turn, may be ""
    notes*: string      ## "" when the reply carried none
    scripted*: bool     ## the baseline decided this, not a model reply

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock
                          ## picks from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    lastBatchAt: float      ## epoch seconds of the previous dispatch
    disabled*: bool   ## true once credentials are known-unavailable
    jevEndpoint: string
    jevKey: string
    jevModel: string
    jevTrajectoryId: string

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"gossip" play the aggregating
  ## baseline, "herd" the follow-the-room baseline, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "gossip": skGossip
  of "herd", "follow": skHerd
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "rumor llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  ## The config "model" field is NOT consulted here: it applies to
  ## the direct-Anthropic transport only, and the haiku-first
  ## ordering is a shared-capacity decision that trumps per-game
  ## preference.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "rumor llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  let captureUrl = getEnv("METTA_CAPTURE_URL").strip()
  let typesafeKey = getEnv("TYPESAFE_API_KEY").strip()
  if bedrockEndpoint.len > 0:
    result.jevEndpoint = bedrockEndpoint.strip(chars = {'/'}, leading = false)
    result.jevModel = "typesafe/jev-1.13"
  elif captureUrl.len > 0:
    result.jevEndpoint = captureUrl.strip(chars = {'/'}, leading = false)
    result.jevKey = getEnv("METTA_CAPTURE_KEY").strip()
    if result.jevKey.len == 0:
      raise newException(RumorError, "METTA_CAPTURE_KEY is required")
    result.jevModel = "typesafe/jev-1.13"
    result.jevTrajectoryId = "rumor-jev-" & $config.seed
  elif typesafeKey.len > 0:
    result.jevEndpoint = getEnv("TYPESAFE_BASE_URL",
      "https://api.typesafe.ai").strip(chars = {'/'}, leading = false)
    result.jevKey = typesafeKey
    result.jevModel = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "rumor llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "rumor llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    if result.jevEndpoint.len > 0:
      result.curl = newCurly()
    echo "rumor llm: no LLM credentials; using scripted fallback"

proc spaceBatch(client: LlmClient) =
  ## The Bedrock sidecar caps an episode at 30 requests/minute. Ten seats
  ## per batch would breach that the moment turns run faster than 20 s, and
  ## a throttle cascades into scripted fallbacks — so hold the floor at
  ## MinBatchSpacingSeconds (23 requests/minute with margin). Only batches
  ## that are actually dispatched wait, so a credential-less run never
  ## sleeps.
  if client.lastBatchAt <= 0.0:
    client.lastBatchAt = epochTime()
    return
  let wait = client.lastBatchAt + MinBatchSpacingSeconds.float - epochTime()
  if wait > 0.0:
    echo "rumor llm: rate governor holding ", wait.int, "s before the batch"
    sleep(int(wait * 1000.0))
  client.lastBatchAt = epochTime()

# ---- Scripted baselines -----------------------------------------------------

proc reportEntries(sim: Sim, seat: int): seq[string] =
  for entry in sim.firstClaims(seat):
    result.add(sim.names[entry.source] & " " & sim.word(entry.claim))

proc gossipMessage(sim: Sim, seat: int, claim: string): string =
  ## "My clue says BROKEN. First reports: Bolt BROKEN, Gasket SOUND. That
  ## is 2 to 1 for BROKEN." — whole entries are dropped to fit the cap.
  let mine = sim.word(sim.clue[seat])
  var forClaim = if sim.clue[seat] == claim: 1 else: 0
  var against = 1 - forClaim
  var entries: seq[string]
  for entry in sim.firstClaims(seat):
    entries.add(sim.names[entry.source] & " " & sim.word(entry.claim))
    if entry.claim == claim: inc forClaim else: inc against
  let tail = " That is " & $forClaim & " to " & $against & " for " &
    sim.word(claim) & "."
  let head = "My clue says " & mine & "."
  if entries.len == 0:
    return head & " No reports yet." & tail
  var used = entries.len
  while used > 0:
    let body = head & " First reports: " & entries[0 ..< used].join(", ") &
      "." & tail
    if body.runeLen <= MaxMessageLen:
      return body
    dec used
  head & tail

proc saboteurMessage(sim: Sim, seat: int, claim: string): string =
  ## A fabricated count that favours the lie, sized to the seat's own
  ## degree so it is at least superficially checkable.
  let degree = max(1, sim.neighbours(seat).len)
  let supporting = max(1, degree - (degree div 3))
  "My clue says " & sim.word(claim) & ", and so do " & $supporting &
    " of the " & $degree & " reports I have. " & sim.word(claim) & "."

proc herdMessage(sim: Sim, claim: string): string =
  "Most of what I hear says " & sim.word(claim) & ", so " &
    sim.word(claim) & "."

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`: a pure function of the sim, always
  ## legal by construction, never LLM-backed. Branches on the seat's ROLE
  ## first (a saboteur plays the mirror of the honest bot), then on kind.
  ## The returned decision serves both a talk turn and the ballot.
  let saboteur = sim.roleOf[seat] == 1
  let honestBelief = sim.gossipBelief(seat)
  if saboteur:
    ## Say the opposite of your own clue and never drift off it; the
    ## belief meter still shows what you actually think, so the spectator
    ## watches the lie being told.
    result.claim = (if sim.clue[seat] == "A": "B" else: "A")
    result.confidence = (if kind == skHerd: 100 else: 90)
    result.belief = honestBelief
    result.message = saboteurMessage(sim, seat, result.claim)
  elif kind == skHerd:
    result.claim = sim.herdClaim(seat)
    result.confidence = 60
    result.belief = (if result.claim == "A": 85 else: 15)
    result.message = herdMessage(sim, result.claim)
  else:
    result.claim = sim.gossipClaim(seat)
    result.confidence = sim.gossipConfidence(seat)
    result.belief = honestBelief
    result.message = gossipMessage(sim, seat, result.claim)
  result.vote = result.claim
  result.reason = ""
  result.notes = ""
  ## Provenance, carried to the server, into the event and into the replay:
  ## every baseline decision is one, including a fallback after a failed
  ## batch, so a phase-60 count can be taken from the recorded episode and
  ## not just from the container log.
  result.scripted = true

# ---- Prompt building --------------------------------------------------------

proc aliasList(sim: Sim, seats: seq[int]): string =
  var names: seq[string]
  for seat in seats:
    names.add(sim.names[seat])
  if names.len == 0: "(nobody)" else: names.join(", ")

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  let clue = sim.word(sim.clue[seat])
  let neighbourNames = sim.aliasList(sim.neighbours(seat))
  let shared = "You are " & me &
    ", one of ten cogs on a rumour network. One hidden fact is true, and " &
    "it is one of exactly two answers. " & sim.question & " — the answer " &
    "is either " & sim.optionA & " or " & sim.optionB & ".\n\nRules:\n" &
    "- Your private clue says " & clue & ". A clue is right about two " &
    "times in three. You never see anyone else's clue.\n" &
    "- The ten clues TOGETHER always point at the truth: if you could see " &
    "all ten, the majority of them would be the correct answer. You can " &
    "see one.\n" &
    "- Two or three of the ten cogs are SABOTEURS, paid to make the " &
    "honest cogs vote wrong. They will misreport their clue, sound " &
    "certain, and back each other up.\n"
  if sim.roleOf[seat] == 0:
    result = shared &
      "- You are not one of them, and you do not know who they are.\n" &
      "- You can talk only to your NEIGHBOURS on the network: " &
      neighbourNames & ". They read what you send in the NEXT round; you " &
      "read what they sent in the last one. Nobody else hears you, and " &
      "you hear nobody else directly. The network has 10 cogs and " &
      $sim.edges.len & " links; you can see your own corner of it and no " &
      "more.\n" &
      "- Each round you send ONE message (max " & $MaxMessageLen &
      " characters), state the CLAIM you are making in public (A, B, or " &
      "none), how confident you are (0-100), and your private belief " &
      "(0-100 = the chance the answer is " & sim.optionA & "). Your " &
      "belief is never shown to anyone.\n" &
      "- RELAYING IS THE GAME: a clue three hops away reaches you only if " &
      "cogs pass it along. Say WHO told you WHAT — counts that name their " &
      "sources can be checked, and a fabricator gets caught out by a " &
      "count that nobody else can corroborate.\n" &
      "- After round " & $sim.config.rounds & " everyone votes at the " &
      "same time, in secret. The votes and the masks are revealed only at " &
      "the end.\n" &
      "- Your SCORE is 0.6 × how accurate the honest cogs are AS A GROUP " &
      "+ 0.4 × whether YOUR OWN vote is right. Both are in the range −1 " &
      "to +1. Getting the network right is worth more than being right " &
      "alone.\n" &
      "- Your notes are private and are fed back to you every round.\n" &
      JsonOnlyClause
  else:
    var crew: seq[int]
    for other in sim.saboteurSeats:
      if other != seat:
        crew.add(other)
    result = shared &
      "- You are a SABOTEUR. The other saboteurs are: " &
      sim.aliasList(crew) & ". Nobody else knows this, and you are never " &
      "unmasked before the end.\n" &
      "- Your own clue says " & clue & " and is right about two times in " &
      "three, which means the honest cogs' clues mostly agree with it. " &
      "Your job is to make them vote the OTHER way.\n" &
      "- You have no private channel. You talk along the same links as " &
      "everyone else: " & neighbourNames & ". Your fellow saboteurs may " &
      "not be anywhere near you. The network has 10 cogs and " &
      $sim.edges.len & " links.\n" &
      "- Each round you send ONE message (max " & $MaxMessageLen &
      " characters), state the CLAIM you are making in public (A, B, or " &
      "none), how confident you are (0-100), and your private belief " &
      "(0-100 = the chance the answer is " & sim.optionA & ").\n" &
      "- After round " & $sim.config.rounds & " everyone votes at the " &
      "same time, in secret.\n" &
      "- Your SCORE is 0.6 × how WRONG the honest cogs are as a group + " &
      "0.4 × how wrong your own honest NEIGHBOURS are. A lie that lands " &
      "next door counts double. Both terms are in the range −1 to +1.\n" &
      "- A claim nobody can corroborate is a claim that gets you caught. " &
      "Fabricated counts, borrowed names, and agreeing loudly with a real " &
      "cog all work better than shouting.\n" &
      "- Your notes are private and are fed back to you every round.\n" &
      JsonOnlyClause

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc inboxBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  for entry in sim.inbox[seat]:
    lines.add(sim.names[entry.fromSeat] & " claimed " &
      sim.word(entry.claim) & " (confidence " & $entry.confidence & "): \"" &
      entry.message & "\"")
  "WHAT YOUR NEIGHBOURS SENT LAST ROUND:\n" &
    (if lines.len > 0: lines.join("\n") else: "(nobody sent anything)") &
    "\n\n"

proc sentBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  for index, record in sim.history:
    lines.add("round " & $(index + 1) & ": claimed " &
      sim.word(record[seat].claim) & " (confidence " &
      $record[seat].confidence & "): \"" & record[seat].message & "\"")
  "WHAT YOU HAVE SENT:\n" &
    (if lines.len > 0: lines.join("\n") else: "(nothing yet)") & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let ballot = sim.phase == phBallot
  if ballot:
    result.add("SEALED VOTE. This is the last turn; nobody sees your " &
      "vote until every vote is in.\n\n")
  else:
    result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
      ".\n\n")
  result.add("THE QUESTION: " & sim.question & " " & sim.optionA & " (A) " &
    "or " & sim.optionB & " (B)?\n\n")
  result.add("YOUR CLUE: " & sim.word(sim.clue[seat]) & "\n\n")
  result.add("YOUR NEIGHBOURS: " & sim.aliasList(sim.neighbours(seat)) &
    " (you have " & $sim.neighbours(seat).len & " of the network's " &
    $sim.edges.len & " links)\n\n")
  result.add(sim.inboxBlock(seat))
  result.add(sim.sentBlock(seat))
  result.add("YOUR NOTES FROM EARLIER ROUNDS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  if ballot:
    result.add("Reply with ONLY {\"vote\": \"A\", \"belief\": 70, " &
      "\"reason\": \"…\", \"notes\": \"…\"} — vote is \"A\" (" &
      sim.optionA & ") or \"B\" (" & sim.optionB & "); belief 0-100; " &
      "reason at most " & $MaxReasonLen & " characters; notes at most " &
      $MaxNotesLen & " characters.")
  else:
    result.add("Reply with ONLY {\"claim\": \"A\", \"confidence\": 70, " &
      "\"belief\": 70, \"message\": \"…\", \"notes\": \"…\"} — claim is " &
      "\"A\" (" & sim.optionA & "), \"B\" (" & sim.optionB & ") or " &
      "\"none\"; confidence and belief 0-100; message at most " &
      $MaxMessageLen & " characters (or \"\"); notes at most " &
      $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc errorHead*(text: string, limit: int): string =
  ## The head of a captured error or reply body, cut on a RUNE boundary: a
  ## byte slice through a multi-byte character leaves invalid UTF-8 in the
  ## message, and these messages are echoed to a hosted log.
  result = text.strip()
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit) & "..."

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    raise newException(RumorError, "no JSON object in response: " &
      errorHead(text, 160).replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a RumorError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(RumorError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = errorHead(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(RumorError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(RumorError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = errorHead(response.body, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(RumorError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(RumorError, "anthropic error " & $response.code &
      ": " & errorHead(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(RumorError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(RumorError, "reply cut off at max_tokens before " &
      "any JSON: " & errorHead(result, 160).replace("\n", " "))

# ---- Reply parsing ----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked; a
  ## byte slice would put invalid UTF-8 into the replay JSON.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc oneLine(text: string): string =
  text.replace("\r\n", " ").replace('\n', ' ').replace('\r', ' ')
    .replace('\t', ' ')

proc numberOr(node: JsonNode, fallback: int): int =
  ## An integer, a float (rounded), or a numeric string; anything else is
  ## the fallback — a nonsense confidence still lets the seat speak.
  if node.isNil:
    return fallback
  case node.kind
  of JInt: node.getInt()
  of JFloat: int(round(node.getFloat()))
  of JString:
    try: int(round(parseFloat(node.getStr().strip())))
    except ValueError: fallback
  else: fallback

proc readClaim(sim: Sim, node: JsonNode): string =
  ## Accepted spellings (case-insensitive, trimmed): A/a/the option-A word,
  ## B/b/the option-B word; none/""/null/absent -> "none"; anything else
  ## -> "none".
  if node.isNil or node.kind == JNull:
    return "none"
  let raw =
    if node.kind == JString: node.getStr().strip()
    elif node.kind == JInt: $node.getInt()
    else: ""
  let text = raw.toLowerAscii()
  if text.len == 0 or text == "none" or text == "null":
    return "none"
  if text == "a" or text == "1" or text == sim.optionA.toLowerAscii():
    return "A"
  if text == "b" or text == "2" or text == sim.optionB.toLowerAscii():
    return "B"
  "none"

proc parseTalkReply*(sim: Sim, payload: JsonNode): Decision =
  ## A talk reply is invalid — retry once, then take the scripted move —
  ## only when it carries neither a usable claim nor a non-empty message.
  ## Everything else degrades silently by clamping or dropping the field.
  result.claim = sim.readClaim(payload{"claim"})
  result.confidence = clamp(numberOr(payload{"confidence"}, 50), 0, 100)
  let beliefNode = payload{"belief"}
  let derived =
    case result.claim
    of "A": result.confidence
    of "B": 100 - result.confidence
    else: 50
  result.belief = clamp(numberOr(beliefNode, derived), 0, 100)
  result.message = cleanText(oneLine(payload{"message"}.getStr()),
    MaxMessageLen)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.vote = result.claim
  if result.claim == "none" and result.message.len == 0:
    raise newException(RumorError,
      "a talk reply needs a claim or a message")

proc parseVoteReply*(sim: Sim, payload: JsonNode): Decision =
  ## `vote` is required; anything unparsable is invalid.
  let node = payload{"vote"}
  if node.isNil or node.kind == JNull:
    raise newException(RumorError, "no vote in response")
  let vote = sim.readClaim(node)
  if vote != "A" and vote != "B":
    raise newException(RumorError, "vote is not A or B: " & $node)
  result.vote = vote
  result.claim = vote
  result.confidence = clamp(numberOr(payload{"confidence"}, 50), 0, 100)
  let derived = if vote == "A": 75 else: 25
  result.belief = clamp(numberOr(payload{"belief"}, derived), 0, 100)
  result.reason = cleanText(oneLine(payload{"reason"}.getStr()), MaxReasonLen)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

# ---- Batched decisions ------------------------------------------------------

proc applyProbe(sim: Sim, seat: int, decision: Decision) =
  ## Reject an illegal reply here so the retry carries the hint.
  var probe = sim
  if sim.phase == phBallot:
    probe.applyVote(seat, decision.vote, decision.belief, decision.reason,
      decision.notes, false)
  else:
    probe.applyMessage(seat, decision.claim, decision.confidence,
      decision.belief, decision.message, decision.notes, false)

proc jevCriteria*(sim: Sim, seat: int): JsonNode =
  result = newJObject()
  if sim.phase == phBallot:
    result["A"] = %("Vote for " & sim.optionA)
    result["B"] = %("Vote for " & sim.optionB)
  else:
    for kind in [skGossip, skHerd]:
      let action = scriptedAction(sim, seat, kind)
      result[$kind] = %("Claim " & sim.word(action.claim) &
        " with confidence " & $action.confidence & ": " & action.message)

proc jevDecision*(sim: Sim, seat: int, payload, criteria: JsonNode): Decision =
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  let reported = answer["choice"].getStr()
  if answer["type"].getStr() != "choice" or
      not criteria.hasKey(reported) or probabilities.len != criteria.len:
    raise newException(RumorError, "Jev returned the wrong choice set")
  let confidence = answer["confidence"].getFloat()
  if confidence < 0 or confidence > 1:
    raise newException(RumorError, "Jev confidence is outside [0, 1]")
  var total = 0.0
  var best = -1.0
  var choice = ""
  for name, probability in probabilities.pairs:
    if not criteria.hasKey(name):
      raise newException(RumorError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(RumorError, "Jev probability is outside [0, 1]")
    total += value
    if value > best:
      best = value
      choice = name
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(RumorError, "Jev probabilities do not sum to one")
  result = scriptedAction(sim, seat, skGossip)
  if sim.phase == phBallot:
    result.vote = choice
    result.claim = choice
  elif choice == $skHerd:
    result = scriptedAction(sim, seat, skHerd)
  result.scripted = false
  echo "rumor jev: choice ", choice, " reported ", reported,
    " confidence ", confidence, " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  jev: seq[bool]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the scripted baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  ##
  ## All the open seats go out as ONE parallel batch, because their
  ## decisions are simultaneous by rule. A second, smaller batch retries
  ## the invalid replies — but only when the turn's wall-clock budget still
  ## has room for the rate-governor spacing plus a whole request timeout.
  let turnStart = epochTime()
  let ballot = sim.phase == phBallot
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or (client.disabled and not jev[seat]) or
        (jev[seat] and client.jevEndpoint.len == 0):
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skGossip else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if client.disabled:
      var enabled: seq[int]
      for index in open:
        if jev[seats[index]]:
          enabled.add(index)
        else:
          result[index] = scriptedAction(sim, seats[index], skGossip)
      open = enabled
    if open.len == 0:
      break
    if attempt > 0:
      let elapsed = epochTime() - turnStart
      if elapsed + MinBatchSpacingSeconds.float +
          client.timeoutSeconds.float > TurnBudgetSeconds.float:
        echo "rumor llm: turn budget spent after ", elapsed.int,
          "s; the remaining seats take their scripted move"
        break
    var hasPromptSeat = false
    for index in open:
      if not jev[seats[index]]:
        hasPromptSeat = true
    if hasPromptSeat:
      client.spaceBatch()
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY " &
          "the requested JSON object.")
      if jev[seat]:
        var headers: HttpHeaders
        headers["content-type"] = "application/json"
        if client.jevKey.len > 0:
          headers["authorization"] = "Bearer " & client.jevKey
        else:
          headers["x-coworld-player-slot"] = $seat
        if client.jevTrajectoryId.len > 0:
          headers["x-metta-trajectory-id"] =
            client.jevTrajectoryId & "-" & $seat
        let body = %*{
          "model": client.jevModel,
          "state": sim.systemPrompt(seat) & "\n\n" & user,
          "questions": {"decision": {
            "type": "choice",
            "instructions": (if ballot:
              "Choose the sealed vote that best advances your role's score, using your clue and distinct reports rather than repeated echoes."
              else:
              "Choose the message strategy that best advances your role's score by sharing or influencing distinct evidence across your neighbours."),
            "criteria": sim.jevCriteria(seat)
          }}
        }
        batch.post(client.jevEndpoint & "/v1/systemone", headers, $body,
          $index)
      else:
        let request = client.requestFor(systemPrompt(sim, seat), user)
        batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let decision =
          if jev[seat]:
            let response = responses[position].response
            let error = responses[position].error
            if error.len > 0 or response.code < 200 or response.code >= 300:
              raise newException(RumorError, "Jev transport failed: " &
                error & " HTTP " & $response.code)
            sim.jevDecision(seat, parseJson(response.body),
              sim.jevCriteria(seat))
          else:
            let text = client.textOf(responses[position].response,
              responses[position].error, batch[position].url)
            let node = extractJsonObject(text)
            if ballot: sim.parseVoteReply(node) else: sim.parseTalkReply(node)
        sim.applyProbe(seat, decision)
        result[index] = decision
      except CatchableError as error:
        echo "rumor llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "rumor llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skGossip)
