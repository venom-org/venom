#!/usr/bin/env python3
"""A stand-in for claude-code or codex that does with venom's MCP config
what the real harness does, without any model or sign-in:

    fake_mcp_harness.py [harness flags…] --fake-mode claude|codex|claude-approve|codex-approve --fake-out FILE

On every turn it starts the `venom` MCP server venom configured, the way
that harness would, calls the `agent_dlist` tool once, and appends the
tool result (one JSON line) to FILE.

* claude: reads `--mcp-config` JSON; the server gets this process's
  environment plus the entry's `env` (Claude Code's behavior for stdio
  servers). Speaks just enough stream-json: `system/init`, then `result`.
* codex: reads the `-c mcp_servers.venom.*` overrides; the server gets only
  a few default variables, plus `env_vars` taken from this process and the
  `env` table (Codex's behavior). Speaks just enough app-server JSON-RPC:
  `initialize`, `thread/start`, `turn/start`, `turn/started`,
  `turn/completed`.

* claude-approve: a Claude Code turn that asks to run a Bash
  command: `tool_use`, then the `permission_prompt` call on the
  `venom-permissions` server from `--mcp-config` (named by
  `--permission-prompt-tool`), held open until venom answers, then the
  `tool_result` (an error unless the answer allows it) and `result`. It
  appends `{"tools": <tools/list>, "result": <tools/call result>}` to FILE.

* claude-calls: a Claude Code turn whose prompt is a JSON plan:
  `{"id": …, "calls": [{"tool": …, "args": {…}}], "hold": PATH, "fail": bool}`.
  It makes the MCP calls over venom's server, appends `{"id": …, "results":
  […]}` to FILE, waits for PATH to exist (or SIGINT), then ends the turn,
  with an error when `fail`. It also appends its argv to FILE.argvs.
  `"then": [calls]` run after the hold (a stop's SIGINT included), results
  under id + ":then"; `"after_end": [calls]` run once the turn has ended,
  results under id + ":end". `--fake-start-hold` waits for FILE.start before
  reading anything; `--fake-ignore-term` ignores SIGTERM (it ends at end of
  stdin), and FILE.argvs existing means that is already in place.

* codex-approve: a Codex app-server turn that asks to run a
  command: `item/commandExecution/requestApproval`, held until venom
  answers, then the command item and `turn/completed`. It appends
  `{"approval": <venom's response>}` to FILE.

It records its argv, the environment variable names it was given and the
values of CLAUDE_CONFIG_DIR and CODEX_HOME in
FILE.argv.json, so tests can check that no token is in argv.
"""
import json, os, re, signal, subprocess, sys, time

args = sys.argv[1:]


def active_profile(msg):
    """Reports a `default_permissions` profile as active, as Codex does."""
    profile = (msg.get("params", {}).get("config") or {}).get("default_permissions")
    return {"activePermissionProfile": {"id": profile, "extends": None}} if profile else {}


def opt(name):
    return args[args.index(name) + 1] if name in args else None


mode = opt("--fake-mode")
out = opt("--fake-out")
with open(out + ".argv.json", "w") as f:
    # Names only, but the config folders' values too: they hold no secret.
    homes = {k: os.environ[k] for k in ("CLAUDE_CONFIG_DIR", "CODEX_HOME") if k in os.environ}
    json.dump({"argv": args, "env": sorted(os.environ), "homes": homes}, f)


def server_claude(name="venom"):
    cfg = json.loads(opt("--mcp-config"))["mcpServers"][name]
    env = dict(os.environ)
    env.update(cfg.get("env", {}))
    return cfg["command"], cfg.get("args", []), env


CODEX_DEFAULT_ENV = ["HOME", "LOGNAME", "PATH", "SHELL", "USER", "LANG", "LC_ALL", "TERM", "TMPDIR", "TZ"]


def server_codex():
    o = {}
    for i, a in enumerate(args):
        if a == "-c" and i + 1 < len(args):
            k, _, v = args[i + 1].partition("=")
            if k.startswith("mcp_servers.venom."):
                o[k[len("mcp_servers.venom."):]] = v
    env = {k: os.environ[k] for k in CODEX_DEFAULT_ENV if k in os.environ}
    for name in json.loads(o.get("env_vars", "[]")):
        if name in os.environ:
            env[name] = os.environ[name]
    if "env" in o:
        for k, v in re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*")', o["env"]):
            env[k] = json.loads(v)
    return json.loads(o["command"]), json.loads(o.get("args", "[]")), env


def call_tool():
    command, cargs, env = server_claude() if mode == "claude" else server_codex()
    lines = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-" + mode, "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "agent_dlist", "arguments": {}}},
    ]
    p = subprocess.run([command] + cargs, input="".join(json.dumps(l) + "\n" for l in lines), capture_output=True, text=True, env=env, timeout=30)
    result = {"error": "no response", "stderr": p.stderr[-2000:]}
    for line in p.stdout.splitlines():
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("id") == 2:
            result = msg.get("result", msg)
    with open(out, "a") as f:
        f.write(json.dumps(result) + "\n")


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def claude():
    session = opt("--session-id") or opt("--resume")
    for line in sys.stdin:
        if not line.strip() or json.loads(line).get("type") != "user":
            continue
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "fake", "claude_code_version": "2.1.319"})
        call_tool()
        emit({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "message": {"role": "assistant", "content": [{"type": "text", "text": "listed"}]}})
        emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session})


def codex():
    turns = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            emit({"id": mid, "result": {"userAgent": "codex_cli_rs/0.167.0 (fake)"}})
        elif method == "thread/start":
            with open(out + ".threads", "a") as f:
                f.write(json.dumps(msg.get("params", {})) + "\n")
            emit({"id": mid, "result": dict(active_profile(msg), thread={"id": "thr_fake"}, model="fake")})
            emit({"method": "thread/started", "params": {"thread": {"id": "thr_fake"}}})
        elif method == "thread/resume":
            emit({"id": mid, "result": dict(active_profile(msg), thread={"id": "thr_fake"}, model="fake")})
        elif method == "turn/start":
            turns += 1
            turn = {"id": "turn_%d" % turns, "status": "inProgress", "items": []}
            emit({"id": mid, "result": {"turn": turn}})
            emit({"method": "turn/started", "params": {"threadId": "thr_fake", "turn": turn}})
            call_tool()
            emit({"method": "turn/completed", "params": {"threadId": "thr_fake", "turn": dict(turn, status="completed", error=None)}})
        elif mid is not None and method is not None:
            emit({"id": mid, "error": {"code": -32601, "message": "not in the fake"}})


def mcp_calls(calls):
    command, cargs, env = server_claude()
    lines = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-claude", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
    ]
    for i, c in enumerate(calls):
        lines.append({"jsonrpc": "2.0", "id": i + 2, "method": "tools/call", "params": {"name": c["tool"], "arguments": c.get("args", {})}})
    # Stays open until every answer is in: a held call answers late.
    p = subprocess.Popen([command] + cargs, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    p.stdin.write("".join(json.dumps(l) + "\n" for l in lines))
    p.stdin.flush()
    got = {}
    for line in p.stdout:
        if not line.strip():
            continue
        msg = json.loads(line)
        got[msg.get("id")] = msg.get("result", msg)
        if all(i + 2 in got for i in range(len(calls))):
            break
    p.stdin.close()
    p.wait(timeout=30)
    return [got.get(i + 2) for i in range(len(calls))]


def claude_calls():
    interrupted = [False]
    signal.signal(signal.SIGINT, lambda *_: interrupted.__setitem__(0, True))
    if "--fake-ignore-term" in args:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(out + ".argvs", "a") as f:
        f.write(json.dumps(args) + "\n")
    if "--fake-start-hold" in args:
        deadline = time.monotonic() + 60
        while not os.path.exists(out + ".start") and time.monotonic() < deadline:
            time.sleep(0.02)
    session = opt("--session-id") or opt("--resume")
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("type") != "user":
            continue
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "fake", "claude_code_version": "2.1.319"})
        plan = json.loads(msg["message"]["content"])
        results = mcp_calls(plan["calls"]) if plan.get("calls") else []
        with open(out, "a") as f:
            f.write(json.dumps({"id": plan.get("id"), "results": results}) + "\n")
        deadline = time.monotonic() + 60
        interrupted[0] = False
        while plan.get("hold") and not os.path.exists(plan["hold"]) and not interrupted[0] and time.monotonic() < deadline:
            time.sleep(0.02)
        def record(key, suffix):
            if plan.get(key):
                results = mcp_calls(plan[key])
                with open(out, "a") as f:
                    f.write(json.dumps({"id": plan.get("id") + suffix, "results": results}) + "\n")
        record("then", ":then")
        failed = bool(plan.get("fail"))
        emit({"type": "result", "subtype": "error_during_execution" if failed else "success", "is_error": failed, "session_id": session})
        time.sleep(0.2 if plan.get("after_end") else 0)
        record("after_end", ":end")


def codex_approve():
    turns, pending, approval_id = 0, None, 100
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if method is None and mid is not None and pending and mid == pending["id"]:
            # venom's answer to the approval request
            with open(out, "a") as f:
                f.write(json.dumps({"approval": msg}) + "\n")
            decision = msg.get("result", {}).get("decision")
            allowed = decision == "accept"
            turn, item = pending["turn"], pending["item"]
            emit({"method": "serverRequest/resolved", "params": {"threadId": "thr_fake", "requestId": mid}})
            emit({"method": "item/completed", "params": {"threadId": "thr_fake", "turnId": turn["id"], "item": dict(item, status="completed" if allowed else "declined", exitCode=0 if allowed else None, aggregatedOutput="venom-%d\n" % turns if allowed else "")}})
            emit({"method": "item/completed", "params": {"threadId": "thr_fake", "turnId": turn["id"], "item": {"type": "agentMessage", "id": "msg_%d" % turns, "text": "ran it" if allowed else "not allowed", "phase": None}}})
            emit({"method": "turn/completed", "params": {"threadId": "thr_fake", "turn": dict(turn, status="completed", error=None)}})
            pending = None
        elif method == "initialize":
            emit({"id": mid, "result": {"userAgent": "codex_cli_rs/0.167.0 (fake)"}})
        elif method == "thread/start" or method == "thread/resume":
            cwd = msg.get("params", {}).get("cwd") or os.getcwd()
            emit({"id": mid, "result": dict(active_profile(msg), thread={"id": "thr_fake"}, model="fake", cwd=cwd)})
            if method == "thread/start":
                emit({"method": "thread/started", "params": {"thread": {"id": "thr_fake"}}})
        elif method == "turn/start":
            turns += 1
            approval_id += 1
            turn = {"id": "turn_%d" % turns, "status": "inProgress", "items": []}
            command = "echo venom-%d" % turns
            item = {"type": "commandExecution", "id": "item_%d" % turns, "command": command, "cwd": os.getcwd(), "status": "inProgress", "commandActions": [{"type": "unknown", "command": command}]}
            emit({"id": mid, "result": {"turn": turn}})
            emit({"method": "turn/started", "params": {"threadId": "thr_fake", "turn": turn}})
            emit({"method": "item/started", "params": {"threadId": "thr_fake", "turnId": turn["id"], "item": item}})
            pending = {"id": approval_id, "turn": turn, "item": item}
            emit({"method": "item/commandExecution/requestApproval", "id": approval_id, "params": {"kind": "command", "threadId": "thr_fake", "turnId": turn["id"], "itemId": item["id"], "startedAtMs": 1794052800000, "environmentId": None, "command": command, "cwd": os.getcwd()}})
        elif mid is not None and method is not None:
            emit({"id": mid, "error": {"code": -32601, "message": "not in the fake"}})


def prompt(tool_name, tool_input, tool_use_id):
    """Claude Code's side of --permission-prompt-tool: one MCP session with
    the prompt server, its stdin open until the answer arrives."""
    tool = opt("--permission-prompt-tool")
    _, server, name = tool.split("__", 2)
    command, cargs, env = server_claude(server)
    p = subprocess.Popen([command] + cargs, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    def send(obj):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-claude", "version": "0"}}})
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": {"tool_name": tool_name, "input": tool_input, "tool_use_id": tool_use_id}}})
    got = {}
    for line in p.stdout:
        if not line.strip():
            continue
        msg = json.loads(line)
        got[msg.get("id")] = msg.get("result", msg)
        if 3 in got:
            break
    p.stdin.close()
    p.wait(timeout=30)
    return got.get(2), got.get(3)


def claude_approve():
    session = opt("--session-id") or opt("--resume")
    n = 0
    for line in sys.stdin:
        if not line.strip() or json.loads(line).get("type") != "user":
            continue
        n += 1
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "fake", "claude_code_version": "2.1.319"})
        tid, inp = "toolu_%d" % n, {"command": "echo venom-%d" % n}
        emit({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "message": {"role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": inp}]}})
        tools, result = prompt("Bash", inp, tid)
        with open(out, "a") as f:
            f.write(json.dumps({"tools": tools, "result": result}) + "\n")
        try:
            allowed = json.loads(result["content"][0]["text"])["behavior"] == "allow"
        except Exception:
            allowed = False
        emit({"type": "user", "session_id": session, "parent_tool_use_id": None, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": "venom-%d" % n if allowed else "denied", "is_error": not allowed}]}})
        emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session})


{"claude": claude, "codex": codex, "claude-calls": claude_calls, "claude-approve": claude_approve, "codex-approve": codex_approve}[mode]()
