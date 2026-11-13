#!/usr/bin/env python3
"""A fake `codex app-server` for venom's codex adapter tests.

It replays a hand-written JSON-RPC trace over stdio, so tests never run a
real Codex turn (no quota, no sign-in). Usage:

    codex_app_server.py TRACE CWD STATE_DIR

TRACE is a text file, one message per line:

    # comment
    > {...}      venom -> app-server: the next line venom writes must match
    < {...}      app-server -> venom: written as is
    ! exit N     exit with code N now
    ? gate NAME  wait until the file STATE_DIR/NAME exists (a harness that
                 has not answered yet, for as long as the test wants)
    === process  starts the trace of the next process (reattach)

A `>` line matches when every member it names is equal in what venom wrote
(objects are compared as subsets, arrays element by element). The `id` of a
`>` request is not compared: the id venom used replaces it in the `<`
responses that carry the trace's id. `$CWD` is replaced by CWD everywhere.

The process picks its section of the trace with a counter in STATE_DIR
(first start: section 0), appends every line it reads to
STATE_DIR/received.<n>.jsonl, and after the last line waits for end of
input, then exits 0, like the real app-server between turns.
"""
import json
import os
import sys
import time


def subset(want, got):
    if isinstance(want, dict):
        return isinstance(got, dict) and all(k in got and subset(v, got[k]) for k, v in want.items())
    if isinstance(want, list):
        return isinstance(got, list) and len(want) == len(got) and all(subset(w, g) for w, g in zip(want, got))
    return want == got


def main():
    trace_path, cwd, state_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    counter = os.path.join(state_dir, "codex-starts")
    n = int(open(counter).read()) if os.path.exists(counter) else 0
    with open(counter, "w") as f:
        f.write(str(n + 1))
    with open(trace_path) as f:
        sections = f.read().replace("$CWD", cwd).split("=== process")
    lines = sections[n].splitlines() if n < len(sections) else []
    received = open(os.path.join(state_dir, "received.%d.jsonl" % n), "a")
    ids = {}

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("! exit"):
            sys.exit(int(line.split()[2]))
        if line.startswith("? gate"):
            while not os.path.exists(os.path.join(state_dir, line.split()[2])):
                time.sleep(0.01)
            continue
        if line.startswith(">"):
            want = json.loads(line[1:])
            got_line = sys.stdin.readline()
            if not got_line:
                sys.stderr.write("trace: end of input, expected %s\n" % line)
                sys.exit(4)
            received.write(got_line)
            received.flush()
            got = json.loads(got_line)
            if "method" in want and "id" in want:
                ids[want["id"]] = got.get("id")
                want = {k: v for k, v in want.items() if k != "id"}
            if not subset(want, got):
                sys.stderr.write("trace mismatch: expected %s, got %s\n" % (line, got_line.strip()))
                sys.exit(3)
        elif line.startswith("<"):
            msg = json.loads(line[1:])
            if "method" not in msg and msg.get("id") in ids:
                msg["id"] = ids[msg["id"]]
            sys.stdout.write(json.dumps(msg, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    for got_line in sys.stdin:
        received.write(got_line)
        received.flush()
    sys.exit(0)


if __name__ == "__main__":
    main()
