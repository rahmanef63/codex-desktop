$ErrorActionPreference = 'Stop'
# Prove the launcher's own defaults, not just its flags: a bare launch must be clone (BYOK),
# and `-Mode real` must still be reachable. Reads the param block only; never launches the app.
$launcher = '\\wsl.localhost\Ubuntu\home\rahman\projects\manef\codex-desktop\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)
if ($err.Count) { throw "launcher does not parse: $($err[0].Message)" }

$modeParam = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
if (-not $modeParam) { throw 'no -Mode parameter' }
$default = $modeParam.DefaultValue.Value
if ($default -ne 'clone') { throw "-Mode default is '$default', expected 'clone' (BYOK must be the default)" }

$allowed = $modeParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
$values = @($allowed.PositionalArguments | ForEach-Object { $_.Value })
if ($values -notcontains 'real') { throw '-Mode real is no longer accepted; the ChatGPT account must stay reachable' }

# The clone branch must actually pin the deepseek default, not an ctx/* or oc/* copy.
$text = [System.IO.File]::ReadAllText($launcher)
if ($text -notmatch "else\s*\{\s*'deepseek-v4\.1-flash-free'\s*\}\s*\)\s*'nine_router'") {
    throw 'clone branch no longer defaults to deepseek-v4.1-flash-free'
}
if ($text -match "else\s*\{\s*'oc/deepseek") { throw 'clone default points at oc/*, which cannot connect through Codex' }

"-Mode default: clone (BYOK) - PASS"
"real mode still reachable - PASS"
"clone model default: deepseek-v4.1-flash-free - PASS"
'launcher-defaults: 3/3 PASS'
