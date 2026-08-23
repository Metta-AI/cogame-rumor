## Rumor player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default dual-role strategy), then idles until the final frame. All of
## the actual decision making happens inside the game server, which sends
## this seat's prompt to Claude every turn.
##
## PLAYER_SCRIPTED=gossip (or 1) registers the seat as the built-in
## aggregating baseline instead; PLAYER_SCRIPTED=herd as the
## follow-the-room baseline. The server plays those deterministically, no
## LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <rumor-image> --name my-rumor \
##     --run /bin/rumor-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
If you are HONEST: in round 1 report your own clue plainly and name it as
yours. After that, relay - every round, say which cogs told you which
answer and give your running count by name, e.g. "Bolt+Rivet say BROKEN,
Gasket says SOUND, me BROKEN: 3-1". Count each source ONCE, ever; a cog
repeating itself is not new evidence, and a chain of echoes is how two
liars beat eight clues. Keep the per-source ledger in your notes. Distrust
a cog whose count nobody else can corroborate, whose claim never moves
however much it hears, or who is certain in round 1 and still certain in
round 5. Vote the majority of the DISTINCT clues you can account for, not
the loudest room.
If you are a SABOTEUR: pick your side in round 1 - the opposite of your own
clue - and never drift off it. Sound like an aggregator, not a preacher:
quote counts, name real neighbours, and add one plausible second-hand
report each round. Agree early and loudly with any honest cog already
leaning your way, and aim your effort at the neighbours who are still
moving.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "rumor player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "rumor player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame, and the game's
  ## quit(0) can outrun the flushed final frame — so a dead socket is a
  ## normal end of episode, not a failure. Without this guard the player
  ## container exits non-zero intermittently and fails certification.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "rumor player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "rumor player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " (", payload{"role"}.getStr(), ")"
          ## Re-deliver the prompt after the welcome, in case the first
          ## send raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "rumor player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "rumor player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "rumor player: socket ended (", error.msg, "); exiting"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
