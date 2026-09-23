# Rumor training

Rumor has a local simulator and hosted text players. Export complete games for
Metta post-training with the same seat prompts and reply parser used by the
hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/rumor-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/rumor-bridged 10 1 bridged
```

The exporter reads the selected certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded games per variant, and writes
`train.jsonl`, `validation.jsonl`, and `manifest.json`. Seeds divisible by five
go to validation, keeping each game entirely in one split. The teacher
alternates the published gossip and herd scripts by seat. Each assistant reply
passes through the hosted parser before its action advances the simulator.
The exporter refuses an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/rumor-standard \
  --output /tmp/rumor-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The `standard` and `bridged` variants each produce 600 examples from ten
games. These are imitation examples from scripted play; loss on this dataset
does not measure competitive strength. The native game has text replies with
free-form claims and notes, so the fixed discrete Metta RL and PufferLib
bridges do not encode its action space.
