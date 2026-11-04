$ErrorActionPreference = 'Stop'
# Set-CloneTopLevelRemove must delete the TOP-LEVEL key only, leave a same-named key inside a
# [table] alone, and be a no-op the second time. It exists because `model_instructions_file`
# REPLACES the Codex prompt instead of adding to it (PROGRESS 15), so a stale one silently
# shrinks the agent's whole instruction set.
$launcher = Join-Path $PSScriptRoot '..\..\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)
if ($err.Count) { throw "launcher does not parse: $($err[0].Message)" }
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-CloneTopLevelRemove' }, $true)[0]
if (-not $fn) { throw 'Set-CloneTopLevelRemove is gone from the launcher' }
Invoke-Expression $fn.Extent.Text

$tmp = Join-Path $env:TEMP 'clone-removekey-fixture.toml'
$original = "model = `"x`"`r`nmodel_instructions_file = `"C:\\a.md`"`r`nmodel_provider = `"nine_router`"`r`n`r`n[model_providers.nine_router]`r`nmodel_instructions_file = `"kept`"`r`n"
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($tmp, $original, $utf8)

$count = { param($t) ([regex]::Matches($t, '(?m)^model_instructions_file\s*=')).Count }
if ((& $count $original) -ne 2) { throw 'fixture is wrong: expected 2 occurrences to start with' }

Set-CloneTopLevelRemove $tmp 'model_instructions_file' | Out-Null
$after = [System.IO.File]::ReadAllText($tmp, $utf8)
if ((& $count $after) -ne 1) { throw "expected exactly the table key to survive, got $((& $count $after))" }
if ($after -notmatch '(?m)^model_instructions_file = "kept"\r?$') { throw 'clobbered the key inside [model_providers]' }
if ($after -notmatch '(?m)^model = "x"\r?$') { throw 'clobbered model' }
if ($after -notmatch '(?m)^model_provider = "nine_router"\r?$') { throw 'clobbered model_provider' }

Set-CloneTopLevelRemove $tmp 'model_instructions_file' | Out-Null
if ([System.IO.File]::ReadAllText($tmp, $utf8) -cne $after) { throw 'not a no-op on second run' }

Remove-Item $tmp -Force
'Set-CloneTopLevelRemove: 4/4 PASS'
