param(
    [string]$InstallDirectory = "$env:LOCALAPPDATA\Programs\Antigravity",
    [switch]$CheckOnly,
    [switch]$PatchOnly
)

$ErrorActionPreference = 'Stop'
$originalHash = '73CE9A2405B455A93D1F13DB2AE555DA50406110217A349B6DD85C377FBDB9D1'
$patchedHash = 'E958319DE43E1425DBFA00B0503B30809A6B8ED854C2AE1C8849B81904F0DDE1'
$patchOffset = 0x306502f
$patchHex = '4983fb090f85fffeffff41837c2408030f84f3feffff49bb667265652d7469654d391a0f85e0feffff41807a08720f85d5feffff498b4c2410498b542418488954246848898c24b80000004c89e0909090'
$serverPath = Join-Path $InstallDirectory 'resources\bin\language_server.exe'
$appPath = Join-Path $InstallDirectory 'Antigravity.exe'
$backupPath = "$serverPath.original-2.35.1"
$mutex = $null
$locked = $false
$server = $null

function Get-StreamHash($Stream) {
    $Stream.Position = 0
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        $Stream.Position = 0
    }
}

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AntigravityRegionPatch2351')
    try {
        $locked = $mutex.WaitOne(10000)
    }
    catch [System.Threading.AbandonedMutexException] {
        $locked = $true
    }
    if (-not $locked) { throw 'Another patch launcher is busy. Try again shortly.' }
    if (-not (Test-Path -LiteralPath $appPath)) { throw "Antigravity not found at $appPath" }
    $hash = (Get-FileHash -LiteralPath $serverPath -Algorithm SHA256).Hash
    if ($hash -ne $originalHash -and $hash -ne $patchedHash) {
        throw "Unsupported language_server build. This patch supports 2.35.1 only. SHA256: $hash"
    }
    if ($CheckOnly) {
        Write-Host "Supported build. Patched: $($hash -eq $patchedHash)"
    }
    else {
        if ($hash -eq $originalHash) {
            $running = Get-Process -Name Antigravity,language_server -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $appPath -or $_.Path -eq $serverPath }
            if ($running) { throw 'Close Antigravity before applying the patch, then run this launcher again.' }

            # An exclusive handle prevents a second writer or process launch during the patch.
            $server = [System.IO.File]::Open($serverPath, 'Open', 'ReadWrite', 'None')
            if ((Get-StreamHash $server) -ne $originalHash) { throw 'The target changed before patching.' }
            if (Test-Path -LiteralPath $backupPath) {
                if ((Get-FileHash -LiteralPath $backupPath).Hash -ne $originalHash) {
                    throw "Existing backup has an unexpected hash: $backupPath"
                }
            }
            else {
                $backup = [System.IO.File]::Open($backupPath, 'CreateNew', 'Write', 'None')
                try { $server.CopyTo($backup); $backup.Flush($true) }
                finally { $backup.Dispose(); $server.Position = 0 }
                if ((Get-FileHash -LiteralPath $backupPath).Hash -ne $originalHash) {
                    throw 'Backup verification failed.'
                }
            }

            $patch = New-Object byte[] ($patchHex.Length / 2)
            for ($i = 0; $i -lt $patch.Length; $i++) {
                $patch[$i] = [Convert]::ToByte($patchHex.Substring($i * 2, 2), 16)
            }
            $saved = New-Object byte[] $patch.Length
            $server.Position = $patchOffset
            if ($server.Read($saved, 0, $saved.Length) -ne $saved.Length) { throw 'Cannot read patch region.' }
            try {
                $server.Position = $patchOffset
                $server.Write($patch, 0, $patch.Length)
                $server.Flush($true)
                if ((Get-StreamHash $server) -ne $patchedHash) { throw 'Patched file verification failed.' }
            }
            catch {
                $failure = $_
                $server.Position = $patchOffset
                $server.Write($saved, 0, $saved.Length)
                $server.Flush($true)
                if ((Get-StreamHash $server) -ne $originalHash) {
                    throw "Restore failed. Original backup: $backupPath"
                }
                throw $failure
            }
            finally { $server.Dispose(); $server = $null }
            Write-Host 'Regional patch applied and verified.'
        }
        else { Write-Host 'Regional patch already applied.' }
        if (-not $PatchOnly) { Start-Process -FilePath $appPath -WindowStyle Normal }
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    if ($server) { $server.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
