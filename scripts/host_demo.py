#!/usr/bin/env python3
"""`ui.chrome` end to end: own and host mode with two agents each.

    scripts/host_demo.py [--venom zig-out/bin/venom] [--venomx ../venomx/zig-out/bin/venomx] [--keep]

It starts its own `venom serve` (and, later, `venomx serve`) with every XDG
directory under a temp root, and fake harnesses as in scripts/demo.py.

1. `auto`, no venomx daemon: `venom` runs in own mode and nothing started one.
2. `own` with a venomx daemon up: `venom` stays out of venomx; two approvals
   are answered from the TUI's inbox.
3. `auto` with a venomx daemon up: this terminal becomes `venomx attach` on a
   control pane (`role = control`, `owner = venom`); `⏎` opens two sibling
   agent panes (`role = agent`, `group = <agent>`, kept on exit); venom's bar
   is the control pane's bottom row and no other pane's; there are no
   `venom.*` segments; approvals set attention, and answering clears it; the
   `venom` key table opens the settings and diff popups, the settings at their
   preset's size; esc closes them, asking first over a pending edit; `,` in the
   control pane draws them there instead; closing a pane leaves the agent alone. Escalation: a blocking item past
   `attention.notify_after` gets one `notify.post` from the daemon, under its
   own short token and never a pane's, dismissed once answered; a new item
   rings a BEL, and what the BEL leaves on the control pane clears too.
4. Splits: next to an agent's pane, its view and a shell in its
   worktree open as read-only panes with no credential; a process in one cannot
   drive a pane in another session; closing them leaves the agent running;
   a take-over runs the same way and takes the agent back when its pane ends.
5. A take-over outlives its TUI: no take-back or turn while its pane may run,
   across a daemon restart too; a new control pane's T says what to do.
6. Attention while away: a hook from inside the take-over pane is
   accepted because venomx confirms the pid; it gives that pane `pane.attention`
   and the agent shows in "Needs you"; the mark clears on take back. Other
   processes and a venomx that can't say are refused.

Needs a built venomx (optional for venom itself, so this is not part of
`zig build test`; `zig build test-host` runs it). Exit status 0 when it passed.
Every wait is bounded, and the whole run has a hard limit.
"""
import argparse
import fcntl
import json
import os
import pty
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import demo as e2e  # noqa: E402

Failed = e2e.Failed
HARD_LIMIT_S = 300


def log(msg):
    print("host-demo: " + msg, flush=True)


def until(what, check, timeout=15):
    deadline = time.time() + timeout
    while True:
        got = check()
        if got:
            return got
        if time.time() > deadline:
            raise Failed("timed out waiting for " + what)
        time.sleep(0.05)


class Terminal:
    """A program on a pty of its own: what a human's terminal would be."""

    def __init__(self, argv, env, cols=100, rows=30):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc = subprocess.Popen(argv, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True, close_fds=True,
                                     preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        self.out = bytearray()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        while True:
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return
            if not data:
                return
            self.out += data

    def text(self):
        return self.out.decode("utf-8", "replace")

    def send(self, data):
        os.write(self.master, data.encode() if isinstance(data, str) else data)

    def wait_for(self, needle, timeout=15):
        until("%r on the terminal; got %r" % (needle, self.text()[-400:]), lambda: needle in self.text(), timeout)

    def close(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGHUP)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait()
        os.close(self.master)


class Demo(e2e.Demo):
    def __init__(self, venom, venomx, root):
        super().__init__(venom, False, root)
        self.venomx_exe = venomx
        self.vx_daemon = None
        self.terms = []
        self.env["SHELL"] = "/bin/sh"
        # `venomx` on PATH, as the attach exec finds it.
        bindir = os.path.join(root, "bin")
        os.makedirs(bindir)
        os.symlink(venomx, os.path.join(bindir, "venomx"))
        self.env["PATH"] = bindir + os.pathsep + self.env.get("PATH", "")
        for name in ("VENOMX_TOKEN", "VENOMX_PANE", "VENOMX_SOCKET", "VENOMX_PRINCIPAL"):
            self.env.pop(name, None)

    def write_config(self):
        # The fake harness speaks protocols only. Resumed with no --fake-mode, it
        # is a TUI that notes its environment and stays until its pane ends.
        super().write_config()
        fake = os.path.join(self.root, "fake_mcp_harness.py")
        os.rename(fake, fake + ".real")
        with open(fake, "w") as f:
            # A hook runs under the TUI, as Claude Code runs it: the test leaves
            # a script for this very process (`fire_hook`), and it is the parent.
            f.write('#!/bin/sh\ncase " $* " in *" --fake-mode "*) exec "%s.real" "$@";; esac\nr="%s"\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$r/takeover.$$.args"\nenv > "$r/takeover.env"\n'
                    'n=0; while [ $n -lt 6000 ]; do [ -e "$r/fire.$$.sh" ] && { mv "$r/fire.$$.sh" "$r/firing.$$.sh"; sh "$r/firing.$$.sh"; }; sleep 0.1; n=$((n+1)); done\n' % (fake, self.root))
        os.chmod(fake, 0o755)

    # --- helpers -----------------------------------------------------------

    def vx(self, *args, ok=True):
        env = dict(self.env, VENOMX_TOKEN="@owner")
        p = subprocess.run([self.venomx_exe, *args, "--json"], env=env, capture_output=True, text=True, timeout=30)
        out = json.loads(p.stdout) if p.stdout.strip() else None
        if ok and p.returncode != 0:
            raise Failed("venomx %s exited %d: %s %s" % (" ".join(args), p.returncode, p.stdout.strip(), p.stderr.strip()))
        return out

    def vx_socket(self):
        return os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venomx.sock")

    def start_venomx(self):
        self.vx_log = open(os.path.join(self.root, "venomx.stderr"), "w")
        self.vx_daemon = subprocess.Popen([self.venomx_exe, "serve"], env=self.env, stdin=subprocess.DEVNULL, stdout=self.vx_log, stderr=subprocess.STDOUT)
        until("venomx ping", lambda: subprocess.run([self.venomx_exe, "ping", "--json"], env=self.env, capture_output=True, timeout=10).returncode == 0)

    def stop_all(self):
        for t in self.terms:
            t.close()
        if self.vx_daemon and self.vx_daemon.poll() is None:
            self.vx_daemon.send_signal(signal.SIGTERM)
            try:
                self.vx_daemon.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.vx_daemon.kill()
                self.vx_daemon.wait()
        self.stop()

    def terminal(self, *args):
        t = Terminal([self.venom, *args], self.env)
        self.terms.append(t)
        return t

    def spawn(self, repo, harness):
        r = self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps([repo]), "--harness=" + harness,
                     "--isolation=worktree", "--title=host demo " + repo, "--task=say hi with echo (%s)" % repo)
        self.spawned[r["agent"]] = r
        self.wait(r["agent"], ("needs_you",))
        log("spawned %s (%s) on %s: needs_you" % (r["agent"], harness, repo))
        return r["agent"]

    def approvals(self):
        # A settled agent adds a review item, so only approvals count down.
        return sum(1 for i in self.cli("inbox", "list")["items"] if i["kind"] == "approval")

    def panes(self):
        return self.vx("pane", "list")["panes"]

    def event_cursor(self):
        """The cursor (`source:seq`) of the newest venomx event, to follow from."""
        p = subprocess.run([self.venomx_exe, "events", "--follow=false", "--json"], env=dict(self.env, VENOMX_TOKEN="@owner"), capture_output=True, text=True, timeout=30)
        last = ""
        for line in p.stdout.splitlines():
            try:
                e = json.loads(line)
                last = "%s:%d" % (e["source"], e["seq"])
            except (ValueError, KeyError):
                pass
        if not last:
            raise Failed("venomx events gave no event seq to follow from: " + p.stdout[:200])
        return last

    def follow_attention(self, after, pane, level):
        """Start collecting `pane.attention_changed` events for a pane after a
        cursor; the result is true once one with `level` was seen. Unlike a
        poll of `pane list`, this can't miss a mark that a focused client
        clears as soon as it sees it."""
        proc = subprocess.Popen([self.venomx_exe, "events", "--after=" + after, "--types=" + json.dumps(["pane.attention_changed"]), "--follow=true", "--json"],
                                env=dict(self.env, VENOMX_TOKEN="@owner"), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        seen = []

        def read():
            for line in proc.stdout:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                d = e.get("data", e)
                if d.get("pane") == pane and d.get("level") == level:
                    seen.append(e)
        threading.Thread(target=read, daemon=True).start()
        return proc, seen

    @staticmethod
    def tags(p):
        return {t["key"]: t["value"] for t in p["tags"]}

    def capture(self, pane):
        return self.vx("pane", "capture", "--pane=" + pane)["text"]

    # --- 1: auto, no daemon --------------------------------------------------

    def auto_without_venomx(self):
        t = self.terminal()
        t.wait_for("need you")
        t.wait_for("Agents")
        time.sleep(0.3)
        if os.path.exists(self.vx_socket()):
            raise Failed("venom started a venomx daemon: %s exists" % self.vx_socket())
        ps = subprocess.run(["pgrep", "-f", self.root + "/bin/venomx"], capture_output=True, text=True).stdout.strip()
        if ps:
            raise Failed("a venomx process runs: %s" % ps)
        t.send("q")
        until("venom to quit", lambda: t.proc.poll() is not None)
        if t.proc.returncode != 0:
            raise Failed("venom exited %d" % t.proc.returncode)
        log("PASS auto, no daemon: own mode, no venomx started")

        # A missing owner file is not a missing daemon.
        owner = os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venom.owner")
        os.rename(owner, owner + ".aside")
        try:
            env = {k: v for k, v in self.env.items() if k != "VENOM_TOKEN"}
            t = Terminal([self.venom], env)
            self.terms.append(t)
            until("venom to give up", lambda: t.proc.poll() is not None)
            time.sleep(0.1)
            if "owner file" not in t.text() or "not running" in t.text():
                raise Failed("a missing owner file reads: %r" % t.text()[-300:])
        finally:
            os.rename(owner + ".aside", owner)
        log("PASS missing owner file: reported as that")

    # --- 2: own, with venomx up ----------------------------------------------

    def set_config(self, key, value):
        # `config set` only persists; `config reload` is what the daemon acts on.
        self.cli("config", "set", "--key=" + key, "--value=" + value)
        self.cli("config", "reload")

    def notifications(self):
        return self.vx("notify", "list")["notifications"]

    def no_key_table_principal(self):
        made = [g for g in self.vx("grant", "list")["principals"] if g.get("label") == "venom key table"]
        if made:
            raise Failed("a principal for the key table: %s" % made)

    def wide_grants_stay_outside_panes(self):
        # Only the daemon's notifications may hold daemon-wide write, and no
        # pane has that principal. The key table has no principal of its own.
        wide = [g for g in self.vx("grant", "list")["principals"] if any(x["right"] in ("write", "spawn") and x["scope"] in ("server:root", "*") for x in g["grants"]) and g["principal"] != "owner"]
        if [g for g in wide if g.get("pane") or g.get("label") != "venom notifications"]:
            raise Failed("daemon-wide write beyond the notifier: %s" % wide)
        return wide

    @staticmethod
    def bells(t):
        # BELs, not the ones ending an OSC string.
        return re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\\\)", b"", bytes(t.out)).count(b"\x07")

    def own_mode(self, agents):
        self.set_config("ui.chrome", ".own")
        self.set_config("attention.notify_after", '"1s"')
        t = self.terminal()
        t.wait_for("need you")

        # What was there at the start does not ring. A new item does, once.
        time.sleep(0.5)
        if self.bells(t) != 0:
            raise Failed("a BEL for items already there")
        extra = self.spawn("alpha", "claude-code")
        until("a BEL for the new item", lambda: self.bells(t) == 1)
        time.sleep(0.5)
        if self.bells(t) != 1:
            raise Failed("more than one BEL for one item")
        log("own: a new blocking item rang one BEL")
        self.cli("config", "set", "--key=attention.bell", "--value=false")
        silent = self.spawn("beta", "codex")
        time.sleep(1.0)
        if self.bells(t) != 1:
            raise Failed("a BEL with attention.bell = false")
        self.cli("config", "set", "--key=attention.bell", "--value=true")
        log("own: attention.bell = false is silent, read live")
        for agent in (extra, silent):
            self.cli("inbox", "answer", "--agent=" + agent, "--answer=allow_once")
            self.wait(agent, ("settled",))
            self.cli("agent", "archive", "--agent=" + agent)

        # Own mode stays out of venomx, however long items wait.
        time.sleep(1.5)
        if self.notifications():
            raise Failed("own mode posted: %s" % self.notifications())
        if [g for g in self.vx("grant", "list")["principals"] if g.get("label") == "venom notifications"]:
            raise Failed("own mode took a token from venomx")
        self.set_config("attention.notify_after", '"2m"')
        log("own: no notification and no venomx token with ui.chrome = own")

        # `d`: the selected agent's diff, in the pager.
        t.send("d")
        t.wait_for("Diff · ")
        t.send("\x1b")
        time.sleep(0.3)
        log("own: d shows the diff in the pager")

        t.send(" ")
        time.sleep(0.1)
        t.send("i")
        t.wait_for("Inbox")
        # Answer-and-advance, one approval per agent.
        for agent in agents:
            until("an inbox item", lambda: any(i["agent"] == agent for i in self.cli("inbox", "list")["items"]))
        for n in range(len(agents)):
            before = self.approvals()
            # Again until it lands: the cursor needs a frame to reach the next item.
            until("the answer to land", lambda: t.send("y") or time.sleep(0.3) or self.approvals() < before)
        for agent in agents:
            self.wait(agent, ("settled",))
        if self.vx("session", "list")["sessions"]:
            raise Failed("own mode touched venomx: %s" % self.vx("session", "list"))
        t.send("\x1b")
        time.sleep(0.3)  # or the two read as alt+q
        t.send("q")
        until("venom to quit", lambda: t.proc.poll() is not None)
        self.set_config("ui.chrome", ".auto")
        log("PASS own with venomx up: two agents answered from the inbox; venomx untouched")

    # --- 3: host ---------------------------------------------------------------

    def host_mode(self, agents):
        t = self.terminal()
        control = until("a control pane", lambda: next((p for p in self.panes() if self.tags(p).get("role") == "control"), None))
        tags = self.tags(control)
        if tags.get("product") != "venom":
            raise Failed("control pane tags: %s" % tags)
        session = [s for s in self.vx("session", "list")["sessions"] if s["session"] == control["session"]][0]
        if session["name"] != "venom":
            raise Failed("control pane in session %s" % session)
        log("control pane %s in session %s" % (control["pane"], control["session"]))
        cp = control["pane"]

        # Its bar is the bottom row of its own pane.
        def bar():
            rows = self.capture(cp).rstrip("\n").split("\n")
            return rows[-1] if "need you" in rows[-1] else None
        last = until("venom's bar on the control pane's bottom row", bar)
        log("control pane's bottom row: " + last.strip())

        # This terminal is now venomx's presentation client, with the table.
        table = until("the venom key table", lambda: next((x for x in self.vx("keys", "list")["tables"] if x["name"] == "venom"), None))
        if table.get("prefix") != "v" or table.get("when") or table.get("layer") != "product" or table.get("source") != "owner":
            raise Failed("key table: %s" % table)
        segments = self.vx("status", "list")["segments"]
        if any(s["id"].startswith("venom.") for s in segments):
            raise Failed("venom published segments: %s" % segments)
        log("key table under v, with no when; no venom.* segments")

        # No pane has daemon-wide write, and registering made no principal.
        self.no_key_table_principal()
        self.wide_grants_stay_outside_panes()
        rights = [g for g in self.vx("grant", "list")["principals"] if g.get("pane") == cp]
        if len(rights) != 1 or sorted((x["right"], x["scope"]) for x in rights[0]["grants"]) != [("read", "*"), ("spawn", "self"), ("write", "self")]:
            raise Failed("the control pane's rights: %s" % rights)
        if rights[0].get("expires") is not None:
            raise Failed("the control pane's principal expires: %s" % rights)
        log("control pane rights: read *, write and spawn self, no expiry; no pane has daemon-wide write")

        # An agent with no pane marks the control pane.
        until("attention on the control pane", lambda: next(p for p in self.panes() if p["pane"] == cp)["attention"] == "urgent")

        # Enter on the list, twice: a sibling pane per agent.
        time.sleep(0.3)
        t.send("\r")
        until("the first agent pane", lambda: len(self.agent_panes()) == 1)
        t.send("j")
        time.sleep(0.2)
        t.send("\r")
        panes = until("the second agent pane", lambda: (lambda x: x if len(x) == 2 else None)(self.agent_panes()))
        groups = sorted(self.tags(p)["group"] for p in panes)
        if groups != sorted(agents):
            raise Failed("agent panes for %s, want %s" % (groups, agents))
        for p in panes:
            if self.tags(p)["product"] != "venom" or p["session"] != control["session"]:
                raise Failed("agent pane %s" % p)
        log("agent panes: %s" % ", ".join("%s=%s" % (p["pane"], self.tags(p)["group"]) for p in panes))

        # Attention moved to the agents' panes and left the control pane.
        until("urgent attention on both agent panes", lambda: all(p["attention"] == "urgent" for p in self.agent_panes()))
        until("the control pane clear", lambda: next(p for p in self.panes() if p["pane"] == cp)["attention"] == "none")
        log("approvals: attention urgent on both agent panes")

        # An agent's pane shows that agent, with no list and no bar.
        for p in panes:
            title = self.spawned[self.tags(p)["group"]].get("title") or "host demo"
            shown = until("the agent's view in %s" % p["pane"], lambda: (lambda c: c if "host demo" in c else None)(self.capture(p["pane"])))
            if "need you" in shown or "Agents" in shown:
                raise Failed("agent pane %s draws venom's chrome:\n%s" % (p["pane"], shown))
            _ = title
        log("agent panes show their agent, no list, no bar")

        # Popups, on this client only, through the key table.
        def popups():
            return [p for p in self.panes() if p["layer"] == "popup"]
        leader = {"ctrl+space": b"\x00", "ctrl+a": b"\x01", "ctrl+b": b"\x02"}[self.vx("keys", "list")["leader"]]
        t.send(leader)
        time.sleep(0.1)
        t.send("v")
        time.sleep(0.1)
        t.send("s")
        pop = until("the settings popup", lambda: (popups() or [None])[0])
        until("the settings popup's content", lambda: "Settings" in self.capture(pop["pane"]))
        log("settings popup: %s" % pop["pane"])
        # Esc reaches the screen, so a pending edit asks before it is lost.
        time.sleep(0.3)
        t.send("\t")
        time.sleep(0.2)
        t.send("\r")
        until("the pending edit", lambda: "1 unsaved" in self.capture(pop["pane"]))
        t.send("\x1b")
        until("the unsaved warning", lambda: "1 unsaved: again drops, ⌃s saves" in self.capture(pop["pane"]))
        if not popups():
            raise Failed("esc closed the settings popup over a pending edit")
        t.send("\x1b")
        until("the settings popup to close", lambda: not popups())
        log("settings popup: esc asks over a pending edit, then closes")

        # Its size comes from the preset: venomx's own default is 60%. This
        # terminal is 100 columns and the border takes two.
        def open_settings():
            t.send(leader)
            time.sleep(0.1)
            t.send("v")
            time.sleep(0.1)
            t.send("s")
            shown = until("the settings popup", lambda: (popups() or [None])[0])
            until("the settings popup's content", lambda: "Settings" in self.capture(shown["pane"]))
            return shown
        pop = open_settings()
        # The capture can come before the popup is laid out at its size.
        until("the settings popup at the registered preset's 80%", lambda: self.size(pop["pane"])[0] == 78)
        t.send("\x1b")
        until("the settings popup to close", lambda: not popups())
        self.vx("config", "set", '--key=floats.presets."venom.settings".width', '--value="50%"')
        self.vx("config", "reload")
        time.sleep(1.0)  # The client refreshes its keys, ending a leader sequence.
        pop = open_settings()
        until("the settings popup after the preset's width became 50%", lambda: self.size(pop["pane"])[0] == 48)
        t.send("\x1b")
        until("the settings popup to close", lambda: not popups())
        self.vx("config", "set", '--key=floats.presets."venom.settings".width', '--value="80%"')
        self.vx("config", "reload")
        time.sleep(1.0)  # The client refreshes its keys, ending a leader sequence.
        log("settings popup: 78 columns from the preset, 48 once config says 50%")

        # A pane has no popup ticket, so `space s` draws the settings right here.
        t.send(" ")
        time.sleep(0.1)
        t.send("s")
        until("the settings in the control pane", lambda: "Settings" in self.capture(cp))
        if popups():
            raise Failed("`space s` opened a popup: %s" % popups())
        t.send("\x1b")
        until("the control pane's list", lambda: "Settings" not in self.capture(cp))
        log("`space s` in the control pane: drawn in the pane, no popup; esc goes back")
        # The tree's popup is the control pane's own content, without the
        # direction rows no verb could run.
        t.send(" ")
        until("venom's key popup", lambda: "venom" in self.capture(cp) and "agents" in self.capture(cp) and "splits" in self.capture(cp))
        t.send("v")
        until("the splits level", lambda: "close the split" in self.capture(cp))
        if "split to the left" in self.capture(cp):
            raise Failed("the direction rows in host mode:\n%s" % self.capture(cp))
        t.send("\x1b")
        until("the popup to close", lambda: "close the split" not in self.capture(cp))
        # doctor warns when venomx would take venom's leader first.
        theirs = self.vx("keys", "list")["leader"]
        self.set_config("ui.keys.leader", json.dumps(theirs))
        found = [c for c in self.cli("doctor", ok=False)["checks"] if c["id"] == "ui.keys.leader"]
        if not found or found[0]["status"] != "warn":
            raise Failed("doctor on a leader equal to venomx's: %s" % found)
        self.set_config("ui.keys.leader", '"space"')
        found = [c for c in self.cli("doctor", ok=False)["checks"] if c["id"] == "ui.keys.leader"]
        if not found or found[0]["status"] != "ok":
            raise Failed("doctor on venom's own leader: %s" % found)
        log("space popup in the control pane; doctor warns on venomx's leader")
        # `d` is the pager in this pane: the popup needs a ticket a pane can't get.
        t.send("d")
        until("the diff in the control pane", lambda: "Diff · " in self.capture(cp))
        if popups():
            raise Failed("`d` opened a popup: %s" % popups())
        t.send("\x1b")
        until("the control pane's list", lambda: "Diff · " not in self.capture(cp))
        t.send(leader)
        time.sleep(0.1)
        t.send("v")
        time.sleep(0.1)
        t.send("d")
        pop = until("the diff popup", lambda: (popups() or [None])[0])
        until("the diff popup's header", lambda: "──" in self.capture(pop["pane"]))
        log("diff popup: %s\n%s" % (pop["pane"], self.capture(pop["pane"]).strip()[:200]))
        t.send(leader)
        time.sleep(0.1)
        t.send("x")
        until("the diff popup to close", lambda: not popups())

        t.send(leader)
        time.sleep(0.1)
        t.send("v")
        time.sleep(0.1)
        t.send("i")
        pop = until("the inbox popup", lambda: (popups() or [None])[0])
        until("the inbox popup's items", lambda: "approval" in self.capture(pop["pane"]))
        t.send(leader)
        time.sleep(0.1)
        t.send("x")
        until("the inbox popup to close", lambda: not popups())
        log("inbox popup: %s" % pop["pane"])
        self.keys_from_any_pane(t, cp, leader)

        # A program in an agent's pane has that pane's rights: read only.
        # Its shell split is the path a take-over harness takes.
        a_pane = panes[0]["pane"]
        out = os.path.join(self.root, "split.out")
        self.vx("pane", "send", "--pane=" + a_pane, "--text=\\")
        until("the agent pane's split menu", lambda: "Shell in worktree" in self.capture(a_pane))
        self.vx("pane", "send", "--pane=" + a_pane, "--text=2")
        time.sleep(0.5)
        command = "(env | grep -c VENOMX_; %s pane send --pane=%s --text=x --json; %s pane kill --pane=%s --json) 2>&1 | cat > %s; echo done >> %s\r" % (self.venomx_exe, cp, self.venomx_exe, panes[1]["pane"], out, out)
        self.vx("pane", "send", "--pane=" + a_pane, "--text=" + command)
        got = until("the split's attempt", lambda: (lambda c: c if "done" in c else None)(open(out).read() if os.path.exists(out) else ""))
        lines = got.splitlines()
        if lines[0] != "0" or "denied.write" not in lines[1] or "denied.write" not in lines[2]:
            raise Failed("a program in a split drove a pane:\n" + got)
        self.vx("pane", "send", "--pane=" + a_pane, "--text=\x17")
        log("a split's program has no VENOMX_* and cannot drive other panes: denied.write")

        # Unanswered past notify_after: one notification each, from the daemon.
        if self.notifications():
            raise Failed("a notification before notify_after: %s" % self.notifications())
        self.set_config("attention.notify_after", '"2s"')
        posted = until("a notification per blocking item", lambda: (lambda n: n if len(n) == 2 else None)(self.notifications()))
        time.sleep(1.0)
        if len(self.notifications()) != 2:
            raise Failed("not one notification per item: %s" % self.notifications())
        for n in posted:
            if n["level"] != "urgent" or n["namespace"] != "venom" or "host demo" not in n["text"]:
                raise Failed("notification: %s" % n)
        # The control pane's rights did not grow for this.
        wide = self.wide_grants_stay_outside_panes()
        if not [g for g in wide if g.get("label") == "venom notifications"]:
            raise Failed("who posted? %s" % wide)
        rights = [g for g in self.vx("grant", "list")["principals"] if g.get("pane") == cp]
        if sorted((x["right"], x["scope"]) for x in rights[0]["grants"]) != [("read", "*"), ("spawn", "self"), ("write", "self")]:
            raise Failed("the control pane's rights changed: %s" % rights)
        log("two blocking items past notify_after: two notifications, posted by the daemon; the control pane still has write self")

        # Answered anywhere: its attention and its notification clear.
        answered, other = agents
        self.cli("inbox", "answer", "--agent=" + answered, "--answer=allow_once")
        until("its notification dismissed", lambda: len(self.notifications()) == 1)
        pane_of = {self.tags(p)["group"]: p["pane"] for p in self.agent_panes()}
        # The approval's urgent mark goes; what is left is its unread review,
        # at `info`.
        until("the urgent mark gone after the answer", lambda: next(p for p in self.panes() if p["pane"] == pane_of[answered])["attention"] in ("none", "info"))
        if next(p for p in self.panes() if p["pane"] == pane_of[other])["attention"] != "urgent":
            raise Failed("the other agent's attention went too")
        self.wait(answered, ("settled",))
        log("answered %s from the CLI: its pane is no longer urgent, its notification gone; %s still is" % (answered, other))

        # A new item in an agent's own pane: the BEL in the control pane leaves
        # venomx's `info` there, and that clears as well.
        self.cli("inbox", "answer", "--agent=" + other, "--answer=allow_once")
        self.wait(other, ("settled",))
        until("the other notification dismissed", lambda: not self.notifications())
        until("the control pane clear of attention", lambda: next(p for p in self.panes() if p["pane"] == cp)["attention"] == "none")
        # Followed from the event log: a client focused on the control pane
        # clears the `info` as soon as it sees it, faster than a poll.
        tail, bel_info = self.follow_attention(self.event_cursor(), cp, "info")
        try:
            self.cli("agent", "send", "--agent=" + other, "--text=say hi with echo again")
            self.wait(other, ("needs_you",))
            until("urgent on its pane", lambda: next(p for p in self.panes() if p["pane"] == pane_of[other])["attention"] == "urgent")
            until("the BEL's info on the control pane", lambda: bel_info)
        finally:
            tail.kill()
            tail.wait()
        self.cli("inbox", "answer", "--agent=" + other, "--answer=allow_once")
        self.wait(other, ("settled",))
        until("the BEL's info cleared", lambda: next(p for p in self.panes() if p["pane"] == cp)["attention"] == "none")
        until("no notification left", lambda: not self.notifications())
        self.set_config("attention.notify_after", '"2m"')
        log("a BEL for an agent in its own pane: info on the control pane, cleared after the answer")

        # on_exit = keep, and a pane is only a view.
        target = pane_of[answered]
        self.vx("pane", "kill", "--pane=" + target)
        p = until("the exited pane to stay", lambda: next((x for x in self.panes() if x["pane"] == target and x["exited"]), None))
        if self.state(answered) != "settled":
            raise Failed("closing a pane touched the agent")
        self.vx("pane", "kill", "--pane=" + pane_of[other])
        until("the second pane to exit", lambda: next((x for x in self.panes() if x["pane"] == pane_of[other] and x["exited"]), None))
        if self.state(other) != "settled":
            raise Failed("closing a pane touched the agent")
        log("killed panes stay (on_exit keep); the agents are untouched")

        # Splits, next to the agents' panes. `⏎` once more, since the
        # kills above left exited panes.
        self.vx("pane", "send", "--pane=" + cp, "--text=\r")
        until("a live agent pane again", lambda: self.agent_panes())
        selected = self.tags(next(p for p in self.panes() if p["pane"] == cp)).get("venom.selected")
        cp, _ = self.host_splits(selected)
        self.host_takeover(cp, selected)

        # A second `venom` finds the control pane instead of making another,
        # and it acts on what that `venom` was asked for.
        # Its registration is under a token cap it would not outlast, had it
        # needed a token: the table has no expiry.
        self.vx("config", "set", "--key=grants.max_token_ttl", "--value=1")
        t2 = self.terminal("agent", "view", "--agent=" + other, "--inbox=true")
        until("the second attach", lambda: b"\x1b[" in t2.out)
        until("the control pane to take --inbox and --agent", lambda: "Inbox " in self.capture(cp))
        tags = self.tags(next(p for p in self.panes() if p["pane"] == cp))
        if tags.get("venom.selected") != other or "venom.open_inbox" in tags or "venom.open_agent" in tags:
            raise Failed("the control pane's tags after --agent: %s" % tags)
        if sum(1 for p in self.panes() if self.tags(p).get("role") == "control") != 1:
            raise Failed("a second control pane: %s" % self.panes())
        log("a second venom reused the control pane and honoured --agent and --inbox")
        t3 = self.terminal("agent", "view", "--usage=true")
        until("the third attach", lambda: b"\x1b[" in t3.out)
        until("the control pane to take --usage", lambda: "Usage" in self.capture(cp) and re.search(r"[1-9]\d* turns", self.capture(cp)))
        if "venom.open_usage" in self.tags(next(p for p in self.panes() if p["pane"] == cp)):
            raise Failed("venom.open_usage stayed on the control pane")
        log("and --usage")
        time.sleep(2.5)
        self.vx("config", "set", "--key=grants.max_token_ttl", "--value=86400")
        table = next((x for x in self.vx("keys", "list")["tables"] if x["name"] == "venom"), None)
        if not table or table.get("source") != "owner":
            raise Failed("the key table after the token cap: %s" % table)
        self.no_key_table_principal()
        log("the key table outlived the token cap; no principal for it")

        # Removed, it is shown, not silent (human_pane).
        self.vx("keys", "unregister", "--name=venom")
        t.send("\x1b")
        until("the key table to go", lambda: not any(x["name"] == "venom" for x in self.vx("keys", "list")["tables"]))
        log("PASS host: control pane, two agent panes, attention, keys, popups")

    def keys_from_any_pane(self, t, cp, leader):
        # The `venom` key table works from any pane, not only the control pane.
        def popups():
            return [p for p in self.panes() if p["layer"] == "popup"]
        def press(*seq):
            t.send(leader)
            for key in seq:
                time.sleep(0.1)
                t.send(key)
        def table():
            return next(x for x in self.vx("keys", "list")["tables"] if x["name"] == "venom")

        # The inbox popup just closed: let the focus come back.
        time.sleep(0.5)
        # No verb moves a client's focus, so `space v` has no direction rows.
        t.send(" ")
        time.sleep(0.1)
        t.send("v")
        tree = until("the space v popup", lambda: (lambda c: c if "split menu" in c else None)(self.capture(cp)))
        rows = ("split to the left", "split to the right", "into the input box")
        if any(r in tree for r in rows) or re.search(r"\bk\b.*\bup\b", tree):
            raise Failed("direction rows in the host-mode popup:\n%s" % tree)
        t.send("\x1b")
        until("the space v popup to close", lambda: "split menu" not in self.capture(cp))
        log("space v in host mode: no direction rows")

        # The rows and labels are the tree's.
        rows = {b["key"]: b.get("label") for b in table()["bindings"]}
        if rows != {"i": "inbox", "s": "settings", "d": "diff", "u": "usage"}:
            raise Failed("the table's rows: %s" % rows)

        # A pane venom knows nothing about: no product tag, no agent.
        before = {p["pane"] for p in self.panes()}
        press("\\")
        shell = until("the human's shell pane", lambda: next((p for p in self.panes() if p["pane"] not in before), None))
        if "product" in self.tags(shell) or "group" in self.tags(shell):
            raise Failed("the human's pane has venom's tags: %s" % self.tags(shell))
        time.sleep(0.3)
        # The split takes this client's focus: the diff below
        # shows which pane has it.
        press("v", "s")
        pop = until("the settings popup from a shell pane", lambda: (popups() or [None])[0])
        until("the settings popup's content from a shell pane", lambda: "Settings" in self.capture(pop["pane"]))
        time.sleep(0.3)
        t.send("\x1b")
        until("the settings popup to close", lambda: not popups())
        time.sleep(0.3)
        press("v", "i")
        pop = until("the inbox popup from a shell pane", lambda: (popups() or [None])[0])
        until("the inbox popup's items from a shell pane", lambda: "approval" in self.capture(pop["pane"]))
        time.sleep(0.3)
        # It stays one screen: no split menu, and so no shell in the agent's worktree.
        t.send("\\")
        until("backslash to say where to open it", lambda: "open it from the control pane" in self.capture(pop["pane"]))
        if "Shell in worktree" in self.capture(pop["pane"]):
            raise Failed("the split menu in the inbox popup: %s" % self.capture(pop["pane"]))
        time.sleep(0.1)
        t.send("\x1b")
        until("esc to close the inbox popup", lambda: not popups())
        time.sleep(0.3)
        press("v", "u")
        pop = until("the usage popup from a shell pane", lambda: (popups() or [None])[0])
        # A row is what usage.show answered: the frame draws without it.
        until("the usage popup's rows", lambda: re.search(r"[1-9]\d* turns", self.capture(pop["pane"])))
        # Enter stays here: this connection can't answer in a transcript.
        t.send("\r")
        until("enter to say where to open it", lambda: "open it from the control pane" in self.capture(pop["pane"]))
        if "allow once" in self.capture(pop["pane"]) or not popups():
            raise Failed("enter left the usage screen: %s" % self.capture(pop["pane"]))
        t.send("\x1b")
        until("esc to close the usage popup", lambda: not popups())
        time.sleep(0.3)
        # A binding that needs an agent says so: this pane has none.
        press("v", "d")
        pop = until("the diff popup from a shell pane", lambda: (popups() or [None])[0])
        until("the diff popup's refusal", lambda: "shows no agent" in self.capture(pop["pane"]))
        # Its process has exited (on_exit keep): a bare esc dismisses it.
        until("the diff popup to exit", lambda: next((x for x in popups() if x["pane"] == pop["pane"] and x["exited"]), None))
        time.sleep(0.3)
        t.send("\x1b")
        until("the diff popup to close", lambda: not popups())
        time.sleep(0.3)
        # Another product's `group` tag names no agent of venom's, even a real one.
        real = next(self.tags(p)["group"] for p in self.panes() if self.tags(p).get("role") == "agent")
        self.vx("pane", "tag", "--pane=" + shell["pane"], "--set=" + json.dumps([{"key": "group", "value": real}]))
        press("v", "d")
        pop = until("the diff popup from a pane with a foreign group", lambda: (popups() or [None])[0])
        until("the refusal for a foreign group", lambda: "shows no agent" in self.capture(pop["pane"]))
        until("the diff popup to exit", lambda: next((x for x in popups() if x["pane"] == pop["pane"] and x["exited"]), None))
        time.sleep(0.3)
        t.send("\x1b")
        until("the diff popup to close", lambda: not popups())
        time.sleep(0.3)
        log("ctrl+a v s, i, u from a shell pane; v d there says it has no agent")

        # keys.prefixes moves the table without restating it.
        self.vx("config", "set", "--key=keys.prefixes", '--value=.{.{.name="venom",.prefix="a"}}')
        until("the moved prefix", lambda: table().get("prefix") == "a")
        time.sleep(0.5)
        press("a", "s")
        pop = until("the settings popup under the moved prefix", lambda: (popups() or [None])[0])
        until("its content under the moved prefix", lambda: "Settings" in self.capture(pop["pane"]))
        time.sleep(0.3)
        t.send("\x1b")
        until("the settings popup to close", lambda: not popups())
        time.sleep(0.3)
        press("v", "s")
        time.sleep(1)
        if popups():
            raise Failed("the old prefix still opens a popup: %s" % popups())
        self.vx("config", "set", "--key=keys.prefixes", "--value=.{}")
        until("the prefix back", lambda: table().get("prefix") == "v")
        log("keys.prefixes moved the table to a and back")

        # Back to the control pane, for what follows.
        self.vx("pane", "kill", "--pane=" + shell["pane"])
        until("the shell pane to go", lambda: all(p["pane"] != shell["pane"] for p in self.panes()))
        time.sleep(0.3)

    def human_pane(self):
        # `venom` typed into a pane the human opened: that pane is the control
        # pane and can't register, so with the table removed its bar
        # says so, whole at 80 columns, and a key press leaves it there.
        made = self.vx("session", "create", "--name=human")
        sock = "--socket=" + os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venom.sock")
        w = self.vx("window", "create", "--session=" + made["session"], "--name=sh", "--argv=" + json.dumps([self.venom, "agent", "view", sock]), "--cols=80", "--rows=30")
        p = w["pane"]
        until("the role tag on the human's pane", lambda: self.tags(next(x for x in self.panes() if x["pane"] == p)).get("role") == "control")
        notice = "no venom keys: run venom outside venomx"
        def bar():
            return self.capture(p).rstrip("\n").split("\n")[-1]
        until("the key table notice", lambda: notice in bar())
        self.vx("pane", "send", "--pane=" + p, "--text=j")
        time.sleep(0.3)
        if notice not in bar():
            raise Failed("a key press took the notice: %r" % bar())
        log("no key table: the bar says so at 80 columns, after a key press too: " + bar().strip())
        self.vx("pane", "send", "--pane=" + p, "--text=\r")
        sib = until("a sibling agent pane in the human's session", lambda: next((x for x in self.panes() if x["session"] == made["session"] and self.tags(x).get("role") == "agent"), None))
        # Quitting gives the pane back: no role left behind.
        self.vx("pane", "send", "--pane=" + p, "--text=q")
        # The program exits, on_exit keep: the tag is what matters.
        until("the control tags cleared", lambda: "role" not in self.tags(next(x for x in self.panes() if x["pane"] == p)))
        log("PASS venom in a human's pane: control pane %s, agent pane %s, no key table" % (p, sib["pane"]))

    # --- 5: a take-over outlives its TUI ---------------------------------------

    def raw(self, *args):
        p = subprocess.run([self.venom, *args, "--json"], env=self.env, capture_output=True, text=True, timeout=30)
        return p.returncode, (json.loads(p.stdout) if p.stdout.strip() else {})

    def control(self):
        return next((p for p in self.panes() if self.tags(p).get("role") == "control" and not p["exited"]), None)

    def take_over_from(self, cp, agent):
        time.sleep(0.3)
        self.vx("pane", "send", "--pane=" + cp, "--text=\\\\")
        until("the menu's take over", lambda: "Take over in" in self.capture(cp))
        self.vx("pane", "send", "--pane=" + cp, "--text=3")
        self.wait(agent, ("handed_over",))
        return until("the take-over pane", lambda: (self.split_panes(agent, "take_over") or [None])[0])["pane"]

    def expect_refused(self, agent, want):
        rc, got = self.raw("agent", "takeback", "--agent=" + agent)
        if rc == 0 or got.get("error", {}).get("code") != want:
            raise Failed("take-back while %s: %d %s" % (want, rc, got))
        rc, got = self.raw("agent", "send", "--agent=" + agent, "--text=a second writer")
        if rc == 0:
            raise Failed("a turn started beside the harness: %s" % got)
        if self.state(agent) != "handed_over":
            raise Failed("%s left handed_over: %s" % (agent, self.state(agent)))

    def quit_control(self, cp):
        self.vx("pane", "send", "--pane=" + cp, "--text=q")
        until("the control pane to go", lambda: not any(p["pane"] == cp and not p["exited"] for p in self.panes()))

    def new_control(self, agent):
        self.terminal("agent", "view", "--agent=" + agent)
        p = until("a control pane", self.control)
        until("the selection", lambda: self.tags(next(x for x in self.panes() if x["pane"] == p["pane"])).get("venom.selected") == agent)
        return p["pane"]

    def takeover_outlives_tui(self, agent):
        self.wait(agent, ("settled",))
        cp = self.new_control(agent)
        pane = self.take_over_from(cp, agent)
        time.sleep(0.5)
        self.quit_control(cp)
        self.expect_refused(agent, "conflict.takeover_pane_running")
        log("TUI quit, pane %s runs: take-back and send refused" % pane)

        self.stop()
        self.start()
        self.expect_refused(agent, "conflict.takeover_pane_running")
        log("daemon restart: re-checked through venomx; still handed over")

        # The new control pane has no write on it, and says what to do.
        cp = self.new_control(agent)
        for _ in range(2):
            self.vx("pane", "send", "--pane=" + cp, "--text=T")
            until("the refusal on the bar", lambda: "cannot close" in self.capture(cp))
        log("T in a new control pane: denied, and it says to quit the harness there, each time")

        # A configured empty grants.unknown: nothing to read; the daemon can't tell.
        default = self.vx("config", "get", "--key=grants.unknown")["content"]
        self.vx("config", "set", "--key=grants.unknown", "--value=.{}")
        self.vx("config", "reload")
        other = self.vx("session", "create", "--name=bystander2")["session"]
        bystander = self.vx("window", "create", "--session=" + other, "--name=b", "--argv=" + json.dumps(["/bin/sh", "-c", "exec sleep 600"]), "--cols=60", "--rows=10")["pane"]
        env = dict(self.env, VENOMX_TOKEN="@owner")
        sock = os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venom.sock")
        made = subprocess.run([self.venom, "agent", "split", "--agent=" + agent, "--kind=shell", "--pane=" + cp, "--socket=" + sock, "--json"], env=env, capture_output=True, text=True, timeout=30)
        shell = json.loads(made.stdout)["pane"]
        rights = [g for g in self.vx("grant", "list")["principals"] if g.get("pane") == shell]
        if len(rights) != 1 or rights[0]["grants"]:
            raise Failed("the shell's rights with grants.unknown = .{}: %s" % rights)
        got = self.in_pane(shell, "%s pane capture --pane=%s --json; %s pane list --json" % (self.venomx_exe, bystander, self.venomx_exe))
        if got.count("denied.read") != 2:
            raise Failed("the shell read with grants.unknown = .{}:\n%s" % got)
        self.expect_refused(agent, "unavailable.takeover_pane")
        self.stop()
        self.start()
        self.expect_refused(agent, "unavailable.takeover_pane")
        self.vx("pane", "kill", "--pane=" + shell, "--remove=true")
        self.vx("config", "set", "--key=grants.unknown", "--value=" + default)
        self.vx("config", "reload")
        log("grants.unknown = .{}: a shell reads nothing; the daemon can't tell, stays handed over, says why")

        # A restart did not end the control pane's rights:
        # it takes the agent back below, with no note and no new pane.
        if "ended" in self.capture(cp):
            raise Failed("a bound control pane says its token ended")

        # The harness ending: the control pane sees it and takes the agent back.
        self.vx("pane", "kill", "--pane=" + pane)
        self.wait(agent, ("settled",))
        log("the harness ended: the new control pane took %s back" % agent)

        # With no TUI at all, the CLI may once venomx says it is gone, and a
        # restart settles it.
        pane = self.take_over_from(cp, agent)
        time.sleep(0.5)
        self.quit_control(cp)
        self.vx("pane", "kill", "--pane=" + pane)
        until("the pane to go", lambda: not self.split_panes(agent, "take_over"))
        if self.state(agent) != "handed_over":
            raise Failed("nobody was watching, yet: %s" % self.state(agent))
        rc, got = self.raw("agent", "takeover-split", "--agent=" + agent, "--pid=2")
        if rc == 0 or got.get("error", {}).get("code") != "conflict.takeover_pane_gone":
            raise Failed("reporting the process of a pane that ended: %d %s" % (rc, got))
        rc, got = self.raw("agent", "takeback", "--agent=" + agent)
        if rc != 0:
            raise Failed("take-back of a gone pane: %s" % got)
        cp = self.new_control(agent)
        pane = self.take_over_from(cp, agent)
        time.sleep(0.5)
        self.quit_control(cp)
        self.vx("pane", "kill", "--pane=" + pane)
        until("the pane to go", lambda: not self.split_panes(agent, "take_over"))
        self.stop()
        self.start()
        self.wait(agent, ("settled",))
        log("PASS take-over outlives its TUI: no second writer; gone panes take back")

    def agent_panes(self):
        return [p for p in self.panes() if self.tags(p).get("role") == "agent" and not p["exited"] and self.tags(p).get("venom.split", "agent_view") == "agent_view"]

    # --- 4: splits ------------------------------------------------------------

    def size(self, pane):
        r = self.vx("pane", "capture", "--pane=" + pane)
        return (r["cols"], r["rows"])

    def split_panes(self, agent, kind):
        return [p for p in self.panes() if self.tags(p).get("group") == agent and self.tags(p).get("venom.split") == kind and not p["exited"]]

    def in_pane(self, pane, script):
        """Runs a script in a shell pane, as a process of that pane; its output."""
        out = os.path.join(self.root, "in-%s-%d.out" % (pane, time.time_ns()))
        self.vx("pane", "send", "--pane=" + pane, "--text=(%s) 2>&1 | cat > %s; echo done >> %s\r" % (script, out, out))
        return until("the script in " + pane, lambda: (lambda c: c if c.endswith("done\n") else None)(open(out).read() if os.path.exists(out) else ""))

    def host_splits(self, agent):
        sock = os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venom.sock")
        cp = next(p for p in self.panes() if self.tags(p).get("role") == "control")["pane"]
        session = next(p for p in self.panes() if p["pane"] == cp)["session"]
        worktree = os.path.realpath(self.cli("agent", "show", "--agent=" + agent)["cwd"])
        state = self.state(agent)

        # An agent's existing pane: its view, from the list. The control pane
        # has been told to select `agent` through --agent earlier.
        t2 = self.terminal("agent", "view", "--agent=" + agent)
        until("the second attach", lambda: b"\x1b[" in t2.out)
        until("the selection", lambda: self.tags(next(p for p in self.panes() if p["pane"] == cp)).get("venom.selected") == agent)
        existing = until("the agent's own pane", lambda: (self.split_panes(agent, "agent_view") or [None])[0])
        log("the agent's existing pane: %s" % existing["pane"])

        # A shell from the menu lands next to it: the agent's pane shrinks and
        # the control pane does not.
        before = (self.size(cp), self.size(existing["pane"]))
        menu_at = len(self.panes())
        self.vx("pane", "send", "--pane=" + cp, "--text=\\")
        until("the split menu with a shell", lambda: "Shell in worktree" in self.capture(cp))
        self.vx("pane", "send", "--pane=" + cp, "--text=2")
        shell = until("the shell split", lambda: (self.split_panes(agent, "shell") or [None])[0])
        if self.tags(shell)["role"] != "agent" or self.tags(shell)["product"] != "venom" or shell["session"] != session or len(self.panes()) != menu_at + 1:
            raise Failed("shell pane: %s" % shell)
        after = (self.size(cp), self.size(existing["pane"]))
        if after[0] != before[0] or after[1] == before[1]:
            raise Failed("the shell did not land next to the agent's pane: %s -> %s" % (before, after))
        log("shell %s landed next to %s: %s -> %s" % (shell["pane"], existing["pane"], before[1], after[1]))

        # `venom agent split`, in a caller with the rights, opens a view beside.
        env = dict(self.env, VENOMX_TOKEN="@owner")
        made = subprocess.run([self.venom, "agent", "split", "--agent=" + agent, "--kind=agent_view", "--pane=" + cp, "--socket=" + sock, "--json"], env=env, capture_output=True, text=True, timeout=30)
        if made.returncode != 0:
            raise Failed("agent split exited %d: %s %s" % (made.returncode, made.stdout, made.stderr))
        view = json.loads(made.stdout)
        if view["agent"] != agent or view["kind"] != "agent_view" or view["session"] != session:
            raise Failed("agent split: %s" % view)
        until("the split agent view", lambda: (lambda c: c if "host dem" in c else None)(self.capture(view["pane"])))
        log("agent split: view %s" % view["pane"])

        # Right cwd, no credential, read only.
        got = self.in_pane(shell["pane"], "pwd; echo agent=$VENOM_AGENT; env | grep -cE '^VENOM[A-Z_]*_(TOKEN|PRINCIPAL)=|^VENOMX_'")
        lines = got.splitlines()
        if os.path.realpath(lines[0]) != worktree or lines[1] != "agent=" + agent or lines[2] != "0":
            raise Failed("the shell's cwd or environment (want %s, %s):\n%s" % (worktree, agent, got))
        log("shell: cwd %s, VENOM_AGENT, no credentials" % lines[0])
        rights = [g for g in self.vx("grant", "list")["principals"] if g.get("pane") == shell["pane"]]
        if len(rights) != 1 or [(x["right"], x["scope"]) for x in rights[0]["grants"]] != [("read", "*")]:
            raise Failed("the shell's rights: %s" % rights)

        # It cannot drive another session's pane, or this one's, by any route.
        other = self.vx("session", "create", "--name=bystander")["session"]
        bystander = self.vx("window", "create", "--session=" + other, "--name=b", "--argv=" + json.dumps(["/bin/sh", "-c", "echo bystander; exec sleep 600"]), "--cols=60", "--rows=10")["pane"]
        until("the bystander", lambda: "bystander" in self.capture(bystander))
        vx = self.venomx_exe
        got = self.in_pane(shell["pane"], "; ".join([
            "%s pane send --pane=%s --text=INTRUDER --json" % (vx, bystander),
            "%s pane kill --pane=%s --json" % (vx, bystander),
            "%s pane send --pane=%s --text=INTRUDER --json" % (vx, cp),
            "%s pane kill --pane=%s --json" % (vx, existing["pane"]),
            "%s pane split --pane=%s --axis=cols --argv='[\"true\"]' --json" % (vx, shell["pane"]),
            "%s pane split --pane=%s --axis=cols --argv='[\"true\"]' --json" % (vx, bystander),
            "VENOMX_TOKEN=@owner %s pane kill --pane=%s --json" % (vx, bystander),
            "%s agent split --agent=%s --kind=shell --pane=%s --socket=%s --json" % (self.venom, agent, shell["pane"], sock),
        ]))
        want = ["denied.write", "denied.write", "denied.write", "denied.write", "denied.spawn", "denied.spawn", "denied.token", "denied.spawn"]
        lines = [l for l in got.splitlines() if l != "done"]
        if len(lines) != len(want) or any(w not in l for w, l in zip(want, lines)):
            raise Failed("a process in a split drove a pane (want %s):\n%s" % (want, got))
        by = next(p for p in self.panes() if p["pane"] == bystander)
        if by["exited"] or "INTRUDER" in self.capture(bystander) or "INTRUDER" in self.capture(cp):
            raise Failed("the bystander was touched: %s" % by)
        log("a process in the shell: send, kill, split and @owner on other panes and sessions all denied")

        # Closing them leaves the agent running: the shell exits on its own
        # (on_exit remove), the view the CLI made is its caller's to close, and `space v x`
        # closes the newest of the control pane's own.
        self.vx("pane", "send", "--pane=" + shell["pane"], "--text=exit\r")
        until("the shell's pane to go", lambda: not any(p["pane"] == shell["pane"] for p in self.panes()))
        self.vx("pane", "kill", "--pane=" + view["pane"], "--remove=true")
        time.sleep(1.2)  # the control pane lists its panes once a second
        self.vx("pane", "send", "--pane=" + cp, "--text= vx")
        until("`space v x` to close the agent's pane", lambda: not any(p["pane"] == existing["pane"] for p in self.panes()))
        if self.state(agent) != state:
            raise Failed("closing a split touched the agent: %s" % self.state(agent))
        log("shell exit, a kill and `space v x` closed the splits; %s is still %s" % (agent, state))
        return cp, bystander

    def host_takeover(self, cp, agent):
        if self.state(agent) != "settled":
            raise Failed("take-over needs a settled agent: %s" % self.state(agent))
        self.vx("pane", "send", "--pane=" + cp, "--text=\\")
        until("the menu's take over", lambda: "Take over in" in self.capture(cp))
        self.vx("pane", "send", "--pane=" + cp, "--text=3")
        self.wait(agent, ("handed_over",))
        pane = until("the take-over pane", lambda: (self.split_panes(agent, "take_over") or [None])[0])
        rights = [g for g in self.vx("grant", "list")["principals"] if g.get("pane") == pane["pane"]]
        if len(rights) != 1 or [(x["right"], x["scope"]) for x in rights[0]["grants"]] != [("read", "*")]:
            raise Failed("the take-over pane's rights: %s" % rights)
        env_file = os.path.join(self.root, "takeover.env")
        got = until("the harness's environment", lambda: open(env_file).read() if os.path.exists(env_file) and os.path.getsize(env_file) else None)
        leaked = [l.split("=")[0] for l in got.splitlines() if l.startswith("VENOMX_") or l.split("=")[0] in ("VENOM_TOKEN", "VENOM_PRINCIPAL")]
        if leaked or "VENOM_AGENT=" + agent not in got:
            raise Failed("the harness's environment: %s" % leaked)
        # T ends the harness in its pane, then takes the agent back.
        self.vx("pane", "send", "--pane=" + cp, "--text=T")
        until("the take-over pane to go", lambda: not self.split_panes(agent, "take_over"))
        self.wait(agent, ("settled",))
        log("take-over: read-only pane %s; T closed it and took %s back" % (pane["pane"], agent))
        # The harness ending by itself does the same.
        time.sleep(0.3)
        self.vx("pane", "send", "--pane=" + cp, "--text=\\\\")
        until("the menu again", lambda: "Take over in" in self.capture(cp))
        self.vx("pane", "send", "--pane=" + cp, "--text=3")
        self.wait(agent, ("handed_over",))
        pane = until("the second take-over pane", lambda: (self.split_panes(agent, "take_over") or [None])[0])
        self.vx("pane", "kill", "--pane=" + pane["pane"])
        self.wait(agent, ("settled",))
        log("take-over: its pane ending took %s back" % agent)

    # --- 6: attention while away -------------------------------------------------

    def takeover_args(self, pid):
        path = os.path.join(self.root, "takeover.%d.args" % pid)
        return until("the harness's arguments", lambda: open(path).read().splitlines() if os.path.exists(path) else None)

    def fire_hook(self, pid, event):
        """The hook Claude Code would run, with the command venom gave it, from
        the harness in the pane whose process is `pid`."""
        args = self.takeover_args(pid)
        settings = json.loads(args[args.index("--settings") + 1])
        command = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
        result = os.path.join(self.root, "hook.result")
        if os.path.exists(result):
            os.unlink(result)
        script = "printf '%%s' '%s' | %s > %s.tmp 2>&1; echo \"exit $?\" >> %s.tmp; mv %s.tmp %s\n" % (json.dumps(event), command, result, result, result, result)
        tmp = os.path.join(self.root, "fire.tmp")
        with open(tmp, "w") as f:
            f.write(script)
        os.rename(tmp, os.path.join(self.root, "fire.%d.sh" % pid))
        return until("the hook to run", lambda: open(result).read() if os.path.exists(result) else None)

    def fire_until_accepted(self, pid, event):
        """The TUI reports the process just after the split: until then it is refused."""
        return until("the hook to be accepted", lambda: (lambda r: r if r.strip().endswith("exit 0") else time.sleep(0.2))(self.fire_hook(pid, event)))

    def pane_entry(self, pane):
        return next((p for p in self.panes() if p["pane"] == pane), None)

    def away_items(self, agent):
        return [i for i in self.cli("inbox", "list")["items"] if i["agent"] == agent and i.get("away")]

    def attention_while_away(self, agent):
        permission = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"}
        self.wait(agent, ("settled",))
        cp = self.new_control(agent)
        pane = self.take_over_from(cp, agent)
        # venomx names the process, and the daemon takes it: a hook from inside counts.
        entry = self.pane_entry(pane)
        if not entry.get("pid") or not entry.get("start"):
            raise Failed("pane.list does not say which process: %s" % entry)
        if not any("agent hook --agent " + agent in a for a in self.takeover_args(entry["pid"])):
            raise Failed("no hook in the take-over's command: %s" % self.takeover_args(entry["pid"]))
        got = self.fire_until_accepted(entry["pid"], permission)
        log("a hook from inside pane %s was accepted: %r" % (pane, got))
        until("the away item", lambda: self.away_items(agent))
        item = self.away_items(agent)[0]
        if item["kind"] != "approval" or not item["blocking"]:
            raise Failed("the away item: %s" % item)
        marked = until("attention on the take-over pane", lambda: (lambda p: p if p and p["attention"] == "urgent" else None)(self.pane_entry(pane)))
        for p in self.panes():
            if p["pane"] != pane and p["attention"] != "none" and self.tags(p).get("venom.split") in ("shell", "take_over"):
                raise Failed("attention on another split: %s" % p)
        shown = self.capture(cp)
        if agent not in shown or ("need you" not in shown and "Needs you" not in shown):
            raise Failed("the control pane does not show %s under Needs you:\n%s" % (agent, shown))
        log("pane.attention urgent on %s; %s shows in Needs you (%s)" % (marked["pane"], agent, item["reason"]))

        # The pid is checked: another process and init are refused, a shell's
        # hook beside it is outside, and neither moves what was recorded.
        for bad in (1, self.daemon.pid, entry["pid"] + 100000):
            rc, res = self.raw("agent", "takeover-split", "--agent=" + agent, "--pid=%d" % bad)
            if rc == 0 or res.get("error", {}).get("code") != "invalid_params.pid":
                raise Failed("a pid that is not the pane's process (%d): %d %s" % (bad, rc, res))
        rc, res = self.raw("agent", "takeover-split", "--agent=" + agent, "--pid=%d" % entry["pid"])
        if rc != 0:
            raise Failed("the pane's process itself: %s" % res)
        sock = os.path.join(self.env["XDG_RUNTIME_DIR"], "venom", "venom.sock")
        env = dict(self.env, VENOMX_TOKEN="@owner")
        made = subprocess.run([self.venom, "agent", "split", "--agent=" + agent, "--kind=shell", "--pane=" + cp, "--socket=" + sock, "--json"], env=env, capture_output=True, text=True, timeout=30)
        shell = json.loads(made.stdout)["pane"]
        outside = self.in_pane(shell, "printf '%%s' '%s' | VENOM_SOCKET=%s %s agent hook --agent %s; echo \"exit $?\"" % (json.dumps(permission), sock, self.venom, agent))
        if "denied.outside_pane" not in outside or "exit 1" not in outside:
            raise Failed("a hook from the shell beside it:\n%s" % outside)
        rc, res = self.raw("harness", "hook", "--agent=" + agent, "--input=" + json.dumps(permission))
        if rc == 0 or res.get("error", {}).get("code") != "denied.outside_pane":
            raise Failed("a hook from outside: %d %s" % (rc, res))
        # A shell split can't pass for the take-over: its tag says shell.
        shell_pid = self.pane_entry(shell).get("pid")
        rc, res = self.raw("agent", "takeover-split", "--agent=" + agent, "--pid=%d" % shell_pid)
        if rc == 0 or res.get("error", {}).get("code") != "invalid_params.pid":
            raise Failed("the shell's process as the take-over's: %d %s" % (rc, res))
        self.vx("pane", "kill", "--pane=" + shell, "--remove=true")
        log("other processes refused: init, the daemon, a stranger, the shell beside it, a hook from outside")

        # A client's focus clear stands until a new prompt, even in the same words.
        self.vx("pane", "attention", "--pane=" + pane, "--clear=true")
        time.sleep(1.5)
        if self.pane_entry(pane)["attention"] != "none":
            raise Failed("the cleared mark came back by itself")
        time.sleep(1.0)
        got = self.fire_hook(entry["pid"], permission)
        if not got.strip().endswith("exit 0"):
            raise Failed("the next prompt's hook: %r" % got)
        until("attention again for the new prompt", lambda: self.pane_entry(pane)["attention"] == "urgent")
        log("a cleared mark stays clear; the next prompt, in the same words, marks it again")

        # Take back: T closes the pane, the item goes, and nothing stays marked.
        self.vx("pane", "send", "--pane=" + cp, "--text=T")
        until("the pane to go", lambda: not self.split_panes(agent, "take_over"))
        self.wait(agent, ("settled",))
        until("the away item to go", lambda: not self.away_items(agent))
        until("no mark left", lambda: not [p for p in self.panes() if self.tags(p).get("group") == agent and p["attention"] != "none"])
        log("take back: pane gone, item gone, no mark left")

        # The harness ending by itself: the pane goes and nothing stays marked.
        pane = self.take_over_from(cp, agent)
        self.fire_until_accepted(self.pane_entry(pane)["pid"], permission)
        until("attention on the new pane", lambda: (self.pane_entry(pane) or {}).get("attention") == "urgent")
        self.vx("pane", "kill", "--pane=" + pane)
        self.wait(agent, ("settled",))
        until("no mark left", lambda: not [p for p in self.panes() if self.tags(p).get("group") == agent and p["attention"] != "none"])

        # A venomx that can't say proves nothing: no hooks count.
        default = self.vx("config", "get", "--key=grants.unknown")["content"]
        self.vx("config", "set", "--key=grants.unknown", "--value=.{}")
        self.vx("config", "reload")
        pane = self.take_over_from(cp, agent)
        time.sleep(0.5)  # the TUI's report has had its chance
        pid = None
        for proc in os.listdir(self.root):
            m = re.match(r"takeover\.(\d+)\.args$", proc)
            if m and os.path.exists("/proc/%s" % m.group(1)) and agent in open(os.path.join(self.root, proc)).read():
                pid = int(m.group(1))
        got = self.fire_hook(pid, permission)
        if "denied.outside_pane" not in got or not got.strip().endswith("exit 1"):
            raise Failed("a hook with no way to check its pane: %r" % got)
        rc, res = self.raw("agent", "takeover-split", "--agent=" + agent, "--pid=%d" % 2)
        if res.get("error", {}).get("code") not in ("unavailable.takeover_pane",):
            raise Failed("takeover-split with no read on venomx: %d %s" % (rc, res))
        self.vx("config", "set", "--key=grants.unknown", "--value=" + default)
        self.vx("config", "reload")
        self.vx("pane", "kill", "--pane=" + pane)
        self.wait(agent, ("settled",))
        self.quit_control(cp)
        log("PASS attention while away: hook, pane.attention, Needs you, cleared on take back; unproved pids refused")

    # --- all -------------------------------------------------------------------

    def run(self):
        self.make_workspace()
        self.write_config()
        self.start()
        self.cli("workspace", "add", "--path=" + self.ws)
        first = [self.spawn("alpha", "claude-code"), self.spawn("beta", "codex")]
        self.auto_without_venomx()
        self.start_venomx()
        self.own_mode(first)
        second = [self.spawn("gamma", "claude-code"), self.spawn("alpha", "codex")]
        self.host_mode(second)
        self.human_pane()
        self.takeover_outlives_tui(second[0])
        self.attention_while_away(second[0])
        log("PASS")

    def dump_all(self):
        for t in self.terms:
            print("--- terminal (tail)\n%r" % t.text()[-1500:], file=sys.stderr)
        try:
            print(json.dumps(self.panes(), indent=1), file=sys.stderr)
            print("--- notifications\n" + json.dumps(self.notifications(), indent=1), file=sys.stderr)
            print("--- inbox\n" + json.dumps(self.cli("inbox", "list")["items"], indent=1)[:2000], file=sys.stderr)
            print("--- grants\n" + json.dumps(self.vx("grant", "list")["principals"], indent=1), file=sys.stderr)
            for p in self.panes():
                print("--- %s\n%s" % (p["pane"], self.capture(p["pane"])), file=sys.stderr)
        except Exception as e:  # the daemon may be gone
            print("host-demo: panes: %s" % e, file=sys.stderr)
        self.dump()


def stale_because(binary):
    """Why a venomx built in a checkout is older than that checkout."""
    source = subprocess.run(["git", "-C", os.path.dirname(binary), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if source.returncode != 0:
        return None  # built elsewhere: the caller chose it
    root = source.stdout.strip()
    built = os.path.getmtime(binary)
    files = subprocess.run(["git", "-C", root, "ls-files", "src", "build.zig", "build.zig.zon"], capture_output=True, text=True, check=True).stdout.split()
    newest = max(files, key=lambda f: os.path.getmtime(os.path.join(root, f)))
    if os.path.getmtime(os.path.join(root, newest)) > built:
        return "%s is newer than the binary" % newest
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--venom", default=os.path.join(e2e.REPO, "zig-out", "bin", "venom"))
    ap.add_argument("--venomx", default=os.path.join(e2e.REPO, "..", "venomx", "zig-out", "bin", "venomx"))
    ap.add_argument("--keep", action="store_true", help="keep the temp root")
    args = ap.parse_args()
    venomx = os.path.abspath(args.venomx)
    if not os.access(venomx, os.X_OK):
        sys.exit("host-demo: no venomx at %s; build ../venomx or pass --venomx" % venomx)
    stale = stale_because(venomx)
    if stale:
        sys.exit("host-demo: stale venomx at %s: %s; rebuild it or pass --venomx (zig build test-host -Dvenomx=<path>)" % (venomx, stale))
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Failed("hard limit of %ds" % HARD_LIMIT_S)))
    signal.alarm(HARD_LIMIT_S)
    # Short: the unix socket path has a limit.
    root = tempfile.mkdtemp(prefix="vh", dir="/tmp")
    demo = Demo(os.path.abspath(args.venom), venomx, root)
    code = 0
    try:
        demo.run()
    except (Failed, subprocess.SubprocessError, OSError, KeyError, ValueError, IndexError, StopIteration) as e:
        print("host-demo: FAIL: %s" % e, file=sys.stderr)
        demo.dump_all()
        code = 1
    finally:
        signal.alarm(0)
        demo.stop_all()
        if args.keep:
            print("host-demo: kept " + root)
        else:
            shutil.rmtree(root, ignore_errors=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
