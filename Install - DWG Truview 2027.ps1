$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Keep the full URL, including the query string; do not split at '?'.
$DownloadUrl = 'https://upload2.delivery.autodesk.com/WebInstall3StubGUI-1794496986758.exe?response-content-disposition=attachment%3B%20filename%20%3D%22Autodesk_DWG_TrueView_2027_English_en-US_setup_webinstall.exe%22%20%3B%20filename%2A%3DUTF-8%27%27Autodesk_DWG_TrueView_2027_English_en-US_setup_webinstall.exe'
$AppName     = 'Autodesk DWG TrueView 2027'
$WorkDir     = Join-Path $env:ProgramData 'Autodesk\DWGTrueView2027NinjaOne'
$Installer   = Join-Path $WorkDir 'DWGTrueView2027-WebInstall.exe'
$TempFile    = Join-Path $WorkDir 'DWGTrueView2027-Download.exe'
$LogFile     = Join-Path $WorkDir 'Install.log'

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    if (Test-Path -LiteralPath $WorkDir) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Get-TrueView2027 {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match '^(Autodesk\s+)?DWG\s+TrueView\s+2027\b'
        } |
        Select-Object -First 1 DisplayName, DisplayVersion
}

function Test-AutodeskSignature {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $false
    }

    if ((Get-Item -LiteralPath $FilePath).Length -lt 100KB) {
        return $false
    }

    $signature = Get-AuthenticodeSignature -FilePath $FilePath
    return ($signature.Status -eq 'Valid' -and
            $null -ne $signature.SignerCertificate -and
            $signature.SignerCertificate.Subject -match 'Autodesk')
}

try {
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    Write-Log "Starting $AppName deployment."

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'DWG TrueView 2027 requires 64-bit Windows.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run this script using 64-bit PowerShell in NinjaOne.'
    }

    $existing = Get-TrueView2027
    if ($null -ne $existing) {
        Write-Log "Already installed: $($existing.DisplayName) [$($existing.DisplayVersion)]. Skipping."
        exit 0
    }

    # Ensure TLS 1.2 is available to PowerShell 5.1 download requests.
    [Net.ServicePointManager]::SecurityProtocol = (
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    )

    Write-Log 'Downloading Autodesk DWG TrueView 2027 web installer...'
    Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempFile -UseBasicParsing -TimeoutSec 1800

    if (-not (Test-AutodeskSignature -FilePath $TempFile)) {
        throw 'The download is missing, too small, or does not have a valid Autodesk digital signature.'
    }

    Move-Item -LiteralPath $TempFile -Destination $Installer -Force
    Write-Log ('Download verified ({0:N2} MB).' -f ((Get-Item -LiteralPath $Installer).Length / 1MB))

    # The 2027 WebInstall3StubGUI package accepts -q --noreboot.
    Write-Log 'Running Autodesk web installer: -q --noreboot'
    $process = Start-Process -FilePath $Installer `
        -ArgumentList '-q --noreboot' `
        -WorkingDirectory $WorkDir `
        -WindowStyle Hidden `
        -PassThru

    # Timeout avoids an indefinite hang in unattended RMM jobs.
    if (-not $process.WaitForExit(2400000)) {
        throw 'Web installer did not exit within 40 minutes. Check Autodesk ODIS logs and whether installation is still running.'
    }
    $process.Refresh()
    $exitCode = [int]$process.ExitCode
    Write-Log "Installer exit code: $exitCode"

    if ($exitCode -notin @(0, 3010, 1641)) {
        throw "Autodesk installer failed with exit code $exitCode. Review Autodesk ODIS logs."
    }

    # Bootstrapper may finish before all child installation steps register.
    Write-Log 'Checking Windows installed-app registry for DWG TrueView 2027...'
    $installed = $null
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $installed = Get-TrueView2027
        if ($null -ne $installed) { break }
        Start-Sleep -Seconds 15
    }

    if ($null -eq $installed) {
        throw 'Installer completed, but DWG TrueView 2027 was not detected in the registry within 10 minutes. Check Autodesk ODIS logs.'
    }

    Write-Log "SUCCESS: $($installed.DisplayName) [$($installed.DisplayVersion)] is installed."
    if ($exitCode -in @(3010, 1641)) {
        Write-Log 'A restart may be required; no restart was initiated by this script.'
    }
    exit 0
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
    Write-Log "Log: $LogFile"
}
