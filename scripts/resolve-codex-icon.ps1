<#
.SYNOPSIS
Prints the one icon path a Codex Desktop shortcut should use.

.DESCRIPTION
The installed MSIX lives in a directory whose name embeds the version, so any
literal path to a file inside it turns into a broken icon on the next Store
update. This resolver copies the shipped icon once into %LOCALAPPDATA% and
prints that copy instead, so the answer does not change when the package does.

Prints exactly one absolute path to an existing, structurally valid .ico file.
Writes diagnostics to stderr. Exits 1 and prints nothing to stdout when no
usable icon can be produced, so callers never receive a path they cannot use.

Exit codes:
  0  stable copy in %LOCALAPPDATA%; survives package updates
  2  degraded: only a version-pinned path inside the package worked; the icon
     is correct now and will break on the next Store update
  1  nothing usable; stdout is empty

The path is bare. Shortcut callers need the IconLocation form:

    $icon = & scripts/resolve-codex-icon.ps1
    if ($LASTEXITCODE -eq 0) { $shortcut.IconLocation = "${icon},0" }
    elseif ($LASTEXITCODE -eq 2) { $shortcut.IconLocation = "${icon},0"; <warn> }

.PARAMETER Refresh
Re-copy from the currently installed package even when the cached copy is
already valid. Use after a package update changes the artwork; not required
for the shortcut to keep working.

.PARAMETER CachePath
Override the cache location. Default: %LOCALAPPDATA%\codex-desktop\icon.ico

.EXAMPLE
& scripts/resolve-codex-icon.ps1
C:\Users\me\AppData\Local\codex-desktop\icon.ico
#>
[CmdletBinding()]
param(
    [switch]$Refresh,
    [string]$CachePath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $CachePath) {
    $CachePath = Join-Path $env:LOCALAPPDATA 'codex-desktop\icon.ico'
}

function Write-Note([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

# An .ico is trusted only after its header is checked. A truncated or
# wrong-format file that merely exists would still paint nothing in Explorer,
# which is the failure this whole script exists to prevent.
function Test-IcoFile([string]$Path) {
    if (-not $Path) { return $false }
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    try {
        $b = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        return $false
    }
    if ($b.Length -lt 22) { return $false }
    if ([BitConverter]::ToUInt16($b, 0) -ne 0) { return $false }  # reserved
    if ([BitConverter]::ToUInt16($b, 2) -ne 1) { return $false }  # 1 = icon, 2 = cursor
    $frames = [BitConverter]::ToUInt16($b, 4)
    if ($frames -lt 1) { return $false }
    if ($b.Length -lt (6 + 16 * $frames)) { return $false }
    return $true
}

function Get-IcoFrames([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    $count = [BitConverter]::ToUInt16($b, 4)
    $list = @()
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + ($i * 16)
        $w = $b[$o]; if ($w -eq 0) { $w = 256 }
        $h = $b[$o + 1]; if ($h -eq 0) { $h = 256 }
        $list += [pscustomobject]@{ Width = $w; Height = $h }
    }
    return $list
}

# Highest version wins. Several versions can be staged at once during a Store
# update, and the newest is the one whose artwork will outlive the others.
#
# Returns an object with Package and Error so callers can tell "not installed"
# apart from "installed but this account may not look inside it". Both end in
# the same failure, but only one of them is solved by reinstalling.
function Get-CodexPackage {
    try {
        $pkgs = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
        if ($pkgs.Count -eq 0) { return [pscustomobject]@{ Package = $null; Error = 'not installed' } }
        $best = $pkgs | Sort-Object -Property { [version]$_.Version } -Descending | Select-Object -First 1
        return [pscustomobject]@{ Package = $best; Error = '' }
    } catch {
        return [pscustomobject]@{ Package = $null; Error = $_.Exception.Message }
    }
}

function Save-StableCopy([string]$Source, [string]$Destination) {
    $dir = Split-Path -Parent $Destination
    if (-not [System.IO.Directory]::Exists($dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    # Copy through a temp file so a half-written cache is never left behind for
    # the next run to trust.
    $tmp = "$Destination.tmp"
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

function Save-ExtractedIcon([string]$ExePath, [string]$Destination) {
    Add-Type -AssemblyName System.Drawing
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
    if ($null -eq $icon) { return $false }
    $dir = Split-Path -Parent $Destination
    if (-not [System.IO.Directory]::Exists($dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $tmp = "$Destination.tmp"
    $stream = [System.IO.File]::Create($tmp)
    try {
        $icon.Save($stream)
    } finally {
        $stream.Close()
        $icon.Dispose()
    }
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
    return $true
}

# 1. Preferred: the cached copy. It has no relationship to the package
#    directory, so a Store update cannot invalidate it.
if (-not $Refresh -and (Test-IcoFile $CachePath)) {
    Write-Output $CachePath
    exit 0
}

$probe = Get-CodexPackage
if ($null -eq $probe.Package) {
    if ($probe.Error -eq 'not installed') {
        Write-Note "resolve-codex-icon: no OpenAI.Codex package is installed for this user."
        Write-Note "  Get-AppxPackage -Name OpenAI.Codex returned nothing."
    } else {
        Write-Note "resolve-codex-icon: could not enumerate the package: $($probe.Error)"
    }
    Write-Note "  install it from the Store, or pass -CachePath pointing at an existing .ico."
    exit 1
}
$pkg = $probe.Package

$installRoot = $pkg.InstallLocation
Write-Note "resolve-codex-icon: package $($pkg.Version) at $installRoot"

# 2. Seed the cache from the icon the package ships. Copying the file keeps all
#    15 frames up to 256x256, which is what Explorer needs at high DPI.
$shippedIco = Join-Path $installRoot 'app\resources\chatgpt-app-light.ico'
if (Test-IcoFile $shippedIco) {
    try {
        Save-StableCopy $shippedIco $CachePath
        if (Test-IcoFile $CachePath) {
            $frames = Get-IcoFrames $CachePath
            Write-Note "resolve-codex-icon: cached from shipped .ico ($($frames.Count) frames, largest $((($frames | Sort-Object Width -Descending)[0]).Width)px)"
            Write-Output $CachePath
            exit 0
        }
        Write-Note "resolve-codex-icon: copy landed but failed validation: $CachePath"
    } catch {
        Write-Note "resolve-codex-icon: could not write cache: $($_.Exception.Message)"
    }
} else {
    Write-Note "resolve-codex-icon: shipped .ico missing or invalid at $shippedIco"
}

# 3. Extract from the exe. Works whenever the package is readable, but yields a
#    single 32x32 frame: acceptable on a shortcut, visibly soft at 150%+ DPI.
$exe = Join-Path $installRoot 'app\ChatGPT.exe'
if ([System.IO.File]::Exists($exe)) {
    try {
        if ((Save-ExtractedIcon $exe $CachePath) -and (Test-IcoFile $CachePath)) {
            Write-Note "resolve-codex-icon: cached from exe extraction (single 32x32 frame, DPI-soft)"
            Write-Output $CachePath
            exit 0
        }
        Write-Note "resolve-codex-icon: exe extraction produced no usable icon"
    } catch {
        Write-Note "resolve-codex-icon: exe extraction failed: $($_.Exception.Message)"
    }
} else {
    Write-Note "resolve-codex-icon: exe not found at $exe"
}

# 4. Last resort: point straight into the package. Correct today, wrong after
#    the next update. Reached only when LOCALAPPDATA is not writable.
if (Test-IcoFile $shippedIco) {
    Write-Note "resolve-codex-icon: WARNING using a version-pinned path; this breaks on the next Store update."
    Write-Output $shippedIco
    exit 2
}

Write-Note "resolve-codex-icon: no usable icon. WindowsApps may be unreadable for this user:"
Write-Note "  try  Get-AppxPackage -Name OpenAI.Codex | Select InstallLocation"
Write-Note "  then run this script from an account that can read that directory."
exit 1
