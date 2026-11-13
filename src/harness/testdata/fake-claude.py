#!/usr/bin/env python3
"""A stand-in for `claude -p --input-format stream-json --output-format
stream-json` that replays a recorded trace, so the claude-code adapter is
tested end to end without the real binary (no model turns, no sign-in).

    fake-claude [claude flags…] --fake-trace TRACE.json --fake-replies DIR

TRACE.json is {"turns": [[item, …], …]}. Each user line on stdin plays the
next turn; an item is a stream-json object printed as one line ("$SESSION"
in strings becomes the session id), or {"$await": ID, "allow": […],
"deny": […]}: wait for venom's permission result in DIR/ID (what venom's MCP
server would return for the permission prompt) and play the branch its
"behavior" picks. A message `$run: CMD` first runs CMD in a shell, as the
agent's own Bash would, with this process's token. End of stdin exits 0. It also records its argv in
DIR/argv.json (appending to DIR/argv.log, one start per line).

Without -p it plays Claude Code's own TUI on `--resume ID` (take-over):
each line typed is a prompt that runs one turn (a Bash call and
an answer); `/exit` or end of input quits. `/hook NAME [TYPE]` runs what
`--settings` says for hook NAME, with Claude Code's JSON on stdin, and prints
`hook NAME exit N`. It records its environment's VENOM_* variables
in CLAUDE_CONFIG_DIR/tui-env.json. With CLAUDE_CONFIG_DIR set, both
modes append their turns to the session transcript Claude Code would keep,
CLAUDE_CONFIG_DIR/projects/<cwd, non-alphanumerics as '-'>/<ID>.jsonl.
"""
import datetime, json, os, re, subprocess, sys, time, uuid

args = sys.argv[1:]

def opt(name):
    return args[args.index(name) + 1] if name in args else None

session = opt("--session-id") or opt("--resume")

def record(lines):
    """Appends transcript lines, stamped now, as Claude Code would."""
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    if not config:
        return
    project = os.path.join(config, "projects", re.sub(r"[^a-zA-Z0-9]", "-", os.getcwd()))
    os.makedirs(project, exist_ok=True)
    with open(os.path.join(project, session + ".jsonl"), "a") as f:
        for line in lines:
            now = datetime.datetime.now(datetime.timezone.utc)
            line = dict(line, uuid=str(uuid.uuid4()), sessionId=session, cwd=os.getcwd(),
                        timestamp=now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000))
            f.write(json.dumps(line) + "\n")

def run_hook(event, notification):
    """Runs the hooks `--settings` has for `event`, as Claude Code would."""
    config = os.environ.get("CLAUDE_CONFIG_DIR", "")
    project = os.path.join(config, "projects", re.sub(r"[^a-zA-Z0-9]", "-", os.getcwd()))
    data = {"session_id": session, "transcript_path": os.path.join(project, session + ".jsonl"), "cwd": os.getcwd(), "hook_event_name": event}
    if notification:
        data.update(notification_type=notification, message="Claude needs your permission to use Bash" if notification == "permission_prompt" else "Claude is waiting for your input")
    settings = json.loads(opt("--settings") or "{}")
    status = "none"
    for group in settings.get("hooks", {}).get(event, []):
        if notification and notification not in group.get("matcher", "").split("|"):
            continue
        for hook in group["hooks"]:
            done = subprocess.run(hook["command"], shell=True, input=json.dumps(data).encode(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            status = str(done.returncode)
            if done.stdout:
                sys.stdout.write(done.stdout.decode().replace("\n", "\r\n"))
    sys.stdout.write("hook %s exit %s\r\n> " % (event, status))
    sys.stdout.flush()

def tui():
    n = 0
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    if config:
        os.makedirs(config, exist_ok=True)
        with open(os.path.join(config, "tui-env.json"), "w") as f:
            json.dump({k: v for k, v in os.environ.items() if k.startswith("VENOM_")}, f)
    sys.stdout.write("fake-claude TUI on %s\r\n> " % session)
    sys.stdout.flush()
    for line in sys.stdin:
        text = line.strip()
        if text == "/exit":
            break
        if not text:
            continue
        if text.startswith("/hook "):
            parts = text.split()
            run_hook(parts[1], parts[2] if len(parts) > 2 else None)
            continue
        n += 1
        tool = "toolu_tui%d" % n
        usage = {"input_tokens": 40, "output_tokens": 12, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 500}
        record([
            {"type": "user", "message": {"role": "user", "content": text}},
            {"type": "assistant", "message": {"id": "msg_tui%da" % n, "model": "claude-opus-4-7", "role": "assistant", "content": [{"type": "tool_use", "id": tool, "name": "Bash", "input": {"command": "git status"}}], "usage": usage}},
            {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool, "content": "clean", "is_error": False}]}},
            {"type": "assistant", "message": {"id": "msg_tui%db" % n, "model": "claude-opus-4-7", "role": "assistant", "content": [{"type": "text", "text": "Done: " + text}], "usage": {"input_tokens": 2, "output_tokens": 30}}},
        ])
        sys.stdout.write("Done: %s\r\n> " % text)
        sys.stdout.flush()
    sys.exit(0)

if "-p" not in args and "--print" not in args:
    tui()

trace = json.load(open(opt("--fake-trace")))
replies = opt("--fake-replies")
with open(os.path.join(replies, "argv.json"), "w") as f:
    json.dump(args, f)
with open(os.path.join(replies, "argv.log"), "a") as f:
    f.write(json.dumps(args) + "\n")

def sub(v):
    if isinstance(v, str):
        return v.replace("$SESSION", session)
    if isinstance(v, list):
        return [sub(x) for x in v]
    if isinstance(v, dict):
        return {k: sub(x) for k, x in v.items()}
    return v

def play(items):
    for item in items:
        if "$await" in item:
            path = os.path.join(replies, item["$await"])
            deadline = time.time() + 10
            while not os.path.exists(path):
                if time.time() > deadline:
                    sys.stderr.write("fake-claude: no permission result\n")
                    sys.exit(3)
                time.sleep(0.01)
            result = json.load(open(path))
            play(item["allow"] if result.get("behavior") == "allow" else item["deny"])
        else:
            sys.stdout.write(json.dumps(sub(item)) + "\n")
            sys.stdout.flush()

turn = 0
for line in sys.stdin:
    if not line.strip():
        continue
    msg = json.loads(line)
    if msg.get("type") != "user":
        continue
    content = msg.get("message", {}).get("content", "")
    if isinstance(content, str) and content.startswith("$run: "):
        subprocess.run(content[6:], shell=True)  # as the harness's own Bash would
    turns = trace["turns"]
    play(turns[turn] if turn < len(turns) else [{"type": "result", "subtype": "success", "is_error": False, "session_id": "$SESSION"}])
    turn += 1
    # What protocol mode leaves in the transcript (venom logged it already).
    record([
        {"type": "user", "message": {"role": "user", "content": msg.get("message", {}).get("content", "")}},
        {"type": "assistant", "message": {"id": "msg_p%d" % turn, "model": "claude-opus-4-7", "role": "assistant", "content": [{"type": "text", "text": "(protocol turn)"}], "usage": {"input_tokens": 999, "output_tokens": 999}}},
    ])
