param(
    [ValidateSet('real', 'clone')]
    [string]$Mode = 'real',
    # Where the real ChatGPT home lives. Default: %USERPROFILE%\.codex
    [string]$RealHome = '',
    # Where the isolated clone home lives. Default: %USERPROFILE%\.codex-clone
    [string]$CloneHome = ''
)

$ErrorActionPreference = 'Stop'

# Homes default to %USERPROFILE% so this works on any machine. Override with
# -RealHome / -CloneHome when they live elsewhere (a separate drive, for example).
$realHome = if ($RealHome) { $RealHome } else { Join-Path $env:USERPROFILE '.codex' }
$cloneHome = if ($CloneHome) { $CloneHome } else { Join-Path $env:USERPROFILE '.codex-clone' }

# Clone home is a fully standalone CODEX_HOME. It contains NO junctions, symlinks or
# other reparse points: plugins/skills are real copies, and sessions/sqlite/cache/tmp/
# browser start empty so clone history never lands in the real account's history.

# The app writes [windows] sandbox = "unelevated" into the clone config on its own.
# Elevated is what the Windows sandbox needs. Only the sandbox key directly under
# [windows] is touched: top-level sandbox_mode is a different key and stays as-is.
function Set-CloneWindowsSandboxElevated($configPath) {
    # Read/write as UTF-8 explicitly: Windows PowerShell 5.1 Get-Content defaults to
    # the ANSI codepage and would mangle the em-dashes in the profile comments.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $raw.EndsWith("`n")

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "`r?`n"))
    if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

    $sectionStart = -1
    $sandboxIndex = -1
    $current = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\[([^\[\]]+)\]$') {
            $current = $Matches[1].Trim().ToLowerInvariant()
            if ($current -eq 'windows' -and $sectionStart -lt 0) { $sectionStart = $i }
            continue
        }
        if ($current -eq 'windows' -and $sandboxIndex -lt 0 -and $trimmed -match '^sandbox\s*=') {
            $sandboxIndex = $i
        }
    }

    $old = $null
    if ($sectionStart -ge 0 -and $sandboxIndex -ge 0) {
        $old = (($lines[$sandboxIndex] -split '=', 2)[1]).Trim().Trim('"')
        if ($old -ceq 'elevated') { return }
        $lines[$sandboxIndex] = 'sandbox = "elevated"'
    } elseif ($sectionStart -ge 0) {
        $lines.Insert($sectionStart + 1, 'sandbox = "elevated"')
    } else {
        $lines.Add('')
        $lines.Add('[windows]')
        $lines.Add('sandbox = "elevated"')
    }

    $out = ($lines -join $newline) + $(if ($endsWithNewline) { $newline } else { '' })
    [System.IO.File]::WriteAllText($configPath, $out, $utf8)

    if ($old) {
        Write-Host "windows.sandbox=elevated (was $old)"
    } else {
        Write-Host 'windows.sandbox=elevated (added)'
    }
}

# The app rewrites the top-level `model` (and sometimes `model_provider`) from the last UI
# pick. In the clone that lands on a ChatGPT-only slug the nine_router provider cannot serve,
# which surfaces as "Invalid model metadata". Re-assert both on every clone run. Only the
# two top-level keys are touched; every [section] below them is left alone.
function Set-CloneModel($configPath, $model, $provider) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $raw.EndsWith("`n")

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "`r?`n"))
    if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

    $changes = @()
    $modelIndex = -1
    $providerIndex = -1
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\[[^\[\]]+\]$') { $inSection = $true; continue }
        if ($inSection) { continue }
        if ($modelIndex -lt 0 -and $trimmed -match '^model\s*=') { $modelIndex = $i }
        elseif ($providerIndex -lt 0 -and $trimmed -match '^model_provider\s*=') { $providerIndex = $i }
    }

    foreach ($pair in @(@{ Index = $modelIndex; Key = 'model'; Value = $model }, @{ Index = $providerIndex; Key = 'model_provider'; Value = $provider })) {
        $line = $pair.Key + ' = "' + $pair.Value + '"'
        if ($pair.Index -ge 0) {
            $old = (($lines[$pair.Index] -split '=', 2)[1]).Trim().Trim('"')
            if ($old -ceq $pair.Value) { continue }
            $lines[$pair.Index] = $line
            $changes += "$($pair.Key)=$($pair.Value) (was $old)"
        } else {
            $lines.Insert(0, $line)
            $changes += "$($pair.Key)=$($pair.Value) (added)"
        }
    }

    if ($changes.Count -eq 0) { return }
    $out = ($lines -join $newline) + $(if ($endsWithNewline) { $newline } else { '' })
    [System.IO.File]::WriteAllText($configPath, $out, $utf8)
    foreach ($c in $changes) { Write-Host $c }
}

function Set-ClonePluginDisabled($configPath, $pluginId) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $raw.EndsWith("`n")

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "`r?`n"))
    if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

    $header = '[plugins."' + $pluginId + '"]'
    $headerIndex = -1
    $current = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\[([^\[\]]+)\]$') { $current = $trimmed; continue }
        if ($current -eq $header -and $trimmed -match '^enabled\s*=') {
            if ($trimmed -ceq 'enabled = true') {
                $lines[$i] = 'enabled = false'
                $out = ($lines -join $newline) + $(if ($endsWithNewline) { $newline } else { '' })
                [System.IO.File]::WriteAllText($configPath, $out, $utf8)
                Write-Host "plugins.$pluginId disabled"
            }
            return
        }
    }

    # No enabled line found: add the block so the plugin stays off even if the app
    # later re-adds it with a different shape.
    $lines.Add('')
    $lines.Add($header)
    $lines.Add('enabled = false')
    $out = ($lines -join $newline) + $(if ($endsWithNewline) { $newline } else { '' })
    [System.IO.File]::WriteAllText($configPath, $out, $utf8)
    Write-Host "plugins.$pluginId disabled (added)"
}

function Copy-Tree($source, $destination) {
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "skip (source missing): $source"
        return
    }
    $robocopyArgs = @($source, $destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/SL', '/R:1', '/W:1', '/MT:16')
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
    # robocopy: 0-7 are success codes, >=8 is failure
    if ($proc.ExitCode -ge 8) {
        Write-Error "robocopy failed ($($proc.ExitCode)) copying $source -> $destination"
        exit 1
    }
}

if ($Mode -eq 'clone') {
    $clonedThisRun = $false
    if (-not (Test-Path -LiteralPath $cloneHome)) {
        New-Item -ItemType Directory -Path $cloneHome -Force | Out-Null
        $clonedThisRun = $true
    }

    # config.toml: seed from the 9router profile with the catalog path pointed inside the
    # clone home. Never overwrite an existing clone config: the app appends its own blocks.
    $targetConfig = Join-Path $cloneHome 'config.toml'
    if (-not (Test-Path -LiteralPath $targetConfig)) {
        $sourceConfig = Join-Path $realHome '9router.config.toml'
        if (-not (Test-Path -LiteralPath $sourceConfig)) {
            Write-Error "Required config file missing: $sourceConfig"
            exit 1
        }
        $catalogPath = Join-Path $cloneHome 'nine-router-models.json'
        $lines = Get-Content -LiteralPath $sourceConfig
        $foundCatalog = $false
        $newLines = foreach ($line in $lines) {
            if ($line -match '^\s*model_catalog_json\s*=') {
                $foundCatalog = $true
                'model_catalog_json = "' + $catalogPath.Replace('\', '\\') + '"'
            } else {
                $line
            }
        }
        if (-not $foundCatalog) {
            $newLines += 'model_catalog_json = "' + $catalogPath.Replace('\', '\\') + '"'
        }
        [System.IO.File]::WriteAllLines($targetConfig, $newLines, [System.Text.UTF8Encoding]::new($false))
        Write-Host "seeded config.toml from $sourceConfig"
    }

    # The app appends [windows] sandbox = "unelevated" on launch, which breaks the
    # Windows sandbox check in the clone window. Re-assert elevated every run.
    Set-CloneWindowsSandboxElevated $targetConfig

    # Same story for the model: a UI pick rewrites `model` to a slug nine_router cannot
    # serve. Pin the pair the profile was measured with.
    # Default clone model = cx/gpt-6.1-sol, the only catalog entry whose image path works.
    # Measured 2026-11-01: sending a screenshot to a non-OpenAI upstream through this
    # gateway silently SWAPS the upstream to kimi-k2.7-code:cloud and tokenises the image
    # base64 as TEXT (~87x the real cost), which is what "exceeded max context length by
    # 1633305 tokens" was. cx keeps input_image intact. Sub-agents also work here, unlike
    # the ctx/* entries, whose collaboration namespace the gateway flattens.
    Set-CloneModel $targetConfig 'cx/gpt-6.1-sol' 'nine_router'

    # Catalog: the clone must read its own copy, not the real home's.
    $targetCatalog = Join-Path $cloneHome 'nine-router-models.json'
    if (-not (Test-Path -LiteralPath $targetCatalog)) {
        Copy-Item -LiteralPath (Join-Path $realHome 'nine-router-models.json') -Destination $targetCatalog
        Write-Host 'seeded nine-router-models.json'
    }

    # Real copies (NOT links). Plugins are needed because the app loads them from the home.
    foreach ($dir in @('plugins', 'skills')) {
        $dst = Join-Path $cloneHome $dir
        if (-not (Test-Path -LiteralPath $dst)) {
            Copy-Tree (Join-Path $realHome $dir) $dst
            Write-Host "copied $dir"
        }
    }

    # Per-mode state starts empty. This is the whole point of the split.
    foreach ($dir in @('sessions', 'sqlite', 'cache', 'tmp', 'browser')) {
        $dst = Join-Path $cloneHome $dir
        if (-not (Test-Path -LiteralPath $dst)) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
        }
    }

    # chrome@openai-bundled must stay OFF in the clone. When it is on, Chrome launches
    # extension-host.exe from inside plugins\cache\openai-bundled\chrome\latest, Windows
    # then locks that file, and the app's own cache refresh fails on every start with
    # "failed to back up plugin cache entry: Access is denied. (os error 5)".
    # Measured: real home 0 occurrences, clone 15. With the plugin off, 0 in 638 log lines.
    # The real account keeps it enabled; this only ever rewrites the clone config.
    Set-ClonePluginDisabled $targetConfig 'chrome@openai-bundled'

    # The clone's Chrome extension host keeps plugins\cache\openai-bundled\chrome\latest
    # open, so the app's own cache refresh hits
    # "failed to back up plugin cache entry: Access is denied. (os error 5)" and warns on
    # every start. Stop the stale hosts whose image lives inside the clone home. Only
    # processes whose executable path is under $cloneHome are touched, so the real
    # account's extension host and the running Chrome are never affected.
    $stale = @(Get-CimInstance Win32_Process -Filter "Name='extension-host.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($cloneHome, 'OrdinalIgnoreCase') })
    foreach ($proc in $stale) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Host "stopped stale clone extension-host pid=$($proc.ProcessId)"
        } catch {
            Write-Host "could not stop pid=$($proc.ProcessId): $($_.Exception.Message)"
        }
    }

    $chosenHome = $cloneHome
    $userDataDir = Join-Path $realHome 'electron-clone'
    $homeState = if ($clonedThisRun) { 'created-this-run' } else { 'already-existed' }
} else {
    $realConfig = Join-Path $realHome 'config.toml'
    if (-not (Test-Path -LiteralPath $realConfig)) {
        Write-Error "Required config file missing: $realConfig"
        exit 1
    }

    $chosenHome = $realHome
    $userDataDir = Join-Path $realHome 'electron-real'
    # Real mode never creates or touches the clone home; report its actual state.
    $homeState = if (Test-Path -LiteralPath $cloneHome) { 'already-existed' } else { 'absent' }
}

if (-not (Test-Path -LiteralPath $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
}

$env:CODEX_HOME = $chosenHome
$env:CODEX_ELECTRON_USER_DATA_PATH = $userDataDir

$directExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1027.3384.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'

if (-not (Test-Path -LiteralPath $directExe)) {
    $installed = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty InstallLocation
    if ($installed) {
        $candidate = Join-Path $installed 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate) { $directExe = $candidate }
    }
}

if (-not (Test-Path -LiteralPath $directExe)) {
    Write-Host "ERROR: direct exe not found at $directExe. Clone mode cannot start; the shell fallback would attach to the existing window instead."
    exit 1
}

Start-Process -FilePath $directExe -ArgumentList "--user-data-dir=$userDataDir"

Write-Host "launch: $directExe --user-data-dir=$userDataDir"
Write-Host "CODEX_HOME=$env:CODEX_HOME"
Write-Host "CODEX_ELECTRON_USER_DATA_PATH=$env:CODEX_ELECTRON_USER_DATA_PATH"
Write-Host "mode=$Mode"
Write-Host "cloneHome=$homeState"
