# Instructions and determinism

Two questions this answers:

1. **How do I make Codex follow my own instructions?** — `model_instructions_file`.
2. **Can I make the model deterministic?** — instructions and hooks, yes. Tokens, no.
   `codex-instruct determinism` prints exactly why, for the active provider.

Everything here uses surfaces the installed binary already honours. Nothing is patched,
nothing is signed, and nothing survives a Store update by copying files into the MSIX.

## Measured, not assumed

Verified 2026-11-05 against `OpenAI.Codex 26.1029.7803.0` on this machine:

| claim | how it was proved | result |
|---|---|---|
| `model_instructions_file` is honoured | profile carrying the key, prompt `say hello` | `MANGO hello` |
| **it REPLACES the prompt, it does not add to it** | `session_meta.base_instructions` with and without the key, same profile | **388 chars vs 21638** |
| it can also be passed per run | `-c model_instructions_file=...` | `PINEAPPLE hello!` |
| project `AGENTS.md` is read | workspace with `AGENTS.md`, prompt `say hi` | instruction applied |
| `AGENTS.override.md` wins over `AGENTS.md` | both present, same workspace | `FROM-OVERRIDE` |
| `hooks.json` has lifecycle events | strings in `codex.exe` | `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `SessionStart`, `Stop`, `SubagentStop`, `PreCompact`, `Notification` |

**Use `AGENTS.md` for extra rules, not `model_instructions_file`.** The second row is the one
that bites: a four-line instruction file on the 9router profile shrank the agent's entire
system prompt by 98%, which is why turns ended after a short answer instead of finishing the
work. Only reach for `model_instructions_file` when replacing the prompt is the goal — a
deliberately different agent, not "the same agent with a couple of house rules".

Strings measured in `app/resources/codex.exe` (355 MB):

```
model_instructions_file   model_reasoning_effort   model_reasoning_summary
model_verbosity           model_catalog_json      project_doc_max_bytes
project_doc_fallback_filenames                    AGENTS.override.md
```

Absent from the same binary: no `temperature`, `top_p` or `seed` **config key** exists.
The sampling fields that do appear are SDK type members of the Chat-Completions request,
which the Codex path does not build.

## Three surfaces, three scopes

| surface | file | scope | deterministic |
|---|---|---|---|
| `model_instructions_file` | `<CODEX_HOME>/<profile>.config.toml` | replaces the model prompt for that profile | yes |
| `AGENTS.md` / `AGENTS.override.md` | the workspace | adds project instructions; the override replaces the plain file | yes |
| `hooks.json` | `<CODEX_HOME>/hooks.json` | runs a command on a lifecycle event | yes |

The first is per profile, the second per project, the third per home. There is no
profile-scoped hooks file — the binary reads one `hooks.json` per `CODEX_HOME`.

## Instructions

```bash
bin/codex-instruct show                          # what is in effect, and where
bin/codex-instruct set 9router --file ~/style.md # copy in and point the profile at it
bin/codex-instruct set 9router --text "Be terse."  # short form
bin/codex-instruct set 9router --clear            # back to OpenAI's default prompt
```

Two behaviours that exist because their absence is silent:

* **The file is copied into the home**, not referenced in place. A profile pointing at a
  file the user later moves loads with the default prompt and no warning.
* **The path is translated to Windows form** and then TOML-escaped. The app is a Windows
  process: `/mnt/c/...` does not exist to it, and a raw backslash becomes a TOML escape
  sequence, so `C:\Users\rahma\x.md` would silently be read as `C:Usersrahmax.md`.

Neither failure produces an error message. Both are asserted in
`tests/instruct-contract.sh`.

## Hooks

```bash
bin/codex-instruct hook --event PreToolUse --command 'my-lint.sh' --matcher 'Edit|Write'
bin/codex-instruct hooks
```

This appends to the existing file rather than replacing it, because the installed app
already writes its own entries and a user may have added others by hand. Written as JSON
with two-space indent, the same shape the app emits.

A hook without `--matcher` runs for every occurrence of that event. The tool prints a
reminder when you do that on a tool event.

## Determinism, honestly

What you can pin:

| knob | effect |
|---|---|
| `model_instructions_file` | same prompt text every run |
| `AGENTS.md`, `AGENTS.override.md` | same project rules every run |
| `hooks.json` | same command on the same event, every run |
| `model_reasoning_effort` | same effort budget every run |
| `model_verbosity` | same verbosity request every run |

What you cannot pin, and why:

* **`temperature`, `top_p`, `seed`** — the Codex request is Responses-shaped and carries
  no such fields; the binary exposes no config key for them. Passing them would be a
  no-op that looks like it worked.
* **Token-level reproducibility** — even at the same settings, a provider batches and
  routes differently between runs. Two identical prompts can differ in wording while
  both are correct.

So the deterministic part of this stack is everything *around* the model: the prompt,
the project rules, the hook commands, and the verification. That is the part worth
owning, and it is the part that does not drift when the app updates.

If you need reproducible *output*, put the model behind a provider that pins a seed and
documents it, and treat the model as one component of a pipeline whose structure is fixed.
That is a different project from this one, and this README will not pretend otherwise.

## When the app updates

`model_instructions_file` and `hooks.json` live in the Codex home, not in the MSIX, so a
Store update does not remove them. What can move is the key name itself.

`bin/codex-version-drift check` records the config keys our tooling depends on. If a new
build renames or drops `model_instructions_file`, that check reports it instead of letting
the instruction file quietly stop applying.

## Symptom table

| symptom | cause | fix |
|---|---|---|
| instructions do not apply | profile path is `/mnt/c/...` | re-run `codex-instruct set` so it writes the Windows form |
| instructions do not apply | key added under a `[table]` instead of top level | it must be top level, above the first `[model_providers.*]` |
| workspace `AGENTS.md` ignored | an `AGENTS.override.md` exists beside it | that is by design; delete the override |
| hook never runs | event name typo | `codex-instruct hooks` lists only real events |
| hook runs for every tool | no `--matcher` | add `--matcher 'Edit|Write'` |
| `determinism` shows nothing | profile name unknown | pass the profile name, or check `codex-instruct show` |
