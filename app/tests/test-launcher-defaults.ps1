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

# The clone branch must pin exactly the model the owner chose: Ollama Cloud DeepSeek V4.1
# Flash (1017) on the VPS gateway. This is a bare upstream slug, not a combo, which was an
# explicit policy decision -- the cost (no prompt cache, so no fallback chain either) is
# documented in codex-launch.ps1 and PROGRESS §20. The test pins the decision so a later
# edit cannot silently move the default back without saying so.
$text = [System.IO.File]::ReadAllText($launcher)
if ($text -notmatch "else\s*\{\s*'([^']+)'\s*\}\s*\)\s*'nine_router'") {
    throw 'clone branch no longer pins a default model'
}
$defaultModel = $Matches[1]
if ($defaultModel -ne 'ctx/ollama/deepseek-v4.1-flash:1017-cloud') {
    throw "clone default is '$defaultModel', expected ctx/ollama/deepseek-v4.1-flash:1017-cloud"
}
if ($text -match "else\s*\{\s*'oc/deepseek") { throw 'clone default points at oc/*, which cannot connect through Codex' }

"-Mode default: clone (BYOK) - PASS"
"real mode still reachable - PASS"
"clone model default: $defaultModel - PASS"
'launcher-defaults: 3/3 PASS'
