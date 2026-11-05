$ErrorActionPreference = 'Stop'
$launcher = '\\wsl.localhost\Ubuntu\home\rahman\projects\manef\codex-desktop\scripts\codex-launch.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tok, [ref]$err)
if ($err.Count) { throw "launcher does not parse: $($err[0].Message)" }

$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-CloneNumber' }, $true)[0]
if (-not $fn) { throw "Set-CloneNumber is missing from the launcher" }
Invoke-Expression $fn.Extent.Text

$passCount = 0

# Test 1 & 4 & 5: Absent key inserted before first [table], CRLF preserved, unquoted integer written
$tmp1 = Join-Path $env:TEMP ('clone-num-fixture1-' + [guid]::NewGuid().ToString('N') + '.toml')
$crlfContent = "model = `"deepseek`"`r`nmodel_provider = `"nine_router`"`r`n`r`n[memories]`r`nenabled = true`r`n"
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($tmp1, $crlfContent, $utf8)

try {
    Set-CloneNumber $tmp1 'model_context_window' 200000 | Out-Null
    $after1 = [System.IO.File]::ReadAllText($tmp1, $utf8)

    # (1) Assert inserted BEFORE first [table]
    $firstTableIdx = $after1.IndexOf('[memories]')
    $keyIdx = $after1.IndexOf('model_context_window = 200000')
    if ($keyIdx -lt 0) { throw 'key not found in file' }
    if ($firstTableIdx -lt 0) { throw '[memories] table missing' }
    if ($keyIdx -ge $firstTableIdx) { throw 'key was not placed before the first table' }

    # (4) Assert CRLF file stays CRLF
    if (-not $after1.Contains("`r`n")) { throw 'CRLF was not preserved' }
    if ($after1.Replace("`r`n", '') -match "`n") { throw 'contains stray bare LF in CRLF file' }

    # (5) Assert unquoted integer
    if ($after1 -notmatch '(?m)^model_context_window = 200000\r?$') { throw 'value is not an unquoted integer line' }

    $passCount++ # Test 1, 4, 5 passed
} finally {
    Remove-Item $tmp1 -Force -ErrorAction SilentlyContinue
}

# Test 2: Existing key rewritten in place, no other byte changes
$tmp2 = Join-Path $env:TEMP ('clone-num-fixture2-' + [guid]::NewGuid().ToString('N') + '.toml')
$fixture2 = "model = `"deepseek`"`nmodel_context_window = 100000`n`n[memories]`nenabled = true`n"
[System.IO.File]::WriteAllText($tmp2, $fixture2, $utf8)

try {
    Set-CloneNumber $tmp2 'model_context_window' 200000 | Out-Null
    $after2 = [System.IO.File]::ReadAllText($tmp2, $utf8)
    $expected2 = "model = `"deepseek`"`nmodel_context_window = 200000`n`n[memories]`nenabled = true`n"
    if ($after2 -cne $expected2) {
        throw "rewrite in place failed. Got:`n$after2`nExpected:`n$expected2"
    }
    $passCount++ # Test 2 passed
} finally {
    Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue
}

# Test 3: Already-correct value is a true no-op (compare file bytes before/after)
$tmp3 = Join-Path $env:TEMP ('clone-num-fixture3-' + [guid]::NewGuid().ToString('N') + '.toml')
$fixture3 = "model = `"deepseek`"`nmodel_context_window = 200000`n`n[memories]`nenabled = true`n"
[System.IO.File]::WriteAllText($tmp3, $fixture3, $utf8)

try {
    $bytesBefore = [System.IO.File]::ReadAllBytes($tmp3)
    Set-CloneNumber $tmp3 'model_context_window' 200000 | Out-Null
    $bytesAfter = [System.IO.File]::ReadAllBytes($tmp3)

    if ($bytesBefore.Length -ne $bytesAfter.Length) {
        throw "no-op failed: length changed from $($bytesBefore.Length) to $($bytesAfter.Length)"
    }
    for ($i = 0; $i -lt $bytesBefore.Length; $i++) {
        if ($bytesBefore[$i] -ne $bytesAfter[$i]) {
            throw "no-op failed: byte mismatch at offset $i"
        }
    }
    $passCount++ # Test 3 passed
} finally {
    Remove-Item $tmp3 -Force -ErrorAction SilentlyContinue
}

# Second key test: model_auto_compact_token_limit insertion
$tmp4 = Join-Path $env:TEMP ('clone-num-fixture4-' + [guid]::NewGuid().ToString('N') + '.toml')
$fixture4 = "model = `"deepseek`"`n`n[section]`nk = `"v`"`n"
[System.IO.File]::WriteAllText($tmp4, $fixture4, $utf8)

try {
    Set-CloneNumber $tmp4 'model_auto_compact_token_limit' 150000 | Out-Null
    $after4 = [System.IO.File]::ReadAllText($tmp4, $utf8)
    if ($after4 -notmatch '(?m)^model_auto_compact_token_limit = 150000$') {
        throw "model_auto_compact_token_limit not written properly"
    }
    $passCount++
} finally {
    Remove-Item $tmp4 -Force -ErrorAction SilentlyContinue
}

Write-Host "context keys: $passCount assertions passed"
