$ErrorActionPreference = 'Stop'
$launcher = '\\wsl.localhost\Ubuntu\home\rahman\projects\manef\codex-desktop\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)

$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-CloneTopLevel' }, $true)[0]
Invoke-Expression $fn.Extent.Text

$tmp = Join-Path $env:TEMP 'clone-toplevel-fixture.toml'
$original = @"
model = "old-model"
model_provider = "nine_router"

[model_providers.nine_router]
name = "x"
model_instructions_file = "section-kept"
"@
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($tmp, $original, $utf8)

# 1. absent key -> inserted at top level, before the first table
Set-CloneTopLevel $tmp 'model_instructions_file' 'C:\Users\rahma\.codex\9router.instructions.md' | Out-Null
$after = [System.IO.File]::ReadAllText($tmp, $utf8)
$head = ($after -split "`r?`n" | Select-Object -First 3)
if ($head[2] -notlike 'model_instructions_file = "C:\\Users\\rahma\\.codex\\9router.instructions.md"') {
    throw "insert placed wrong: $($head -join ' | ')"
}
$top = ($after -split "(?m)^\[" )[0]
if (($top -split "`r?`n" | Where-Object { $_ -match '^model_instructions_file\s*=' }).Count -ne 1) {
    throw "expected exactly one top-level model_instructions_file; head was:`n$top"
}
if ($after -notmatch '(?m)^model = "old-model"$') { throw 'clobbered model' }
if ($after -notmatch '(?m)^model_instructions_file = "section-kept"$') { throw 'clobbered section key' }

# 2. already correct -> byte-identical no-op
Set-CloneTopLevel $tmp 'model_instructions_file' 'C:\Users\rahma\.codex\9router.instructions.md' | Out-Null
if ([System.IO.File]::ReadAllText($tmp, $utf8) -cne $after) { throw 'not a no-op on second run' }

# 3. changed value -> one line replaced, nothing else
Set-CloneTopLevel $tmp 'model_instructions_file' 'D:\other.md' | Out-Null
$third = [System.IO.File]::ReadAllText($tmp, $utf8)
if ($third -notmatch '(?m)^model_instructions_file = "D:\\\\other\.md"$') { throw "value not rewritten: $third" }
if (($third -split "(?m)^\[" )[0] -match 'model_instructions_file' -and
    (($third -split "(?m)^\[" )[0] -split "`r?`n" | Where-Object { $_ -match '^model_instructions_file\s*=' }).Count -ne 1) { throw 'duplicate top-level key after rewrite' }

Remove-Item $tmp -Force
'Set-CloneTopLevel: 3/3 PASS'
