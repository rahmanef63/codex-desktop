$ErrorActionPreference = 'Stop'
# Every plugin stays enabled in this clone, by owner decision 2026-11-06.
#
# This test used to demand that five plugins be disabled to save tokens. That was reversed:
# a disabled plugin is a feature the owner loses, and one of them (browser@openai-bundled)
# powered the in-app browser panel. What remains is the honest record of the cost, and an
# assertion that the launcher does not quietly re-introduce a disable pass.
#
# Measured, same trivial task, capture proxy on the request body:
#   all plugins enabled, linear inline     ~39.8k input tokens per turn
#   linear disabled                        ~18k
#   browser@openai-bundled on vs off       18,941 both ways (zero cost, 4 alternating runs)
#
# Codex does have tool deferral (tool_search / tool_search_always_defer_mcp_tools /
# deferred_tool_world_state appear in the binary), but this build reports those keys as
# unrecognized configuration settings, so the idle cost cannot be switched off from config.
# The remaining lever is behaviour: clone-AGENTS.md forbids speculative mcp__* calls.
$launcher = '\\wsl.localhost\Ubuntu\home\rahman\projects\manef\codex-desktop\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)
if ($err.Count) { throw "launcher does not parse: $($err[0].Message)" }

$text = [System.IO.File]::ReadAllText($launcher)

# 1. No plugin may be disabled by the launcher any more. A hardcoded disable is exactly the
#    mistake that broke the browser panel.
if ($text -match 'Set-ClonePluginDisabled') {
    throw 'the launcher still force-disables a plugin; every plugin is meant to stay enabled'
}

# 2. The clone AGENTS.md must still carry the behaviour rule, since config cannot defer tools.
$agents = Join-Path $PSScriptRoot '..\..\scripts\clone-AGENTS.md'
$agentsText = [System.IO.File]::ReadAllText($agents)
if ($agentsText -notmatch '## Plugins and MCP') {
    throw 'clone-AGENTS.md lost the Plugins and MCP section; nothing else tells the model not to call mcp__* speculatively'
}
if ($agentsText -notmatch 'mcp__\*') {
    throw 'the Plugins and MCP rule no longer mentions mcp__* explicitly'
}

"launcher disables no plugin - PASS"
"clone-AGENTS.md still has the Plugins and MCP rule - PASS"
'plugin-policy: 2/2 PASS'
