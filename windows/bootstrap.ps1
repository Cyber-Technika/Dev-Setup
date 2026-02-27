# windows/bootstrap.ps1
# CyTechnika Dev-Setup bootstrap (Fresh Windows 11 -> WSL2 Ubuntu 22.04 -> Terminal theme -> Ansible -> ZSH)
# Run in elevated PowerShell (Admin).
# Designed to be safe + rerunnable (idempotent-ish).

$ErrorActionPreference = "Stop"

# ----------------------------
# Helpers
# ----------------------------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }
function Write-Ok($msg) { Write-Host "OK: $msg" -ForegroundColor Green }

function Require-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Run this script in an elevated PowerShell (Run as Administrator)." }
}

function Ensure-Winget {
    Write-Step "Checking winget"
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install 'App Installer' from Microsoft Store, then re-run."
    }
}

function Ensure-GitWindows {
    Write-Step "Ensuring Git for Windows is installed"
    if (Get-Command git.exe -ErrorAction SilentlyContinue) { Write-Ok "git already installed"; return }
    winget install --id Git.Git -e --source winget | Out-Host
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw "Git install did not complete successfully."
    }
    Write-Ok "git installed"
}

function Ensure-WindowsTerminal {
    Write-Step "Ensuring Windows Terminal is installed"
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) { Write-Ok "Windows Terminal present"; return }
    winget install --id Microsoft.WindowsTerminal -e --source winget | Out-Host
    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        throw "Windows Terminal install did not complete successfully."
    }
    Write-Ok "Windows Terminal installed"
}

function Ensure-WSLFeatures {
    Write-Step "Ensuring WSL optional features are enabled"
    # Enable features via DISM so this works even if wsl --install isn't available/behaves differently
    $f1 = (dism.exe /online /get-featureinfo /featurename:Microsoft-Windows-Subsystem-Linux) 2>$null
    $f2 = (dism.exe /online /get-featureinfo /featurename:VirtualMachinePlatform) 2>$null

    $needReboot = $false

    if ($f1 -notmatch "State : Enabled") {
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Host
        $needReboot = $true
    }
    if ($f2 -notmatch "State : Enabled") {
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Host
        $needReboot = $true
    }

    if ($needReboot) {
        Write-Warn "WSL features were just enabled. A reboot is required. This script will auto-continue after reboot."
        Register-RunOnceAndReboot
        exit 0
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe not found even after enabling features. Your Windows build may not support WSL."
    }

    Write-Ok "WSL features enabled"
}

function Register-RunOnceAndReboot {
    # Re-run this same script after reboot
    $scriptPath = $PSCommandPath
    if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
        throw "Cannot auto-continue because script path is unknown. Run via the one-liner that downloads to a file."
    }

    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
        -Name "CyTechnikaDevSetupBootstrap" -Value $cmd -PropertyType String -Force | Out-Null

    Restart-Computer -Force
}

function Ensure-Ubuntu2204 {
    Write-Step "Ensuring Ubuntu 22.04 is installed for WSL2"
    # If already installed, do nothing
    $distros = (& wsl -l -q 2>$null) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($distros -contains "Ubuntu-22.04") {
        Write-Ok "Ubuntu-22.04 already registered"
    }
    else {
        # Install distro
        & wsl --install -d Ubuntu-22.04 | Out-Host
        Write-Warn "Ubuntu installation initiated. If prompted for reboot, this script will auto-continue."
        # Some systems require reboot here; we detect via exit code 0 but message, so be conservative:
        # Register RunOnce and reboot if Ubuntu isn't registered immediately after.
        Start-Sleep -Seconds 2
        $distros2 = (& wsl -l -q 2>$null) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        if ($distros2 -notcontains "Ubuntu-22.04") {
            Register-RunOnceAndReboot
            exit 0
        }
    }

    & wsl --set-default-version 2 | Out-Host

    # Ensure distro is WSL2
    try { & wsl --set-version Ubuntu-22.04 2 | Out-Host } catch { }

    Write-Ok "Ubuntu-22.04 installed (or already present) and set to WSL2"
}

function Ensure-UbuntuInitialized {
    Write-Step "Ensuring Ubuntu has completed first-run initialization"
    # First run may require interactive UNIX username/password creation.
    # We probe with a simple command.
    try {
        & wsl.exe -d Ubuntu-22.04 -- bash -lc "echo INIT_OK" | Out-Host
    }
    catch {
        Write-Warn "Ubuntu first-run may require creating a UNIX user."
    }

    # Check for typical first-run state by trying to run a command and seeing if it fails to exec bash
    $out = & wsl.exe -d Ubuntu-22.04 -- bash -lc "id -u 2>/dev/null || true; echo __DONE__" 2>&1
    if ($out -match "create a default UNIX user|username|Enter new UNIX username|passwd") {
        Write-Warn "Ubuntu needs first-run user creation."
        Write-Host ""
        Write-Host "ACTION REQUIRED (one-time):" -ForegroundColor Yellow
        Write-Host "1) Open Windows Terminal -> select Ubuntu-22.04" -ForegroundColor Yellow
        Write-Host "2) Create your UNIX username + password" -ForegroundColor Yellow
        Write-Host "3) Close Ubuntu, then re-run the same one-command install line" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    Write-Ok "Ubuntu appears initialized"
}

function Install-JetBrainsMonoNerdFont {
    Write-Step "Installing JetBrainsMono Nerd Font (Windows) from Nerd Fonts GitHub release"
    # Fully automated, no winget dependency for font package IDs.
    $zipUrl = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
    $tmpZip = Join-Path $env:TEMP "JetBrainsMono-NerdFont.zip"
    $tmpDir = Join-Path $env:TEMP "JetBrainsMono-NerdFont"

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }

    iwr -useb $zipUrl -OutFile $tmpZip

    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

    # Install all TTFs (skip Windows Compatible variants to reduce duplicates)
    $ttfs = Get-ChildItem -Path $tmpDir -Recurse -Filter *.ttf |
    Where-Object { $_.Name -notmatch "Windows Compatible" }

    if (-not $ttfs) { throw "No .ttf fonts found in downloaded Nerd Font zip." }

    $fontsFolder = "$env:WINDIR\Fonts"
    foreach ($f in $ttfs) {
        $dest = Join-Path $fontsFolder $f.Name
        if (-not (Test-Path $dest)) {
            Copy-Item $f.FullName $dest -Force
        }
    }

    Write-Ok "JetBrainsMono Nerd Font installed (or already present)"
}

function Get-WindowsTerminalSettingsPath {
    $candidates = @(
        Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    )

    # Preview package
    $preview = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Packages") -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "Microsoft.WindowsTerminalPreview_*" } |
    Select-Object -First 1
    if ($preview) {
        $candidates += Join-Path $preview.FullName "LocalState\settings.json"
    }

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }

    # If none found, open terminal once to force generation
    Write-Warn "Windows Terminal settings.json not found. Launching Terminal once to generate it..."
    Start-Process wt.exe | Out-Null
    Start-Sleep -Seconds 2
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }

    throw "Windows Terminal settings.json still not found. Open Windows Terminal once manually, then re-run."
}

function Patch-WindowsTerminalSettings {
    Write-Step "Patching Windows Terminal settings.json (Monokai Classic + Ubuntu profile)"
    $settingsPath = Get-WindowsTerminalSettingsPath

    $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $settingsPath $backup -Force
    Write-Host "Backup saved: $backup" -ForegroundColor DarkGray

    $json = Get-Content $settingsPath -Raw | ConvertFrom-Json

    # Ensure schemes exists
    if (-not $json.schemes) { $json | Add-Member -NotePropertyName schemes -NotePropertyValue @() }

    $schemeName = "Monokai Classic (CyTechnika)"
    $scheme = [pscustomobject]@{
        name                = $schemeName
        background          = "#272822"
        foreground          = "#F8F8F2"
        cursorColor         = "#F8F8F0"
        selectionBackground = "#49483E"
        black               = "#272822"
        red                 = "#F92672"
        green               = "#A6E22E"
        yellow              = "#E6DB74"
        blue                = "#66D9EF"
        purple              = "#AE81FF"
        cyan                = "#66D9EF"
        white               = "#F8F8F2"
        brightBlack         = "#75715E"
        brightRed           = "#F92672"
        brightGreen         = "#A6E22E"
        brightYellow        = "#E6DB74"
        brightBlue          = "#66D9EF"
        brightPurple        = "#AE81FF"
        brightCyan          = "#66D9EF"
        brightWhite         = "#FFFFFF"
    }

    # Upsert scheme
    $idx = -1
    for ($i = 0; $i -lt $json.schemes.Count; $i++) {
        if ($json.schemes[$i].name -eq $schemeName) { $idx = $i; break }
    }
    if ($idx -ge 0) { $json.schemes[$idx] = $scheme } else { $json.schemes += $scheme }

    # Ensure profiles container
    if (-not $json.profiles) { $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $json.profiles.list) { $json.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() }

    # Create a dedicated Ubuntu profile so we don't clobber PowerShell/CMD/PS7 styling
    $ubuntuName = "Ubuntu-22.04 (CyTechnika)"
    $existing = $null
    foreach ($p in $json.profiles.list) {
        if ($p.name -eq $ubuntuName) { $existing = $p; break }
    }

    if (-not $existing) {
        $guid = [Guid]::NewGuid().ToString("B")
        $existing = [pscustomobject]@{
            guid        = $guid
            name        = $ubuntuName
            commandline = "wsl.exe -d Ubuntu-22.04"
            hidden      = $false
        }
        $json.profiles.list += $existing
    }

    # Apply CyTechnika look only to this Ubuntu profile
    $existing.colorScheme = $schemeName
    $existing.cursorShape = "bar"
    $existing.opacity = 100
    $existing.useAcrylic = $false
    $existing.lineHeight = 1.3
    $existing.font = [pscustomobject]@{
        face = "JetBrainsMono Nerd Font"
        size = 14
    }

    ($json | ConvertTo-Json -Depth 60) | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Ok "Windows Terminal patched (scheme + Ubuntu-22.04 (CyTechnika) profile)"
}

function Wsl-Bash($cmd) {
    & wsl.exe -d Ubuntu-22.04 -- bash -lc $cmd
}

function Ensure-WslPrereqs {
    Write-Step "Installing prerequisites inside WSL (git, ansible, curl)"
    Wsl-Bash "sudo apt-get update -y"
    Wsl-Bash "sudo apt-get install -y git ansible curl"
    Write-Ok "WSL prerequisites installed"
}

function CloneRepoAndRunAnsible {
    Write-Step "Cloning Dev-Setup repo inside WSL and running Ansible"
    $repoUrl = "https://github.com/Cyber-Technika/Dev-Setup.git"
    Wsl-Bash "if [ ! -d \"\$HOME/dev_setup/.git\" ]; then git clone \"$repoUrl\" \"\$HOME/dev_setup\"; else cd \"\$HOME/dev_setup\" && git pull; fi"
    Wsl-Bash "cd \"\$HOME/dev_setup/ansible\" && ansible-playbook -i inventory.txt playbook.yml"
    Write-Ok "Ansible run complete"
}

# ----------------------------
# Main
# ----------------------------
Require-Admin
Ensure-Winget
Ensure-GitWindows
Ensure-WindowsTerminal
Ensure-WSLFeatures
Ensure-Ubuntu2204
Ensure-UbuntuInitialized
Install-JetBrainsMonoNerdFont
Patch-WindowsTerminalSettings
Ensure-WslPrereqs
CloneRepoAndRunAnsible

Write-Host "`nAll done." -ForegroundColor Cyan
Write-Host "Open Windows Terminal -> 'Ubuntu-22.04 (CyTechnika)'" -ForegroundColor Cyan
Write-Host "Verify Nerd glyphs:  echo `$'\uf015'  (should show a house icon)" -ForegroundColor Cyan