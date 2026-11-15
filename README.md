# venom

**Main product.** A terminal-native orchestrator for existing AI coding agents (Claude Code, Codex app-server, generic ACP, opencode); think of it as a terminal-native t3code. It is headless and event-sourced: a pure decider, then a transactional outbox, then an effect worker. It handles workspaces (folders the user adds, holding 0..n repos), agents (one run of a harness on a task) and their turns; fan-out; a git worktree per agent per repo; hidden-ref checkpoints; approval routing and an inbox; scheduled agent jobs; and an MCP server so agents can orchestrate agents. It ships its own TUI and places agents in venomx panes when venomx is available.

Part of [Venom](https://venom.tools). Status: **alpha**; interfaces may still change. Documentation: [venom.tools](https://venom.tools).

Build from source with the Zig version in `.zigversion` (see [Build](#build)).

Licensed under the [MIT License](LICENSE). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Build

Zig 0.17 (see `.zigversion`). `zig build` fetches `venom-std` and `venom-term` at the commits pinned in `build.zig.zon`; to build against local checkouts instead, add `--fork=../venom-std --fork=../venom-term` to any `zig build` command:

```sh
zig build                 # zig-out/bin/venom
zig build test            # unit tests + agent-contract conformance
venom                     # the TUI; starts a daemon when none runs
venom serve               # or run the daemon yourself (persistent)
venom doctor --json       # health report
venom mcp                 # MCP server over stdio
venom --help              # every verb, generated from src/verbs.zon
```

## The daemon's lifetime

Whoever starts the daemon decides how long it runs.

- **`venom` in a terminal, with no daemon running**, starts one: `venom serve --lifetime on-demand --origin interactive`, detached in its own session, in `$HOME`, without your tokens. It stops 5 s after the last venom TUI quits, so quitting and starting `venom` again keeps it. Running agents are stopped cleanly then: each turn ends `interrupted`, and the next send continues the same conversation. Queued agents stay queued until venom runs again. When quitting would stop work like that, venom asks first.
- **`venom serve`**, by hand or from a supervisor, is persistent: TUIs come and go, and only a signal stops it. `venom serve --lifetime on-demand` follows the on-demand rules, and with no TUI exits after 5 s.
- **Agents, hooks, MCP and every other command never start a daemon.** With none running they fail with `unavailable.not_running`. So does `venom` inside a venomx pane or an agent (`denied.startup_context`), with a `VENOM_TOKEN` of its own, or with `daemon.interactive_start = false`: start `venom` in a terminal outside venomx.

`daemon.interactive_start` (default `true`) and `daemon.startup_timeout_ms` (default `5000`, the TUI's budget to get a daemon ready) are restart-only and belong in your user config. A supervised setup sets `daemon.interactive_start = false`, so a stray `venom` never starts a second daemon. `venom doctor` shows the lifetime, who started the daemon and how many TUIs hold it.

```sh
zig build test-on-demand   # bare venom on pseudo-terminals: start, linger, races, a crash, refusals
```

## End-to-end demo: 3 agents, 3 worktrees, approved from the CLI

`scripts/demo.py` runs the demo headless. It makes a temp workspace with three git repos (`alpha`, `beta`, `gamma`), starts its own `venom serve` with every XDG directory under the temp root (your daemon, config and agents are untouched), and then, all through the CLI:

1. `venom workspace add --path=<ws>`
2. `venom agent spawn --workspace=<ws> --repos='["<repo>"]' --harness=<h> --isolation=worktree --task=…` three times: claude-code on `alpha`, codex on `beta`, claude-code on `gamma`. Each agent gets its own worktree (`<repo>-<agent-id>` on branch `venom/<agent-id>`).
3. Each agent asks to run a command and turns `needs_you`; `venom inbox list` shows three approvals.
4. `venom inbox answer --agent=<id> --answer=allow_once` for each one.
5. All three settle; the script checks each ran inside its own git worktree.

```sh
zig build test-demo                      # the demo against fake harnesses (also part of zig build test)
python3 scripts/demo.py               # the same, using zig-out/bin/venom
python3 scripts/demo.py --real        # real claude and codex from PATH (signed in; spends a few model turns)
python3 scripts/demo.py --keep        # keep the temp root (daemon log, worktrees) for a look
```

By default the harnesses are `src/testdata/fake_mcp_harness.py` (modes `claude-approve` and `codex-approve`), set as `harness.claude_code.path` and `harness.codex.path` in the demo's `config.zon`. They are driven by venom's real claude-code and codex adapters: the claude-code approvals go through venom's permission prompt server the way Claude Code's do, and the codex ones through app-server's `item/commandExecution/requestApproval`. `zig build test` runs this without vendor binaries or sign-ins.

With `--real` the config is left at its defaults (`claude` and `codex` from `PATH`), and each agent is asked to write a file outside its worktree, which both harnesses must ask about. The script allows whatever they ask (up to five times per agent) and fails if an agent settles without asking. Run it by hand; `zig build test` never runs it.

## Chrome modes: own and host

`ui.chrome` (`venom config set --key=ui.chrome --value=.auto`) says where the TUI runs. venom never starts venomx.

- `.own`: full-screen TUI on the terminal.
- `.host`: a control pane in venomx (`role = control`), or `.own` when no venomx daemon is reachable. In a venomx pane, that pane becomes the control pane. Outside venomx, venom makes session `venom` with the control pane (or finds it), and the terminal becomes `venomx attach` on it. Started that way, the process outside venomx registers the `venom` key table before it becomes `venomx attach`; the table has no expiry, and goes when the daemon stops. Started only inside a pane you opened, there may be no table, and the bar says so. On venomx, a control pane has a pane's default rights: it can write only itself and the panes it creates. venom gives it those rights explicitly, so they hold even with venomx's `grants.isolation` off. On venom, that outside process binds a principal to its process, with everything but `admin`, and it holds no token. Shells and take-over are offered only in an agent's read-only pane, not the control pane, until they are panes of their own.
- `.auto` (default): `.host` when a daemon is reachable, else `.own`.

venom's bar is the bottom row of the area it draws in both modes; venomx's own line is separate, and venom publishes no `venom.*` segments. In host mode:

- `⏎` on an agent opens a sibling pane (`role = agent`, `group = <agent>`, kept on exit) running `venom agent view <agent> --solo=true`: that agent, no list, no bar. Closing it leaves the agent running.
- `venom --agent=<id>`, `--inbox` or `--usage` with a control pane already running hands those to it.
- Inbox items set `pane.attention` on the agent's pane, or on the control pane while it has none, and clear when answered anywhere.
- From any pane, after the leader, `v s` opens settings (`venom.settings`), `v d` the diff of the focused pane's agent (`venom.diff`, `venom agent diff --pane <p>`), `v i` the inbox, `v u` the usage. The diff uses the control pane's selected agent when that pane has focus, and says so when the pane has no agent. `keys.prefixes` in venomx's config moves `v`.

```sh
zig build test-host                      # both modes, two agents, throwaway daemons; fails on a stale ../venomx build
zig build test-host -Dvenomx=<path>      # the same with that venomx binary
```

## venom in a venomx pane

A process in a venomx pane, or in a split of venom's own TUI, is refused venom's owner file, and an agent is refused venomx's. A pane looks the same whether a person or an agent runs in it. So:

- **Start `venom` in a terminal outside venomx.** It starts venom's daemon if none runs. With a venomx daemon up you get a control pane, with everything but `admin`. Its agents keep running if that pane ends, as long as another venom TUI holds an on-demand daemon or the daemon is persistent; detaching venomx keeps the control pane running.
- **To save settings, stop the daemon or read the audit log,** use a terminal outside venomx: `venom settings`, or `VENOM_TOKEN=@owner venom …`. The settings and inbox popups (`ctrl+a v s`, `v i`) only read; save and answer in the control pane.
- **To use venom from a pane of your own,** issue a token outside venomx, then set it in the pane:
  ```bash
  VENOM_TOKEN=@owner venom grant issue --namespace=person --label=my-pane --json \
    --grants='[{"right":"read","scope":"*"},{"right":"write","scope":"*"},{"right":"respond","scope":"*"},{"right":"files","scope":"*"},{"right":"spawn","scope":"*"}]'
  read -rs VENOM_TOKEN; export VENOM_TOKEN   # in the pane: paste it at the silent prompt
  venom
  ```
  Anything run from that shell can use the token. Anyone with `read` can see a pane's screen, so don't print the token in a pane; if it did show, clear that pane's screen and history.
  With nothing set, `venom` in a pane only reads.
- **A token you issued ends** after `grants.max_token_ttl` (24 hours by default) or when `venom serve` restarts. The TUI says so; issue another. A control pane has no token: its rights last as long as its process, across a restart of `venom serve`, and nothing in its environment can be stolen. Its agent views are bound the same way and lose their rights when it quits. These rights are that one process's: a shell or take-over opened from an agent view is `unknown`, and only reads.

### venomx isolation

venomx ships with `grants.isolation` off, like tmux: every process of yours may write and spawn anywhere in venomx. venom's own agents stay capped: the agent panes venom splits are created with `read` and nothing else, and an agent venom starts outside venomx stays read-only there. venom creates its control pane with explicit grants too, so it can write only itself and its agent panes. A pane of your own that you start `venom` in keeps that pane's rights. An agent that escapes its pane's process tree, though, resolves to venomx's `unknown` and gets those wide rights. `venom doctor` warns (`venomx.isolation`) when the venomx it drives has isolation off. Turn it on before running agents in venomx:

```bash
VENOMX_TOKEN=@owner venomx config set --key grants.isolation --value true && VENOMX_TOKEN=@owner venomx config reload
```

venom itself keeps isolation on (`grants.isolation`, the *Permissions and grants* settings section).

### Durable log snapshots

The reactor checkpoints after 4096 commits since the last snapshot or 16 MiB of active log. The
`events.log.snapshot` v1 envelope contains `version`, `commit`, a JSON-encoded
`state` string, and a SHA-256 checksum covering the format domain, commit number
(little-endian u64), and state bytes. State maps are ordered `{key,value}` arrays;
lists are arrays and transcript events retain their log schema. All projection
fields are required; future incompatible changes need a snapshot version migration.

The snapshot retains transcripts, usage, inbox state, bindings, ID counters, and
both pending and completed effects. Pending effects keep their original keys and
at-least-once recovery behavior. Completed keys remain available for deduplication.
Transcripts remain accessible through the existing agent views, indefinitely.
Snapshot size and loading cost therefore scale with retained state/history; the
active log and event-folding work are bounded by the checkpoint interval.

A temporary snapshot is written and fsynced, renamed atomically, and its directory
fsynced before the locked log is truncated and fsynced. Recovery skips any prefix
already covered by the snapshot and replays the suffix. Unpublished temporary
files are ignored. Corrupt or unsupported published snapshots fail closed.
Compaction failures do not turn an already committed command into a failure;
maintenance is retried on the next commit. `doctor`'s `events.durable` check reports
the snapshot commit, active log bytes, and snapshot-plus-log recovery milliseconds.
