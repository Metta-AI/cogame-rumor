"""Compare complete simultaneous-talk and sealed-ballot games across wordings."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

WORDINGS = ("canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference")


def play(binary: Path, manifest: Path, variant: str, wording: str, prompt_seed: int, seed: int) -> str:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )
    input_stream, output_stream = process.stdin, process.stdout
    assert input_stream is not None and output_stream is not None
    digest = hashlib.sha256()

    def request(value: dict) -> dict:
        input_stream.write(json.dumps(value) + "\n")
        input_stream.flush()
        return json.loads(output_stream.readline())

    def record(value: dict) -> None:
        digest.update(json.dumps(value, sort_keys=True).encode())

    try:
        observation = request(
            {
                "kind": "reset",
                "players": 10,
                "seed": f"rumor-{seed}",
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "validation",
            }
        )
        selected = WORDINGS[prompt_seed % 5] if wording == "mixed" else wording
        systems = {}
        roles, phases = set(), set()
        decisions = 0
        while observation["kind"] == "decision":
            view = observation["semantic_view"]
            system, user = [message["content"] for message in observation["messages"]]
            assert view.pop("prompt_template") == {
                "bank": "rumor-rules-v2",
                "selection": wording,
                "variant": selected,
                "seed": prompt_seed,
                "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
            }
            seat = observation["seat"]
            if seat in systems:
                assert systems[seat] == system
            else:
                systems[seat] = system
            assert view["name"] in system
            assert not {"truth", "votes", "roles", "seed", "players", "policy", "prompt"} & view.keys()
            if view["role"] == "Honest":
                assert not view["crew"]
            roles.add(view["role"])
            phases.add(view["phase"])
            observation["messages"][0]["content"] = "<game-owned rules>"
            record(observation)
            proposal = request({"kind": "teacher"})
            record(proposal)
            response = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": proposal["response"]}
            )
            assert response["kind"] == "accepted"
            record(response["action"])
            observation = response["observation"]
            decisions += 1
            assert decisions <= 70
        assert observation["kind"] == "terminal" and roles == {"Honest", "Saboteur"}
        assert phases == {"talk", "ballot"}
        assert decisions == 60 and len(systems) == 10
        assert set(observation["scores"]) == {str(i) for i in range(10)}
        record(observation)
        return digest.hexdigest()
    finally:
        input_stream.close()
        output_stream.close()
        assert process.wait(timeout=10) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
    for variant in ("standard", "bridged"):
        for seed in (17, 946001):
            reference = play(args.binary, manifest, variant, "canonical", 0, seed)
            for wording, prompt_seed in [(w, 0) for w in WORDINGS[1:]] + [("mixed", 4)]:
                assert play(args.binary, manifest, variant, wording, prompt_seed, seed) == reference
        print(variant, "16 complete games PASS", flush=True)
    for wording in WORDINGS[-2:]:
        rejected = subprocess.run(
            [str(args.binary), str(manifest), "standard"],
            input=json.dumps({"kind": "reset", "players": 10, "seed": "guard", "promptVariant": wording}) + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        assert rejected.returncode != 0 and "held-out wording cannot enter training" in rejected.stderr
    print("32 complete games and held-out exclusion PASS", flush=True)


if __name__ == "__main__":
    main()
