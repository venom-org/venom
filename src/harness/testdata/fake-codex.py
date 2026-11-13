#!/usr/bin/env python3
"""A fake `codex` for venom's take-over tests.

    fake-codex app-server        the fake app-server (codex_app_server.py)
                                 on the trace `codex.trace` beside this file
    fake-codex resume ID [-c notify=[...]]
                                 Codex's own TUI: "runs" a turn by putting
                                 `native.jsonl` in place as the rollout, then
                                 reads commands from stdin until /exit or end
                                 of input. `/turn-end` runs the notify program
                                 the way Codex does, its JSON as the last
                                 argument.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(__file__))


def main():
    if sys.argv[1] == "app-server":
        script = os.path.join(HERE, "codex_app_server.py")
        trace = os.path.join(HERE, "codex.trace")
        os.execv(sys.executable, [sys.executable, script, trace, HERE, HERE])
    assert sys.argv[1] == "resume"
    notify = None
    for arg in sys.argv[3:]:
        if arg.startswith("notify="):
            notify = json.loads(arg[len("notify="):])
    native = os.path.join(HERE, "native.jsonl")
    if os.path.exists(native):
        shutil.copy(native, os.path.join(HERE, "rollout.jsonl"))
    print("resumed " + sys.argv[2], flush=True)
    for line in sys.stdin:
        command = line.strip()
        if command == "/exit":
            break
        if command == "/turn-end":
            payload = json.dumps({"type": "agent-turn-complete", "thread-id": sys.argv[2], "turn-id": "turn_2", "cwd": os.getcwd()})
            code = subprocess.run(notify + [payload]).returncode
            print("notify exit %d" % code, flush=True)


if __name__ == "__main__":
    main()
