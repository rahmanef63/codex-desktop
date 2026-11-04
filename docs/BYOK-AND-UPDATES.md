# Bring your own key, and stay current

Two facts decide everything here, and both are measured rather than assumed:

1. **Codex Desktop is an MSIX** (`OpenAI.Codex`). It updates itself through the Microsoft
   Store. We never pin its version, never re-pack it, never sign it. "Stuck on the version we
   adapted" cannot happen to the app — only to our tooling around it.
2. **Codex already supports BYOK profiles natively.** `codex -p <name>` layers
   `$CODEX_HOME/<name>.config.toml` over `config.toml`. That is a free built-in mechanism, so
   nothing here needs an installer, a certificate, or a paid service.

Everything below is a thin layer over those two facts.

## 1. Nothing here is signed, and that is deliberate

| what | signed? | how |
| --- | --- | --- |
| Codex Desktop (MSIX) | **yes, by OpenAI** | we do not touch it; Store handles updates |
| our scripts (`bin/*`) | not applicable | plain Python, run in place |
| the Electron window (`app/`) | **no** | `signExecutable: false` in `electron-builder.yml` |

A code-signing certificate costs money every year. `signExecutable: false` skips *only* the
signature — the icon and the version metadata are still written into the exe. The cost is
that Windows SmartScreen warns on first run ("unrecognised app"). That is the price of not
buying a certificate, not a defect, and it is recorded here so nobody rediscovers it.

If a certificate is ever bought, drop that one line. Nothing else changes.

## 2. Keeping up with the app: `bin/codex-version-drift`

The app rewrites config keys between runs (CONTRACT §6), and a new build can rename or drop a
key we depend on. This records a fingerprint of everything our tooling relies on and reports
when it moves.

```bash
bin/codex-version-drift record      # after a successful clone launch
bin/codex-version-drift check       # before trusting a session; exit 1 when something moved
```

It reports, it never blocks a launch. What it watches:

| signal | why it matters |
| --- | --- |
| `[windows] sandbox`, `model`, `model_provider`, `sandbox_mode`, the chrome plugin key | the launcher re-asserts these; if one disappears from the file the app renamed it |
| config keys added or removed | a new build writing new keys is harmless but worth reading (CONTRACT) |
| catalog slug hash | the model list the app can resolve; a change means re-run `codex-9router-catalog` |
| catalog entries missing `tool_mode` / `use_responses_lite` | tool calling breaks on that entry (CONTRACT §8) |
| MSIX identity + version | an app update. Expected; the launcher re-asserts its keys on the next clone launch |

Measured on this machine: 56 config keys, 80 catalog models, app `26.1027.3384.0`.
A deleted `model_provider` line is caught as `config-keys-removed` **and**
`load-bearing-key-vanished`.

## 3. BYOK profiles: `bin/codex-byok`

```bash
bin/codex-byok profile list                     # every profile, and what it can really serve
bin/codex-byok profile add local \
    --base-url http://127.0.0.1:20128/v1 --token-stdin --model cx/gpt-6.1-sol
bin/codex-byok pick                             # every model across every profile
bin/codex-byok apply local:ctx/ollama/kimi-k3:cloud
```

`profile list` does not trust the profile — it **probes** the gateway with the key the profile
carries and reports how many models answer. On this machine the existing `9router` profile
reports **99 models**.

### Two ways to carry a key, and why both exist

| form | trade-off |
| --- | --- |
| `env_key = "NAME"` | key stays in the environment, CONTRACT §9 prefers it. But the app cannot read a Windows shell environment, so it only works when launched from a shell that has it |
| `experimental_bearer_token = "sk-…"` | what the existing `~/.codex/9router.config.toml` already does, because it is the form that works. Written `chmod 600` |

`--token-stdin` reads the key from **stdin**, never from an argument, because arguments land in
shell history (CONTRACT §10). The script never prints a key; `profile list` shows only whether
one is present.

## 4. The Electron window (`app/`)

One window over those two scripts: which profile and model is active, what every profile can
serve with a filter box, and the drift report. It is **not** a Codex clone and runs no agent.

```bash
cd app && npm start          # dev
cd app && npm run dist       # unsigned NSIS installer for x64
```

Safety that is enforced, not promised:

* `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`;
* the preload exposes exactly four functions, no dynamic channel names;
* `apply` accepts only a model id the gateway **actually listed** in this session, so a
  renderer cannot smuggle `../../evil` or `--flag` through the target string;
* external links open in the system browser, never in the window;
* CSP forbids remote script and any network fetch from the page.

Tests, both runnable without Electron:

```bash
node app/tests/ipc-contract.mjs     # apply() refuses anything not proven to be served
python3 app/tests/test-apply.py     # the config rewrite touches one key and nothing else
```

The second one found two real defects while it was written: a lost trailing comment on the
rewritten line, and an extra blank line inserted on every apply. Both are fixed, and the
8 cases now assert the exact bytes that change.

## 5. Launcher integration

```powershell
scripts/codex-launch.ps1 -Mode clone                        # unchanged: nine_router + cx/gpt-6.1-sol
scripts/codex-launch.ps1 -Mode clone -Profile 9router      # layer a BYOK profile
scripts/codex-launch.ps1 -Mode clone -Profile 9router -Model ctx/ollama/kimi-k3:cloud
```

With `-Profile`, the profile owns `model_provider` and `model`; the launcher no longer
overwrites them. It still re-asserts `[windows] sandbox` and
`chrome@openai-bundled`, because those are the two the app rewrites on every launch.

## 6. What is still not free, and what is not done

* **The VPS is unpatched.** `docs/vps-upgrade-runbook.md` covers it; the window is a human
  decision. Nothing here needs paying for — it is a downtime question, not a money one.
* **The API key has not been rotated.** It was exposed; the code is closed and the DB is
  clean, but the value in use is the value that leaked.
* **SmartScreen warns** on the unsigned installer. Only a purchased certificate removes it.
* **The window is unsigned too**, and it is an app of its own — it does not replace or update
  Codex Desktop.
