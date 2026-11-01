# codex-desktop

Configuration and tooling for running **Codex Desktop** (OpenAI's Rust + Electron app) in two
non-overlapping modes on one machine:

| Mode | Account | Backend | Home |
| --- | --- | --- | --- |
| `real` | your ChatGPT account | OpenAI | `~/.codex` |
| `clone` | none | your own 9router gateway | `~/.codex-clone` |

The two modes share one app binary and nothing else. Different `CODEX_HOME`, different user-data
directory, different sessions, different SQLite. A clone session has never landed in the real
account's history, and that is enforced by the launcher rather than by hope.

The sibling repository [**codex-web**](https://github.com/rahmanef63/codex-web) is the browser
console for the same workspace. It is a SvelteKit shell; it is **not** a clone of this app and
does not run a local agent. Same scope, different techstack, deliberately.

## What is here

| Path | What it does |
| --- | --- |
| `scripts/codex-launch.ps1` | The launcher. `-Mode real` or `-Mode clone`, and it re-asserts the two config values the app likes to rewrite. |
| `bin/codex-9router-catalog` | Regenerates the Codex model catalog from the gateway's live `/v1/models`. |
| `bin/codex-real-quicktest` | Proves chat, exec and MCP against both providers. |
| `bin/codex-caps-quicktest` | Prints the capability matrix and probes it. |
| `bin/codex-clone-quicktest` | Gates the sibling web repo: lint, types, tests, build, boot. |
| `bin/qcheck` | Runs both quick tests and prints one verdict. |
| `scripts/capture_proxy.py` | Records the exact request the app sends to a gateway. |
| `scripts/mcp_echo.py` | Harmless MCP server used to prove MCP survives the gateway path. |
| `docs/PROGRESS.md` | Working notes: what is proven, what is not, and every trap that cost time. |
| `parity-evidence/capability-matrix.txt` | The measured capability matrix and the root cause behind each verdict. |

`docs/PROGRESS.md` is the entry point. It is a working document, not marketing: it records
failures and dead ends as carefully as successes.

## Three things that are load-bearing

**Three variables, not one.** A second instance needs `CODEX_HOME`,
`CODEX_ELECTRON_USER_DATA_PATH` **and** `--user-data-dir=` on the command line. Without the flag,
Chromium's `ProcessSingleton` forwards the launch to the running instance in about 0.15 s and every
environment variable is ignored. Measured, not assumed.

**The app rewrites config.** It appends `[windows]`, `[desktop]`, `[plugins.*]`,
`[marketplaces.*]`, `[projects.*]` and it can overwrite the top-level `model`. So the launcher
re-asserts `[windows] sandbox = "elevated"`, `model`, `model_provider` and
`chrome@openai-bundled = false` on every clone run, and never rewrites the file wholesale.

**Two catalog fields carry tool calling.** Every model entry needs
`tool_mode = "code_mode_only"` and `use_responses_lite = false`. Without that pair, chat still
works and every tool dies with `unsupported call`.

## Capability summary

Proven on this machine; details and evidence in `parity-evidence/capability-matrix.txt`.

| Capability | ChatGPT | 9router (`cx/*`) | 9router (`ctx/*`) |
| --- | --- | --- | --- |
| chat, exec, `apply_patch` | yes | yes | yes |
| MCP tool call | yes | yes | yes |
| sub-agents | yes | **yes** | **no** |
| screenshots / images | yes | **yes** | **no** |
| web search, clock | yes | no | no |
| in-app browser | blocked | blocked | blocked |
| computer use | per-app approval | per-app approval | per-app approval |

Two failures are silent and worth stating plainly:

- **Sub-agents** need an OpenAI-native upstream. The gateway's Responses → Chat translator
  flattens a non-OpenAI upstream's `collaboration` namespace into one opaque function, so
  `spawn_agent` never reaches the model.
- **Images** through a non-OpenAI upstream come back on a *different model* (`kimi-k2.7-code`),
  with empty output, and the base64 is tokenised as text — about 87× the real cost. A 2.3 MB
  screenshot costs 17,274 tokens via `cx/*` and blows past a million-token window anywhere else.

Both are upstream bugs in the gateway, not in this repo. They are documented so nobody spends a
day rediscovering them.

## Setup

The launcher expects the app installed and a profile at `~/.codex/9router.config.toml`.

```powershell
# clone mode: first run seeds ~/.codex-clone from the profile and copies plugins/skills.
powershell -ExecutionPolicy Bypass -File scripts/codex-launch.ps1 -Mode clone

# real mode: untouched ChatGPT home.
powershell -ExecutionPolicy Bypass -File scripts/codex-launch.ps1 -Mode real
```

Create desktop shortcuts that pass `-Mode real` and `-Mode clone`.

The profile contains a bearer token for your gateway. **It is not in this repository.**
`.env.example` lists what a profile needs; copy your own values into
`~/.codex/9router.config.toml`. The launcher never reads a token from here.

## Regenerating the catalog

```sh
NINE_ROUTER_KEY=sk-... bin/codex-9router-catalog
# pin the default model instead of taking whatever sorts first:
DEFAULT_MODEL=cx/gpt-6.1-sol NINE_ROUTER_KEY=sk-... bin/codex-9router-catalog
```

## Verification

```sh
bin/codex-real-quicktest      # chat + exec + MCP, ChatGPT vs gateway
bin/codex-caps-quicktest      # capability matrix, writes real files and reads them back
bin/codex-caps-quicktest --list   # matrix only, runs nothing
```

Probes read the disk, never the model's claim about itself. A probe once reported `apply_patch`
as PASS while the file still said `OLD`; every assertion since then has been a file read.

## Requirements

- Windows host with Codex Desktop installed (MSIX).
- PowerShell 7 or Windows PowerShell 5.1.
- Node **24.22.2** for the reverse-engineering helper scripts; older versions fail on syntax the
  bundled code uses.
- Python 3.12 for `scripts/*.py`.

## Licence

MIT. See `LICENSE`.
