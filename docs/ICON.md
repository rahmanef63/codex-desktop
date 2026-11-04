# Shortcut icons that survive a Store update

The desktop shortcuts lost their icon after Codex Desktop updated itself. This
file records why, what actually renders, and what the resolver does about it.

Resolver: `scripts/resolve-codex-icon.ps1`. Check:
`tests/resolve-codex-icon.test.ps1`.

## The bug

An MSIX installs into a directory named after its version:

```
C:\Program Files\WindowsApps\OpenAI.Codex_26.1029.7803.0_x64__2p2nqsd0c76g0
```

The shortcuts were written when `26.1027.3384.0` was installed, so every
`IconLocation` was:

```
...\OpenAI.Codex_26.1027.3384.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe,0
```

The Store replaced 3384 with 7803 and deleted the old directory. All four
shortcuts on this machine now point at a path that does not exist. Measured:

```
Codex.lnk              iconOk=False
Codex Clone.lnk        iconOk=False
Codex Real (repo).lnk  iconOk=False
Codex Clone (repo).lnk iconOk=False
```

A version inside the path is not a stale value to refresh. It is a guarantee
that the shortcut breaks on every update, forever, because the next version
string cannot be known in advance.

## What renders

Rendered through `SHGetFileInfo` on a `.lnk` built in `%TEMP%`, comparing 32x32
pixel hashes. `no-iconlocation` is the control: Notepad with no icon override.

| source | renders? | hash | why |
| --- | --- | --- | --- |
| `ChatGPT.exe` inside current MSIX | yes | `472953623` | `ExtractAssociatedIcon` path works, but the art is the exe's own |
| `chatgpt-app-light.ico` inside current MSIX | yes | `-46746588` | the real artwork, 15 frames up to 256px |
| same `.ico` copied to `%LOCALAPPDATA%\codex-desktop\icon.ico` | yes | `-46746588` | byte-identical to the line above |
| version-pinned path to the removed `26.1027.3384.0` | **no** | `919434519` | Explorer silently substitutes a generic icon |
| a path that never existed | **no** | `919434519` | same generic icon, same hash |

Two things this settles:

1. A broken `IconLocation` does not fall back to the target's icon. The old
   shortcuts did not quietly show the PowerShell icon, they showed the blank
   generic file icon. That is why the failure is visible but unexplained.
2. The `%LOCALAPPDATA%` copy renders pixel-identically to the file inside the
   package. Moving the icon out of WindowsApps costs nothing visually.

Frame inventory of the shipped `.ico` (30,208 bytes):

```
16 20 24 30 32 36 40 44 48 60 64 72 80 96 256   (all 32bpp)
```

## What each fallback costs

`ExtractAssociatedIcon` is the alternative that needs no `.ico` on disk. It is
strictly worse here:

| | shipped `.ico` copy | `ExtractAssociatedIcon` from exe |
| --- | --- | --- |
| frames | 15 | 1 |
| largest | 256x256 | 32x32 |
| size on disk | 30,208 bytes | 766 bytes |
| renders at 100% DPI | sharp | sharp |
| renders at 150-200% DPI | sharp | visibly soft |
| survives package update | yes, if cached | yes, if cached |

Extraction is a fine fallback and the resolver keeps it as step 3, but a
32x32 image upscaled to a 48px shortcut tile is a soft icon. Copy the file.

Measured: `extracted size=32x32 file bytes=766` versus
`frames=15 bytes=30208`.

## Rejected: AppUserModelID and `shell:AppsFolder`

The tempting answer is to stop pointing at files and point at the app identity:

```
OpenAI.Codex_2p2nqsd0c76g0!App
```

It does not work for a shortcut icon, for two measured reasons.

A `.lnk` cannot store a `shell:AppsFolder\...` target at all. Assigning it and
reading it back returns empty:

```
TargetPath=''   IconLocation=',0'   target exists as file: False
```

`System.AppUserModel.ID` does persist on a `.lnk` (write returned `hr=0`) but it
exists for taskbar grouping and jump lists. It is not an icon source. A
shortcut with a valid AUMID and no `IconLocation` still shows the generic icon.

The one route that does work, a pinned Start tile for the package, inherits the
icon from the package manifest and needs no path. It was rejected because it
produces a Start menu tile, not a desktop `.lnk`, and the existing shortcuts
must keep launching a specific PowerShell profile (`-Mode real` or
`-Mode clone`, `scripts/codex-launch.ps1`). A package tile launches the app
directly and loses that.

## If WindowsApps ACLs change

Today this account can read inside the package, but only because of a group
grant, not because of the user:

```
Get-Acl 'C:\Program Files\WindowsApps'
  -> UnauthorizedAccessException (cannot even read the root ACL)

Get-Acl $installLocation
  owner = NT AUTHORITY\SYSTEM
  BUILTIN\Users                                  ReadAndExecute, Synchronize
  ALL APPLICATION PACKAGES                        ReadAndExecute, Synchronize
  ALL RESTRICTED APPLICATION PACKAGES             ReadAndExecute, Synchronize
  NT SERVICE\TrustedInstaller                    FullControl
```

The root is denied. Each versioned package directory separately grants
`BUILTIN\Users` read and execute. That single line is the entire reason a
literal path renders today, and it is not a documented guarantee. Remove or
narrow it in a future build, a policy, or on a locked-down machine, and every
version-pinned shortcut goes blank again with the same generic icon.

The resolver is ordered so that a lockout is never observed in the normal case:

1. **cache hit** returns before the package is touched at all. Verified by
   stubbing `Get-AppxPackage` to throw: still exit 0 with the cached path.
2. **seed from the shipped `.ico`** when readable.
3. **extract from the exe** when the `.ico` is missing but the exe is readable.
4. **version-pinned path**, exit 2, with a warning on stderr.
5. **nothing**, exit 1, empty stdout.

Case 5 is the only hard failure, and it is recoverable by installing the app or
by supplying `-CachePath` to any existing `.ico`.

The cache is the load-bearing part. Once step 2 has run one time, no later
lockout matters, and no update can invalidate the answer. That is also why the
resolver checks the cache before it calls `Get-AppxPackage`: the denied case and
the readable case produce the identical answer, so the ACL stops being on the
critical path after the first run.

## Contract

```
$icon = & scripts/resolve-codex-icon.ps1
$shortcut.IconLocation = "$icon,0"
```

The script prints one absolute path on stdout, nothing else. Diagnostics go to
stderr.

| exit | meaning | caller should |
| --- | --- | --- |
| 0 | stable copy, survives updates | use the path |
| 2 | only a version-pinned path worked | use it, but warn: breaks on next update |
| 1 | nothing usable, stdout empty | fail; do not write an `IconLocation` |

It never prints a path it has not validated as a real `.ico` header. A truncated
or wrong-format file is rejected even though it exists, because "exists but
paints nothing" is the exact failure being fixed.

Options: `-Refresh` re-copies from the current package (use after an update
changes the artwork; not needed for the shortcut to keep working).
`-CachePath` overrides the location, default
`%LOCALAPPDATA%\codex-desktop\icon.ico`.

The installer must call this rather than building an icon path itself, so there
is one place that decides. If the installer hardcodes a version string, this
whole file stops being true.

## Proof it survives an update

`Get-AppxPackage` was stubbed to report three different versions, two of which
do not exist on disk. The cache was seeded once, from the real install.

```
installed 26.1029.7803.0 -> %LOCALAPPDATA%\codex-desktop\icon.ico
old       26.1027.3384.0 -> %LOCALAPPDATA%\codex-desktop\icon.ico
future    99.9999.9999.0 -> %LOCALAPPDATA%\codex-desktop\icon.ico
all identical          : True
all exit 0             : True
```

The mocked `InstallLocation` for the old and future versions both reported
`exists on disk = False`, which is exactly the state after an update removes the
previous version. The control is blunt:

```
old-msix literal exists    = False
future literal exists      = False
```

A literal path is wrong in 2 of 3 versions. The cache is right in 3 of 3.

The path itself contains no version, no package name, and no `WindowsApps`:

```
matchesVersion=False  matchesPkg=False  matchesWinApps=False
```

That is the mechanism. Nothing in the answer can be invalidated by a package
changing, which is why it survives.

## Reproducing

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tests\resolve-codex-icon.test.ps1
```

15 checks, exit 0 when all pass. From WSL the repo is a UNC path and PowerShell
will not run `.ps1` files over UNC, so the test copies the resolver to `%TEMP%`
first.
