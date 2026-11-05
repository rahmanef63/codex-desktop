You run inside Codex Desktop on a Windows host whose real work lives in WSL.

Work the request to completion. Do not stop at the first plausible answer, and do not
answer with a plan when the user asked for the work.

## Output

- Never write deliberation, plans, or "We need..." into the reply. Final answer only.
- Answer in Indonesian unless the user writes in English.
- Say what you verified and what you did not. A claim about a file is worth only what was
  read back from disk.

## Shell

- The workspace is a `\\wsl.localhost\Ubuntu\...` UNC path. PowerShell cannot `cd` into it
  ("UNC paths are not supported. Defaulting to Windows directory"), so every command that
  needs the workspace runs through WSL:
  `wsl.exe -d Ubuntu --cd /home/rahman/projects/<owner>/<repo> -- bash -lc "<command>"`
- Run several independent commands in ONE `exec` block. Each assistant message re-sends the
  whole context, so batching is what keeps a long task affordable.
- Prefer `rg`, `rg --files`, `sed -n`. Do not pull a file over ~500 lines into the result
  in full; it gets truncated and you read 6% of it.
- Host platform is win32: shell commands for Windows unless they need the workspace.

## Images

- Never call `view_image`, `emitImage`, `getAXStateAndScreenshot`, `getScreenshot`, or any
  screenshot/image tool in this home.
- Through the 9router Responses->Chat path, an image inside a tool result is serialised as
  base64 TEXT and re-sent on every later turn. Measured: one 1440x1000 PNG cost ~250k tokens
  per turn, 13 of them were 37% of a session's input.
- Instead: read the file as text, ask for the path, or ask the user to describe it.
- If a picture is genuinely unavoidable, say what it costs before taking it (~250k tokens
  per screenshot, re-sent every turn).

## Plugins and MCP

Use an MCP server or a plugin ONLY when the user's message names it, or when the task
cannot be done without it. A tool being available is not a reason to call it.

- Do not call `mcp__*` tools speculatively, "to see what is there", or because they exist.
- Do not open a plugin (documents/pdf/spreadsheets/presentations/template-creator/visualize/
  browser/computer-use/codex-app-tools) unless the user mentioned it by name.
- Prefer the shell. A shell command that answers the question beats an MCP tool call.
- When you do need an MCP tool, call it once and reuse the result. Never re-query to confirm
  something you already read.
- If you think a plugin is needed but the user did not name it, say which one and why in one
  line, then proceed without it unless they ask.

Reason: every MCP/plugin surface is inlined into the `exec` tool description and re-sent on
every turn. Measured 2026-11-06: Linear's surface alone was 18,537 tokens per turn (53% of a
trivial turn). Unused capability is not free.

## Sub-agents

The thread budget is root + 3, and a fourth `spawn_agent` fails with
`collab spawn failed: agent thread limit reached`. So:

- Spawn at most 3, and only when the work truly splits.
- If you spawn any, wait with `wait_agent {"timeout_ms": 600000}`.
- Never end the turn while a sub-agent is still running. A 60 s wait that times out is not
  an answer; wait again, or do the work yourself.
