$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DownloadURL = "https://upload2.delivery.autodesk.com/WebInstall3StubGUI-1795541247844.exe?response-content-disposition=attachment%3B%20filename%20%3D%22Autodesk_AutoCAD_2027_1_1_English_en-US_setup_webinstall.exe%22%20%3B%20filename%2A%3DUTF-8%27%27Autodesk_AutoCAD_2027_1_1_English_en-US_setup_webinstall.exe"

$Stage = Join-Path $env:ProgramFiles ("AutoCAD2027-Stage-" + [guid]::NewGuid().ToString("N"))

$Installer = Join-Path $Stage "Autodesk_AutoCAD_2027_1_1_English_en-US_setup_webinstall.exe"

$InstallTimeoutMinutes = 120

function Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Get-AutoCAD {
    $RegistryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    Get-ItemProperty -Path $RegistryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match "^(Autodesk )?AutoCAD 2027($| - | English)" -and
            $_.Publisher -match "Autodesk"
        } |
        Select-Object -First 1
}

try {
    Log "=========================================="
    Log "AutoCAD 2027.1.1 Zero-Touch Deployment"
    Log "Computer: $env:COMPUTERNAME"
    Log "Running as: $env:USERNAME"
    Log "=========================================="

    # Validate PowerShell architecture
    if (-not [Environment]::Is64BitProcess) {
        throw "64-bit PowerShell is required."
    }

    # Check existing installation
    $Installed = Get-AutoCAD

    if ($Installed) {
        Log "AutoCAD 2027 is already installed."
        Log "Product: $($Installed.DisplayName)"
        Log "Version: $($Installed.DisplayVersion)"
        exit 0
    }

    # Check available disk space
    $Drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(":"))
    $FreeGB = [math]::Round($Drive.Free / 1GB, 2)

    Log "Available disk space: $FreeGB GB"

    if ($Drive.Free -lt 30GB) {
        throw "Insufficient disk space. Minimum 30 GB required by this script."
    }

    # Create staging directory
    New-Item -Path $Stage -ItemType Directory -Force | Out-Null

    Log "Staging directory: $Stage"

    # Download installer
    Log "Downloading Autodesk Web Installer..."

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Invoke-WebRequest -Uri $DownloadURL -OutFile $Installer -UseBasicParsing -TimeoutSec 1800
            break
        }
        catch {
            if ($Attempt -eq 3) {
                throw
            }

            Log "Download attempt $Attempt failed. Retrying..."
            Remove-Item $Installer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 15
        }
    }

    if (-not (Test-Path $Installer -PathType Leaf)) {
        throw "Installer download failed."
    }

    $SizeMB = [math]::Round((Get-Item $Installer).Length / 1MB, 2)

    Log "Download completed: $SizeMB MB"

    # Validate digital signature
    Log "Validating Autodesk digital signature..."

    $Signature = Get-AuthenticodeSignature -FilePath $Installer

    Log "Signature status: $($Signature.Status)"
    Log "Signature message: $($Signature.StatusMessage)"
    Log "Publisher: $($Signature.SignerCertificate.Subject)"
    Log "SHA256: $((Get-FileHash $Installer -Algorithm SHA256).Hash)"

    if ($Signature.Status -ne "Valid") {
        throw "Installer digital signature validation failed."
    }

    if ($Signature.SignerCertificate.Subject -notmatch "Autodesk") {
        throw "Unexpected installer publisher."
    }

    # Start silent web installation
    Log "Starting AutoCAD Web Installer..."
    Log "Installation argument: -q"
    Log "Silent installation requested."

    $Process = Start-Process -FilePath $Installer -ArgumentList "-q" -WorkingDirectory $Stage -WindowStyle Hidden -PassThru

    Log "Installer process ID: $($Process.Id)"

    # Monitor background installation
    $Deadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)
    $Installed = $null
    $ExitLogged = $false

    do {
        $Process.Refresh()

        if ($Process.HasExited -and -not $ExitLogged) {
            $ExitCode = $Process.ExitCode
            Log "Web Installer exit code: $ExitCode"
            $ExitLogged = $true

            if ($ExitCode -notin @(0, 259, 1641, 3010)) {
                throw "Web Installer failed with exit code $ExitCode."
            }

            if ($ExitCode -in @(1641, 3010)) {
                Log "NOTICE: Installer reported a reboot."
            }

            Log "Checking for background installation..."
        }

        $Installed = Get-AutoCAD

        $AutoCADExe = Join-Path $env:ProgramFiles "Autodesk\AutoCAD 2027\acad.exe"

        if ($Installed -and (Test-Path $AutoCADExe) -and $Process.HasExited) {
            break
        }

        Log "Waiting for AutoCAD installation to complete..."
        Start-Sleep -Seconds 30

    } until ((Get-Date) -ge $Deadline)

    # Verify installation
    $Installed = Get-AutoCAD
    $Process.Refresh()

    if (-not $Installed) {
        throw "AutoCAD 2027 installation could not be verified before timeout."
    }

    if (-not (Test-Path $AutoCADExe)) {
        throw "AutoCAD registry entry found but acad.exe is missing."
    }

    if (-not $Process.HasExited) {
        throw "AutoCAD was detected but the installer is still running."
    }

    if ($Process.ExitCode -notin @(0, 259, 1641, 3010)) {
        throw "Installer returned exit code $($Process.ExitCode)."
    }

    # Installation successful
    Log "=========================================="
    Log "SUCCESS: AutoCAD 2027 installed."
    Log "Product: $($Installed.DisplayName)"
    Log "Installed version: $($Installed.DisplayVersion)"
    Log "Executable: $AutoCADExe"
    Log "=========================================="

    # Cleanup staging directory
    Log "Cleaning up downloaded installer..."

    Remove-Item -Path $Stage -Recurse -Force -ErrorAction SilentlyContinue

    Log "Deployment completed successfully."

    exit 0
}
catch {
    Log "=========================================="
    Log "ERROR: $($_.Exception.Message)"
    Log "Staging directory: $Stage"
    Log "Autodesk logs: $env:LOCALAPPDATA\Autodesk\ODIS"
    Log "Additional logs: C:\ProgramData\Autodesk\ODIS"
    Log "Installation files retained for troubleshooting."
    Log "=========================================="

    exit 1
}
