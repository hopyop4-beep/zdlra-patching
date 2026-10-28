<#
.SYNOPSIS
    Step 1 of staging: check a patch folder on a ZDLRA, zip the whole folder there,
    and download the archive to this PC.

.DESCRIPTION
    Patches cannot move between hosts directly (firewall), so they travel through
    this PC. This script does the first hop, using the OpenSSH client built into
    Windows (ssh.exe / scp.exe):

      1. Connects to the ZDLRA and checks that -RemotePath exists, holds at least one
         .zip, and holds every file listed in the manifest (for example the
         precheck script). Stops before zipping if anything is missing.
      2. Checks free space on the ZDLRA and on this PC.
      3. Archives the whole folder on the ZDLRA in -RemoteWorkDir. zip -0 (stored, no
         compression, because patch zips are already compressed), or tar if zip is
         not installed.
      4. Downloads the archive with scp to <DestRoot>\<ZdlraName>\.
      5. Checks the download: size and SHA-256 against the values from the ZDLRA,
         and that the archive opens. Writes <archive>.sha256 next to it.
      6. Deletes the archive on the ZDLRA (unless -KeepRemoteArchive).

    Each step opens its own SSH connection, so use key authentication to avoid
    typing the password several times.

    Manifest (optional): manifests\<ZdlraName>.txt, one path per line relative to
    -RemotePath. Blank lines and lines starting with # are ignored.

.PARAMETER ZdlraName
    Appliance name. Used as the SSH host (unless -SshHost is given), in the archive
    name, and as the destination folder name.

.PARAMETER RemotePath
    Folder on the ZDLRA to check and archive. Default: /radump/patches

.PARAMETER RemoteWorkDir
    Folder on the ZDLRA where the archive is built. Default: /radump

.PARAMETER DestRoot
    Root folder on this PC. Default: C:\ZDLRA\staging

.PARAMETER Manifest
    Manifest to use instead of manifests\<ZdlraName>.txt. Without one, only the
    "at least one .zip" check applies.

.PARAMETER SshHost
    Host name or address to connect to, when it differs from -ZdlraName.

.PARAMETER SshUser
    SSH user. Default: root

.PARAMETER SshPort
    SSH port. Default: 22

.PARAMETER SshKey
    Private key file for SSH.

.PARAMETER ArchiveFormat
    zip (default) or tar.

.PARAMETER KeepRemoteArchive
    Leave the archive on the ZDLRA after a verified download.

.PARAMETER SshPath
    ssh client to use. Default: ssh.exe

.PARAMETER ScpPath
    scp client to use. Default: scp.exe

.EXAMPLE
    .\Copy-ZdlraPatches.ps1 -ZdlraName zdlra01

.EXAMPLE
    .\Copy-ZdlraPatches.ps1 -ZdlraName zdlra01 -RemotePath /radump/patches -SshKey $HOME\.ssh\id_ed25519
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$ZdlraName,

    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]
    [string]$RemotePath = '/radump/patches',

    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]
    [string]$RemoteWorkDir = '/radump',

    [string]$DestRoot = 'C:\ZDLRA\staging',

    [string]$Manifest,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.:-]*$')]
    [string]$SshHost,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SshUser = 'root',

    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,

    [string]$SshKey,

    [ValidateSet('zip', 'tar')]
    [string]$ArchiveFormat = 'zip',

    [switch]$KeepRemoteArchive,

    [string]$SshPath = 'ssh.exe',

    [string]$ScpPath = 'scp.exe'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
}

function Stop-WithError {
    param([string]$Message)
    Write-Log $Message 'ERROR'
    exit 1
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} bytes' -f $Bytes
}

# Reject paths that could leave the folder or would need shell quoting.
function Test-SafeRelativePath {
    param([string]$Path)
    return ($Path -match '^[A-Za-z0-9._][A-Za-z0-9._/-]*$') -and ($Path -notmatch '(^|/)\.\.(/|$)')
}

# ---------------------------------------------------------------------------
# Runs on the ZDLRA (bash). Prints one tagged line per result:
#   FOUND <bytes> <path> | MISSING <path> | NOTE <text> | ERROR <text>
#   TOTAL <bytes> <files> | FREE <bytes> | ARCHIVE <bytes> <path> | SHA256 <hash>
# Arguments: <src> <workdir> <name> <format> <stamp> [required paths...]
# ---------------------------------------------------------------------------
$remoteScript = @'
set -uo pipefail
src="$1"; work="$2"; name="$3"; fmt="$4"; stamp="$5"; shift 5
[ -d "$src" ] || { echo "ERROR Folder not found on $(hostname): $src"; exit 2; }

missing=0
for rel in "$@"; do
    if [ -s "$src/$rel" ]; then
        echo "FOUND $(stat -c %s "$src/$rel") $rel"
    else
        echo "MISSING $rel"; missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 3

zips=$(find "$src" -type f -name '*.zip' | wc -l)
[ "$zips" -gt 0 ] || { echo "ERROR No .zip files under $src"; exit 3; }
echo "NOTE $zips .zip file(s) under $src"
echo "TOTAL $(du -sb "$src" | cut -f1) $(find "$src" -type f | wc -l)"

mkdir -p "$work" || { echo "ERROR Cannot create $work"; exit 4; }
total=$(du -sb "$src" | cut -f1)
free=$(df -B1 --output=avail "$work" | tail -1 | tr -dc '0-9')
echo "FREE $free"
[ "$free" -gt $(( total + 1073741824 )) ] || { echo "ERROR Not enough free space in $work"; exit 4; }

base=$(basename "$src")
parent=$(dirname "$src")
if [ "$fmt" = zip ] && ! command -v zip >/dev/null 2>&1; then
    echo "NOTE zip is not installed; using tar"; fmt=tar
fi
if [ "$fmt" = zip ]; then
    archive="$work/${name}_${base}_${stamp}.zip"
    ( cd "$parent" && zip -r -0 -q "$archive" "$base" ) || { echo "ERROR zip failed"; exit 5; }
else
    archive="$work/${name}_${base}_${stamp}.tar"
    ( cd "$parent" && tar -cf "$archive" "$base" ) || { echo "ERROR tar failed"; exit 5; }
fi
[ -s "$archive" ] || { echo "ERROR Archive was not created: $archive"; exit 5; }
echo "ARCHIVE $(stat -c %s "$archive") $archive"
echo "SHA256 $(sha256sum "$archive" | cut -d' ' -f1)"
'@

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
if (-not $SshHost) { $SshHost = $ZdlraName }
$target = "$SshUser@$SshHost"
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

foreach ($tool in @($SshPath, $ScpPath)) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Stop-WithError "$tool not found. Install the Windows OpenSSH client (Settings > Optional features)."
    }
}

$sshOpts = @('-p', "$SshPort", '-o', 'ConnectTimeout=20')
$scpOpts = @('-P', "$SshPort", '-o', 'ConnectTimeout=20')
if ($SshKey) {
    if (-not (Test-Path -LiteralPath $SshKey -PathType Leaf)) { Stop-WithError "SSH key not found: $SshKey" }
    $sshOpts += @('-i', $SshKey)
    $scpOpts += @('-i', $SshKey)
}

if (-not $Manifest) { $Manifest = Join-Path $PSScriptRoot "manifests\$ZdlraName.txt" }
$required = @()
if (Test-Path -LiteralPath $Manifest -PathType Leaf) {
    $required = @(Get-Content -LiteralPath $Manifest | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($rel in $required) {
        if (-not (Test-SafeRelativePath $rel)) { Stop-WithError "Unsafe path in manifest ${Manifest}: $rel" }
    }
}

$destDir = Join-Path $DestRoot $ZdlraName
New-Item -ItemType Directory -Path $destDir -Force | Out-Null
$script:LogFile = Join-Path $destDir "download_$stamp.log"

Write-Log "ZDLRA:        $ZdlraName ($target, port $SshPort)"
Write-Log "Remote:       $RemotePath (archive built in $RemoteWorkDir)"
Write-Log "Destination:  $destDir"
if ($required.Count) { Write-Log "Manifest:     $Manifest ($($required.Count) required file(s))" }
else { Write-Log "Manifest:     none; checking only that the folder holds .zip files" 'WARN' }

# ---------------------------------------------------------------------------
# 1-3. Check and archive on the ZDLRA
# ---------------------------------------------------------------------------
Write-Log "Connecting to $SshHost to check and archive $RemotePath ..."
# The script travels base64-encoded on the command line and is decoded on the ZDLRA.
# Piping it to ssh.exe instead lets Windows PowerShell add a byte-order mark, and
# Windows PowerShell mangles double quotes in native arguments, so none are used.
# Every argument has passed the validation patterns above, so single quotes are enough.
$scriptBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($remoteScript -replace "`r`n", "`n"))
$b64 = [Convert]::ToBase64String($scriptBytes)
$quoted = @($RemotePath, $RemoteWorkDir, $ZdlraName, $ArchiveFormat, $stamp) + $required | ForEach-Object { "'$_'" }
$remoteCmd = "echo $b64 | base64 -d | bash -s -- " + ($quoted -join ' ')
# stderr is not redirected, so ssh prompts and errors reach the console directly.
$out = @(& $SshPath @sshOpts $target $remoteCmd)
$rc = $LASTEXITCODE
if ($script:LogFile) { $out | ForEach-Object { Add-Content -Path $script:LogFile -Value "  remote: $_" -Encoding UTF8 } }

$archive = $null; $archiveSize = [long]-1; $remoteSha = $null; $totalBytes = [long]0
foreach ($line in $out) {
    $tag, $rest = ([string]$line).Split(' ', 2)
    switch ($tag) {
        'FOUND'   { $b, $p = $rest.Split(' ', 2); Write-Log ("  found    {0} ({1})" -f $p, (Format-Size ([long]$b))) }
        'MISSING' { Write-Log "  MISSING  $rest" 'ERROR' }
        'NOTE'    { Write-Log "  $rest" }
        'ERROR'   { Write-Log "  $rest" 'ERROR' }
        'TOTAL'   { $b, $n = $rest.Split(' ', 2); $totalBytes = [long]$b; Write-Log ("  folder   {0} file(s), {1}" -f $n, (Format-Size $totalBytes)) }
        'FREE'    { Write-Log ("  free on ZDLRA in {0}: {1}" -f $RemoteWorkDir, (Format-Size ([long]$rest))) }
        'ARCHIVE' { $b, $archive = $rest.Split(' ', 2); $archiveSize = [long]$b }
        'SHA256'  { $remoteSha = $rest.Trim().ToLower() }
    }
}
if ($rc -eq 255) { Stop-WithError "SSH connection to $target failed." }
if ($rc -ne 0)   { Stop-WithError "Checks on $SshHost failed (exit code $rc). Nothing was downloaded." }
if (-not $archive -or -not $remoteSha) { Stop-WithError "The ZDLRA did not report an archive. See $script:LogFile" }
if (-not $archive.StartsWith("$RemoteWorkDir/")) { Stop-WithError "Unexpected archive path from the ZDLRA: $archive" }
Write-Log ("  archive  {0} ({1})" -f $archive, (Format-Size $archiveSize))

# ---------------------------------------------------------------------------
# 4. Download
# ---------------------------------------------------------------------------
$localFile = Join-Path $destDir (Split-Path $archive -Leaf)
$free = (New-Object System.IO.DriveInfo((Split-Path ([System.IO.Path]::GetFullPath($destDir)) -Qualifier))).AvailableFreeSpace
Write-Log ("Free on this PC: {0}" -f (Format-Size $free))
if ($free -lt ($archiveSize + 1GB)) { Stop-WithError "Not enough free space on this PC for $(Format-Size $archiveSize)." }

Write-Log "Downloading to $localFile ..."
$started = Get-Date
& $ScpPath @scpOpts "${target}:$archive" $localFile
if ($LASTEXITCODE -ne 0) { Stop-WithError "scp failed (exit code $LASTEXITCODE). The archive is still on the ZDLRA: $archive" }
$secs = [math]::Max(1, ((Get-Date) - $started).TotalSeconds)
Write-Log ("Downloaded in {0:N0}s ({1}/s)" -f $secs, (Format-Size ([long]($archiveSize / $secs))))

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
$localSize = (Get-Item -LiteralPath $localFile).Length
if ($localSize -ne $archiveSize) { Stop-WithError "Size mismatch: $localSize bytes here, $archiveSize on the ZDLRA." }
$localSha = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash.ToLower()
if ($localSha -ne $remoteSha) { Stop-WithError "SHA-256 mismatch: $localSha here, $remoteSha on the ZDLRA." }
if ($localFile -like '*.zip') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($localFile); $entries = $zip.Entries.Count; $zip.Dispose() }
    catch { Stop-WithError "The downloaded zip cannot be opened: $localFile" }
    Write-Log "Archive opens: $entries entries."
}
Write-Log "Verified: size and SHA-256 match the ZDLRA."

# sha256sum format with LF and no BOM, so `sha256sum -c` works on Linux.
$shaFile = "$localFile.sha256"
$shaLine = "$localSha  $(Split-Path $localFile -Leaf)`n"
[System.IO.File]::WriteAllText($shaFile, $shaLine, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# 6. Remove the archive on the ZDLRA
# ---------------------------------------------------------------------------
if ($KeepRemoteArchive) {
    Write-Log "Remote archive kept: $archive"
} else {
    & $SshPath @sshOpts $target "rm -f '$archive'"
    if ($LASTEXITCODE -eq 0) { Write-Log "Removed remote archive $archive" }
    else { Write-Log "Could not remove remote archive $archive (exit code $LASTEXITCODE)" 'WARN' }
}

Write-Log "Done. $localFile"
