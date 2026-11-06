param(
    # Clone is the default: this machine's default is BYOK (9router), not the ChatGPT account.
    # `-Mode real` stays available for the real account and is never touched by clone runs.
    [ValidateSet('real', 'clone')]
    [string]$Mode = 'clone',
    # Where the real ChatGPT home lives. Default: %USERPROFILE%\.codex
    [string]$RealHome = '',
    # Where the isolated clone home lives. Default: %USERPROFILE%\.codex-clone
    [string]$CloneHome = '',
    # Which BYOK profile to run under, by name: $CODEX_HOME\<name>.config.toml.
    # Empty means the built-in `nine_router` provider below, i.e. the original behaviour.
    # Manage these with bin/codex-byok (list / add / pick / apply).
    [string]$Profile = '',
    # Override the model for this launch only. Empty means the profile's own value, or the
    # measured default when no profile is named.
    [string]$Model = ''
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

function Set-CloneTopLevelRemove($configPath, $key) {
    # Delete ONE top-level key if present. Needed because `model_instructions_file` replaces
    # the Codex prompt wholesale, so leaving a stale one silently shrinks it (PROGRESS 15).
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $raw.EndsWith("`n")
    $suffix = if ($endsWithNewline) { $newline } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "`r?`n"))
    if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

    $pattern = '^' + [regex]::Escape($key) + '\s*='
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\[[^\[\]]+\]$') { $inSection = $true; continue }
        if ($inSection) { continue }
        if ($trimmed -match $pattern) {
            $lines.RemoveAt($i)
            [System.IO.File]::WriteAllText($configPath, (($lines -join $newline) + $suffix), $utf8)
            Write-Host "$key removed (it replaces the Codex prompt instead of adding to it)"
            return
        }
    }
}

function Set-CloneTopLevel($configPath, $key, $value) {
    # Rewrite ONE top-level key, leaving every other byte alone (CONTRACT §5). Used for keys
    # the app never writes, where "already correct" must be a no-op instead of a rewrite.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $raw.EndsWith("`n")
    $suffix = if ($endsWithNewline) { $newline } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "`r?`n"))
    if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

    $line = $key + ' = "' + $value.Replace('\', '\\') + '"'
    $pattern = '^' + [regex]::Escape($key) + '\s*='
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\[[^\[\]]+\]$') { $inSection = $true; continue }
        if ($inSection) { continue }
        if ($trimmed -match $pattern) {
            if ($lines[$i] -ceq $line) { return }
            $lines[$i] = $line
            [System.IO.File]::WriteAllText($configPath, (($lines -join $newline) + $suffix), $utf8)
            Write-Host "$key set"
            return
        }
    }

    # Absent: insert before the first table so it lands top-level.
    $first = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[') { $first = $i; break }
    }
    if ($first -gt 0 -and $lines[$first - 1].Trim() -eq '') { $lines.Insert($first - 1, $line) }
    else { $lines.Insert($first, $line) }
    [System.IO.File]::WriteAllText($configPath, (($lines -join $newline) + $suffix), $utf8)
    Write-Host "$key added"
}

function Set-CloneNumber($configPath, $key, $value) {
    # Rewrite ONE numeric top-level key, leaving every other byte alone (CONTRACT §5).
    # Unquoted integer, strictly placed before the first [table] line.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $raw.EndsWith("`n")
    $suffix = if ($endsWithNewline) { $newline } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "`r?`n"))
    if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

    $line = "$key = $value"
    $pattern = '^' + [regex]::Escape($key) + '\s*='
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\[[^\[\]]+\]$') { $inSection = $true; continue }
        if ($inSection) { continue }
        if ($trimmed -match $pattern) {
            if ($lines[$i] -ceq $line) { return }
            $lines[$i] = $line
            [System.IO.File]::WriteAllText($configPath, (($lines -join $newline) + $suffix), $utf8)
            Write-Host "$key set"
            return
        }
    }

    # Absent: insert before the first table so it lands top-level.
    $first = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[') { $first = $i; break }
    }
    if ($first -gt 0 -and $lines[$first - 1].Trim() -eq '') { $lines.Insert($first - 1, $line) }
    else { $lines.Insert($first, $line) }
    [System.IO.File]::WriteAllText($configPath, (($lines -join $newline) + $suffix), $utf8)
    Write-Host "$key added"
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

function Test-GatewayReachable($baseUrl, $timeoutSec = 5) {
    # A profile whose provider lives on a local gateway opens a window that says
    # "Reconnecting..." forever and answers nothing. That is indistinguishable from a broken
    # model, and on 2026-11-05 it cost an afternoon: the gateway was down and the model got
    # blamed (`ctx/...:1017-cloud` looked dead; it had never been tested).
    #
    # Only loopback is probed. A remote provider is reachable or not for reasons this script
    # cannot fix, and a wrong guess there would block a launch that actually works. That means
    # the VPS endpoint (https://router.antinrml.com/v1, the default since 2026-11-05) is never
    # preflighted here: `bin/codex-doctor` is the tool that answers "is it answering".
    if (-not $baseUrl) { return $true }
    $u = $null
    if (-not [System.Uri]::TryCreate($baseUrl, [System.UriKind]::Absolute, [ref]$u)) { return $true }
    if ($u.Host -notin @('127.0.0.1', 'localhost', '::1', '[::1]')) { return $true }
    try {
        $req = [System.Net.HttpWebRequest]::Create($u.GetLeftPart([System.UriPartial]::Authority) + '/v1/models')
        $req.Timeout = $timeoutSec * 1000
        $req.ReadWriteTimeout = $timeoutSec * 1000
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        # Any HTTP response means something IS listening; only a transport failure is "down".
        if ($r -and [int]$r.StatusCode -gt 0) { return $true }
        # A raw TCP listener that never speaks HTTP also throws here. Distinguish it from a
        # closed port: a closed port fails at connect, a dumb listener fails at read.
        $sock = New-Object System.Net.Sockets.TcpClient
        try {
            $conn = $sock.BeginConnect($u.Host, $u.Port, $null, $null)
            if (-not $conn.AsyncWaitHandle.WaitOne($timeoutSec * 1000)) { return $false }
            $sock.EndConnect($conn)
            return $true
        } catch {
            return $false
        } finally {
            $sock.Close()
        }
    } catch {
        return $false
    }
}

function Get-ProfileBaseUrl($profilePath) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($profilePath, $utf8)
    $provider = [regex]::Match($raw, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
    if (-not $provider.Success) { return $null }
    $table = [regex]::Escape($provider.Groups[1].Value)
    $base = [regex]::Match($raw, '(?m)^\s*base_url\s*=\s*"([^"]+)"')
    if ($base.Success) { return $base.Groups[1].Value }
    return $null
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
    #
    # With -Profile, the profile is the source of truth: it names its own provider table and
    # model, so we do not overwrite those. Only the sandbox and plugin keys are still
    # re-asserted, because those are the two the app rewrites on every launch regardless.
    if ($Profile) {
        $profilePath = Join-Path $cloneHome ($Profile + '.config.toml')
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "no such BYOK profile: $profilePath. Create one with: bin/codex-byok profile add $Profile ..."
        }
        if ($Profile -notmatch '^[A-Za-z0-9._-]+$') {
            throw "profile name may only contain letters, digits, dot, underscore and dash"
        }
        # The profile is layered by the app, not copied: keep it where it is and let Codex
        # merge it. A model override still has to go into the BASE config, because that is
        # the file the app reads first.
        if ($Model) {
            $provider = ''
            $m = Select-String -LiteralPath $profilePath -Pattern '^\s*model_provider\s*=\s*"([^"]+)"'
            if ($m) { $provider = $m.Matches[0].Groups[1].Value }
            if (-not $provider) {
                throw "profile $Profile has no model_provider; it cannot be layered"
            }
            Set-CloneModel $targetConfig $Model $provider
        }
        Write-Host "using BYOK profile: $Profile$(if ($Model) { ' (model override: ' + $Model + ')' })"
    } else {
        # Pinned by explicit owner decision 2026-11-06: Ollama Cloud DeepSeek V4.1 Flash (1017)
        # through the VPS/SSoT gateway. `-Model ...` still overrides this for one launch.
        #
        # Measured cost of this choice, so nobody has to rediscover it: this slug is a bare
        # upstream (owned_by "ctx"), NOT a combo, and every ctx/* upstream reports zero prompt
        # cache. Session logs for it: 136 turns, 24,293,175 input tokens, 0 cached. The
        # cache-first combo measured 84-92% cache on the same 11-step task. Cached input bills
        # at roughly a tenth of fresh input, so the same work costs several times more here.
        # This is a deliberate policy override, not an oversight.
        Set-CloneModel $targetConfig $(if ($Model) { $Model } else { 'ctx/ollama/deepseek-v4.1-flash:1017-cloud' }) 'nine_router'
    }

    # Preflight: never open a window that cannot answer. The gateway is a separate process on
    # this machine and it can be down (measured 2026-11-05: ~/.9router quarantined, port 20128
    # closed, every model "broken"). Refusing here turns a silent hang into one sentence and a
    # command that starts the thing.
    $probeSource = if ($Profile) { Join-Path $cloneHome ($Profile + '.config.toml') } else { $targetConfig }
    $probeBase = Get-ProfileBaseUrl $probeSource
    if (-not (Test-GatewayReachable $probeBase)) {
        $port = 20128
        if ($probeBase -match ':(\d+)') { $port = [int]$Matches[1] }
        Write-Host ''
        Write-Host "gateway not answering: $probeBase" -ForegroundColor Red
        Write-Host "  nothing that needs nine_router would answer; the model is not the problem."
        Write-Host "  start it:  9router start          (or: systemctl --user start 9router)"
        Write-Host "  use the real account instead:  codex-launch.ps1 -Mode real"
        Write-Host "  or pick a provider that does not use the gateway: -Profile <name>"
        throw "gateway unreachable on port $port"
    }

    # Catalog: the clone must read its own copy, not the real home's. Refresh it when the real
    # home's copy is newer — otherwise a regenerated catalog (truncation limit, verbosity,
    # hidden models) never reaches the clone and every fix here only lands on the real side.
    $targetCatalog = Join-Path $cloneHome 'nine-router-models.json'
    $sourceCatalog = Join-Path $realHome 'nine-router-models.json'
    if (-not (Test-Path -LiteralPath $targetCatalog)) {
        Copy-Item -LiteralPath $sourceCatalog -Destination $targetCatalog
        Write-Host 'seeded nine-router-models.json'
    } elseif ((Test-Path -LiteralPath $sourceCatalog) -and
        ((Get-Item -LiteralPath $sourceCatalog).LastWriteTimeUtc -gt (Get-Item -LiteralPath $targetCatalog).LastWriteTimeUtc)) {
        Copy-Item -LiteralPath $sourceCatalog -Destination $targetCatalog -Force
        Write-Host 'refreshed nine-router-models.json from the real home'
    }

    # Real copies (NOT links). Plugins are needed because the app loads them from the home.
    foreach ($dir in @('plugins', 'skills')) {
        $dst = Join-Path $cloneHome $dir
        if (-not (Test-Path -LiteralPath $dst)) {
            Copy-Tree (Join-Path $realHome $dir) $dst
            Write-Host "copied $dir"
        }
    }

    # `model_instructions_file` REPLACES the whole Codex prompt, it does not add to it. Measured
    # 2026-11-05: a clone carrying it reported base_instructions 388 chars against 21638
    # without it, because the file is four lines of output rules and nothing else. That is what
    # made the agent stop after a short answer. Never set it here; put additions in AGENTS.md,
    # which is appended instead of substituted. Remove it if an older config still has it.
    Set-CloneTopLevelRemove $targetConfig 'model_instructions_file'

    # Pin the context budget so Codex does not compact too late (PROGRESS §16).
    # The catalog advertises 1M context with 95% effective_context_window_percent, so Codex only
    # compacts near 950,000 tokens. Upstream rejected at 1,177,971 tokens ("prompt is too long...
    # model maximum context length: 1048576"). 200k is safely inside every upstream's real limit
    # and 150k leaves room for one large tool result. Verified: `-c model_context_window=200000`
    # makes Codex log `ctx window: 190000` (it applies the same 95% factor).
    Set-CloneNumber $targetConfig 'model_context_window' 200000
    Set-CloneNumber $targetConfig 'model_auto_compact_token_limit' 150000

    # The clone's global AGENTS.md was 0 bytes, so the model ran with no project rules at all:
    # no UNC workaround, no batching rule, nothing about the 3-agent limit or the 60 s wait
    # ceiling that ended turns mid-task. AGENTS.md is APPENDED to the Codex prompt, which is
    # the correct surface for these rules (see the model_instructions_file removal above).
    # Seed it from the repo, refill it if empty, and never overwrite an edited file.
    $agentsMd = Join-Path $cloneHome 'AGENTS.md'
    $agentsSeed = Join-Path $PSScriptRoot 'clone-AGENTS.md'
    if ((Test-Path -LiteralPath $agentsSeed) -and
        (-not (Test-Path -LiteralPath $agentsMd) -or (Get-Item -LiteralPath $agentsMd).Length -eq 0)) {
        Copy-Item -LiteralPath $agentsSeed -Destination $agentsMd -Force
        Write-Host 'seeded AGENTS.md'
    } elseif ((Test-Path -LiteralPath $agentsSeed) -and (Test-Path -LiteralPath $agentsMd)) {
        # A shorter-than-seed AGENTS.md is the stale 0-byte-era file that predates the rules.
        if ((Get-Item -LiteralPath $agentsMd).Length -lt (Get-Item -LiteralPath $agentsSeed).Length) {
            Write-Host 'note: clone AGENTS.md is shorter than scripts/clone-AGENTS.md; leaving your version alone'
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

    # linear@openai-api-curated leaks its whole MCP tool surface into the `exec` tool
    # description: 60+ tools, 74,150 characters, ~18,537 tokens — re-sent on EVERY turn.
    # Measured 2026-11-06 by capturing the exact request body: with linear enabled the
    # `exec` tool was 93,960 bytes and a trivial `say OK` turn cost 38,779 input tokens;
    # with it disabled `exec` was 17,646 bytes and the same turn cost 18,150. That is a
    # 53% cut on every single turn of every session, for a plugin this clone never uses.
    # The real ChatGPT home keeps it on; only the clone is touched.
    Set-ClonePluginDisabled $targetConfig 'linear@openai-api-curated'

    # The GUI/desktop plugins advertise their tool surface the same way. Measured on top of
    # the Linear cut: `mcp__cua_repl` alone was 6,601 bytes / ~1,650 tokens per turn, and
    # `exec` inlined an `mcp__node_repl` section besides. Disabling all four took a `say`
    # turn from 18,125 to 15,218 tokens.
    # What is lost: in-app browser, Chrome control, computer use (screenshot clicks), and
    # the codex-app-tools thread API. None of them worked here anyway — browser needs an app
    # host (PROGRESS 13) and computer use needs a per-app allowlist decided in the ChatGPT
    # UI. The shell is the supported path in this home, and clone-AGENTS.md says so.
    # NOT disabled: browser@openai-bundled. It powers the in-app browser panel on the right,
    # and turning it off visibly broke that panel -- a real loss, reported by the owner.
    # Its tool surface costs less than the GUI plugins and it is a feature people use.
    foreach ($plugin in @('unified-computer-use@openai-bundled',
                          'computer-use@openai-bundled',
                          'codex-app-tools@openai-bundled')) {
        Set-ClonePluginDisabled $targetConfig $plugin
    }

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
