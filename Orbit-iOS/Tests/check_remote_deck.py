"""Check the button deck (DESIGN F4) as the Apple Watch, Mac and Apple TV apps read it.

Compiles the shared deck model (Shared/OrbitRemoteDeck.swift) and the iPhone → Watch payload builder
(Orbit/OrbitWatchDeckSync.swift) into a test binary and feeds it a deck in the `GET /api/deck` shape:

* When the agent in this checkout has the deck (`orbit_deck`), the deck and `/api/capabilities` come
  from the real agent through FastAPI's TestClient (HTTPS, main token): a sample deck is saved with
  `PUT /api/deck` and read back with `GET /api/deck`. The agent's settings go to a temporary folder.
* Otherwise a fixture written from the DESIGN contract is used, and the script says so.

No Windows PC, simulator or network is used. Run with the agent venv when the agent has the deck:
    output/.recovery-test-venv/bin/python3 Orbit-iOS/Tests/check_remote_deck.py
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / "Orbit-Windows-Agent"

SAMPLE_BUTTONS = [
    {"id": "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f", "title": "Mute Discord", "symbol": "mic.slash.fill", "color": "#FF453A",
     "action": {"type": "hotkey", "keys": ["ctrl", "shift", "m"]}},
    {"id": "7a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", "title": "Save clip", "symbol": "film.stack", "color": "#30D158",
     "action": {"type": "hotkey", "keys": ["alt", "f10"]}},
    {"id": "8b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e", "title": "Record", "symbol": "record.circle.fill", "color": "#FF375F",
     "action": {"type": "obs", "request": "ToggleRecord", "data": {}}},
    {"id": "9c4d5e6f-7a8b-4c9d-0e1f-2a3b4c5d6e7f", "title": "YouTube", "symbol": "play.rectangle.fill", "color": "#FF0000",
     "action": {"type": "openUrl", "url": "https://www.youtube.com/"}},
    {"id": "0d5e6f7a-8b9c-4d0e-1f2a-3b4c5d6e7f8a", "title": "GG", "symbol": "text.bubble.fill", "color": "#64D2FF",
     "action": {"type": "text", "text": "gg wp"}},
    {"id": "1e6f7a8b-9c0d-4e1f-2a3b-4c5d6e7f8a9b", "title": "Play / Pause", "symbol": "playpause.fill", "color": "#BF5AF2",
     "action": {"type": "media", "name": "playpause"}},
    {"id": "2f7a8b9c-0d1e-4f2a-3b4c-5d6e7f8a9b0c", "title": "Sleep", "symbol": "moon.fill", "color": "#5E5CE6", "confirm": True,
     "action": {"type": "system", "name": "sleep"}},
    {"id": "3a8b9c0d-1e2f-4a3b-4c5d-6e7f8a9b0c1d", "title": "Clip then restart", "symbol": "arrow.clockwise", "color": "#FF9F0A",
     "confirm": True,
     "action": {"type": "sequence", "delayMs": 300, "steps": [
         {"type": "hotkey", "keys": ["alt", "f10"]}, {"type": "system", "name": "restart"}]}},
]


def contract_fixture():
    buttons = json.loads(json.dumps(SAMPLE_BUTTONS))
    # A field from a future version must survive the Mac's `PUT /api/deck`.
    buttons[0]["futureField"] = {"nested": [1, 2.5, True, None]}
    return {"buttons": buttons, "updatedAt": "2026-10-24T10:00:00Z"}, \
        {"agentVersion": "4.4.0", "features": ["events", "hotkeys", "openUrl", "deck"]}


def agent_fixture(work):
    """The real agent's reply, or None when this checkout's agent has no deck yet."""
    if not (AGENT / "orbit_deck.py").exists():
        return None
    os.environ["LOCALAPPDATA"] = str(work)
    os.environ["APPDATA"] = str(work)
    sys.path.insert(0, str(AGENT))
    from fastapi.testclient import TestClient
    import orbit_agent

    token = "check-only-token-with-more-than-24-characters"
    with patch.object(orbit_agent, "API_TOKEN", token):
        client = TestClient(orbit_agent.app, base_url="https://testserver")
        headers = {"Authorization": f"Bearer {token}"}
        capabilities = client.get("/api/capabilities", headers=headers)
        capabilities.raise_for_status()
        if "deck" not in capabilities.json().get("features", []):
            return None
        saved = client.put("/api/deck", headers=headers, json={"buttons": SAMPLE_BUTTONS})
        if saved.status_code == 422:
            # The contract leaves open whether a sequence may end with a power step; try without it.
            print(f"The agent refused a sequence with a restart step ({saved.json().get('detail')}); retrying without it.")
            simple = [button for button in SAMPLE_BUTTONS if button["action"]["type"] != "sequence"]
            saved = client.put("/api/deck", headers=headers, json={"buttons": simple})
        if saved.status_code >= 400:
            raise SystemExit(f"PUT /api/deck refused the contract sample: {saved.status_code} {saved.text}")
        deck = client.get("/api/deck", headers=headers)
        deck.raise_for_status()
        return deck.json(), capabilities.json()


with tempfile.TemporaryDirectory(prefix="orbit-remote-deck-") as directory:
    work = Path(directory)
    fixture = agent_fixture(work)
    source = "the agent in this checkout"
    if fixture is None:
        fixture = contract_fixture()
        source = "the DESIGN contract fixture (this checkout's agent has no deck yet)"
    deck_path = work / "deck.json"
    capabilities_path = work / "capabilities.json"
    deck_path.write_text(json.dumps(fixture[0]))
    capabilities_path.write_text(json.dumps(fixture[1]))
    binary = work / "remote-deck-tests"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library",
        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"),
        str(ROOT / "Orbit-iOS/Shared/OrbitRemoteDeck.swift"),
        str(ROOT / "Orbit-iOS/Orbit/OrbitWatchDeckSync.swift"),
        str(ROOT / "Orbit-iOS/Tests/OrbitRemoteDeckTests.swift"),
        "-o", str(binary),
    ], check=True)
    print(f"Deck from {source}.", flush=True)
    subprocess.run([str(binary), str(deck_path), str(capabilities_path)], check=True, timeout=60)
