$ErrorActionPreference = 'Stop'
# The clone must never pay for a plugin's tool surface it does not use.
#
# Measured 2026-11-06 by capturing the exact request body Codex sends:
#   linear@openai-api-curated enabled  -> exec tool 93,960 bytes, `say OK` = 38,779 input tokens
#   linear disabled                    -> exec tool 17,646 bytes, `say OK` = 18,150 input tokens
# The whole MCP surface (60+ tools, 74,150 chars, ~18,537 tokens) is inlined into the `exec`
# tool DESCRIPTION and re-sent on every turn of every session.
#
# This asserts the launcher keeps disabling it, and that the mechanism it uses (Set-
# ClonePluginDisabled) still produces a disabled block rather than silently doing nothing.
$launcher = '\\wsl.localhost\Ubuntu\home\rahman\projects\manef\codex-desktop\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)
if ($err.Count) { throw "launcher does not parse: $($err[0].Message)" }

$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-ClonePluginDisabled' }, $true)[0]
if (-not $fn) { throw 'Set-ClonePluginDisabled is gone from the launcher' }
Invoke-Expression $fn.Extent.Text

$text = [System.IO.File]::ReadAllText($launcher)
if ($text -notmatch "Set-ClonePluginDisabled\s+\`$targetConfig\s+'linear@openai-api-curated'") {
    throw 'the launcher no longer disables linear@openai-api-curated; its 18.5k-token tool surface would come back'
}
if ($text -notmatch "Set-ClonePluginDisabled\s+\`$targetConfig\s+'chrome@openai-bundled'") {
    throw 'the launcher no longer disables chrome@openai-bundled (the Access is denied cache lock)'
}
# The GUI plugins advertise their tool surface too: mcp__cua_repl cost ~1,650 tokens/turn.
foreach ($plugin in @('unified-computer-use@openai-bundled', 'computer-use@openai-bundled',
                      'codex-app-tools@openai-bundled', 'browser@openai-bundled')) {
    if ($text -notmatch [regex]::Escape("'$plugin'")) {
        throw "the launcher no longer disables $plugin; its tool surface would be re-sent every turn"
    }
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$pass = 0

# 1. An enabled block flips to false.
$tmp = Join-Path $env:TEMP ('plugin-off-' + [guid]::NewGuid().ToString('N') + '.toml')
[System.IO.File]::WriteAllText($tmp, "[plugins.`"linear@openai-api-curated`"]`nenabled = true`n", $utf8)
try {
    Set-ClonePluginDisabled $tmp 'linear@openai-api-curated' | Out-Null
    $got = [System.IO.File]::ReadAllText($tmp, $utf8)
    if ($got -notmatch 'enabled = false') { throw "enabled block was not disabled: $got" }
    if ($got -match 'enabled = true') { throw "still enabled after the call: $got" }
    $pass++
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

# 2. An absent block is added as disabled (so a later app rewrite cannot re-enable it silently).
$tmp2 = Join-Path $env:TEMP ('plugin-add-' + [guid]::NewGuid().ToString('N') + '.toml')
[System.IO.File]::WriteAllText($tmp2, "model = `"x`"`n", $utf8)
try {
    Set-ClonePluginDisabled $tmp2 'linear@openai-api-curated' | Out-Null
    $got2 = [System.IO.File]::ReadAllText($tmp2, $utf8)
    if ($got2 -notmatch '\[plugins\."linear@openai-api-curated"\]') {
        throw "no plugin block added: $got2"
    }
    if ($got2 -notmatch 'enabled = false') { throw "added block is not disabled: $got2" }
    $pass++
} finally { Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue }

# 3. Already-disabled is a no-op: no rewrite, other bytes untouched.
$tmp3 = Join-Path $env:TEMP ('plugin-noop-' + [guid]::NewGuid().ToString('N') + '.toml')
$fixture = "model = `"x`"`n`n[plugins.`"linear@openai-api-curated`"]`nenabled = false`n"
[System.IO.File]::WriteAllText($tmp3, $fixture, $utf8)
try {
    Set-ClonePluginDisabled $tmp3 'linear@openai-api-curated' | Out-Null
    $after = [System.IO.File]::ReadAllText($tmp3, $utf8)
    if ($after -ne $fixture) { throw "already-disabled file changed:`n$after" }
    $pass++
} finally { Remove-Item $tmp3 -Force -ErrorAction SilentlyContinue }

"launcher disables linear@openai-api-curated - PASS"
"launcher still disables chrome@openai-bundled - PASS"
"plugin disable is idempotent and byte-safe - PASS"
"tool-surface: $pass/3 assertions passed"
