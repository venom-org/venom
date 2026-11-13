#!/usr/bin/env python3
"""A subreaper's orphans are reaped, and venom's own waits keep their statuses.

    scripts/orphan_reap_test.py [--venom zig-out/bin/venom]

Starts its own `venom serve` with every XDG directory under a temp root. The
harness is the fake one behind a wrapper that first leaves a process behind
with a double fork and `setsid`. Checks, on the running daemon:

1. the escaped process is venom's child, and leaves no zombie once it exits;
2. git, run by `std.process.run` on the reactor, still works: the agent gets
   its worktree (a stolen status crashes the daemon or fails the verb);
3. a harness's exit status is still its own: a codex that exits 42 is logged
   with 42, not the 255 of a lost status;
4. the harness probes on their own threads still get theirs: `harness show`
   reports what the fake's `--version` printed;
5. with orphans exiting during all of it, the daemon stays up and stops cleanly.

Check 1 needs the reaper; it fails with the option off. Checks 2 to 4 are smoke
tests: their waits are quick, so they still pass if the reaper loses
`__WNOTHREAD` and can steal. venom-std's supervisor tests hold that guarantee.

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
import demo as e2e  # noqa: E402

Failed = e2e.Failed
HARD_LIMIT_S = 120


def until(what, check, timeout=15):
    deadline = time.time() + timeout
    while True:
        got = check()
        if got:
            return got
        if time.time() > deadline:
            raise Failed("timed out waiting for " + what)
        time.sleep(0.02)


def proc_state(pid):
    """The state letter from /proc/<pid>/stat and the parent, or None if gone."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            rest = f.read().rsplit(")", 1)[1].split()
    except OSError:
        return None
    return rest[0], int(rest[1])


class Test(e2e.Demo):
    def write_config(self):
        super().write_config()
        self.hold = os.path.join(self.root, "hold")
        self.pid_file = os.path.join(self.root, "escaped.pid")
        fake = os.path.join(self.root, "fake_mcp_harness.py")
        os.rename(fake, fake + ".inner")
        escapee = "echo $$ > %s; while [ -e %s ]; do sleep 0.02; done" % (self.pid_file, self.hold)
        with open(fake, "w") as f:
            f.write('#!/bin/sh\ncase "$1" in --version) echo 2.1.319; exit 0;; esac\n')
            f.write("if [ ! -e %s ]; then (setsid /bin/sh -c '%s' >/dev/null 2>&1 </dev/null &); fi\n" % (self.pid_file, escapee))
            f.write('exec %s %s.inner "$@"\n' % (sys.executable, fake))
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        open(self.hold, "w").close()
        # Exits at once, with a status that can only have come from this process.
        exits = os.path.join(self.root, "exits-42")
        with open(exits, "w") as f:
            f.write("#!/bin/sh\nexit 42\n")
        os.chmod(exits, 0o755)
        config = os.path.join(self.env["XDG_CONFIG_HOME"], "venom", "config.zon")
        with open(config, "w") as f:
            f.write(".{ .harness = .{\n"
                    "    .claude_code = .{ .path = %s, .extra_args = .{ \"--fake-mode\", \"claude-approve\", \"--fake-out\", %s } },\n"
                    "    .codex = .{ .path = %s },\n"
                    "} }\n" % (json.dumps(fake), json.dumps(os.path.join(self.root, "claude.out")), json.dumps(exits)))

    def run(self):
        self.make_workspace()
        self.write_config()
        self.start()
        self.cli("workspace", "add", "--path=" + self.ws)

        agent = self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps(["alpha"]), "--harness=claude-code", "--title=orphan", "--task=say hi with echo (alpha)")["agent"]
        # 2. The worktree that git made through `std.process.run`.
        cwd = self.cli("agent", "show", "--agent=" + agent)["cwd"]
        if not os.path.exists(os.path.join(cwd, ".git")):
            raise Failed("no worktree at %s" % cwd)

        # 1. Venom's orphan, then no zombie.
        until("the harness to leave a process behind", lambda: os.path.exists(self.pid_file) and os.path.getsize(self.pid_file) > 0)
        with open(self.pid_file) as f:
            escaped = int(f.read())
        state = until("the process to reach venom", lambda: (lambda s: s if s and s[1] == self.daemon.pid else None)(proc_state(escaped)))
        print("orphan-reap: pid %d state %s is venom's child" % (escaped, state[0]), flush=True)
        os.unlink(self.hold)
        until("the orphan to be reaped", lambda: proc_state(escaped) is None)
        print("orphan-reap: reaped, no zombie", flush=True)

        # 4. Probes on their own threads.
        shown = self.cli("harness", "show", "--harness=claude-code")
        print("orphan-reap: harness show: %s" % json.dumps(shown), flush=True)
        if shown.get("version") != "2.1.319":
            raise Failed("the harness probe lost its result: %s" % json.dumps(shown))

        # 3. The harness's own status.
        self.cli("agent", "spawn", "--workspace=" + self.ws, "--repos=" + json.dumps(["beta"]), "--harness=codex", "--title=exits", "--task=say hi")
        log_file = os.path.join(self.root, "serve.stderr")
        line = until("the harness exit in the log", lambda: next((x for x in open(log_file) if "harness exited" in x), None))
        print("orphan-reap: %s" % line.strip(), flush=True)
        if " code=42 " not in line:
            raise Failed("a harness exit status was lost: %s" % line)

        # 5. Still up, and a clean stop.
        self.cli("inbox", "answer", "--agent=" + agent, "--answer=allow_once")
        self.wait(agent, ("settled",))
        self.stop()
        if self.daemon.returncode != 0:
            raise Failed("venom serve exited %d" % self.daemon.returncode)
        print("orphan-reap: PASS", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--venom", default=os.path.join(e2e.REPO, "zig-out", "bin", "venom"))
    args = ap.parse_args()
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Failed("hard limit of %ds" % HARD_LIMIT_S)))
    signal.alarm(HARD_LIMIT_S)
    root = tempfile.mkdtemp(prefix="vr", dir="/tmp")
    demo = Test(os.path.abspath(args.venom), False, root)
    code = 0
    try:
        demo.run()
    except (Failed, subprocess.SubprocessError, OSError, KeyError, ValueError) as e:
        print("orphan-reap: FAIL: %s" % e, file=sys.stderr)
        try:
            with open(os.path.join(root, "serve.stderr")) as f:
                print("--- serve.stderr\n" + f.read()[-1500:], file=sys.stderr)
        except OSError:
            pass
        code = 1
    finally:
        signal.alarm(0)
        try:
            os.unlink(os.path.join(root, "hold"))
        except OSError:
            pass
        demo.stop()
        shutil.rmtree(root, ignore_errors=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
