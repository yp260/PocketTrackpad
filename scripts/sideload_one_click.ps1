<#
.SYNOPSIS
  One-click path to a side-loadable PocketTrackpad IPA.

.DESCRIPTION
  Automates everything that does not need your credentials or your hands:
    1. Check git / GitHub CLI, install GitHub CLI if missing
    2. Sign in to GitHub (one browser confirmation, unavoidable)
    3. Create a public repo, commit and push this project
    4. Trigger the macOS build workflow and wait for it to finish
    5. Download the IPA from the generated Release and verify SHA256
    6. Check the Windows side-load prerequisites and open the download pages
    7. Launch Sideloadly if present

  Three things still need YOU, because Apple requires them:
    A. Your Apple ID password and 2FA code inside Sideloadly
    B. USB cable + tapping "Trust This Computer" on the iPhone
    C. Trusting the developer profile and enabling Developer Mode on the iPhone

  All output is ASCII on purpose: Windows PowerShell 5.1 reads UTF-8 scripts
  without BOM as ANSI, which garbles non-ASCII text.

.PARAMETER RepoName
  Name of the GitHub repository to create. Default: PocketTrackpad.

.PARAMETER OutDir
  Where the IPA is saved. Default: "build" inside the project root.

.PARAMETER OpenDownloads
  Open the iTunes / Sideloadly download pages in the browser automatically.

.PARAMETER SkipGitHub
  Skip all GitHub steps and only run the local prerequisite checks.
  Use this if you already downloaded the IPA.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\sideload_one_click.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\sideload_one_click.ps1 -RepoName MyTrackpad -OpenDownloads
#>
[CmdletBinding()]
param(
    [string]$RepoName = "PocketTrackpad",
    [string]$OutDir = "",
    [switch]$OpenDownloads,
    [switch]$SkipGitHub
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Root "build"
}
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

function Write-Phase([string]$Text) {
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Text)
}

function Write-Todo([string]$Number, [string]$Text) {
    Write-Host ("  {0}. {1}" -f $Number, $Text)
}

function Get-GhJson([string[]]$Arguments) {
    $Raw = (& $script:GhExe @Arguments 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Raw)) { return @() }
    try { return @($Raw | ConvertFrom-Json) } catch { return @() }
}

Write-Host ""
Write-Host "PocketTrackpad - side-load one-click helper"
Write-Host ""
Write-Host "Three things cannot be automated (Apple requires them):"
Write-Todo "A" "Your Apple ID password and 2FA code in Sideloadly"
Write-Todo "B" "USB cable + tap 'Trust This Computer' on the iPhone"
Write-Todo "C" "Trust developer profile + enable Developer Mode on the iPhone"
Write-Host "Everything else is handled below."
Write-Host ""

$DownloadedIpa = ""

if (-not $SkipGitHub) {
    # ------------------------------------------------------------ Phase 1 ---
    Write-Phase "1/6  Toolchain"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is required but not found. Install Git for Windows first."
    }
    Write-Host "  OK    git found"

    $script:GhExe = ""
    $GhCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -ne $GhCmd) { $script:GhExe = $GhCmd.Source }

    # winget / MSI 刚装完时，当前会话的 PATH 可能还没刷新，直接查默认安装路径
    if ([string]::IsNullOrWhiteSpace($script:GhExe)) {
        foreach ($Candidate in @("C:\Program Files\GitHub CLI\gh.exe", "C:\Program Files (x86)\GitHub CLI\gh.exe", (Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\gh.exe"))) {
            if (Test-Path $Candidate) { $script:GhExe = $Candidate; break }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:GhExe)) {
        Write-Host "  GitHub CLI missing, trying winget..."
        $Winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($null -ne $Winget) {
            & winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements --disable-interactivity
        }
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $GhCmd = Get-Command gh -ErrorAction SilentlyContinue
        if ($null -ne $GhCmd) { $script:GhExe = $GhCmd.Source }
        if ([string]::IsNullOrWhiteSpace($script:GhExe)) {
            foreach ($Candidate in @("C:\Program Files\GitHub CLI\gh.exe", "C:\Program Files (x86)\GitHub CLI\gh.exe")) {
                if (Test-Path $Candidate) { $script:GhExe = $Candidate; break }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:GhExe)) {
        Write-Host ""
        Write-Host "  Cannot install GitHub CLI automatically."
        Write-Host "  Install it manually: https://cli.github.com"
        Write-Host "  Then re-run this script."
        throw "GitHub CLI (gh) is not available."
    }
    Write-Host ("  OK    GitHub CLI: {0}" -f $script:GhExe)

    # ------------------------------------------------------------ Phase 2 ---
    Write-Phase "2/6  GitHub sign-in"
    & $script:GhExe auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  The terminal will print an 8-character one-time code like ABCD-1234."
        Write-Host "  COPY THAT CODE FIRST, then press Enter when asked."
        Write-Host ""
        Write-Host "  The 'Authorize GitHub CLI' button is NOT on the GitHub home page."
        Write-Host "  Go to https://github.com/login/device (open it manually if needed),"
        Write-Host "  paste the code, click Continue, then click 'Authorize GitHub CLI'."
        Write-Host ""
        Write-Host "  Waiting for authorization..."
        Write-Host ""
        & $script:GhExe auth login --web --git-protocol https --scopes "repo,workflow"
        if ($LASTEXITCODE -ne 0) { throw "GitHub sign-in failed or was cancelled." }
    }
    $Account = (& $script:GhExe api user --jq .login 2>$null)
    Write-Host ("  OK    signed in as {0}" -f $Account)

    # ------------------------------------------------------------ Phase 3 ---
    Write-Phase "3/6  Repository and push"
    Set-Location $Root

    $IsRepo = $false
    try { & git rev-parse --is-inside-work-tree 2>$null | Out-Null; $IsRepo = ($LASTEXITCODE -eq 0) } catch { }
    if (-not $IsRepo) {
        & git init -b main | Out-Null
        Write-Host "  Initialised git repository"
    }

    $ConfiguredName = (& git config user.name 2>$null)
    $ConfiguredMail = (& git config user.email 2>$null)
    $GitIdentity = @()
    if ([string]::IsNullOrWhiteSpace($ConfiguredName)) { $GitIdentity += @("-c", "user.name=PocketTrackpad Builder") }
    if ([string]::IsNullOrWhiteSpace($ConfiguredMail)) { $GitIdentity += @("-c", "user.email=builder@localhost") }

    $Pending = @(& git status --porcelain 2>$null)
    if ($Pending.Count -gt 0) {
        & git add -A | Out-Null
        if ($GitIdentity.Count -gt 0) {
            & git @GitIdentity commit -m "PocketTrackpad: initial project" | Out-Null
        } else {
            & git commit -m "PocketTrackpad: initial project" | Out-Null
        }
        Write-Host "  Committed local changes"
    } else {
        Write-Host "  No pending local changes"
    }

    $Remote = ""
    try { $Remote = (& git remote get-url origin 2>$null) } catch { }
    if ([string]::IsNullOrWhiteSpace($Remote)) {
        Write-Host ("  Creating PUBLIC repo '{0}' (public repos get free macOS runners)" -f $RepoName)
        & $script:GhExe repo create $RepoName --public --source=. --push --remote=origin
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Repo creation failed. If the name is taken, re-run with -RepoName <other-name>."
            throw "gh repo create failed"
        }
    } else {
        & git push origin HEAD
        if ($LASTEXITCODE -ne 0) { throw "git push failed" }
    }
    Write-Host "  OK    code pushed"

    # ------------------------------------------------------------ Phase 4 ---
    Write-Phase "4/6  Cloud build (macOS runner, about 10 minutes)"

    $Before = Get-GhJson -Arguments @("run", "list", "--workflow", "unsigned-ipa.yml", "--limit", "1", "--json", "databaseId")
    $BeforeId = [int64]0
    if ($Before.Count -gt 0) { $BeforeId = [int64]$Before[0].databaseId }

    & $script:GhExe workflow run "unsigned-ipa.yml"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Could not trigger workflow via CLI; the push may already have triggered it."
    }

    $Deadline = (Get-Date).AddMinutes(30)
    $RunId = [int64]0
    $Conclusion = ""
    while ((Get-Date) -lt $Deadline) {
        $Runs = Get-GhJson -Arguments @("run", "list", "--workflow", "unsigned-ipa.yml", "--limit", "1", "--json", "databaseId,status,conclusion,url")
        if ($Runs.Count -gt 0) {
            $R = $Runs[0]
            if ([int64]$R.databaseId -gt $BeforeId) {
                if ($RunId -ne [int64]$R.databaseId) {
                    $RunId = [int64]$R.databaseId
                    Write-Host ("  Run #{0} started: {1}" -f $RunId, $R.url)
                }
                if ($R.status -eq "completed") { $Conclusion = $R.conclusion; break }
            }
        }
        Start-Sleep -Seconds 15
    }
    if ($Conclusion -ne "success") {
        Write-Host ("  Build result: {0}" -f $(if ($Conclusion) { $Conclusion } else { "timed out" }))
        if ($RunId -gt 0) { Write-Host ("  Logs: gh run view {0} --log-failed" -f $RunId) }
        throw "Cloud build did not succeed."
    }
    Write-Host "  OK    build succeeded"

    # ------------------------------------------------------------ Phase 5 ---
    Write-Phase "5/6  Download IPA and verify"

    $Releases = Get-GhJson -Arguments @("release", "list", "--limit", "5", "--json", "tagName,isPrerelease")
    if ($Releases.Count -eq 0) { throw "No Release found. Check the workflow run logs." }
    $Tag = $Releases[0].tagName
    Write-Host ("  Latest release: {0}" -f $Tag)

    & $script:GhExe release download $Tag --pattern "*.ipa" --dir $OutDir --clobber
    if ($LASTEXITCODE -ne 0) { throw "IPA download failed." }
    & $script:GhExe release download $Tag --pattern "SHA256SUMS" --dir $OutDir --clobber 2>$null | Out-Null

    $IpaFiles = @(Get-ChildItem -Path $OutDir -Filter "*.ipa" -File | Sort-Object LastWriteTime -Descending)
    if ($IpaFiles.Count -eq 0) { throw "No .ipa file appeared in $OutDir" }
    $DownloadedIpa = $IpaFiles[0].FullName
    Write-Host ("  Saved: {0}" -f $DownloadedIpa)

    $SumPath = Join-Path $OutDir "SHA256SUMS"
    if (Test-Path $SumPath) {
        $Expected = ""
        foreach ($Line in (Get-Content $SumPath)) {
            if ($Line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
                if ($Matches[2].Trim() -eq $IpaFiles[0].Name) { $Expected = $Matches[1].ToLowerInvariant(); break }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Expected)) {
            $Actual = (Get-FileHash -Path $DownloadedIpa -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Actual -ne $Expected) { throw "SHA256 mismatch. Delete the file and re-run." }
            Write-Host ("  OK    SHA256 {0}" -f $Actual.Substring(0, 16))
        }
    }
} else {
    $IpaFiles = @(Get-ChildItem -Path $OutDir -Filter "*.ipa" -File | Sort-Object LastWriteTime -Descending)
    if ($IpaFiles.Count -gt 0) { $DownloadedIpa = $IpaFiles[0].FullName }
}

# ---------------------------------------------------------------- Phase 6 ---
Write-Phase "6/6  Side-load prerequisites on this PC"

$WebITunes = "C:\Program Files\iTunes\iTunes.exe"
$HasWebITunes = Test-Path $WebITunes
$StoreITunes = $null
try { $StoreITunes = Get-AppxPackage -Name "AppleInc.iTunes" -ErrorAction SilentlyContinue } catch { }
$HasStoreITunes = ($null -ne $StoreITunes)

if ($HasStoreITunes) {
    Write-Host "  [ACTION] Microsoft Store iTunes is installed and MUST be uninstalled."
    Write-Host "           Settings > Apps > iTunes > Uninstall, then install the web version."
}
if (-not $HasWebITunes) {
    Write-Host "  [ACTION] Web-installer iTunes not found: https://www.apple.com/itunes/download/win64"
} else {
    Write-Host "  OK    web-installer iTunes"
}
Write-Host "  [ACTION] iCloud for Windows (web version) is also required: https://support.apple.com/kb/DL1455"

$SideloadlyCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Sideloadly\Sideloadly.exe"),
    "C:\Program Files\Sideloadly\Sideloadly.exe",
    "C:\Program Files (x86)\Sideloadly\Sideloadly.exe"
)
$SideloadlyExe = $null
foreach ($Candidate in $SideloadlyCandidates) {
    if (Test-Path $Candidate) { $SideloadlyExe = $Candidate; break }
}
if ($null -eq $SideloadlyExe) {
    Write-Host "  [ACTION] Sideloadly not installed: https://sideloadly.io"
} else {
    Write-Host ("  OK    Sideloadly: {0}" -f $SideloadlyExe)
}

if ($OpenDownloads) {
    if (-not $HasWebITunes) { Start-Process "https://www.apple.com/itunes/download/win64" }
    if ($null -eq $SideloadlyExe) { Start-Process "https://sideloadly.io" }
}

if ($null -ne $SideloadlyExe -and (Test-Path $SideloadlyExe)) {
    Start-Process -FilePath $SideloadlyExe
    Write-Host "  Sideloadly launched."
}

# ---------------------------------------------------------------- Final -----
Write-Host ""
Write-Host "=== ONLY 3 STEPS LEFT FOR YOU ==="
Write-Host ""
if ([string]::IsNullOrWhiteSpace($DownloadedIpa)) {
    Write-Todo "1" "Put the downloaded .ipa into $OutDir (or re-run without -SkipGitHub)."
} else {
    Write-Todo "1" ("Drag this IPA into Sideloadly: {0}" -f $DownloadedIpa)
}
Write-Todo "2" "Connect the iPhone by USB, tap 'Trust', enter your Apple ID + 2FA, click Start."
Write-Todo "3" "iPhone: Settings > General > VPN & Device Management > Trust; iOS 16+ also enable Developer Mode."
Write-Host ""
Write-Host "That is the side-load install. Free Apple ID signatures last 7 days;"
Write-Host "enable Sideloadly automatic refresh so it renews over Wi-Fi."
Write-Host ""
Write-Host "=== Done ==="
Write-Host ""
