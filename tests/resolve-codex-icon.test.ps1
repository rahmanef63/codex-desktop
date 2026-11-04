# Self-check for scripts/resolve-codex-icon.ps1.
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/resolve-codex-icon.test.ps1
# Exits 0 when every assertion holds, 1 otherwise. No test framework: each check
# prints PASS/FAIL so a failure names itself without a runner.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'scripts\resolve-codex-icon.ps1'
if (-not (Test-Path $script)) { throw "resolver not found at $script" }

# PowerShell writes native stderr as ErrorRecords, which NativeCommandError turns
# into noise that looks like a failure. The resolver reports diagnostics there by
# design, so downgrade it and judge results only by exit code and stdout.
$ErrorActionPreference = 'Continue'

$failures = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name $Detail"; $script:failures++ }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ric-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
# PowerShell refuses to run .ps1 files straight off a UNC share, and this repo
# lives on a WSL path. Stage a local copy so the test works from either place.
$staged = Join-Path $work 'resolve-codex-icon.ps1'
Copy-Item -LiteralPath $script -Destination $staged -Force
$script = $staged
$cache = Join-Path $work 'cache\icon.ico'

function Invoke-Resolver([string]$Path, [switch]$Refresh) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path, '-CachePath', $cache)
    if ($Refresh) { $psArgs += '-Refresh' }
    $stdout = & powershell.exe @psArgs 2>$null
    return [pscustomobject]@{
        Exit   = $LASTEXITCODE
        Lines  = @($stdout)
        Answer = (@($stdout) | Select-Object -First 1)
    }
}

function New-Stub([string]$Name, [string]$Version, [string]$Location, [switch]$Throw) {
    $stub = Join-Path $work $Name
    $body = if ($Throw) {
        "function Get-AppxPackage { param([string]`$Name,[string]`$PackageType,[switch]`$AllUsers) throw [System.UnauthorizedAccessException]::new('Access is denied') }"
    } else {
        "function Get-AppxPackage { param([string]`$Name,[string]`$PackageType,[switch]`$AllUsers) [pscustomobject]@{ Name='OpenAI.Codex'; Version='$Version'; InstallLocation='$Location'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0' } }"
    }
    @"
$body
& '$script' -CachePath '$cache'
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $stub -Encoding ASCII
    return $stub
}

try {
    # Cold start seeds the cache from the shipped .ico and keeps every frame.
    $r = Invoke-Resolver $script
    Check 'cold start exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)"
    Check 'cold start prints exactly one line' ($r.Lines.Count -eq 1) "lines=$($r.Lines.Count)"
    Check 'cold start prints an existing file' ([System.IO.File]::Exists($r.Answer)) "answer=$($r.Answer)"
    $bytes = [System.IO.File]::ReadAllBytes($cache)
    Check 'cache is a real multi-frame ico' ([BitConverter]::ToUInt16($bytes, 2) -eq 1 -and [BitConverter]::ToUInt16($bytes, 4) -ge 2) "frames=$([BitConverter]::ToUInt16($bytes, 4))"

    # Warm path must not depend on the package at all.
    $r = Invoke-Resolver $script
    Check 'warm path exits 0' ($r.Exit -eq 0)
    Check 'warm path answer is version-free' ($r.Answer -notmatch 'WindowsApps' -and $r.Answer -notmatch 'OpenAI\.Codex')

    # A corrupt cache is rejected, not trusted.
    [System.IO.File]::WriteAllBytes($cache, [byte[]](0xDE, 0xAD, 0xBE, 0xEF))
    $r = Invoke-Resolver $script
    Check 'corrupt cache is rebuilt' ($r.Exit -eq 0 -and (Get-Item $cache).Length -gt 1000) "bytes=$((Get-Item $cache).Length)"

    # The point of the whole script: the answer cannot move when the package does.
    $oldVer = '26.1027.3384.0'
    $futureVer = '99.9999.9999.0'
    $oldStub = New-Stub 'old.ps1' $oldVer "C:\Program Files\WindowsApps\OpenAI.Codex_${oldVer}_x64__2p2nqsd0c76g0"
    $futureStub = New-Stub 'future.ps1' $futureVer "C:\Program Files\WindowsApps\OpenAI.Codex_${futureVer}_x64__2p2nqsd0c76g0"
    $a = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $oldStub 2>$null | Select-Object -First 1)
    $b = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $futureStub 2>$null | Select-Object -First 1)
    Check 'survives an older deleted version' ([System.IO.File]::Exists($a)) "answer=$a"
    Check 'survives a future unseen version' ([System.IO.File]::Exists($b)) "answer=$b"
    Check 'answer is identical across versions' ($a -eq $b -and $a -eq $cache) "old=$a future=$b"

    # No package and no cache must fail loudly with an empty stdout.
    Remove-Item (Split-Path $cache -Parent) -Recurse -Force
    $throwStub = New-Stub 'blocked.ps1' '' '' -Throw
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $throwStub 2>&1
    Check 'no package exits nonzero' ($LASTEXITCODE -ne 0) "exit=$LASTEXITCODE"
    Check 'no package prints no path' (-not ($out | Where-Object { $_ -match '\.ico$' })) "out=$($out -join '|')"

    # A cache on an unwritable drive must degrade loudly, never invent a path.
    $degraded = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -CachePath 'Z:\nope\icon.ico' 2>$null
    $answer = (@($degraded) | Select-Object -First 1)
    Check 'unwritable cache exits 2' ($LASTEXITCODE -eq 2) "exit=$LASTEXITCODE"
    Check 'degraded path still exists' ([System.IO.File]::Exists($answer)) "answer=$answer"
    Check 'degraded path is flagged version-pinned' ($answer -match 'WindowsApps') "answer=$answer"

    if ($failures -gt 0) { Write-Host "$failures check(s) failed"; exit 1 }
    Write-Host 'all checks passed'
    exit 0
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
