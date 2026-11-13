#!/usr/bin/env python3
"""The end-to-end demo: three agents on three worktrees, approved
from the CLI, headless.

    scripts/demo.py [--venom zig-out/bin/venom] [--real] [--keep]

It builds a temp workspace holding three git repos (alpha, beta, gamma),
starts its own `venom serve` (every XDG directory under the temp root, so
your own daemon, config and agents are untouched), adds the workspace and
spawns one agent per repo with worktree isolation: claude-code on alpha,
codex on beta, claude-code on gamma. Each agent asks for an approval; the
script answers each one with `venom inbox answer`, then waits until all
three settle and checks that each ran in its own git worktree.

By default the harnesses are fakes (`src/testdata/fake_mcp_harness.py` in
its claude-approve and codex-approve modes) driven by venom's real
claude-code and codex adapters: the claude-code approvals go through
venom's permission prompt server exactly as Claude Code's do, the codex
ones through app-server's requestApproval. No vendor binary, sign-in or
model quota is needed; this is what `zig build test` runs.

With --real the agents run the real `claude` and `codex` from PATH (signed
in; this spends a few model turns). The task asks each agent to write a
file outside its worktree, which both harnesses must ask about; the script
allows whatever they ask, up to a few times per agent.

Exit status 0 when the demo passed, 1 otherwise (the daemon log and each
agent's `agent show` are printed).
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FAKE = os.path.join(REPO, "src", "testdata", "fake_mcp_harness.py")

# (repo, harness): at least one claude-code and one codex agent.
AGENTS = [("alpha", "claude-code"), ("beta", "codex"), ("gamma", "claude-code")]


class Failed(Exception):
    pass


def log(msg):
    print("demo: " + msg, flush=True)


class Demo:
    def __init__(self, venom, real, root):
        self.venom = venom
        self.real = real
        self.root = root
        self.timeout = 600 if real else 30
        self.ws = os.path.join(root, "ws")
        self.env = dict(os.environ)
        for kind in ("CONFIG", "STATE", "DATA", "CACHE", "RUNTIME"):
            d = os.path.join(root, "xdg", kind.lower())
            os.makedirs(d, mode=0o700)
            self.env["XDG_%s_HOME" % kind if kind != "RUNTIME" else "XDG_RUNTIME_DIR"] = d
        # The human's own client: the owner token file.
        self.env["VENOM_TOKEN"] = "@owner"
        self.daemon = None
        self.spawned = {}

    # --- the CLI -----------------------------------------------------------

    def cli(self, *args, ok=True):
        p = subprocess.run([self.venom, *args, "--json"], env=self.env, capture_output=True, text=True, timeout=60)
        try:
            out = json.loads(p.stdout) if p.stdout.strip() else None
        except json.JSONDecodeError:
            out = None
        if ok and p.returncode != 0:
            raise Failed("venom %s exited %d: %s %s" % (" ".join(args), p.returncode, p.stdout.strip(), p.stderr.strip()))
        if isinstance(out, dict) and "result" in out and ok:
            return out["result"]
        return out

    def state(self, agent):
        return self.cli("agent", "show", "--agent=" + agent)["state"]

    def wait(self, agent, states):
        deadline = time.time() + self.timeout
        while True:
            s = self.state(agent)
            if s in states:
                return s
            if s == "failed":
                raise Failed("%s failed" % agent)
            if time.time() > deadline:
                raise Failed("%s is %s after %ds, want %s" % (agent, s, self.timeout, "/".join(states)))
            time.sleep(0.05)

    # --- setup ---------------------------------------------------------------

    def make_workspace(self):
        git = ["git", "-c", "user.name=venom demo", "-c", "user.email=demo@venom.invalid", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"]
        for repo, _ in AGENTS:
            path = os.path.join(self.ws, repo)
            os.makedirs(path)
            subprocess.run(git + ["init", "-q", path], check=True)
            with open(os.path.join(path, "README.md"), "w") as f:
                f.write("# %s\n" % repo)
            subprocess.run(git + ["-C", path, "add", "README.md"], check=True)
            subprocess.run(git + ["-C", path, "commit", "-q", "-m", "init"], check=True)

    def write_config(self):
        if self.real:
            return  # the defaults: claude and codex from PATH
        out = lambda name: os.path.join(self.root, name)
        # A copy with its exec bit set, whatever the checkout kept.
        fake = os.path.join(self.root, "fake_mcp_harness.py")
        shutil.copyfile(FAKE, fake)
        os.chmod(fake, 0o755)
        zon = (
            ".{ .harness = .{\n"
            "    .claude_code = .{ .path = %s, .extra_args = .{ \"--fake-mode\", \"claude-approve\", \"--fake-out\", %s } },\n"
            "    .codex = .{ .path = %s, .extra_args = .{ \"--fake-mode\", \"codex-approve\", \"--fake-out\", %s } },\n"
            "} }\n"
        ) % (json.dumps(fake), json.dumps(out("claude.out")), json.dumps(fake), json.dumps(out("codex.out")))
        d = os.path.join(self.env["XDG_CONFIG_HOME"], "venom")
        os.makedirs(d)
        with open(os.path.join(d, "config.zon"), "w") as f:
            f.write(zon)

    def start(self):
        self.daemon_log = open(os.path.join(self.root, "serve.stderr"), "w")
        self.daemon = subprocess.Popen([self.venom, "serve"], env=self.env, stdin=subprocess.DEVNULL, stdout=self.daemon_log, stderr=subprocess.STDOUT)
        deadline = time.time() + 15
        while True:
            if self.daemon.poll() is not None:
                raise Failed("venom serve exited %d" % self.daemon.returncode)
            if subprocess.run([self.venom, "ping", "--json"], env=self.env, capture_output=True, timeout=10).returncode == 0:
                return
            if time.time() > deadline:
                raise Failed("venom serve did not answer ping")
            time.sleep(0.05)

    def stop(self):
        if self.daemon and self.daemon.poll() is None:
            self.daemon.send_signal(signal.SIGTERM)
            try:
                self.daemon.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.daemon.kill()
                self.daemon.wait()

    # --- the demo ------------------------------------------------------------

    def task(self, repo):
        if self.real:
            return ("Run exactly this one shell command, and nothing else: date > ../demo-%s.txt "
                    "(it writes outside your folder, so ask for permission when you need it). "
                    "Then reply with the single word: done." % repo)
        return "say hi with echo (%s)" % repo

    def run(self):
        self.make_workspace()
        self.write_config()
        self.start()
        log("daemon up; workspace %s" % self.ws)

        added = self.cli("workspace", "add", "--path=" + self.ws)
        repos = sorted(r["name"] for r in added["repos"])
        if repos != sorted(r for r, _ in AGENTS):
            raise Failed("workspace add found %s" % repos)

        agents = []
        for repo, h in AGENTS:
            r = self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps([repo]), "--harness=" + h,
                         "--isolation=worktree", "--title=demo " + repo, "--task=" + self.task(repo))
            agents.append((r["agent"], repo, h))
            self.spawned[r["agent"]] = r
            log("spawned %s (%s) on %s" % (r["agent"], h, repo))

        if self.real:
            self.answer_real(agents)
        else:
            self.answer_fake(agents)

        for agent, repo, h in agents:
            self.wait(agent, ("settled",))
            log("%s (%s) settled" % (agent, h))
        self.check_worktrees(agents)
        if not self.real:
            self.check_fakes()
        log("PASS: 3 agents (%s) on 3 worktrees, approved from the CLI" % ", ".join(h for _, _, h in agents))

    def answer_fake(self, agents):
        # Every agent asks before anything is answered: three approvals wait
        # in the inbox at once.
        for agent, _, _ in agents:
            self.wait(agent, ("needs_you",))
        items = self.cli("inbox", "list")["items"]
        approvals = sorted(i["agent"] for i in items if i["kind"] == "approval")
        if approvals != sorted(a for a, _, _ in agents):
            raise Failed("inbox approvals are %s, want one per agent" % approvals)
        log("inbox: 3 approvals")
        for agent, _, h in agents:
            self.cli("inbox", "answer", "--agent=" + agent, "--answer=allow_once")
            log("answered %s (%s): allow_once" % (agent, h))

    def answer_real(self, agents):
        asked = {a: 0 for a, _, _ in agents}
        deadline = time.time() + self.timeout
        pending = {a for a, _, _ in agents}
        while pending:
            for agent in sorted(pending):
                s = self.state(agent)
                if s == "needs_you":
                    if asked[agent] >= 5:
                        raise Failed("%s keeps asking" % agent)
                    self.cli("inbox", "answer", "--agent=" + agent, "--answer=allow_once")
                    asked[agent] += 1
                    log("answered %s: allow_once" % agent)
                elif s in ("settled", "failed"):
                    pending.discard(agent)
            if time.time() > deadline:
                raise Failed("agents %s did not settle in %ds" % (sorted(pending), self.timeout))
            time.sleep(0.2)
        for agent, _, h in agents:
            if asked[agent] == 0:
                raise Failed("%s (%s) settled without asking for an approval" % (agent, h))

    def check_worktrees(self, agents):
        seen = set()
        for agent, repo, _ in agents:
            # What spawn created, and where the agent ran.
            a = self.spawned[agent]
            cwd = self.cli("agent", "show", "--agent=" + agent)["cwd"]
            if a.get("isolation") != "worktree":
                raise Failed("%s isolation is %s" % (agent, a.get("isolation")))
            checkouts = a.get("checkouts") or []
            if len(checkouts) != 1 or checkouts[0]["repo"] != repo:
                raise Failed("%s checkouts: %s" % (agent, checkouts))
            path = checkouts[0]["path"]
            listed = subprocess.run(["git", "-C", os.path.join(self.ws, repo), "worktree", "list", "--porcelain"], capture_output=True, text=True, check=True).stdout
            if ("worktree " + path) not in listed.splitlines():
                raise Failed("%s is not a worktree of %s" % (path, repo))
            if path in seen or not os.path.isdir(path):
                raise Failed("%s: bad worktree %s" % (agent, path))
            if os.path.commonpath([cwd, path]) != path:
                raise Failed("%s ran in %s, outside its worktree %s" % (agent, cwd, path))
            seen.add(path)
            log("%s ran in worktree %s (branch %s, cwd %s)" % (agent, os.path.relpath(path, self.ws), checkouts[0].get("branch"), os.path.relpath(cwd, self.ws)))

    def check_fakes(self):
        # What each fake harness got back for its approval.
        lines = lambda name: [json.loads(l) for l in open(os.path.join(self.root, name)) if l.strip()]
        claude = lines("claude.out")
        if len(claude) != 2:
            raise Failed("claude-code fakes got %d permission results, want 2" % len(claude))
        for line in claude:
            if json.loads(line["result"]["content"][0]["text"])["behavior"] != "allow":
                raise Failed("claude-code permission result: %s" % line)
        codex = lines("codex.out")
        if len(codex) != 1 or codex[0]["approval"].get("result", {}).get("decision") != "accept":
            raise Failed("codex approval responses: %s" % codex)

    def dump(self):
        try:
            for a in (self.cli("agent", "list", ok=False) or {}).get("result", {}).get("agents", []):
                print(json.dumps(self.cli("agent", "show", "--agent=" + a["agent"], ok=False), indent=2), file=sys.stderr)
        except Exception as e:  # the daemon may be gone
            print("demo: agent show: %s" % e, file=sys.stderr)
        self.daemon_log.flush()
        for path in (os.path.join(self.root, "serve.stderr"), os.path.join(self.env["XDG_STATE_HOME"], "venom", "venom", "venom.log")):
            if os.path.exists(path):
                print("--- %s (tail)" % path, file=sys.stderr)
                print("".join(open(path).readlines()[-60:]), file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--venom", default=os.path.join(REPO, "zig-out", "bin", "venom"))
    ap.add_argument("--real", action="store_true", help="run the real claude and codex (spends model turns)")
    ap.add_argument("--keep", action="store_true", help="keep the temp root")
    args = ap.parse_args()
    venom = os.path.abspath(args.venom)
    if args.real:
        for exe in ("claude", "codex"):
            if shutil.which(exe) is None:
                sys.exit("demo: --real needs %s on PATH" % exe)
    # Short, so the socket path stays under the unix socket limit.
    root = tempfile.mkdtemp(prefix="venom-demo-")
    demo = Demo(venom, args.real, root)
    code = 0
    try:
        demo.run()
    except (Failed, subprocess.SubprocessError, OSError, KeyError, ValueError) as e:
        print("demo: FAIL: %s" % e, file=sys.stderr)
        demo.dump()
        code = 1
    finally:
        demo.stop()
        if args.keep or code != 0:
            log("kept %s" % root)
        else:
            shutil.rmtree(root, ignore_errors=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
