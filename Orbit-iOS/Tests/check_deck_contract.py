"""Check the button deck model (Shared/OrbitDeck.swift) against the DESIGN F4 contract and the agent.

1. Compiles Shared/OrbitDeck.swift with Tests/OrbitDeckTests.swift (Swift 6, strict concurrency) and
   runs the model checks: the DESIGN sample, exact JSON of every action type, actions from newer apps
   kept on save, lossy decoding, confirm rules, validation, OBS/apps/capabilities payloads.
2. Compares the key picker with orbit_input.KEY_NAMES and the Windows actions with orbit_agent.ACTIONS
   (read from the source, so no agent dependencies are needed for this part).
3. When the agent has `/api/deck` (orbit_deck.py) and its Python dependencies are installed, PUTs a deck
   with every action type through FastAPI's TestClient over https, reads it back with GET and decodes it
   with the Swift model. Otherwise this part is skipped with a note.

No PC, network or device is touched.
"""
import ast
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / "Orbit-Windows-Agent"
sys.path.insert(0, str(AGENT))
sys.dont_write_bytecode = True


def agent_key_names():
    import orbit_input  # ctypes, dataclasses and threading only
    return sorted(orbit_input.KEY_NAMES)


def agent_actions():
    tree = ast.parse((AGENT / "orbit_agent.py").read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "ACTIONS" for t in node.targets):
            call = node.value
            if isinstance(call, ast.Call) and call.args:
                return sorted(ast.literal_eval(call.args[0]))
    raise SystemExit("FAIL: ACTIONS not found in orbit_agent.py")


def agent_round_trip(binary, deck_path, directory):
    import os
    from unittest.mock import patch
    token = "deck-contract-token-0123456789abcdef"
    # The agent keeps the deck in %LOCALAPPDATA%\Orbit\settings.json: point it at a temporary folder
    # before the agent is imported, so nothing is written to this Mac's real data folder.
    with tempfile.TemporaryDirectory(prefix="orbit-deck-agent-") as data_dir, patch.dict(os.environ, {"LOCALAPPDATA": data_dir}):
        try:
            import orbit_settings
            orbit_settings.set_shared_store(orbit_settings.SettingsStore(Path(data_dir) / "settings.json"))
            import orbit_agent as agent
            from fastapi.testclient import TestClient
        except Exception as error:  # agent dependencies missing (run with the test venv)
            print(f"SKIP: agent round trip ({type(error).__name__}: {error}); run with the agent's Python environment")
            return
        if not any(getattr(route, "path", "") == "/api/deck" for route in agent.app.routes):
            print("SKIP: agent round trip — this agent has no /api/deck yet (orbit_deck.py not merged)")
            return
        agent.API_TOKEN = token
        client = TestClient(agent.app, base_url="https://testserver")
        headers = {"Authorization": f"Bearer {token}"}
        body = json.loads(Path(deck_path).read_text())
        response = client.put("/api/deck", json=body, headers=headers)
        if response.status_code != 200:
            raise SystemExit(f"FAIL: the agent refused the app's deck: {response.status_code} {response.text}")
        response = client.get("/api/deck", headers=headers)
        if response.status_code != 200:
            raise SystemExit(f"FAIL: GET /api/deck returned {response.status_code} {response.text}")
        returned = Path(directory) / "returned.json"
        returned.write_text(response.text)
        subprocess.run([str(binary), "--decode", str(returned)], check=True, timeout=60)
        plain = TestClient(agent.app, base_url="http://testserver").get("/api/deck", headers=headers)
        if plain.status_code != 426:
            raise SystemExit(f"FAIL: GET /api/deck over http returned {plain.status_code}, expected 426")
        print("PASS: agent /api/deck accepts every action type the app makes and answers 426 over http")


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-deck-contract-") as directory:
        root = Path(directory)
        keys = root / "keys.json"
        actions = root / "actions.json"
        deck = root / "deck.json"
        keys.write_text(json.dumps(agent_key_names()))
        actions.write_text(json.dumps(agent_actions()))
        binary = root / "deck-tests"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
            str(ROOT / "Orbit-iOS/Shared/OrbitDeck.swift"),
            str(ROOT / "Orbit-iOS/Tests/OrbitDeckTests.swift"),
            "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(keys), str(actions), str(deck)], check=True, timeout=60)
        agent_round_trip(binary, deck, root)


if __name__ == "__main__":
    main()
