#!/usr/bin/env python3
"""The owner-file chain, end to end.

    scripts/owner_chain_test.py [--venom zig-out/bin/venom] [--venomx ../venomx/zig-out/bin/venomx] [--keep]

Starts its own `venom serve` and `venomx serve` with every XDG directory under
a temp root, so it never sees the user's daemons. The harness is the fake one
behind a wrapper: the wrapper is a real agent process, a child of `venom serve`
with the agent's credential, and it runs this script's probe before it execs
the harness.

The chain: an agent reads venomx's owner file, splits a pane with it, and that
pane's process reads venom's owner file. Every link must be refused:

1. the agent, and a double-forked descendant of it, get `owner_context` from
   venomx and from venom;
2. with no owner token it cannot split a pane;
3. a process in a pane the human made gets `owner_context` from venom while
   venomx's isolation is on, when venomx marks itself as a manager; with it
   off (venomx's default) that pane is the human's terminal and gets `owner`
   on venom, and still `owner_context` on venomx;
4. the human's ways in still work: outside every tree `@owner` gives `owner`,
   and in a pane a token issued from outside gives that token's rights;
5. an own-mode TUI's shell split and take-over are refused too, in the
   foreground, after a double fork, and as a job whose parent shell exited;
6. host mode binds a principal to the control pane's process: no credential in
   its environment or its agent view's, and it keeps working past where a token
   would have expired and across a daemon restart, a kill -9 included. It is that
   process's alone: a shell or take-over harness below a bound view is `unknown`,
   and can't answer another agent's approval or bind anything;
7. when a token the human chose ends, by revocation or expiry, idle or busy, the
   TUI says so, and its agents outlive it;
8. a forged marker does deny the human's `@owner`, and `doctor` reports it.

Exit status 0 when it passed. Every wait is bounded.
"""
import argparse
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import host_demo  # noqa: E402
import demo as e2e  # noqa: E402

Failed = e2e.Failed
HARD_LIMIT_S = 330

# Runs as the agent, in a pane or as a double-forked orphan: no imports from
# the repo, and every child is bounded.
PROBE = r'''
import json, os, signal, subprocess, sys, time
venom, venomx, root, role = sys.argv[1:5]

def call(tool, token, *args):
    env = dict(os.environ)
    var = "VENOMX_TOKEN" if tool == venomx else "VENOM_TOKEN"
    if token is None:
        env.pop(var, None)
    elif token != "":
        env[var] = token
    p = subprocess.run([tool, *args, "--json"], env=env, capture_output=True, text=True, timeout=20)
    text = p.stdout.strip() or p.stderr.strip()
    try:
        out = json.loads(text)
    except ValueError:
        out = {"raw": text[:300]}
    err = out.get("error") if isinstance(out, dict) else None
    return {"exit": p.returncode, "principal": out.get("principal") if isinstance(out, dict) else None,
            "code": err.get("code") if err else None,
            "reason": (err.get("data") or {}).get("reason") if err else None, "out": out}

def save(name, value):
    tmp = os.path.join(root, name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(value, f)
    os.rename(tmp, os.path.join(root, name))

def owner_probe():
    return {"venom": call(venom, "@owner", "whoami"), "venomx": call(venomx, "@owner", "whoami")}

if role == "pane":
    got = owner_probe()
    got["venom_plain"] = call(venom, None, "whoami")
    save(sys.argv[5], got)
elif role == "token-pane":
    # A human's pane with a token issued from outside (VENOM_TOKEN is set).
    got = {"whoami": call(venom, "", "whoami"), "list": call(venom, "", "agent", "list"),
           "admin": call(venom, "", "audit")}
    save(sys.argv[5], got)
elif role == "orphan":
    os.setsid()
    if os.fork():
        os._exit(0)
    time.sleep(0.2)
    got = owner_probe()
    got["parent"] = os.getppid()
    save(sys.argv[5], got)
    os._exit(0)
elif role == "job":
    # A background job: it probes once the shell that started it has exited.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    time.sleep(1)
    got = owner_probe()
    got["parent"] = os.getppid()
    save(sys.argv[5], got)
elif role == "view-shell":
    # A shell in a bound agent view: a model's Bash in a take-over looks the same.
    target, vx_pid = sys.argv[6:8]
    got = {"plain": call(venom, None, "whoami"), "has_token": "VENOM_TOKEN" in os.environ}
    got["answer"] = call(venom, None, "inbox", "answer", "--agent=" + target, "--answer=allow_once")
    got["bind"] = call(venom, None, "grant", "issue", "--pid=" + vx_pid, "--grants=" + json.dumps([{"right": "read", "scope": "*"}]))
    got.update(owner_probe())
    save(sys.argv[5], got)
elif role == "takeover":
    got = owner_probe()
    got["plain"] = call(venom, None, "whoami")
    got["ppid"] = os.getppid()
    save(sys.argv[5] + ".json", got)
    pid = os.fork()
    if pid == 0:
        os.execv(sys.executable, [sys.executable, "-I", os.path.join(root, "probe.py"), venom, venomx, root, "orphan", sys.argv[5] + "_orphan.json"])
    os.waitpid(pid, 0)
else:
    # The daemon binds the process just after it starts it.
    for _ in range(50):
        me = call(venom, "", "whoami")
        if me["principal"] != "unknown":
            break
        time.sleep(0.1)
    got = {"self": me, "has_token": "VENOM_TOKEN" in os.environ}
    got.update(owner_probe())
    # What the agent can do in venomx with whatever that gave it.
    token = "@owner" if got["venomx"]["principal"] == "owner" else None
    made = call(venomx, token, "session", "create", "--name=agent-made")
    got["session"] = made
    session = (made["out"] or {}).get("session")
    argv = [sys.executable, "-I", os.path.join(root, "probe.py"), venom, venomx, root, "pane", "agent_pane.json"]
    if session:
        got["split"] = call(venomx, token, "window", "create", "--session=" + session, "--name=x", "--argv=" + json.dumps(argv), "--cols=80", "--rows=24")
    else:
        got["split"] = {"exit": made["exit"], "code": made["code"], "principal": None, "reason": None, "out": None}
    save("agent.json", got)
    pid = os.fork()
    if pid == 0:
        os.execv(sys.executable, [sys.executable, "-I", os.path.join(root, "probe.py"), venom, venomx, root, "orphan", "orphan.json"])
    os.waitpid(pid, 0)
'''


class Chain(host_demo.Demo):
    def __init__(self, venom, venomx, root):
        super().__init__(venom, venomx, root)
        self.bad = []

    def write_config(self):
        super().write_config()
        probe = os.path.join(self.root, "probe.py")
        with open(probe, "w") as f:
            f.write(PROBE)
        # The fake harness behind one more wrapper: this is the agent process.
        fake = os.path.join(self.root, "fake_mcp_harness.py")
        os.rename(fake, fake + ".inner")
        with open(fake, "w") as f:
            # With --fake-mode it speaks protocols. Without, it is a take-over.
            f.write('#!/bin/sh\ncase " $* " in *" --fake-mode "*) role=agent; out=;; *) role=takeover; out=takeover;; esac\n'
                    '"%s" -I "%s" "%s" "%s" "%s" $role $out >>"%s/probe.log" 2>&1\nexec "%s.inner" "$@"\n'
                    % (sys.executable, probe, self.venom, self.venomx_exe, self.root, self.root, fake))
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)

    def result(self, name, timeout=15):
        path = os.path.join(self.root, name)
        host_demo.until(name, lambda: os.path.exists(path), timeout)
        with open(path) as f:
            return json.load(f)

    def expect(self, what, ok, got):
        print("owner-chain: %s %s: %s" % ("ok  " if ok else "FAIL", what, json.dumps(got)[:300]), flush=True)
        if not ok:
            self.bad.append(what)

    def refused(self, what, got):
        self.expect(what + " is refused the owner token", got.get("code") == "denied.token" and got.get("reason") == "owner_context", {k: got.get(k) for k in ("exit", "principal", "code", "reason")})

    def vx_isolation(self, on):
        """Sets venomx's isolation and waits for its manager marker to follow."""
        self.vx("config", "set", "--key=grants.isolation", "--value=" + ("true" if on else "false"))
        self.vx("config", "reload")
        folder = os.path.dirname(self.vx_socket())
        marked = lambda: any(n.startswith("manager-%d-" % self.vx_daemon.pid) for n in os.listdir(folder))
        host_demo.until("venomx's manager marker to follow isolation", lambda: marked() == on, 10)

    def human_pane(self, argv, env=None):
        made = self.vx("session", "create", "--name=human%d" % len(argv) + str(time.time_ns() % 100000))
        args = ["window", "create", "--session=" + made["session"], "--name=sh", "--argv=" + json.dumps(argv), "--cols=80", "--rows=24"]
        if env:
            args.append("--env=" + json.dumps(env))
        return self.vx(*args)["pane"]

    def probe_argv(self, role, out):
        return [sys.executable, "-I", os.path.join(self.root, "probe.py"), self.venom, self.venomx_exe, self.root, role, out]

    def own_split(self, t, key):
        t.send("\\\\")
        t.wait_for("Take over")
        t.send(key)
        time.sleep(0.5)

    def own_mode(self, agent):
        """5. Own mode: no pane, but below a manager."""
        self.set_config("ui.chrome", ".own")
        t = self.terminal("agent", "view", "--agent=" + agent)
        t.wait_for("settled")
        time.sleep(0.3)
        # The shell split, in the foreground.
        self.own_split(t, "2")
        t.send(" ".join(self.probe_argv("pane", "own_split.json")) + " &\r")
        split = self.result("own_split.json")
        self.refused("a shell split of an own-mode TUI to venom", split["venom"])
        self.refused("a shell split of an own-mode TUI to venomx", split["venomx"])
        # A job whose parent shell exits: without the TUI's subreaper it would
        # reparent past the marked TUI and be owner.
        t.send(" ".join(self.probe_argv("job", "own_job.json")) + " & exit\r")
        job = self.result("own_job.json", 25)
        self.expect("the job outlived its shell and landed on the TUI", job["parent"] == t.proc.pid, {"parent": job["parent"], "tui": t.proc.pid})
        self.refused("a background job of an own-mode split to venom", job["venom"])
        self.refused("a background job of an own-mode split to venomx", job["venomx"])
        t.close()
        self.terms.remove(t)
        # A take-over: this is where a model's Bash runs.
        t = self.terminal("agent", "view", "--agent=" + agent)
        t.wait_for("settled")
        time.sleep(0.3)
        self.own_split(t, "3")
        for name, label in (("takeover.json", "an own-mode take-over"), ("takeover_orphan.json", "a double-forked own-mode take-over process")):
            got = self.result(name, 25)
            self.refused(label + " to venom", got["venom"])
            self.refused(label + " to venomx", got["venomx"])
        t.close()
        self.terms.remove(t)

    def new_control(self, *args, env=None):
        t = host_demo.Terminal([self.venom, "agent", "view", *args], env) if env else self.terminal("agent", "view", *args)
        if env:
            self.terms.append(t)
        pane = host_demo.until("a control pane", self.control)
        return t, pane

    def end_control(self, t, pane):
        self.vx("pane", "kill", "--pane=" + pane["pane"], "--remove=true")
        t.close()
        self.terms.remove(t)
        host_demo.until("the control pane to go", lambda: self.control() is None)

    def environ_of(self, pid):
        with open("/proc/%d/environ" % pid, "rb") as f:
            return f.read()

    def bound(self, label):
        return [x for x in self.cli("grant", "list")["principals"] if x.get("label") == label]

    def settle(self, agent):
        def settled():
            state = self.state(agent)
            if state == "needs_you":
                self.cli("inbox", "answer", "--agent=" + agent, "--answer=allow_once", ok=False)
            return state == "settled"
        host_demo.until(agent + " to settle", settled, 30)

    def socket_of_venom(self):
        return os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venom.sock")

    def crash(self):
        self.daemon.kill()
        self.daemon.wait()

    def control_acts(self, cp, agent, what):
        """The control pane's own request: it reads as `unknown` otherwise, and this fails."""
        self.settle(agent)
        before = self.cli("agent", "show", "--agent=" + agent).get("turns")
        self.vx("pane", "send", "--pane=" + cp, "--text=i")
        time.sleep(0.3)
        self.vx("pane", "send", "--pane=" + cp, "--text=say hi with echo (beta)")
        time.sleep(0.2)
        self.vx("pane", "send", "--pane=" + cp, "--text=\r")
        ok = True
        try:
            host_demo.until(what, lambda: self.cli("agent", "show", "--agent=" + agent).get("turns") != before, 15)
        except Failed:
            ok = False
        self.expect("the control pane starts a turn " + what, ok, self.capture(cp)[-300:] if not ok else "")
        self.settle(agent)
        self.vx("pane", "send", "--pane=" + cp, "--text=\x1b")
        time.sleep(0.2)

    def control_pane(self, agent):
        """6. Host mode: a principal bound to the pane's process, no credential."""
        self.set_config("ui.chrome", ".auto")
        # A token issued now would be dead before the first check below.
        self.set_config("grants.max_token_ttl", "4")
        t, pane = self.new_control("--agent=" + agent)
        cp = pane["pane"]
        env = self.environ_of(pane["pid"])
        self.expect("no venom credential in the control pane's environment", b"VENOM_TOKEN=" not in env and b"vnt1.venom." not in env, "")
        got = host_demo.until("its principal", lambda: self.bound("venom control pane"))
        self.expect("one process principal, no admin", len(got) == 1 and got[0]["kind"] == "process" and not any(g["right"] == "admin" for g in got[0]["grants"]), got)
        self.expect("no expiry", got[0].get("expires") is None, got[0].get("expires"))
        time.sleep(5)
        self.control_acts(cp, agent, "past where a token would have expired")
        self.expect("no note about a token", "ended" not in self.capture(cp), "")

        # A process in another pane: nothing to read, and no rights by ancestry.
        self.human_pane(self.probe_argv("pane", "beside_control.json"))
        beside = self.result("beside_control.json")
        self.expect("a process beside it stays unknown", beside["venom_plain"]["principal"] == "unknown", beside["venom_plain"]["principal"])
        bound_file = os.path.splitext(self.socket_of_venom())[0] + ".bound"
        self.expect("the binding file is 0600", stat.S_IMODE(os.stat(bound_file).st_mode) == 0o600, oct(os.stat(bound_file).st_mode))
        self.expect("it holds no secret", "vnt1." not in open(bound_file).read(), "")

        # Its agent view is bound the same way.
        self.vx("pane", "send", "--pane=" + cp, "--text=\r")
        view = host_demo.until("the agent view", lambda: (self.split_panes(agent, "agent_view") or [None])[0])
        env = self.environ_of(view["pid"])
        self.expect("no venom credential in the view's environment", b"VENOM_TOKEN=" not in env and b"vnt1.venom." not in env, "")
        got = host_demo.until("the view's principal", lambda: self.bound("venom agent view"))
        self.expect("the view is a process principal", len(got) == 1 and got[0]["kind"] == "process", got)

        # It acts, but what runs below it doesn't get that.
        self.control_acts(view["pane"], agent, "from its agent view")
        self.view_shell(view, agent)

        # A clean restart, then a crash.
        self.stop()
        self.start()
        again = host_demo.until("its principal back", lambda: self.bound("venom control pane"))
        self.expect("a restart keeps it, under a new ID", len(again) == 1 and again[0]["kind"] == "process", again)
        self.expect("a restart keeps the view's", len(self.bound("venom agent view")) == 1, "")
        self.expect("it says it was restored", again[0].get("restored") is True, again[0].get("restored"))
        restored = [r for r in self.cli("audit", "--limit=50")["records"] if r["event"] == "restored"]
        self.expect("audit: restored, naming the process, no issue by the owner", any(r["peer"]["pid"] == pane["pid"] and r["peer"].get("start") for r in restored), restored[-1:])
        checks = json.loads(subprocess.run([self.venom, "doctor", "--json"], env=self.env, capture_output=True, text=True, timeout=30).stdout)["checks"]
        listed = [c["message"] for c in checks if c["id"] == "grants.process_principals"]
        self.expect("doctor lists it", bool(listed) and "pid %d" % pane["pid"] in listed[0] and "(restored)" in listed[0], listed)
        self.control_acts(cp, agent, "after a restart")
        self.crash()
        self.start()
        host_demo.until("its principal back after a crash", lambda: self.bound("venom control pane"))
        self.control_acts(cp, agent, "after kill -9")
        self.expect("no note about a token after either", "ended" not in self.capture(cp), "")

        # The pane's end ends it, and the view's with it.
        self.end_control(t, pane)
        host_demo.until("its principal to go", lambda: not self.bound("venom control pane"), 5)
        host_demo.until("the view's to go", lambda: not self.bound("venom agent view"), 5)
        self.expect("the principals end with the pane", True, "")
        for p in self.split_panes(agent, "agent_view"):
            self.vx("pane", "kill", "--pane=" + p["pane"], "--remove=true")
        self.set_config("grants.max_token_ttl", "86400")

    def view_shell(self, view, agent):
        target = self.spawn("alpha", "codex")
        before = self.approvals()
        time.sleep(0.5)
        self.vx("pane", "send", "--pane=" + view["pane"], "--text=\\\\")
        host_demo.until("the view's menu", lambda: "Shell" in self.capture(view["pane"]), 10)
        self.vx("pane", "send", "--pane=" + view["pane"], "--text=2")
        time.sleep(1)
        argv = self.probe_argv("view-shell", "view_shell.json") + [target, str(self.vx_daemon.pid)]
        self.vx("pane", "send", "--pane=" + view["pane"], "--text=" + " ".join("'%s'" % a for a in argv) + "\r")
        got = self.result("view_shell.json", 25)
        self.expect("a shell below a bound view is unknown", got["plain"]["principal"] == "unknown", got["plain"]["principal"])
        self.expect("it holds no venom credential", not got["has_token"], "")
        self.expect("it can't answer another agent's approval", got["answer"]["exit"] != 0, {k: got["answer"].get(k) for k in ("exit", "code")})
        self.expect("that approval is still pending", self.state(target) == "needs_you" and self.approvals() == before, self.state(target))
        self.expect("it can't bind venomx's daemon", got["bind"]["exit"] == 4, got["bind"]["code"])
        # With isolation on venomx is a manager, and nothing binds to it.
        self.vx_isolation(True)
        rc, owner_bind = self.raw("grant", "issue", "--pid=%d" % self.vx_daemon.pid, "--grants=" + json.dumps([{"right": "read", "scope": "*"}]))
        self.vx_isolation(False)
        self.expect("the owner can't either: it is a manager", rc != 0 and owner_bind.get("error", {}).get("code") == "conflict.process_manager", owner_bind)
        self.refused("a shell below a bound view to venom", got["venom"])
        self.refused("a shell below a bound view to venomx", got["venomx"])
        self.cli("inbox", "answer", "--agent=" + target, "--answer=allow_once")
        self.settle(target)

    def view_takeover(self, agent):
        """A take-over from a bound view is that view's child: a model's Bash runs there."""
        t, pane = self.new_control("--agent=" + agent)
        host_demo.until("its principal", lambda: self.bound("venom control pane"))
        self.vx("pane", "send", "--pane=" + pane["pane"], "--text=\r")
        view = host_demo.until("the agent view", lambda: (self.split_panes(agent, "agent_view") or [None])[0])
        host_demo.until("the view's principal", lambda: self.bound("venom agent view"))
        path = os.path.join(self.root, "takeover.json")
        os.unlink(path)
        time.sleep(0.5)
        self.vx("pane", "send", "--pane=" + view["pane"], "--text=\\\\")
        host_demo.until("the view's menu", lambda: "Take over" in self.capture(view["pane"]), 10)
        self.vx("pane", "send", "--pane=" + view["pane"], "--text=3")
        got = self.result("takeover.json", 25)
        self.expect("a take-over harness below a bound view is unknown", got["plain"]["principal"] == "unknown", got["plain"]["principal"])
        self.refused("a take-over below a bound view to venom", got["venom"])
        self.vx("pane", "kill", "--pane=" + view["pane"], "--remove=true")
        self.end_control(t, pane)

    def chosen_token(self, ttl=None):
        """A control pane with a token the human set outside: passed on as they asked."""
        grants = [{"right": r, "scope": "*"} for r in ("read", "write", "respond", "files", "spawn")]
        args = ["grant", "issue", "--namespace=person", "--label=chosen", "--grants=" + json.dumps(grants)]
        if ttl:
            args.append("--ttl=%d" % ttl)
        issued = self.cli(*args)
        t, pane = self.new_control(env=dict(self.env, VENOM_TOKEN=issued["token"]))
        return issued, t, pane

    def token_pane(self):
        """7. A token the human chose: its agents outlive it, and the TUI says when it ends."""
        issued, t, pane = self.chosen_token()
        env = self.environ_of(pane["pid"])
        self.expect("a chosen token reaches the control pane", issued["token"].encode() in env, "")
        env2 = dict(self.env, VENOM_TOKEN=issued["token"])
        made = subprocess.run([self.venom, "agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps(["beta"]), "--harness=codex", "--title=from the pane", "--task=say hi with echo (beta)", "--json"], env=env2, capture_output=True, text=True, timeout=30)
        agent = json.loads(made.stdout)["agent"] if made.returncode == 0 else None
        self.expect("it starts an agent", agent is not None, made.stdout[:200] or made.stderr[:200])
        self.expect("no note while the token is good", "ended" not in self.capture(pane["pane"]), "")
        self.cli("grant", "revoke", "--principal=" + issued["principal"])
        self.expect("the agent outlives the token", self.cli("agent", "show", "--agent=" + agent)["state"] != "failed", agent)
        principals = self.cli("grant", "list")["principals"]
        self.expect("the agent's principal stayed", any(x.get("label") == agent for x in principals), [x.get("label") for x in principals])
        self.token_note(pane, "a revoked token")
        self.end_control(t, pane)

    def token_note(self, pane, what):
        try:
            host_demo.until(what + " note", lambda: "token ended" in " ".join(self.capture(pane["pane"]).split()), 15)
            self.expect("the TUI says " + what + " ended", True, "")
        except Failed:
            self.expect("the TUI says " + what + " ended", False, self.capture(pane["pane"])[-400:])

    def token_expiry(self):
        """7. The token expires under an open connection, idle and in use."""
        _, t, pane = self.chosen_token(4)
        self.token_note(pane, "an expired token, idle,")
        self.end_control(t, pane)
        _, t, pane = self.chosen_token(4)
        # Keys move the selection, so requests are in flight when it expires.
        deadline = time.time() + 8
        while time.time() < deadline:
            self.vx("pane", "send", "--pane=" + pane["pane"], "--text=j")
            time.sleep(0.5)
        self.token_note(pane, "an expired token, in use,")
        self.end_control(t, pane)

    def forged_marker(self):
        """8. A forged marker can only deny service: it refuses the owner file, it grants nothing."""
        def ref(pid):
            with open("/proc/%d/stat" % pid) as f:
                return pid, f.read().rsplit(")", 1)[1].split()[19]
        marker = os.path.join(os.path.dirname(self.vx_socket()), "manager-%d-%s" % ref(os.getpid()))
        before = subprocess.run([self.venom, "doctor", "--json"], env={k: v for k, v in self.env.items() if k != "VENOM_TOKEN"}, capture_output=True, text=True, timeout=30)
        self.expect("doctor is quiet with no marker", "grants.below_manager" not in before.stdout, "")
        with open(marker, "w"):
            pass
        try:
            denied = subprocess.run([self.venom, "whoami", "--json"], env=self.env, capture_output=True, text=True, timeout=30)
            self.expect("a forged marker denies the human's @owner", denied.returncode == 4, (denied.stdout or denied.stderr)[:200])
            doctor = subprocess.run([self.venom, "doctor", "--json"], env={k: v for k, v in self.env.items() if k != "VENOM_TOKEN"}, capture_output=True, text=True, timeout=30)
            self.expect("doctor reports it", "grants.below_manager" in doctor.stdout, doctor.stdout[-200:])
        finally:
            os.unlink(marker)
        self.expect("deleting it ends the denial", self.cli("whoami")["principal"] == "owner", "owner")

    def run(self):
        self.make_workspace()
        self.write_config()
        self.start_venomx()
        self.start()
        self.cli("workspace", "add", "--path=" + self.ws)

        # 4a. Outside every tree the human is still the owner of both.
        self.expect("outside: venom @owner", self.cli("whoami")["principal"] == "owner", "owner")
        self.expect("outside: venomx @owner", self.vx("whoami")["principal"] == "owner", "owner")

        # 1 and 2: the chain from a real agent process.
        first = self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps(["alpha"]), "--harness=claude-code", "--title=chain", "--task=say hi with echo (alpha)")["agent"]
        agent = self.result("agent.json")
        self.expect("agent runs as its own principal", (agent["self"]["principal"] or "").startswith("g"), {"principal": agent["self"]["principal"], "has_token": agent["has_token"]})
        self.refused("agent to venom", agent["venom"])
        self.refused("agent to venomx", agent["venomx"])
        self.expect("agent cannot make a venomx session", agent["session"]["exit"] == 4, {k: agent["session"].get(k) for k in ("exit", "code")})
        self.expect("agent cannot split a pane", agent["split"]["exit"] == 4, {k: agent["split"].get(k) for k in ("exit", "code")})
        if os.path.exists(os.path.join(self.root, "agent_pane.json")) or agent["split"]["exit"] == 0:
            pane = self.result("agent_pane.json")
            self.refused("the agent's pane to venom", pane["venom"])
        orphan = self.result("orphan.json")
        self.refused("double-forked agent process to venom", orphan["venom"])
        self.refused("double-forked agent process to venomx", orphan["venomx"])

        # 3. A process in a pane the human made, with venomx's isolation on:
        # venomx is a manager.
        self.vx_isolation(True)
        self.human_pane(self.probe_argv("pane", "human_pane.json"))
        pane = self.result("human_pane.json")
        self.refused("a process in a human's pane to venom", pane["venom"])
        self.refused("a process in a human's pane to venomx", pane["venomx"])
        self.expect("with no token that pane is unknown on venom", pane["venom_plain"]["principal"] == "unknown", pane["venom_plain"]["principal"])
        # And off, venomx's default: the pane is the human's terminal to venom.
        self.vx_isolation(False)
        self.human_pane(self.probe_argv("pane", "open_pane.json"))
        pane = self.result("open_pane.json")
        self.expect("isolation off: a human's pane is the owner on venom", pane["venom"]["principal"] == "owner", {k: pane["venom"].get(k) for k in ("exit", "principal", "code", "reason")})
        self.refused("isolation off: a human's pane to venomx", pane["venomx"])

        # 4b. The documented way: a token issued from outside.
        grants = [{"right": r, "scope": "*"} for r in ("read", "write", "respond", "files", "spawn")]
        issued = self.cli("grant", "issue", "--grants=" + json.dumps(grants), "--ttl=600", "--label=my-pane")
        self.human_pane(self.probe_argv("token-pane", "token_pane.json"), [{"name": "VENOM_TOKEN", "value": issued["token"]}])
        token = self.result("token_pane.json")
        self.expect("an issued token works in a pane", token["whoami"]["principal"] == issued["principal"], token["whoami"]["principal"])
        self.expect("the token reads agents", token["list"]["exit"] == 0, token["list"]["exit"])
        self.expect("the token is not admin", token["admin"]["code"] == "denied.admin", token["admin"]["code"])

        self.cli("inbox", "answer", "--agent=" + first, "--answer=allow_once")
        self.wait(first, ("settled",))
        self.own_mode(first)
        # A new one: the take-over above leaves `first` to its own ending.
        fresh = self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps(["beta"]), "--harness=codex", "--title=control", "--task=say hi with echo (beta)")["agent"]
        self.settle(fresh)
        self.control_pane(fresh)
        other = self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps(["beta"]), "--harness=claude-code", "--title=view take-over", "--task=say hi with echo (beta)")["agent"]
        self.settle(other)
        self.set_config("ui.chrome", ".auto")
        self.view_takeover(other)
        self.token_pane()
        self.token_expiry()
        self.forged_marker()

        if self.bad:
            raise Failed("%d checks failed: %s" % (len(self.bad), "; ".join(self.bad)))
        print("owner-chain: PASS", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--venom", default=os.path.join(e2e.REPO, "zig-out", "bin", "venom"))
    ap.add_argument("--venomx", default=os.path.join(e2e.REPO, "..", "venomx", "zig-out", "bin", "venomx"))
    ap.add_argument("--keep", action="store_true", help="keep the temp root")
    args = ap.parse_args()
    venomx = os.path.abspath(args.venomx)
    if not os.access(venomx, os.X_OK):
        sys.exit("owner-chain: no venomx at %s; build ../venomx or pass --venomx" % venomx)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Failed("hard limit of %ds" % HARD_LIMIT_S)))
    signal.alarm(HARD_LIMIT_S)
    # Short: the unix socket path has a limit.
    root = tempfile.mkdtemp(prefix="vo", dir="/tmp")
    demo = Chain(os.path.abspath(args.venom), venomx, root)
    code = 0
    try:
        demo.run()
    except (Failed, subprocess.SubprocessError, OSError, KeyError, ValueError, IndexError) as e:
        print("owner-chain: FAIL: %s" % e, file=sys.stderr)
        for name in ("probe.log", "serve.stderr", "venomx.stderr"):
            try:
                with open(os.path.join(root, name)) as f:
                    print("--- %s\n%s" % (name, f.read()[-1500:]), file=sys.stderr)
            except OSError:
                pass
        code = 1
    finally:
        signal.alarm(0)
        # Everything the run made: panes die with venomx; a double-forked probe exits itself.
        demo.stop_all()
        if args.keep:
            print("owner-chain: kept " + root)
        else:
            shutil.rmtree(root, ignore_errors=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
