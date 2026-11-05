$ErrorActionPreference = 'Stop'
# Test-GatewayReachable must be false ONLY when nothing is listening.
#
# Why this test exists: on 2026-11-05 the gateway was down (port 20128 closed, ~/.9router
# quarantined after the deepseek-default work) and the failure was blamed on the model —
# `ctx/ollama/deepseek-v4.1-flash:1017-cloud` "looked dead" and had never been measured.
# A preflight that refuses to launch when the gateway is down turns that into one sentence.
# A preflight that refuses wrongly is worse: it blocks a launch that would have worked.
#
# Both directions are asserted here. No window is opened, no app is started.
$launcher = Join-Path $PSScriptRoot '..\..\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)
if ($err.Count) { throw "launcher does not parse: $($err[0].Message)" }

foreach ($name in 'Test-GatewayReachable', 'Get-ProfileBaseUrl') {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)[0]
    if (-not $fn) { throw "$name is gone from the launcher" }
    Invoke-Expression $fn.Extent.Text
}

# 1. A closed loopback port must be reported down. 20999 is chosen because nothing in this
#    repo uses it, and it is below the ephemeral range in practice on Windows and WSL.
if (Test-GatewayReachable 'http://127.0.0.1:20999/v1' 1) {
    throw 'a closed port was reported reachable'
}

# 2. A listening loopback port must be reported up, even when it answers 404 or 401.
#    A gateway that rejects our unauthenticated probe IS alive; treating that as down would
#    block every real launch, because /v1/models needs a key.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 20998)
$listener.Start()
try {
    if (-not (Test-GatewayReachable 'http://127.0.0.1:20998/v1' 2)) {
        throw 'a listening port was reported down'
    }
} finally {
    $listener.Stop()
}

# 3. A remote provider is never probed: this script cannot fix a remote outage, and a wrong
#    verdict there would block a launch that works.
if (-not (Test-GatewayReachable 'https://api.example.com/v1' 1)) {
    throw 'a remote provider was probed and refused'
}

# 4. No base URL means no opinion.
if (-not (Test-GatewayReachable '' 1)) { throw 'an empty base URL was refused' }
if (-not (Test-GatewayReachable $null 1)) { throw 'a null base URL was refused' }

# 5. Get-ProfileBaseUrl must find the table the profile actually uses. A temp fixture, not the
#    live profile: that one moved from http://127.0.0.1:20128/v1 to the VPS on 2026-11-05, and
#    a test pinned to today's value fails on the next deliberate change instead of on a bug.
$fixture = Join-Path $env:TEMP ('nine-router-profile-' + [guid]::NewGuid().ToString('N') + '.toml')
@'
approval_policy = "never"
model_provider = "nine_router"
model = "deepseek-v4.1-flash-free"

[model_providers.nine_router]
base_url = "https://router.example.test/v1"
wire_api = "responses"
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
try {
    $base = Get-ProfileBaseUrl $fixture
    if ($base -ne 'https://router.example.test/v1') {
        throw "expected the fixture's base_url, got '$base'"
    }
} finally {
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
}

# 6. The live profile, when present, must name SOME base_url: a profile with none is a launch
#    that cannot answer, whatever that URL happens to be this week.
$real = Join-Path $env:USERPROFILE '.codex\9router.config.toml'
if (Test-Path -LiteralPath $real) {
    $base = Get-ProfileBaseUrl $real
    if (-not $base) { throw 'the live nine_router profile has no base_url' }
}

Write-Host 'gateway preflight: 7 assertions passed'
