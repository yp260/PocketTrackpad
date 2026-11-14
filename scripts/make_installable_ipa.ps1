<#
.SYNOPSIS
  Download the unsigned IPA from a GitHub Release, verify its checksum,
  check the Windows signing prerequisites, and print the exact steps that
  produce an INSTALLABLE (signed) IPA on this machine.

.DESCRIPTION
  This script does NOT sign the IPA. Apple's code signature must be issued
  to your own Apple ID and bound to your own iPhone UDID. No pre-built IPA
  can be universal. Use Sideloadly's "Export IPA" signing mode (one GUI
  operation) to turn the downloaded file into a directly installable IPA.

  All output strings are ASCII on purpose: Windows PowerShell 5.1 reads
  UTF-8 scripts without BOM as ANSI, which would garble non-ASCII text.

.PARAMETER Repo
  GitHub repository in "owner/repo" form. Required.

.PARAMETER Tag
  Release tag to download. Empty means the newest release (prerelease included).

.PARAMETER OutDir
  Output directory. Defaults to "build" inside the project root.

.PARAMETER OpenSideloadly
  Launch Sideloadly after the checks, if it can be found.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\make_installable_ipa.ps1 -Repo "myname/PocketTrackpad"

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\make_installable_ipa.ps1 -Repo "myname/PocketTrackpad" -Tag v1.0.0 -OpenSideloadly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Tag = "",

    [string]$OutDir = "",

    [switch]$OpenSideloadly
)

$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Headers = @{ "User-Agent" = "PocketTrackpad-IPA-Fetcher" }

$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Root "build"
}
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

function Write-Step([string]$Number, [string]$Text) {
    Write-Host ("  [{0}] {1}" -f $Number, $Text)
}

Write-Host ""
Write-Host "=== PocketTrackpad: prepare an installable IPA ==="
Write-Host ""

# ---------------------------------------------------------------- Release ---
Write-Host "[1/5] Resolving GitHub Release"
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Invalid Repo value. Expected 'owner/repo', got: $Repo"
}

if ([string]::IsNullOrWhiteSpace($Tag)) {
    $ApiUrl = "https://api.github.com/repos/$Repo/releases?per_page=1"
} else {
    $ApiUrl = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
}

try {
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        $Releases = @(Invoke-RestMethod -Uri $ApiUrl -Headers $Headers -Method Get)
        if ($Releases.Count -eq 0) {
            throw "No releases found in $Repo. Push a commit first, or run the workflow manually."
        }
        $Release = $Releases[0]
    } else {
        $Release = Invoke-RestMethod -Uri $ApiUrl -Headers $Headers -Method Get
    }
} catch {
    throw "Cannot query GitHub Release: $($_.Exception.Message)"
}

$ReleaseTag = $Release.tag_name
Write-Host ("      Release: {0} ({1})" -f $ReleaseTag, $Release.name)

$IpaAsset = $null
$SumAsset = $null
foreach ($Asset in $Release.assets) {
    if ($Asset.name -like "*.ipa") { $IpaAsset = $Asset }
    if ($Asset.name -eq "SHA256SUMS") { $SumAsset = $Asset }
}
if ($null -eq $IpaAsset) {
    throw "This release has no .ipa asset. Check the workflow run logs."
}
Write-Host ("      IPA asset: {0} ({1:N1} MB)" -f $IpaAsset.name, ($IpaAsset.size / 1MB))

# ---------------------------------------------------------------- Download ---
Write-Host "[2/5] Downloading"
$IpaPath = Join-Path $OutDir $IpaAsset.name
$SumPath = Join-Path $OutDir "SHA256SUMS"

Invoke-WebRequest -Uri $IpaAsset.browser_download_url -Headers $Headers -OutFile $IpaPath
Write-Host ("      Saved: {0}" -f $IpaPath)

if ($null -ne $SumAsset) {
    Invoke-WebRequest -Uri $SumAsset.browser_download_url -Headers $Headers -OutFile $SumPath
}

# ---------------------------------------------------------------- Checksum ---
Write-Host "[3/5] Verifying SHA256"
if ($null -eq $SumAsset) {
    Write-Host "      No SHA256SUMS in this release, skipped."
} else {
    $Expected = ""
    foreach ($Line in (Get-Content $SumPath)) {
        if ($Line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            if ($Matches[2].Trim() -eq $IpaAsset.name) { $Expected = $Matches[1].ToLowerInvariant(); break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        Write-Host "      No matching checksum line found, skipped."
    } else {
        $Actual = (Get-FileHash -Path $IpaPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Actual -ne $Expected) {
            throw "Checksum mismatch. Expected $Expected, got $Actual. Delete the file and retry."
        }
        Write-Host ("      OK  {0}" -f $Actual)
    }
}

# ---------------------------------------------------------------- Prereqs ----
Write-Host "[4/5] Checking Windows signing prerequisites"

$WebITunes = "C:\Program Files\iTunes\iTunes.exe"
$StoreITunes = $null
try { $StoreITunes = Get-AppxPackage -Name "AppleInc.iTunes" -ErrorAction SilentlyContinue } catch { }
if ($null -ne $StoreITunes) {
    Write-Host "      [WARN] Microsoft Store iTunes detected. Sideloadly requires the web installer version."
} elseif (Test-Path $WebITunes) {
    Write-Host "      OK    Web-installer iTunes found"
} else {
    Write-Host "      [WARN] iTunes not found. Install the WEB version (not Microsoft Store)."
}

$SideloadlyCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Sideloadly\Sideloadly.exe"),
    "C:\Program Files\Sideloadly\Sideloadly.exe",
    "C:\Program Files (x86)\Sideloadly\Sideloadly.exe"
)
$SideloadlyExe = $null
foreach ($Candidate in $SideloadlyCandidates) {
    if (Test-Path $Candidate) { $SideloadlyExe = $Candidate; break }
}
if ($null -ne $SideloadlyExe) {
    Write-Host ("      OK    Sideloadly found: {0}" -f $SideloadlyExe)
} else {
    Write-Host "      [WARN] Sideloadly not found in standard locations. Get it from https://sideloadly.io"
}

# ---------------------------------------------------------------- Next steps -
Write-Host "[5/5] How to get a DIRECTLY INSTALLABLE IPA"
Write-Host ""
Write-Host "  The downloaded file is UNSIGNED. iOS will refuse it as-is."
Write-Host "  A universal pre-signed IPA does not exist: the signature is bound"
Write-Host "  to your Apple ID and your iPhone UDID. Generate it once, locally:"
Write-Host ""
Write-Step "1" "Connect the iPhone by USB, tap 'Trust This Computer'."
Write-Step "2" "Open Sideloadly, drag this IPA into the IPA slot:"
Write-Host ("       {0}" -f $IpaPath)
Write-Step "3" "Click 'Advanced Options' -> Signing Mode -> select 'Export IPA'."
Write-Step "4" "Enter your Apple ID (use a dedicated burner account), click Start."
Write-Step "5" "Sideloadly writes a SIGNED IPA next to the source file."
Write-Host ""
Write-Host "  That exported file is the directly installable package you asked for."
Write-Host "  Install it with Sideloadly 'Normal Install', Apple Configurator,"
Write-Host "  or Xcode > Devices and Simulators. Valid 7 days on a free Apple ID."
Write-Host ""
Write-Step "6" "On the iPhone: Settings > General > VPN & Device Management > Trust."
Write-Step "7" "iOS 16+: Settings > Privacy & Security > Developer Mode > On > Restart."
Write-Host ""
Write-Host "  Alternative without any PC signing: see README section 11,"
Write-Host "  workflow signed-ipa.yml (requires a paid developer account + UDID)."
Write-Host ""

if ($OpenSideloadly) {
    if ($null -ne $SideloadlyExe) {
        Start-Process -FilePath $SideloadlyExe
        Write-Host "Sideloadly launched."
    } else {
        Write-Host "Cannot launch Sideloadly: executable not found."
    }
}

Write-Host "=== Done ==="
Write-Host ""
