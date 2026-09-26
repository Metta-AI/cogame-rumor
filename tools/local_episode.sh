#!/usr/bin/env bash
set -euo pipefail

seed=${1:?usage: local_episode.sh seed}
port=${PORT:-18086}

mkdir -p bin tmp
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path
seed, path = sys.argv[1:]
Path(path).write_text(json.dumps({
    'tokens': [f't{i}' for i in range(10)],
    'players': [{'name': f'P{i}'} for i in range(10)],
    'seed': int(seed), 'rounds': 3, 'turnDelayMs': 0,
    'player_connect_timeout_seconds': 10,
}))
PY
nim c --hints:off -o:bin/rumor src/rumor.nim
nim c --hints:off -o:bin/rumor-player src/rumor_player.nim
bin/rumor --host:127.0.0.1 --port:"$port" \
  --config-path:"$episode_dir/config.json" \
  --results-uri:"file://$episode_dir/results.json" \
  --save-replay-uri:"file://$episode_dir/episode.replay" \
  > "$episode_dir/game.log" 2>&1 &
game=$!
trap 'kill "$game" 2>/dev/null || true' EXIT
sleep 0.5
for slot in {0..9}; do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
    PLAYER_SCRIPTED=gossip bin/rumor-player \
    > "$episode_dir/player$slot.log" 2>&1 &
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'episode.replay').read_text())
print(json.dumps({
    'artifacts': str(path), 'seat0_score': results['scores'][0],
    'seat0_role': results['roles'][0], 'accuracy': results['accuracy'],
    'seat0_scripted': sum(event['scripted'] for event in replay['events']
        if event['kind'] in ('say', 'vote') and event['seat'] == 0),
}))
PY
