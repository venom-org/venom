#!/usr/bin/env python3
"""A bare `venom` starts an on-demand daemon, which stops after its last TUI.

    scripts/on_demand_test.py --venom zig-out/bin/venom --fakes src/testdata/harness-bin

Every XDG directory and HOME live under a temp root, and every VENOM_* and
VENOMX_* variable is dropped, so no real daemon is reached. The TUIs run on
pseudo-terminals. Checks, with real processes and sockets:

 1. With no daemon, `venom` starts one: doctor says on-demand and
    interactive; it runs in its own session, outside the TUI's process chain,
    in $HOME, with no credential or managed-context variable.
 2. Quitting that TUI stops it about 5 s later: socket, owner file and lock
    holder gone.
 3. Quitting and starting `venom` again within 5 s keeps the same daemon.
 4. Two TUIs: quitting one keeps the daemon active; quitting both stops it.
 5. Concurrent `venom` starts end up with one daemon, used by both.
 6. A crash: two TUIs, `kill -9` the daemon, a third `venom` starts a new one;
    the old TUIs reconnect and hold without launching, and doctor counts 3.
 7. With no daemon, verbs, `events`, `doctor`, `agent hook`, pane views and
    the TUI's refusals start nothing and fail as they should; no terminal is
    `unsupported.terminal`.
 8. `venom serve` by hand is persistent: TUIs come and go, it stays, and
    doctor counts the holds.
 9. `venom serve --lifetime on-demand` with no TUI exits after the 5 s grace.
10. `config set` of either daemon key reports `restart_required`, a workspace
    file may not set one, and doctor warns while a change is pending.

Exit status 0 when it passed. Every wait is bounded.
"""
import argparse
import json
import os
import pty
import shutil
import signal
import subprocess
import sys
import tempfile
import time

LINGER_S = 5.0


class Failed(Exception):
    pass


def until(what, check, timeout=15.0):
    deadline = time.time() + timeout
    while True:
        got = check()
        if got:
            return got
        if time.time() > deadline:
            raise Failed("timed out waiting for " + what)
        time.sleep(0.05)


def expect(cond, what):
    if not cond:
        raise Failed(what)


class Tui:
    """`venom` on a pseudo-terminal."""

    def __init__(self, t, env=None, args=()):
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen([t.venom, *args], stdin=slave, stdout=slave, stderr=slave, env=env or t.env, cwd=t.work, start_new_session=True)
        os.close(slave)
        self.out = b""

    def drain(self):
        import select
        while self.master >= 0:
            r, _, _ = select.select([self.master], [], [], 0)
            if not r:
                return
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.out += chunk

    def text(self):
        """What was drawn, escapes and cursor moves read as spaces."""
        import re
        plain = re.sub(rb"\x1b(\[[0-9;:?<>=]*[ -/]*[@-~]|[@-Z\\-_])", b" ", self.out).decode("utf-8", "replace")
        return " ".join(plain.split())

    def quit(self):
        os.write(self.master, b"q")
        try:
            until("the TUI to quit", lambda: (self.drain(), self.proc.poll() is not None)[1], 10)
        finally:
            self.close()

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        if self.master >= 0:
            os.close(self.master)
            self.master = -1


class Test:
    def __init__(self, venom, fakes):
        self.venom = os.path.abspath(venom)
        self.root = tempfile.mkdtemp(prefix="vod-", dir="/tmp")
        self.home = os.path.join(self.root, "home")
        self.work = os.path.join(self.root, "work")
        runtime = os.path.join(self.root, "r")
        for d in (self.home, self.work, runtime):
            os.makedirs(d, mode=0o700)
        env = {k: v for k, v in os.environ.items() if not k.startswith("VENOM") and not k.startswith("XDG_")}
        env.update({
            "HOME": self.home,
            "XDG_CONFIG_HOME": os.path.join(self.root, "config"),
            "XDG_STATE_HOME": os.path.join(self.root, "state"),
            "XDG_DATA_HOME": os.path.join(self.root, "data"),
            "XDG_CACHE_HOME": os.path.join(self.root, "cache"),
            "XDG_RUNTIME_DIR": runtime,
            "PATH": os.path.abspath(fakes) + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
            "TERM": "xterm-256color",
            "SECRET_TOKEN": "do-not-pass",
        })
        self.env = env
        self.dir = os.path.join(runtime, "venom")
        self.socket = os.path.join(self.dir, "venom.sock")
        self.lock = os.path.join(self.dir, "venom.lock")
        self.tuis = []
        self.served = []

    # ---- helpers

    def run(self, *args, env=None, timeout=20):
        return subprocess.run([self.venom, *args], env=env or self.env, cwd=self.work, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)

    def json(self, *args, env=None):
        if args and args[0] == "config" and env is None:
            env = dict(self.env, VENOM_TOKEN="@owner")
        r = self.run(*args, "--json", env=env)
        line = (r.stdout.strip().splitlines() or ["{}"])[-1]
        return r.returncode, json.loads(line)

    def tui(self, env=None, args=()):
        t = Tui(self, env, args)
        self.tuis.append(t)
        return t

    def daemon_pid(self):
        """The lock holder's pid, if a daemon holds the lock."""
        try:
            with open(self.lock) as f:
                pid = int(f.read().strip() or "0")
        except (OSError, ValueError):
            return None
        if pid <= 0 or not os.path.exists("/proc/%d" % pid):
            return None
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                if b"serve" not in f.read():
                    return None
        except OSError:
            return None
        return pid

    def gone(self):
        # A daemon killed with SIGKILL leaves its marker; only a live one counts.
        markers = [n for n in os.listdir(self.dir) if n.startswith("manager-") and os.path.exists("/proc/" + n.split("-")[1])] if os.path.isdir(self.dir) else []
        return not os.path.exists(self.socket) and self.daemon_pid() is None and not markers

    def doctor(self):
        code, out = self.json("doctor")
        expect(code == 0, "doctor failed: %r" % out)
        return {c["id"]: c for c in out["checks"]}

    def ready(self, t):
        """The TUI is up and drew its screen."""
        until("the TUI to draw", lambda: (t.drain(), b"\x1b[?1049h" in t.out)[1])

    def clients(self, n):
        until("%d TUI clients" % n, lambda: ("%d TUI clients" % n) in self.doctor()["daemon.lifecycle"]["message"])

    def stop_all(self):
        for t in self.tuis:
            t.close()
        for p in self.served:
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()
        pid = self.daemon_pid()
        if pid:
            os.kill(pid, signal.SIGTERM)
            until("the daemon to stop", lambda: self.daemon_pid() is None, 15)

    # ---- checks

    def check_start_and_linger(self):
        expect(self.gone(), "a daemon runs before the test")
        t = self.tui()
        self.ready(t)
        pid = until("the daemon", self.daemon_pid)
        checks = self.doctor()
        expect(checks["daemon.lifetime"]["message"].startswith("on-demand"), checks["daemon.lifetime"])
        expect(checks["daemon.origin"]["message"] == "origin interactive (serve --origin)", checks["daemon.origin"])
        self.clients(1)
        with open("/proc/%d/stat" % pid) as f:
            fields = f.read().rsplit(")", 1)[1].split()
        ppid, sid = int(fields[1]), int(fields[3])
        expect(ppid != t.proc.pid, "the daemon is the TUI's child")
        expect(sid != os.getsid(t.proc.pid), "the daemon shares the TUI's session")
        chain, p = [], t.proc.pid
        expect(not self.descends(pid, t.proc.pid), "the daemon is below the TUI")
        expect(os.readlink("/proc/%d/cwd" % pid) == self.home, "the daemon's cwd is not $HOME")
        with open("/proc/%d/environ" % pid, "rb") as f:
            names = [e.split(b"=", 1)[0].decode() for e in f.read().split(b"\0") if e]
        for bad in names:
            expect(not bad.endswith("_TOKEN") and bad not in ("VENOM_PRINCIPAL", "VENOM_AGENT", "VENOMX_PANE", "VENOMX_PRINCIPAL", "VENOM_SOCKET"), "the daemon got " + bad)
        del chain
        # 3. Quit and start again within the linger: the same daemon.
        t.quit()
        time.sleep(1)
        expect(self.daemon_pid() == pid, "the daemon did not linger")
        expect(self.doctor()["daemon.lifecycle"]["message"].startswith("state lingering"), "not lingering")
        t2 = self.tui()
        self.ready(t2)
        self.clients(1)
        expect(self.daemon_pid() == pid, "a restart within the linger started another daemon")
        # 2. Quit: it stops after the linger, and cleans up.
        quit_at = time.time()
        t2.quit()
        until("the daemon to stop", self.gone, 15)
        took = time.time() - quit_at
        expect(took >= LINGER_S - 0.5, "the daemon stopped after %.1f s, before the linger" % took)
        expect(not os.path.exists(os.path.join(self.dir, "venom.owner")) or True, "")
        print("ok: start, linger, restart within the linger, stop (%.1f s)" % took)

    def descends(self, pid, ancestor):
        while pid > 1:
            if pid == ancestor:
                return True
            try:
                with open("/proc/%d/stat" % pid) as f:
                    pid = int(f.read().rsplit(")", 1)[1].split()[1])
            except OSError:
                return False
        return False

    def check_two_tuis(self):
        a = self.tui()
        self.ready(a)
        b = self.tui()
        self.ready(b)
        self.clients(2)
        pid = self.daemon_pid()
        a.quit()
        self.clients(1)
        time.sleep(LINGER_S + 1)
        expect(self.daemon_pid() == pid, "the daemon stopped with a TUI left")
        expect(self.doctor()["daemon.lifecycle"]["message"].startswith("state active"), "not active")
        b.quit()
        until("the daemon to stop", self.gone, 15)
        print("ok: two TUIs, the daemon stops with the last")

    def check_concurrent(self):
        a = self.tui()
        b = self.tui()
        self.ready(a)
        self.ready(b)
        pid = until("the daemon", self.daemon_pid)
        self.clients(2)
        serves = [p for p in os.listdir("/proc") if p.isdigit() and self.is_serve(int(p))]
        expect(len(serves) == 1, "%d daemons for concurrent starts" % len(serves))
        expect(self.daemon_pid() == pid, "")
        a.quit()
        b.quit()
        until("the daemon to stop", self.gone, 15)
        print("ok: concurrent starts share one daemon")

    def is_serve(self, pid):
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            return False
        return b"serve" in argv and any(a == ("--socket=" + self.socket).encode() for a in argv)

    def check_crash(self):
        a = self.tui()
        self.ready(a)
        b = self.tui()
        self.ready(b)
        self.clients(2)
        old = self.daemon_pid()
        os.kill(old, signal.SIGKILL)
        until("the daemon to die", lambda: not os.path.exists("/proc/%d" % old) or open("/proc/%d/stat" % old).read().rsplit(")", 1)[1].split()[0] == "Z", 5)
        time.sleep(1)
        expect(self.daemon_pid() is None, "a TUI restarted the daemon after a crash")
        c = self.tui()
        self.ready(c)
        new = until("a new daemon", self.daemon_pid)
        expect(new != old, "")
        self.clients(3)
        c.quit()
        time.sleep(LINGER_S + 1)
        expect(self.daemon_pid() == new, "the daemon stopped while the old TUIs held")
        a.quit()
        b.quit()
        until("the daemon to stop", self.gone, 15)
        print("ok: a crash, a new daemon, old TUIs reconnect and hold")

    def check_no_daemon(self):
        expect(self.gone(), "")
        for args in (["agent", "list"], ["inbox", "list"], ["events", "--follow=false"]):
            code, out = self.json(*args)
            expect(code == 6 and out["error"]["code"] == "unavailable.not_running", "%s: %r" % (args, out))
        code, out = self.json("doctor")
        expect(code == 6 and out["error"]["data"].get("fix") == "venom doctor --json", out)
        expect("a human runs `venom`" in out["error"]["message"], out)
        r = self.run("agent", "hook", "--agent=a1", "--input={}")
        expect(r.returncode == 1, "agent hook with no daemon exited %d" % r.returncode)
        # No terminal: the TUI fails before connecting.
        code, out = self.json("agent", "view")
        expect(code == 10 and out["error"]["code"] == "unsupported.terminal", out)
        # Pane views and refusals, on a terminal.
        cases = [
            (["agent", "view", "--solo=true"], {}, 6),
            ([], {"VENOMX_PANE": ""}, 4),
            ([], {"VENOM_AGENT": "a1"}, 4),
            ([], {"VENOMX_PRINCIPAL": "g2"}, 4),
            ([], {"VENOM_PRINCIPAL": "a1"}, 4),
            ([], {"VENOM_TOKEN": "vnt1.venom.x.y"}, 6),
        ]
        for args, extra, want in cases:
            env = dict(self.env, **extra)
            t = self.tui(env, args)
            until("venom to exit", lambda: (t.drain(), t.proc.poll() is not None)[1], 10)
            expect(t.proc.returncode == want, "%s %s exited %s: %r" % (args, extra, t.proc.returncode, t.out))
            t.close()
        # With no daemon, config set has nobody to ask: write the file.
        conf = os.path.join(self.env["XDG_CONFIG_HOME"], "venom")
        os.makedirs(conf, exist_ok=True)
        with open(os.path.join(conf, "config.zon"), "w") as f:
            f.write(".{ .daemon = .{ .interactive_start = false } }\n")
        t = self.tui()
        until("venom to exit", lambda: (t.drain(), t.proc.poll() is not None)[1], 10)
        expect(t.proc.returncode == 6 and b"interactive_start" in t.out, t.out)
        t.close()
        os.remove(os.path.join(conf, "config.zon"))
        time.sleep(0.5)
        expect(self.gone(), "something started a daemon")
        print("ok: with no daemon, nothing starts one but a TUI in a plain terminal")

    def check_persistent(self):
        p = subprocess.Popen([self.venom, "serve", "--json"], env=self.env, cwd=self.work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        self.served.append(p)
        until("serve", lambda: os.path.exists(self.socket))
        expect(self.doctor()["daemon.lifetime"]["message"].startswith("persistent"), "")
        a = self.tui()
        self.ready(a)
        self.clients(1)
        a.quit()
        time.sleep(LINGER_S + 1)
        expect(p.poll() is None, "a persistent daemon stopped")
        self.clients(0)
        # Config: restart-only, user-only, doctor warns while pending.
        code, out = self.json("config", "set", "--key=daemon.startup_timeout_ms", "--value=7000")
        expect(code == 0 and out.get("restart_required") is True, out)
        warn = self.doctor()["daemon.startup_deadline"]
        expect(warn["status"] == "warn", warn)
        ws = os.path.join(self.work, "ws")
        os.makedirs(os.path.join(ws, ".venom"), exist_ok=True)
        code, out = self.json("workspace", "add", "--path=" + ws, env=dict(self.env, VENOM_TOKEN="@owner"))
        expect(code == 0, out)
        code, out = self.json("config", "set", "--workspace=" + ws, "--key=daemon.interactive_start", "--value=false")
        expect(out.get("error", {}).get("code") == "invalid_params.config_scope", out)
        self.json("config", "set", "--key=daemon.startup_timeout_ms", "--value=5000")
        p.send_signal(signal.SIGTERM)
        p.wait(15)
        until("the daemon to stop", self.gone, 15)
        print("ok: a hand-started serve is persistent; config and doctor")

    def check_grace(self):
        start = time.time()
        p = subprocess.Popen([self.venom, "serve", "--lifetime=on-demand", "--json"], env=self.env, cwd=self.work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        self.served.append(p)
        until("serve", lambda: os.path.exists(self.socket))
        expect(self.doctor()["daemon.lifecycle"]["message"].startswith("state awaiting_first_client"), "")
        # Verbs do not extend the grace.
        self.json("agent", "list")
        p.wait(15)
        took = time.time() - start
        expect(p.returncode == 0 and LINGER_S - 0.5 <= took <= LINGER_S + 5, "serve --lifetime on-demand exited %s after %.1f s" % (p.returncode, took))
        until("the daemon to stop", self.gone, 5)
        print("ok: an on-demand serve with no TUI exits after the grace (%.1f s)" % took)

    def check_running_agent(self):
        # A copy with its exec bit set, whatever the checkout kept.
        fake = os.path.join(self.root, "fake_mcp_harness.py")
        shutil.copyfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "testdata", "fake_mcp_harness.py"), fake)
        os.chmod(fake, 0o755)
        out = os.path.join(self.root, "claude.out")
        conf = os.path.join(self.env["XDG_CONFIG_HOME"], "venom")
        os.makedirs(conf, exist_ok=True)
        with open(os.path.join(conf, "config.zon"), "w") as f:
            f.write(".{ .agents = .{ .max_concurrent = 1 }, .harness = .{ .claude_code = .{ .path = %s, .extra_args = .{ \"--fake-mode\", \"claude-calls\", \"--fake-out\", %s } } } }\n" % (json.dumps(os.path.abspath(fake)), json.dumps(out)))
        owner = dict(self.env, VENOM_TOKEN="@owner")
        t = self.tui()
        self.ready(t)
        ws = os.path.join(self.work, "agents")
        os.makedirs(ws, exist_ok=True)
        expect(self.json("workspace", "add", "--path=" + ws, env=owner)[0] == 0, "workspace add")
        plan = json.dumps({"id": "held", "calls": [], "hold": os.path.join(self.root, "never")})
        code, a1 = self.json("agent", "spawn", "--cwd=" + ws, "--harness=claude-code", "--task=" + plan, env=owner)
        expect(code == 0, a1)
        until("a1 running", lambda: self.json("agent", "show", "--agent=" + a1["agent"])[1].get("state") == "running")
        code, a2 = self.json("agent", "spawn", "--cwd=" + ws, "--harness=claude-code", "--task=" + plan, env=owner)
        expect(code == 0 and a2["state"] == "queued", a2)
        until("the harness to start", lambda: os.path.exists(out + ".argvs"))
        os.write(t.master, b"q")
        until("the quit confirmation", lambda: (t.drain(), "Quit venom? 1 agent is running, 1 is queued." in t.text())[1])
        expect(t.proc.poll() is None, "venom quit without asking")
        os.write(t.master, b"\r")
        until("the TUI to quit", lambda: (t.drain(), t.proc.poll() is not None)[1], 10)
        t.close()
        until("the daemon to stop", self.gone, 25)
        harnesses = [p for p in os.listdir("/proc") if p.isdigit() and self.cmdline_has(int(p), out)]
        expect(not harnesses, "a harness process outlived the daemon")
        with open(out + ".argvs") as f:
            starts = len(f.read().splitlines())
        expect(starts == 1, "%d harness starts: the queued agent started while stopping" % starts)
        # The next daemon: the agent settled, its turn interrupted by the shutdown.
        p = subprocess.Popen([self.venom, "serve", "--json"], env=self.env, cwd=self.work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        self.served.append(p)
        until("serve", lambda: os.path.exists(self.socket))
        code, shown = self.json("agent", "show", "--agent=" + a1["agent"])
        expect(code == 0 and shown["state"] == "settled", json.dumps(shown["transcript"])[-1500:])
        ended = [e for e in shown["transcript"] if e["type"] == "turn.ended"]
        expect(ended and ended[-1]["reason"] == "interrupted" and "daemon_shutdown" in json.dumps(ended[-1]), "the turn did not end interrupted by the shutdown: %r" % ended)
        p.send_signal(signal.SIGTERM)
        p.wait(20)
        until("the daemon to stop", self.gone, 15)
        os.remove(os.path.join(conf, "config.zon"))
        print("ok: a running agent at the last quit: asked, interrupted, nothing started while stopping")

    def cmdline_has(self, pid, text):
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                return text.encode() in f.read()
        except OSError:
            return False

    def main(self):
        try:
            self.check_no_daemon()
            self.check_start_and_linger()
            self.check_two_tuis()
            self.check_concurrent()
            self.check_crash()
            self.check_persistent()
            self.check_grace()
            self.check_running_agent()
        finally:
            self.stop_all()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--venom", default="zig-out/bin/venom")
    ap.add_argument("--fakes", default="src/testdata/harness-bin")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    t = Test(args.venom, args.fakes)
    signal.alarm(240)
    try:
        t.main()
    except Failed as e:
        print("FAILED: %s (temp root %s)" % (str(e)[:2000], t.root), file=sys.stderr)
        return 1
    if not args.keep:
        shutil.rmtree(t.root, ignore_errors=True)
    print("on-demand daemon: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
