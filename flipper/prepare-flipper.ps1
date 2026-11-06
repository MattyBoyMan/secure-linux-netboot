# Prepare a Flipper Zero SD card for Secure Linux netboot.
# Windows PowerShell 5.1: right-click this file, Run with PowerShell.
# Nothing is written to the card until you pick it by number AND confirm the plan.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://github.com/MattyBoyMan/secure-linux-netboot'
$ReleaseApi = 'https://api.github.com/repos/MattyBoyMan/secure-linux-netboot/releases/tags/flipper-fap'
$IpxeEfiUrl = 'https://boot.ipxe.org/x86_64-efi/ipxe.efi'
$IpxeLkrnUrl = 'https://boot.ipxe.org/x86_64-pcbios/ipxe.lkrn'

function Say([string]$Text) { Write-Host $Text }
function Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Confirm-YesNo([string]$Message) {
  while ($true) {
    $answer = Read-Host "$Message [y/N]"
    if ($answer -match '^(y|yes)$') { return $true }
    if ($answer -eq '' -or $answer -match '^(n|no)$') { return $false }
    Say 'Please type y for yes, or n for no.'
  }
}
function Show-Size([long]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
  return ('{0:N0} MB' -f ($Bytes / 1MB))
}
function Show-ManualFapSteps {
  Write-Host "`nThe Boot2Flipper app is not in a release yet. One manual GitHub step is needed:" -ForegroundColor Yellow
  Say '  1. Open https://github.com/MattyBoyMan/secure-linux-netboot and choose Add file -> Create new file.'
  Say '  2. Name it .github/workflows/build-flipper-fap.yml. In another tab, open this repository''s'
  Say '     flipper/build-flipper-fap.yml, copy ALL of its text, paste it into the new file, then Commit changes.'
  Say '  3. Open Actions -> Build the Boot2Flipper app (Flipper Zero) -> Run workflow -> Run workflow.'
  Say '  4. When it finishes, open the repository''s flipper-fap release; the app will be attached there.'
  Say 'Then run prepare-flipper.ps1 again. It will find the app and copy it onto the card automatically.'
}

Step 'Find the Flipper SD card'
Say 'Removable drives on this computer (your card is usually FAT32):'
$drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2')
if ($drives.Count -eq 0) {
  Write-Host 'No removable drive was found. Put the Flipper SD card in its reader and run this script again.' -ForegroundColor Red
  exit 1
}
$rows = @()
for ($i = 0; $i -lt $drives.Count; $i++) {
  $d = $drives[$i]
  $label = [string]$d.VolumeName
  if ($label -eq '') { $label = '(no label)' }
  $size = if ($null -eq $d.Size) { 'unknown size' } else { Show-Size ([long]$d.Size) }
  $fs = [string]$d.FileSystem
  if ($fs -eq '') { $fs = 'unknown format' }
  $rows += [pscustomobject]@{ Number = $i + 1; Drive = [string]$d.DeviceID; Label = $label; Size = $size; FileSystem = $fs }
}
$rows | Format-Table -AutoSize | Out-Host
$fat32 = @($rows | Where-Object { $_.FileSystem -ieq 'FAT32' })
$suggested = 0
if ($fat32.Count -eq 1) {
  $suggested = $fat32[0].Number
  Say "Suggested answer: $suggested (the only removable FAT32 drive). Check its label and size yourself."
}
$selected = $null
while ($null -eq $selected) {
  $prompt = 'Type the number of the Flipper SD card'
  if ($suggested -ne 0) { $prompt += " [$suggested]" }
  $answer = Read-Host $prompt
  if ($answer -eq '' -and $suggested -ne 0) { $answer = [string]$suggested }
  $number = 0
  if ([int]::TryParse($answer, [ref]$number)) {
    $selected = $rows | Where-Object { $_.Number -eq $number }
  }
  if ($null -eq $selected) { Say 'That is not one of the numbers above. No drive has been chosen.' }
}
$cardRoot = "$($selected.Drive)\"
Say "You chose $($selected.Drive) - $($selected.Label), $($selected.Size), $($selected.FileSystem)."

Step 'Confirm before anything is written'
Say 'The script will now, on the CHOSEN CARD only:'
Say "  - copy apps_data/boot2flipper and badusb into $cardRoot"
Say '  - download and verify ipxe.efi and ipxe.lkrn into apps_data/boot2flipper/ipxe/'
Say '  - look for boot2flipper.fap in the latest public release and copy it to apps/USB/'
Say 'Files with those same names are replaced. Your other files are not deleted. Downloads use temporary names first.'
if (-not (Confirm-YesNo "Write these Secure Linux files to $($selected.Drive)?")) {
  Say 'Cancelled. Nothing was written to the card.'
  exit 0
}

function Save-VerifiedDownload([string]$Url, [string]$Destination, [string]$Kind) {
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    Say "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $temporary -UseBasicParsing
    $bytes = [IO.File]::ReadAllBytes($temporary)
    $minimum = if ($Kind -eq 'fap') { 1024 } else { 65536 }
    if ($bytes.Length -lt $minimum -or $bytes.Length -gt 16777216) {
      throw "downloaded size $($bytes.Length) bytes is outside the safe sanity range"
    }
    if ($Kind -eq 'efi') {
      if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw 'ipxe.efi does not start with the PE MZ signature' }
    } elseif ($Kind -eq 'lkrn') {
      if ($bytes[514] -ne 0x48 -or $bytes[515] -ne 0x64 -or $bytes[516] -ne 0x72 -or $bytes[517] -ne 0x53) {
        throw 'ipxe.lkrn does not have the Linux kernel HdrS signature at byte 514'
      }
    }
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
    $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Say "Verified and copied $(Split-Path -Leaf $Destination) ($($bytes.Length) bytes)."
    Say "  SHA-256 for your records: $hash"
  } catch {
    Write-Host "ERROR: could not download or verify $Url : $($_.Exception.Message)" -ForegroundColor Red
    throw
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
}

Step 'Copy the Secure Linux SD-card pack'
foreach ($folder in @('apps_data', 'badusb')) {
  $source = Join-Path $PSScriptRoot $folder
  if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "The prep pack is incomplete: $source is missing" }
  $target = Join-Path $cardRoot $folder
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
  Say "Copied $folder to $target"
}

Step 'Download and verify the iPXE boot files'
Say 'boot.ipxe.org does not publish SHA-256 checksums for these downloads. The checks below confirm'
Say 'the expected size and file signature (PE MZ for EFI, Linux HdrS for LKRN); they are sanity checks,'
Say 'not cryptographic proof that the files came from iPXE. HTTPS provides the transport protection.'
$ipxeDir = Join-Path $cardRoot 'apps_data\boot2flipper\ipxe'
Save-VerifiedDownload $IpxeEfiUrl (Join-Path $ipxeDir 'ipxe.efi') 'efi'
Save-VerifiedDownload $IpxeLkrnUrl (Join-Path $ipxeDir 'ipxe.lkrn') 'lkrn'

Step 'Get the Boot2Flipper app, if a release exists'
$fapCopied = $false
$fapDestination = Join-Path $cardRoot 'apps\USB\boot2flipper.fap'
$release = $null
try {
  $release = Invoke-RestMethod -Uri $ReleaseApi -Headers @{ 'User-Agent' = 'Secure-Linux-Flipper-Prep'; 'Accept' = 'application/vnd.github+json' }
} catch {
  Say "No downloadable flipper-fap release was reported by GitHub ($($_.Exception.Message))."
}
$asset = $null
if ($null -ne $release -and $null -ne $release.assets) {
  $asset = $release.assets | Where-Object { $_.name -ieq 'boot2flipper.fap' -and $_.browser_download_url } | Select-Object -First 1
}
if ($null -ne $asset) {
  Save-VerifiedDownload ([string]$asset.browser_download_url) $fapDestination 'fap'
  $fapCopied = $true
} else {
  Show-ManualFapSteps
}

Step 'Verification summary'
Say "SD pack:      $cardRoot" + 'apps_data\ and ' + $cardRoot + 'badusb\'
foreach ($name in @('ipxe.efi', 'ipxe.lkrn')) {
  $path = Join-Path $ipxeDir $name
  if (Test-Path -LiteralPath $path) { Say "Present:       $path" } else { Say "MISSING:       $path" }
}
if ($fapCopied -and (Test-Path -LiteralPath $fapDestination)) { Say "Present:       $fapDestination" }
else { Say "Still missing: $fapDestination (follow the GitHub steps above, then re-run this script)" }

Write-Host "`nYou're ready - here's how to use it:" -ForegroundColor Green
Say '  1. Put the SD card in the Flipper. Open USB -> Boot2Flipper, choose Load Config, then config.b2f.'
Say '  2. Press Start in Boot2Flipper and plug the Flipper into the computer you want to set up.'
Say '  3. Start that computer from its boot menu, pick FLIPPER Boot2Flipper, then press Enter on the install.'
Say 'The install menu waits for you. Nothing starts or is erased automatically.'
