#!/usr/bin/env python3
"""`venom doctor --json` and `venom harness list --json` with fake harnesses
on a temp PATH, against this build's daemon.

Copies src/testdata/harness-bin to a temp directory that is the daemon's whole
PATH, and checks every harness's checks, that every fix parses as POSIX sh,
that the sign-in fixes really sign the fakes in, and that nothing from a
harness's account output (email, organization, key) leaves venom. No real
vendor CLI is ever on that PATH.

    scripts/harness_discovery_test.py --venom zig-out/bin/venom --fakes src/testdata/harness-bin
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

TIMEOUT = 30
CHECKS = ("found", "version", "signed_in", "protocol")


class Env:
    def __init__(self, venom, fakes, root):
        self.venom = venom
        self.bin = os.path.join(root, "bin")
        self.state = os.path.join(root, "state")
        os.makedirs(self.bin)
        os.makedirs(self.state)
        for name in ("claude", "codex"):
            shutil.copy(os.path.join(fakes, name), self.bin)
        self.env = {
            "PATH": self.bin,
            "HOME": root,
            "VENOM_FAKE_HARNESS_STATE": self.state,
        }
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            self.env["XDG_%s_HOME" % kind] = os.path.join(root, kind.lower())
        self.env["XDG_RUNTIME_DIR"] = os.path.join(root, "run")
        os.makedirs(self.env["XDG_RUNTIME_DIR"], mode=0o700)
        self.daemon = None

    def start(self):
        self.daemon = subprocess.Popen([self.venom, "serve"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        end = time.monotonic() + TIMEOUT
        while time.monotonic() < end:
            if subprocess.run([self.venom, "agent", "list", "--json"], env=self.env, capture_output=True, timeout=TIMEOUT).returncode == 0:
                return
            assert self.daemon.poll() is None, "venom serve exited with %s" % self.daemon.returncode
            time.sleep(0.05)
        raise AssertionError("venom serve did not start")

    def stop(self):
        if self.daemon is None or self.daemon.poll() is not None:
            return
        self.daemon.send_signal(signal.SIGTERM)
        try:
            self.daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.daemon.pid, signal.SIGKILL)
            self.daemon.wait(timeout=10)

    def cli(self, *args, code=0, env=None):
        p = subprocess.run([self.venom, *args, "--json"], env=env or self.env, capture_output=True, text=True, timeout=TIMEOUT)
        assert p.returncode == code, "%s exited %d, not %d: %s %s" % (args, p.returncode, code, p.stdout, p.stderr)
        assert "fake-secret" not in p.stdout + p.stderr, "account data leaked: " + p.stdout + p.stderr
        return json.loads(p.stdout)

    def doctor(self, code=0):
        report = self.cli("doctor", code=code)
        assert report["status"] == code, report
        for c in report["checks"]:
            assert c["fix"], c
            assert subprocess.run(["/bin/sh", "-n", "-c", c["fix"]], capture_output=True).returncode == 0, "fix is not POSIX sh: %s" % c["fix"]
        return {c["id"]: c for c in report["checks"]}

    def harnesses(self):
        return {h["harness"]: h for h in self.cli("harness", "list")["harnesses"]}

    def run_fix(self, line):
        subprocess.run(["/bin/sh", "-c", line], env=self.env, check=True, capture_output=True, timeout=TIMEOUT)


def expect_all_ok(checks):
    for h in ("claude-code", "codex"):
        for c in CHECKS:
            got = checks["harness.%s.%s" % (h, c)]
            assert got["status"] == "ok", got


def run(e):
    e.start()

    # Found, signed in, reachable.
    checks = e.doctor()
    expect_all_ok(checks)
    assert checks["harness.claude-code.found"]["message"] == "claude 2.1.319 at %s/claude" % e.bin, checks
    assert checks["harness.claude-code.signed_in"]["message"] == "Signed in (max)", checks
    assert checks["harness.codex.signed_in"]["message"] == "Signed in (API key)", checks
    assert checks["harness.codex.protocol"]["fix"] == "venom harness show --harness=codex --json", checks
    # That fix runs.
    show = e.cli("harness", "show", "--harness=codex")
    assert show["protocol"] is True and show["tested_version"] == "0.167.0", show

    listed = e.harnesses()
    assert list(listed) == ["claude-code", "codex"], listed
    assert listed["claude-code"] == {"harness": "claude-code", "enabled": True, "found": True, "path": e.bin + "/claude", "version": "2.1.319", "signed_in": True, "sign_in_detail": "max", "protocol": True}, listed
    assert listed["codex"] == {"harness": "codex", "enabled": True, "found": True, "path": e.bin + "/codex", "version": "0.167.0", "signed_in": True, "sign_in_detail": "API key", "protocol": True}, listed

    # Signed out: the fix is the harness's own command, and it works.
    for name in ("claude", "codex"):
        open(os.path.join(e.state, name + "-signed-out"), "w").close()
    checks = e.doctor(code=1)
    for h, fix in (("claude-code", "claude auth login"), ("codex", "codex login")):
        got = checks["harness.%s.signed_in" % h]
        assert got["status"] == "fail" and got["fix"] == fix and got["message"] == h + " is not signed in", got
    listed = e.harnesses()
    assert listed["claude-code"]["signed_in"] is False and listed["claude-code"]["fix"] == "claude auth login", listed
    assert listed["codex"]["signed_in"] is False and listed["codex"]["fix"] == "codex login", listed
    assert "sign_in_detail" not in listed["codex"], listed

    # A spawn is refused with the same fix, and starts nothing.
    owner = dict(e.env, VENOM_TOKEN="@owner")
    for args, fix in ((["--harness=codex"], "codex login"), ([], "claude auth login")):
        for extra in ([], ["--dry-run=true"]):
            refused = e.cli("agent", "spawn", "--cwd=" + e.state, "--task=hello", *args, *extra, code=6, env=owner)
            assert refused["error"]["code"] == "unavailable.harness_not_signed_in", refused
            assert refused["error"]["data"]["fix"] == fix, refused
    assert e.cli("agent", "list")["agents"] == [], "a refused spawn left an agent"
    e.run_fix(checks["harness.claude-code.signed_in"]["fix"])
    e.run_fix(checks["harness.codex.signed_in"]["fix"])
    expect_all_ok(e.doctor())
    # Signed in again: the very next spawn is not refused.
    assert e.cli("agent", "spawn", "--cwd=" + e.state, "--task=hello", "--harness=codex", "--dry-run=true", env=owner)["dry_run"] is True

    # A protocol that does not answer fails, with the verb that shows why.
    codex = os.path.join(e.bin, "codex")
    good = open(codex).read()
    with open(codex, "w") as f:
        f.write(good.replace("app-server*)", "app-server*)\n    exit 3\n    ;;\nnever*)"))
    checks = e.doctor(code=1)
    got = checks["harness.codex.protocol"]
    assert got["status"] == "fail" and "protocol not reachable" in got["message"], got
    assert e.cli("harness", "show", "--harness=codex")["protocol_problem"], got
    with open(codex, "w") as f:
        f.write(good)

    # Not on PATH: found fails with the install command, the rest not checked.
    os.remove(codex)
    checks = e.doctor(code=1)
    got = checks["harness.codex.found"]
    assert got["status"] == "fail" and got["fix"] == "npm install -g @openai/codex", got
    for c in CHECKS[1:]:
        assert checks["harness.codex.%s" % c]["status"] == "ok" and "not" in checks["harness.codex.%s" % c]["message"], checks
    listed = e.harnesses()
    assert listed["codex"] == {"harness": "codex", "enabled": True, "found": False, "fix": "npm install -g @openai/codex"}, listed
    assert listed["claude-code"]["found"] is True, listed

    # The hint for turning it off says what the command needs, and works.
    hint = "VENOM_TOKEN=@owner venom config set --key=harness.codex.enabled --value=false, then restart venom serve"
    assert hint in got["message"], got
    denied = e.cli("config", "set", "--key=harness.codex.enabled", "--value=false", code=4)
    assert denied["error"]["code"] == "denied.admin", denied
    subprocess.run([e.venom, "config", "set", "--key=harness.codex.enabled", "--value=false", "--json"], env=owner, check=True, capture_output=True, timeout=TIMEOUT)
    subprocess.run([e.venom, "config", "set", "--key=harness.codex.enabled", "--value=true", "--json"], env=owner, check=True, capture_output=True, timeout=TIMEOUT)

    assert e.cli("harness", "show", "--harness=nope", code=3)["error"]["code"] == "not_found.harness"

    # A harness that hangs: `harness list` and `doctor` wait off the
    # reactor, other verbs still answer, and stopping the daemon does not wait
    # for it.
    with open(codex, "w") as f:
        f.write("#!/bin/sh\nexec /bin/sleep 60\n")
    os.chmod(codex, 0o755)
    waiting = subprocess.Popen([e.venom, "harness", "list", "--json"], env=e.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    spawning = subprocess.Popen([e.venom, "agent", "spawn", "--cwd=" + e.state, "--task=hello", "--harness=codex", "--dry-run=true", "--json"], env=owner, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    diagnosing = subprocess.Popen([e.venom, "doctor", "--json"], env=e.env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        time.sleep(0.3)
        assert waiting.poll() is None, "harness list did not wait for the hung harness"
        assert diagnosing.poll() is None, "doctor did not wait for the hung harness"
        assert spawning.poll() is None, "agent spawn did not wait for the hung harness"
        t0 = time.monotonic()
        e.cli("agent", "list")
        took = time.monotonic() - t0
        assert took < 1, "agent list took %.1fs while harness list and doctor waited" % took
        t0 = time.monotonic()
        e.cli("config", "get", "--key=harness.codex.enabled")
        took = time.monotonic() - t0
        assert took < 1, "config get took %.1fs while doctor waited" % took
        # The probe is cut off at its budget, and doctor still answers whole:
        # the other checks, the hung harness's, and the trailing schema check.
        out, _ = diagnosing.communicate(timeout=TIMEOUT)
        report = json.loads(out)
        ids = [c["id"] for c in report["checks"]]
        assert "schema.digest" in ids and "harness.claude-code.found" in ids and "harness.codex.found" in ids, ids
        assert ids.index("harness.codex.protocol") < ids.index("schema.digest"), ids
        # A new run is going when the daemon stops.
        waiting.wait(timeout=TIMEOUT)
        waiting = subprocess.Popen([e.venom, "harness", "list", "--json"], env=e.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)
        t0 = time.monotonic()
        e.stop()
        took = time.monotonic() - t0
        assert took < 5, "venom serve took %.1fs to stop during a discovery run" % took
    finally:
        for client in (waiting, spawning, diagnosing):
            client.kill()
            client.wait(timeout=10)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--venom", required=True)
    ap.add_argument("--fakes", required=True)
    args = ap.parse_args()
    # Short, so the socket path stays under the unix socket limit.
    root = tempfile.mkdtemp(prefix="venom-hd-")
    e = Env(os.path.abspath(args.venom), os.path.abspath(args.fakes), root)
    try:
        run(e)
    finally:
        e.stop()
        shutil.rmtree(root, ignore_errors=True)
    print("harness-discovery: ok")


if __name__ == "__main__":
    sys.exit(main())
