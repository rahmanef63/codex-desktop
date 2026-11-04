# Desktop shortcuts for the app in this repository.
#
#   powershell -ExecutionPolicy Bypass -File scripts/install-shortcuts.ps1
#   ... -RepoRoot \\wsl.localhost\Ubuntu\home\rahman\projects\manef\codex-desktop
#   ... -DryRun            report only, write nothing
#   ... -NoPrune           leave duplicate shortcuts alone
#
# Why this exists: the four shortcuts found on 2026-11-04 each pinned
#   C:\Program Files\WindowsApps\OpenAI.Codex_26.1027.3384.0_x64__2p2nqsd0c76g0\...
# as their icon. The Store replaced that package with 26.1029.7803.0 and the pinned folder
# went away, so every icon fell back to the generic Windows one. A literal version in a
# shortcut is wrong by design: MSIX install folders are version-stamped and are replaced on
# every update. The icon is therefore resolved from the *installed package* at creation time.
#
# The same shortcuts used to run a copy of the launcher sitting on the Desktop, which drifted
# from the repository. They now run this repository's scripts/codex-launch.ps1 over the
# \\wsl.localhost share, so the desktop can never disagree with the checkout again.

param(
    # Checkout whose scripts\codex-launch.ps1 the shortcuts should run. Defaults to the
    # checkout this script lives in, which is what you want when run from the repo.
    [string]$RepoRoot = '',
    # Report what would change without touching the Desktop.
    [switch]$DryRun,
    # Keep duplicate shortcuts that this script would otherwise consolidate.
    [switch]$NoPrune
)

$ErrorActionPreference = 'Stop'

# One shortcut per mode. Four was two modes times two copies (Desktop launcher vs repo
# launcher), and the duplication is what made "many Codex" on the desktop. Mode is the only
# real axis, so one shortcut per mode — and clone (BYOK) comes first because it is this
# machine's default. `codex-launch.ps1` defaults to -Mode clone too; both agree on purpose.
$Shortcuts = @(
    @{ Name = 'Codex Clone'; Mode = 'clone'; Icon = 'ico'; Description = 'Codex Desktop - clone mode, 9router gateway, isolated home' }
    @{ Name = 'Codex';       Mode = 'real';  Icon = 'exe'; Description = 'Codex Desktop - real mode, own ChatGPT account' }
)

if (-not $RepoRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $scriptDir
}

# The desktop must point at the durable checkout, never at a throwaway worktree. This repo is
# routinely checked out as .../manef/cd-dN for parallel work and those disappear; a shortcut that
# pointed there would break on cleanup. git already knows the main worktree, so ask it.
#
# Only applies to a checkout reached over \\wsl.localhost. Anywhere else -RepoRoot is the truth,
# because there is no git to ask over the same plumbing.
$useGit = $PSBoundParameters.ContainsKey('RepoRoot') -eq $false -and $scriptDir -like '\\wsl*'
if ($useGit) {
    $repoPosix = (& wsl.exe -e wslpath -u $scriptDir 2>$null)
    if ($repoPosix) {
        $main = & wsl.exe -e git -C $repoPosix.Trim() worktree list --porcelain 2>$null |
            Select-String -Pattern '^worktree ' | Select-Object -First 1
        if ($main) {
            $mainWin = & wsl.exe -e wslpath -w (($main.Line -replace '^worktree ', '').Trim()) 2>$null
            if ($mainWin) { $RepoRoot = $mainWin.Trim() }
        }
    }
}

function ConvertTo-UncPath($path) {
    # A Windows-style path passed in by hand still has to reach the launcher over the share,
    # because powershell.exe on Windows cannot read a POSIX path at all.
    if ($path -match '^[A-Za-z]:[\\/]' -or $path -match '^\\\\') { return $path }
    throw "RepoRoot must be a Windows or UNC path, got: $path"
}

$RepoRoot = (ConvertTo-UncPath $RepoRoot).TrimEnd('\')
$Launcher = Join-Path $RepoRoot 'scripts\codex-launch.ps1'

if (-not (Test-Path -LiteralPath $Launcher)) {
    Write-Error "launcher not found: $Launcher"
    exit 1
}
Write-Host "launcher: $Launcher"

# ---------------------------------------------------------------- icon, resolved not pinned
#
# Get-AppxPackage is the supported way to ask Windows where a packaged app actually lives.
# It is answered by the package database, not by a path we guessed, so it keeps working after
# every Store update: the query returns a new InstallLocation and the icon follows it.
# Nothing here contains a version number.
function Resolve-CodexIcon([ValidateSet('exe', 'ico')][string]$Prefer) {
    $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg -or -not $pkg.InstallLocation) {
        throw "OpenAI.Codex is not registered for this user (Get-AppxPackage found no InstallLocation). Refusing to write a shortcut whose icon would be a guess."
    }
    $root = $pkg.InstallLocation
    $byKind = @{
        # The mode shortcuts historically used different art; keep that, since it is the only
        # thing that tells the two apart on a desktop full of icons.
        ico = @(
            'app\resources\chatgpt-app-light.ico',
            'app\resources\icon-chatgpt.ico',
            'app\ChatGPT.exe'
        )
        exe = @(
            'app\ChatGPT.exe',
            'app\resources\chatgpt-app-light.ico'
        )
    }
    foreach ($rel in $byKind[$Prefer]) {
        $candidate = Join-Path $root $rel
        if (Test-Path -LiteralPath $candidate) {
            return [pscustomobject]@{
                Path    = $candidate
                Version = $pkg.Version
                Source  = 'Get-AppxPackage OpenAI.Codex -> InstallLocation'
            }
        }
    }
    throw "package OpenAI.Codex $($pkg.Version) is installed at $root but none of these exist: $($byKind[$Prefer] -join ', '). Refusing to write an icon path that does not exist."
}

$icons = @{}
foreach ($kind in @('exe', 'ico')) {
    $icons[$kind] = Resolve-CodexIcon -Prefer $kind
    Write-Host ("icon({0}): {1}  (package {2})" -f $kind, $icons[$kind].Path, $icons[$kind].Version)
}

# ---------------------------------------------------------------- write the shortcuts

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) {
    $desktop = Join-Path $env:USERPROFILE 'Desktop'
}
if (-not (Test-Path -LiteralPath $desktop)) {
    Write-Error "no Desktop directory at $desktop"
    exit 1
}

$shell = New-Object -ComObject WScript.Shell
$wanted = @{}
$written = 0
$skipped = 0

foreach ($spec in $Shortcuts) {
    $lnkPath = Join-Path $desktop ($spec.Name + '.lnk')
    $icon = $icons[$spec.Icon]

    # The launcher is quoted because the share path contains no spaces today but the user's
    # projects folder is theirs to rename. -NoProfile keeps a user profile from injecting
    # aliases into a launcher that then starts an app.
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Launcher + '" -Mode ' + $spec.Mode

    $state = 'created'
    if (Test-Path -LiteralPath $lnkPath) {
        $existing = $shell.CreateShortcut($lnkPath)
        $same = ($existing.TargetPath -eq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) -and
                ($existing.Arguments -eq $arguments) -and
                ($existing.IconLocation -eq ($icon.Path + ',0')) -and
                ($existing.Description -eq $spec.Description)
        if ($same) {
            $state = 'unchanged'
            $skipped++
        } else {
            $state = 'updated'
        }
    }

    $wanted[$lnkPath] = $true

    if ($DryRun) {
        Write-Host ("would write: {0}.lnk [{1}] -Mode {2}" -f $spec.Name, $state, $spec.Mode)
        continue
    }
    if ($state -eq 'unchanged') {
        Write-Host ("unchanged:   {0}.lnk -Mode {1}" -f $spec.Name, $spec.Mode)
        continue
    }

    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = $arguments
    $sc.WorkingDirectory = $env:USERPROFILE
    $sc.IconLocation = $icon.Path + ',0'
    $sc.Description = $spec.Description
    $sc.WindowStyle = 1
    $sc.Save()
    $written++
    Write-Host ("{0}: {1}.lnk -Mode {2}" -f $state, $spec.Name, $spec.Mode)
}

# ------------------------------------------------------- duplicates that run the same script
#
# Four shortcuts collapsed to two. Anything else on the Desktop that still launches a
# codex-launch.ps1 is a leftover of the old duplication: it is removed so there is exactly one
# way to start each mode. The match is narrow on purpose - the shortcut must actually run the
# launcher - so unrelated desktop icons are never touched.
if (-not $NoPrune) {
    $dupes = @(Get-ChildItem -LiteralPath $desktop -Filter *.lnk -File -ErrorAction SilentlyContinue | Where-Object {
            if ($wanted.ContainsKey($_.FullName)) { return $false }
            $args = ''
            try { $args = $shell.CreateShortcut($_.FullName).Arguments } catch { return $false }
            $args -match 'codex-launch\.ps1'
        })
    foreach ($d in $dupes) {
        if ($DryRun) {
            Write-Host ("would remove duplicate: {0}" -f $d.Name)
            continue
        }
        try {
            Remove-Item -LiteralPath $d.FullName -Force
            Write-Host ("removed duplicate: {0}" -f $d.Name)
        } catch {
            Write-Host ("could not remove duplicate {0}: {1}" -f $d.Name, $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------- stale Desktop launcher
#
# The old shortcuts ran a private copy at Desktop\codex-launch.ps1. It has drifted from the
# repository, and a drifted launcher is invisible until a behaviour difference bites. It is
# reported, never deleted: whether the file is still wanted is the user's call.
$stale = Join-Path $desktop 'codex-launch.ps1'
if (Test-Path -LiteralPath $stale) {
    $staleInfo = Get-Item -LiteralPath $stale
    $repoInfo = Get-Item -LiteralPath $Launcher
    $same = $false
    try {
        $same = (Get-FileHash -LiteralPath $stale -Algorithm SHA256).Hash -eq
                (Get-FileHash -LiteralPath $Launcher -Algorithm SHA256).Hash
    } catch {
        $same = $false
    }
    Write-Host ''
    Write-Host 'WARNING: a stale copy of the launcher is on the Desktop' -ForegroundColor Yellow
    Write-Host "  $stale"
    Write-Host ("  modified {0}, {1} bytes, {2}" -f $staleInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $staleInfo.Length,
        $(if ($same) { 'identical to the repo copy today' } else { 'DIFFERS from the repo copy' }))
    Write-Host "  the repo copy is $Launcher"
    Write-Host ("  modified {0}, {1} bytes" -f $repoInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $repoInfo.Length)
    Write-Host '  no shortcut created here uses it. See the difference, from this checkout, with:'
    Write-Host ("    diff <(tr -d '\r' < ""`$(wslpath -u '{0}')"") <(tr -d '\r' < scripts/codex-launch.ps1)" -f $stale)
    Write-Host '  Delete or rename it when nothing else points at it.'
}

Write-Host ''
Write-Host ("summary: {0} written, {1} unchanged, desktop {2}" -f $written, $skipped, $desktop)
Write-Host 'verify from WSL with: bin/shortcut-check'
