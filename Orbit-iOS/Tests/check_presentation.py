"""Check the presentation remote's Swift models against the real agent module.

Compiles `Shared/OrbitPresentationModels.swift` with `Tests/OrbitPresentationTests.swift` (which also checks
the talk timer, the Watch's saved timer and reminder plan, demo mode and lenient decoding) and feeds it
replies made by `orbit_presentation.py`'s own router: a fake PowerPoint (the agent's test fakes from
`test_presentation.py`) in every state the app shows,
key presses, refusals (409, 422, 503), an older agent's 404, plain HTTP's 426 and a wrong token's 401. Then
checks that the action names the iPhone, the Watch and Shortcuts send exist in the agent.

Mocked Windows only: no server is started, nothing is pressed, no PC is contacted.
Run with the venv python (needs fastapi and httpx): python3 Orbit-iOS/Tests/check_presentation.py
"""
import json
import logging
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / 'Orbit-Windows-Agent'
sys.path.insert(0, str(AGENT))
logging.disable(logging.CRITICAL)

import orbit_agent as agent  # noqa: E402
import orbit_presentation as presentation  # noqa: E402
import test_presentation as fakes  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

TOKEN = 'check-presentation-token-0123456789abcdef'


def scenario():
    case = fakes.PresentationTestCase(methodName='setUp')
    case.setUp()
    return case


def get(case, expect=200):
    response = case.client.get('/api/presentation')
    assert response.status_code == expect, response.text
    return response.json()


def post(case, action, body=None, expect=200):
    response = case.client.post(f'/api/presentation/{action}', json=body) if body is not None \
        else case.client.post(f'/api/presentation/{action}')
    assert response.status_code == expect, (action, response.status_code, response.text)
    return response


states, replies, errors = {}, {}, {}

# PowerPoint closed, a browser in front: keys.
case = scenario()
case.com.ppt = None
states['closed'] = get(case)
replies['keysNext'] = post(case, 'next').json()
assert case.pressed == ['right'], case.pressed
# PowerPoint in front but not visible over COM yet (its window never lost focus): blocked, no deck to show.
case.foreground = 'powerpnt.exe'
states['frontNoCOM'] = get(case)
case.doCleanups()

# A deck in PowerPoint's editor with PowerPoint in front: blocked, next is refused.
case = scenario()
case.ppt.editor = 4
case.foreground = 'powerpnt.exe'
states['editorBlocked'] = get(case)
response = post(case, 'next', expect=409)
errors['blockedNext'] = {'status': 409, 'body': response.text}
assert case.pressed == []
# The same deck with a browser in front: keys go to the browser.
case.foreground = 'chrome.exe'
states['editorKeys'] = get(case)
replies['keysWithDeck'] = post(case, 'next').json()
# PowerPoint in front again: Start runs the show over COM.
case.foreground = 'powerpnt.exe'
replies['start'] = post(case, 'start').json()
states['running'] = get(case)
replies['next'] = post(case, 'next').json()
replies['black'] = post(case, 'black').json()
states['black'] = get(case)
replies['blackAgain'] = post(case, 'black').json()
response = post(case, 'goto', {'slide': 13}, expect=422)
errors['gotoPastEnd'] = {'status': 422, 'body': response.text}
response = post(case, 'goto', expect=422)
errors['gotoNoSlide'] = {'status': 422, 'body': response.text}
response = post(case, 'goto', {'slide': 'x'}, expect=422)
errors['gotoBadBody'] = {'status': 422, 'body': response.text}
replies['goto'] = post(case, 'goto', {'slide': 7}).json()
response = post(case, 'fly', expect=404)
errors['unknownAction'] = {'status': 404, 'body': response.text}
post(case, 'last')
replies['nextAtEnd'] = post(case, 'next').json()
states['done'] = get(case)
# PowerPoint stays busy: 503 with a sentence (and Retry-After).
case.ppt.fault('GetActiveObject', lambda: fakes.FakeCOMError(fakes.CALL_REJECTED, 'Call was rejected by callee.'), times=None)
response = case.client.get('/api/presentation')
assert response.status_code == 503 and response.headers.get('retry-after'), response.text
errors['busy'] = {'status': 503, 'body': response.text}
case.ppt.faults.clear()
replies['end'] = post(case, 'end').json()
states['ended'] = get(case)
case.doCleanups()

# The real agent: older agents have no route (FastAPI's bare 404), plain HTTP gets 426, a wrong token 401.
older = TestClient(FastAPI())
response = older.get('/api/presentation')
errors['olderAgent'] = {'status': response.status_code, 'body': response.text}
with patch.object(agent, 'API_TOKEN', TOKEN):
    plain = TestClient(agent.app, base_url='http://testserver')
    response = plain.get('/api/presentation', headers={'Authorization': f'Bearer {TOKEN}'})
    errors['insecure'] = {'status': response.status_code, 'body': response.text}
    secure = TestClient(agent.app, base_url='https://testserver')
    response = secure.post('/api/presentation/next', headers={'Authorization': 'Bearer wrong'})
    errors['unauthorized'] = {'status': response.status_code, 'body': response.text}
    capabilities = agent.get_capabilities(f'Bearer {TOKEN}')
assert errors['olderAgent']['status'] == 404 and errors['insecure']['status'] == 426 and errors['unauthorized']['status'] == 401, errors
assert 'presentation' in capabilities['features'], capabilities

with tempfile.TemporaryDirectory(prefix='orbit-presentation-check-') as directory:
    root = Path(directory)
    (root / 'input.json').write_text(json.dumps({'states': states, 'replies': replies, 'errors': errors}))
    binary = root / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library',
                    str(ROOT / 'Orbit-iOS/Shared/OrbitPresentationModels.swift'),
                    str(ROOT / 'Orbit-iOS/Tests/OrbitPresentationTests.swift'), '-o', str(binary)], check=True)
    result = json.loads(subprocess.run([str(binary), str(root / 'input.json')], check=True,
                                       stdout=subprocess.PIPE, text=True, timeout=60).stdout)

S, R, E = result['states'], result['replies'], result['errors']

# Action names and bodies.
assert set(result['actions']) == set(presentation.ACTIONS), (result['actions'], presentation.ACTIONS)
assert result['bodies'] == {'goto': '{"slide":7}', 'next': '{}'}, result['bodies']

# States.
assert S['closed']['app'] == 'none' and S['closed']['control'] == 'keys' and not S['closed']['showingSlide'], S['closed']
assert S['closed']['position'] is None and S['closed']['status'] == 'Ready to press keys', S['closed']
assert S['editorBlocked']['control'] == 'blocked' and S['editorBlocked']['blocked'], S['editorBlocked']
assert S['editorBlocked']['readyInEditor'] and S['editorBlocked']['slide'] == 4 and not S['editorBlocked']['running']
assert S['editorBlocked']['status'] == 'Ready in PowerPoint' and S['editorBlocked']['position'] is None
assert S['editorBlocked']['controlTitle'] == 'Start the slide show first'
front = S['frontNoCOM']
assert front['app'] == 'none' and front['control'] == 'blocked' and front['blocked'] and not front['readyInEditor'], front
assert front['status'] == 'PowerPoint in front' and front['position'] is None, front
assert S['editorKeys']['control'] == 'keys' and S['editorKeys']['source'] == 'editor' and not S['editorKeys']['blocked']
assert S['editorKeys']['status'] == 'Ready in PowerPoint' and S['editorKeys']['controlTitle'] == 'Pressing keys on the PC'
running = S['running']
assert running['showingSlide'] and running['position'] == '1 / 12' and running['spoken'] == 'Slide 1 of 12', running
assert running['notes'] == 'Notes for slide 1' and running['slideTitle'] == 'Slide title 1' and running['title'] == 'Quarterly Review'
assert running['elapsed'] == 754 and running['slideElapsed'] == 31 and running['canThumbnail'] and running['control'] == 'powerpoint'
assert running['status'] == 'Slide show running' and running['controlTitle'] == 'Controlling PowerPoint'
assert S['black']['state'] == 'black' and S['black']['showingSlide'] and not S['black']['canThumbnail'], S['black']
assert S['black']['status'] == 'Screen is black'
done = S['done']
assert done['state'] == 'done' and done['running'] and not done['showingSlide'] and done['position'] is None, done
assert done['notes'] == '' and done['status'] == 'End of slide show' and done['slide'] == 12 and done['slideElapsed'] is None
assert not S['ended']['running'] and S['ended']['source'] == 'editor', S['ended']

# Replies.
assert R['keysNext']['via'] == 'keys' and R['keysNext']['keys'] == ['Right'] and R['keysNext']['usedKeys'], R['keysNext']
assert R['keysNext']['presentation']['app'] == 'none'
assert R['keysNext']['intent'] == 'Pressed Right on the PC. Keys go to the window in front.', R['keysNext']['intent']
assert R['keysWithDeck']['via'] == 'keys' and R['keysWithDeck']['presentation']['source'] == 'editor'
assert R['start']['via'] == 'powerpoint' and R['start']['keys'] == [] and R['start']['presentation']['running'], R['start']
assert R['next']['presentation']['slide'] == 2 and R['next']['intent'] == 'Went to the next slide. Slide 2 of 12.', R['next']
assert R['black']['presentation']['state'] == 'black' and 'Press Black again' in R['black']['detail'], R['black']
assert R['blackAgain']['detail'] == 'Showing the slide again.' and R['blackAgain']['presentation']['state'] == 'running'
assert R['goto']['presentation']['slide'] == 7 and R['goto']['intent'] == 'Went to slide 7. Slide 7 of 12.', R['goto']
assert R['nextAtEnd']['presentation']['state'] == 'done' and R['nextAtEnd']['intent'] == 'Went to the next slide.', R['nextAtEnd']
assert R['end']['presentation']['running'] is False and R['end']['intent'] == 'Ended the slide show.', R['end']

# Errors in plain words.
assert E['blockedNext'] == presentation.NO_SHOW, E['blockedNext']
assert E['gotoPastEnd'] == 'This presentation has 12 slides. Choose a slide from 1 to 12.', E['gotoPastEnd']
assert E['gotoNoSlide'] == presentation.GOTO_NEEDS_SLIDE, E['gotoNoSlide']
assert E['gotoBadBody'] == 'The PC refused that slide number. Choose a slide from the presentation.', E['gotoBadBody']
assert E['unknownAction'] == presentation.UNKNOWN_ACTION, E['unknownAction']
assert E['busy'] == presentation.BUSY, E['busy']
assert 'newer Orbit agent' in E['olderAgent'], E['olderAgent']
assert "encrypted connection" in E['insecure'], E['insecure']
assert 'access key' in E['unauthorized'], E['unauthorized']

# What the other clients send.
intents = (ROOT / 'Orbit-iOS/Shared/OrbitPresentationIntents.swift').read_text()
cases = re.search(r'enum OrbitPresentationIntentAction[^{]*\{\s*case ([^\n]+)', intents).group(1)
intent_actions = {name.strip() for name in cases.split(',')}
assert intent_actions == set(presentation.ACTIONS) - {'goto'}, intent_actions
watch_http = (ROOT / 'Orbit-iOS/Shared/OrbitWatchHTTPClient.swift').read_text()
watch_set = re.search(r'presentationActions: Set<String> = \[([^\]]+)\]', watch_http).group(1)
assert set(re.findall(r'"(\w+)"', watch_set)) == set(presentation.ACTIONS), watch_set
relay = (ROOT / 'Orbit-iOS/Orbit/OrbitWatchPresentationRelay.swift').read_text()
watch = (ROOT / 'Orbit-iOS/OrbitWatch/OrbitWatchPresentation.swift').read_text()
bridge = (ROOT / 'Orbit-iOS/Orbit/OrbitWatchBridge.swift').read_text()
assert 'static let command = "presentation"' in relay and '"cmd": "presentation"' in watch
assert 'static let stateAction = "state"' in relay and 'relayPresentation("state"' in watch
assert bridge.count('OrbitWatchPresentationRelay.command') >= 2, 'bridge must dispatch and forward the presentation command'
shortcuts = (ROOT / 'Orbit-iOS/Orbit/OrbitApp.swift').read_text()
assert shortcuts.count('AppShortcut(') <= 10, 'Apple allows at most 10 App Shortcuts'

print(f"PASS: presentation remote models against orbit_presentation ({len(states)} states, {len(replies)} replies, "
      f"{len(errors)} errors), timer, saved timer, reminder plan, demo deck, lenient decoding, Shortcuts/Watch/relay action names")
