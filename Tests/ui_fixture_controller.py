"""UI QA only: owns fixtures, never controls an existing process."""
import json
import pathlib
import subprocess
import time

root = pathlib.Path(__file__).resolve().parent
children = []
state = []
try:
    for mode, count in [("normal", 2), ("ignore-term", 1)]:
        child = subprocess.Popen([str(root / ".build/test_listener"), mode, str(count)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True)
        children.append(child)
        item = json.loads(child.stdout.readline())
        assert item["pid"] == child.pid
        item["mode"] = mode
        state.append(item)
    (root / "ui_fixture_state.json").write_text(json.dumps(state), encoding="utf-8")
    print(json.dumps(state), flush=True)
    deadline = time.monotonic() + 170
    while time.monotonic() < deadline and any(child.poll() is None for child in children):
        time.sleep(0.1)
finally:
    for child in children:
        if child.stdin:
            child.stdin.close()
        child.wait(timeout=3)
    print("UI-owned fixtures cleaned up", flush=True)
