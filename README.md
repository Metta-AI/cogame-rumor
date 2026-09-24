# Rumor

**Ten cogs on a hidden social graph, ten noisy clues, two or three of them
paid to mislead.** Built for the Softmax Coworld platform on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology stack,
forked from [cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip).

One binary fact is true — a proposition drawn from the seed, such as *"The
relay tower on Ash Hill is BROKEN or SOUND?"* — and every cog holds a private
clue that is right about two times in three. **Two or three of the ten are
saboteurs**, dealt from the seed, paid to make the honest cogs vote wrong;
nobody is unmasked before the end. A cog may message only its **neighbours**
on the graph, and only they read it — one hop, one round later. The topology
(a ring with chords, a small world, two clusters joined by a single bridge,
or hubs) is drawn per episode, and no seat sees beyond its own corner of it.

The one public rule that makes the game winnable: **the ten clues together
always point at the truth** — they split 6–4, 7–3 or 8–2 in its favour. So
the whole game is *how much of the network's clue evidence can you actually
collect, and how much of what you collect is a saboteur's fabrication?*

After **five rounds of simultaneous talk** every seat casts a **sealed
vote**. Then the ballots open, the truth is stamped across the table, and the
saboteurs' masks come off.

**Scoring.** An honest seat scores `0.6 × (2A − 1) + 0.4 × (its own vote was
right ? +1 : −1)`, where `A` is the fraction of the *honest* seats that voted
the truth. A saboteur scores the exact mirror of the first term plus
`0.4 × (2 × localWrong − 1)`, where `localWrong` is the fraction of its own
honest neighbours who voted wrong. Both ranges are `[−1, +1]`, higher is
better, and saboteur votes never enter `A`. Roles are dealt from the seed, so
the same policy plays both sides across a ladder. See
[`docs/plans`](docs/plans) and the manifest's `scoring.md` page.

**The game is LLM-driven and a policy is a prompt or a Jev choice policy.** Every turn the
server sends each seat's policy prompt, its role, its clue, its
neighbourhood, its inbox, its own send history and its private notes to
Claude — all ten seats as **one parallel batch**, because their decisions are
simultaneous — and Claude answers with a claim, a confidence, a private
belief, a message and new notes (and, on the last turn, a vote). Player
containers exist only to deliver their prompt over the websocket. Two
built-in **scripted baselines** — `gossip` (aggregate log-odds, counting each
source exactly once) and `herd` (follow the majority of whatever you heard
last round) — play any seat that registers as scripted, and every seat when
no LLM credentials are available, so episodes and offline certification
always complete. Measured over 500 seeds an all-`gossip` table reaches about
**0.69** collective accuracy and an all-`herd` table about **0.63**, against
a **0.93** ceiling for perfect relaying and perfect saboteur discounting:
that band is what a prompt can win.

With `PLAYER_JEV=1`, the server asks Jev System One to rank the valid
`gossip` and `herd` message strategies during talk, then the two sealed
ballots. It uses the highest probability choice and checks the full choice
set and probability mass. If Jev is unavailable, the seat uses `gossip`.
The route accepts the hosted Bedrock sidecar, Observatory capture, or direct
TypeSafe key. It does not generate new message text; this pilot tests whether
Jev can select a better bounded strategy than the free baseline.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy display
names never reach the agents' prompts, so nobody can meta-game "that seat is
the champion". The spectator and replay viewers map the aliases back to
policy names; results are reported under policy names.

The episode ends `complete` when the ballot resolves, or `deadline` when the
episode clock forces it — and a forced ballot is still fully tallied, revealed
and scored.

## Layout

- `src/rumor.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/rumor/types.nim` — config, seat records, events
- `src/rumor/sim.nim` — pure rules: the seeded scenario (proposition, truth,
  roles, graph, clues), message routing, the sealed ballot, the tally,
  scoring, replay derivation; shared by server, tests and the wasm viewer
- `src/rumor/llm.nim` — Claude client (one parallel batch per turn, a
  26 s rate governor, an 80 s hard turn budget) + the scripted baselines
- `src/rumor/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/rumor_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the
  bullwhip broadcast chrome around the social-graph stage and the belief tide)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `tools/make_cog_palette.py` — the deterministic HSV recolour that derives
  the six extra seat sprites from the starter's red cog
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT) plus the six
  recolours
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r -d:release --path:src tests/test_bot.nim # scripted-baseline tests
nim c -d:release -o:bin/rumor src/rumor.nim
nim c -d:release -o:bin/rumor-player src/rumor_player.nim
nim c --hints:off -d:emscripten replay-viewer/rumor_replay.nim  # wasm viewer

# Paired local gossip/Jev episodes; artifacts stay in ignored tmp/:
tools/local_episode.sh gossip 7
TYPESAFE_API_KEY=<key> tools/local_episode.sh jev 7

# One real containerised episode (game + ten players, results and replay
# in dist/smoke/), exactly what CI runs:
docker build --platform=linux/amd64 -t coworld-rumor:ci .
./tools/ci/docker_smoke.sh coworld-rumor:ci
# Export ANTHROPIC_API_KEY for real Claude play; omit for the scripted
# baselines.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put rumor anthropic_api_key <keyfile>   # hosted Claude
```

In CI, `.github/workflows/coworld-release.yml` does all of that in the
load-bearing order (build → certify → upload policies → upload-coworld →
secret put) and uploads a `release-result` artifact.

## Fielding a policy

```bash
uv run coworld upload-policy <rumor image> --name my-rumor \
  --run /bin/rumor-player \
  --secret-env PLAYER_PROMPT="Your rumour-network strategy here."
```

Your prompt has to cover **both roles** — the role is dealt after seating, so
the same prompt plays honest in one episode and saboteur in the next. Or
field a scripted baseline: same image, `--env PLAYER_SCRIPTED=gossip` or
`--env PLAYER_SCRIPTED=herd`.

To field the bounded Jev policy, use `--env PLAYER_JEV=1` on the same image.
