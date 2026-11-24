$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '1.4.1.1032'
$Architecture = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
$DownloadUrl = "https://www.voidtools.com/Everything-$Version.$Architecture.msi"
$WorkDir = Join-Path $env:ProgramData 'NinjaOne\Everything'
$InstallerPath = Join-Path $WorkDir "Everything-$Version.$Architecture.msi"
$LogPath = Join-Path $WorkDir 'Install-Everything.log'
$MsiLogPath = Join-Path $WorkDir 'Everything-MSI.log'

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $Line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $Line
    Add-Content -Path $LogPath -Value $Line -Encoding UTF8
}

function Test-EverythingInstalled {
    $RegistryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($RegistryPath in $RegistryPaths) {
        $Apps = @(Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue)
        foreach ($App in $Apps) {
            if ($App.DisplayName -and $App.DisplayName -match '^Everything(?:\s+(?:\d|Search).*)?$') {
                Write-Log "Existing installation detected: $($App.DisplayName) $($App.DisplayVersion)"
                return $true
            }
        }
    }

    $ExePaths = @(
        "${env:ProgramFiles}\Everything\Everything.exe",
        "${env:ProgramFiles}\Everything\Everything64.exe",
        "${env:ProgramFiles(x86)}\Everything\Everything.exe",
        "${env:ProgramFiles(x86)}\Everything\Everything64.exe",
        "${env:ProgramFiles}\Everything-1.5a\Everything.exe"
    )
    foreach ($ExePath in $ExePaths) {
        if (Test-Path -LiteralPath $ExePath) {
            Write-Log "Existing installation detected: $ExePath"
            return $true
        }
    }
    return $false
}

try {
    Write-Log '======================================'
    Write-Log 'NinjaOne - Everything Silent Installer'
    Write-Log "Computer: $env:COMPUTERNAME"
    Write-Log "Target version: $Version ($Architecture)"
    Write-Log '======================================'

    if (Test-EverythingInstalled) {
        Write-Log 'SUCCESS: Everything is already installed. No changes made.'
        exit 0
    }

    # TLS 1.2 is required by many HTTPS download servers.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Log "Downloading official installer: $DownloadUrl"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath -UseBasicParsing -ErrorAction Stop

    $DownloadedFile = Get-Item -LiteralPath $InstallerPath -ErrorAction Stop
    if ($DownloadedFile.Length -lt 100KB) {
        throw "Downloaded MSI is unexpectedly small: $($DownloadedFile.Length) bytes."
    }
    Write-Log "Download completed ($($DownloadedFile.Length) bytes)."

    # MSI logging is separate from the general NinjaOne script log.
    $MsiArguments = @(
        '/i',
        ('"{0}"' -f $InstallerPath),
        '/qn',
        '/norestart',
        'REBOOT=ReallySuppress',
        'EVERYTHING_SERVICE=1',
        'START_ON_STARTUP=1',
        'START_MENU_SHORTCUT=1',
        'DESKTOP_SHORTCUT=0',
        '/L*v',
        ('"{0}"' -f $MsiLogPath)
    )

    Write-Log 'Starting silent, all-users MSI installation.'
    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $MsiArguments -Wait -PassThru -WindowStyle Hidden
    Write-Log "MSI exit code: $($Process.ExitCode)"

    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "MSI installation failed with exit code $($Process.ExitCode). See: $MsiLogPath"
    }

    if (-not (Test-EverythingInstalled)) {
        throw 'MSI returned success, but Everything was not detected afterward.'
    }

    if ($Process.ExitCode -eq 3010) {
        Write-Log 'SUCCESS: Everything installed. A reboot may be required; none was initiated.'
    }
    else {
        Write-Log 'SUCCESS: Everything installed and verified. No reboot initiated.'
    }
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    if (Test-Path -LiteralPath $InstallerPath) {
        Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction SilentlyContinue
    }
}
