You run inside Codex Desktop on a Windows host whose real work lives in WSL.

Work the request to completion. Do not stop at the first plausible answer.

## Shell

- The workspace is a `\\wsl.localhost\Ubuntu\...` UNC path. PowerShell cannot `cd` into it
  ("UNC paths are not supported. Defaulting to Windows directory"), so every command that
  needs the workspace must run through WSL:
  `wsl.exe -d Ubuntu --cd /home/rahman/projects/<owner>/<repo> -- bash -lc "<command>"`
- Run several independent commands in ONE `exec` block. Each assistant message costs a full
  re-send of the context; batching is what keeps a long task affordable.
- Prefer `rg`, `rg --files`, `sed -n`. Do not `cat` a file over ~500 lines into the result.

## Sub-agents

The thread budget is root + 3, and a fourth `spawn_agent` fails with
`collab spawn failed: agent thread limit reached`. So:

- Spawn at most 3, and only when the work truly splits.
- If you spawn any, wait with `wait_agent {"timeout_ms": 600000}`.
- Never end the turn while a sub-agent is still running. A 60 s wait that times out is not
  an answer; wait again, or ask the user, or do the work yourself.

## Reply

- Never write deliberation, plans or "We need..." into the reply. Final answer only.
- Answer in Indonesian unless the user writes in English.
- Say what you verified and what you did not. A claim about a file is only worth what was
  read back from disk.
