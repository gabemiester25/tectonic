[CmdletBinding()]
param(
    [string]$DownloadUrl = 'https://bluebeam.com/MSIdeployx64',
    [string]$PackagePath = '',
    [switch]$SkipOCR
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WorkDir = Join-Path $env:ProgramData 'NinjaOne\BluebeamRevu21'
$ZipFile = Join-Path $WorkDir 'BluebeamRevu21Deployment.zip'
$ExtractDir = Join-Path $WorkDir 'Extracted'
$LogFile = Join-Path $WorkDir 'Install-BluebeamRevu21.log'
$RevuMsiLog = Join-Path $WorkDir 'BluebeamRevu21-MSI.log'
$OCRLog = Join-Path $WorkDir 'BluebeamOCR-MSI.log'
$ExitCode = 1
$RebootRequired = $false

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Get-RevuInstalled {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^Bluebeam Revu(?:\s|$)' -and $_.DisplayVersion })
}

function Convert-ToVersion {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '^\s*(\d+(?:\.\d+){0,3})') {
        throw "Invalid Bluebeam version: '$Value'"
    }
    $parts = @($Matches[1].Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]($parts -join '.')
}

function Get-MsiProductVersion {
    param([Parameter(Mandatory)][string]$Path)
    # Reads the MSI's own ProductVersion, so an older package cannot downgrade Revu.
    $wi = $null
    $db = $null
    $view = $null
    $record = $null
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db,
            @("SELECT Value FROM Property WHERE Property = 'ProductVersion'"))
        $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, @())
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, @())
        if ($null -eq $record) { throw 'ProductVersion is missing from the MSI.' }
        return [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
    }
    finally {
        if ($view) {
            try { $null = $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, @()) }
            catch { }
        }
        foreach ($obj in @($record, $view, $db, $wi)) {
            if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj)
            }
        }
    }
}

function Assert-BluebeamSignature {
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate -or
        $sig.SignerCertificate.Subject -notmatch 'Bluebeam') {
        throw "Installer signature verification failed for '$Path' (status: $($sig.Status))."
    }
}

function Invoke-MsiInstall {
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        [Parameter(Mandatory)][string]$MsiLog
    )
    $args = '/i "{0}" /qn /norestart REBOOT=ReallySuppress IGNORE_RBT=1 /L*v "{1}"' -f $MsiPath, $MsiLog
    Write-Log "Installing MSI: $([IO.Path]::GetFileName($MsiPath))"
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
        -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    Write-Log "Windows Installer exit code: $($p.ExitCode)"
    if ($p.ExitCode -notin @(0, 3010)) {
        throw "MSI failed (exit code $($p.ExitCode)); see $MsiLog"
    }
    if ($p.ExitCode -eq 3010) { $script:RebootRequired = $true }
}

try {
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    Write-Log 'Starting Bluebeam Revu 21 deployment via NinjaOne.'

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Bluebeam Revu 21 requires 64-bit Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as SYSTEM or an elevated administrator.'
    }
    if (Get-Process -Name 'Revu' -ErrorAction SilentlyContinue) {
        throw 'Bluebeam Revu is running. Ask the user to save their work and close it before retrying.'
    }

    $existing = @(Get-RevuInstalled)
    foreach ($app in $existing) {
        $v = Convert-ToVersion -Value $app.DisplayVersion
        Write-Log "Detected: $($app.DisplayName) version $($app.DisplayVersion)"
        if ($v.Major -lt 21) {
            throw 'Revu 20 or older was detected. Stopping to protect the existing perpetual license. Plan this migration separately.'
        }
    }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (Test-Path -LiteralPath $ExtractDir) {
        Remove-Item -LiteralPath $ExtractDir -Force -Recurse
    }
    New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null

    if ($PackagePath) {
        if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
            throw "Local package not found: $PackagePath"
        }
        Write-Log "Using local deployment archive: $PackagePath"
        Copy-Item -LiteralPath $PackagePath -Destination $ZipFile -Force
    }
    else {
        Write-Log "Downloading Bluebeam's official Revu 21 deployment package: $DownloadUrl"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipFile -UseBasicParsing -TimeoutSec 3600
    }

    if ((Get-Item -LiteralPath $ZipFile).Length -lt 1MB) {
        throw 'Downloaded package is unexpectedly small. The link may have returned an error page.'
    }
    $header = New-Object byte[] 4
    $stream = [IO.File]::OpenRead($ZipFile)
    try { $bytesRead = $stream.Read($header, 0, 4) }
    finally { $stream.Dispose() }
    if ($bytesRead -ne 4 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) {
        throw 'The download is not a ZIP archive. Check the Bluebeam download link or use -PackagePath.'
    }
    Write-Log 'Extracting the enterprise deployment ZIP...'
    Expand-Archive -LiteralPath $ZipFile -DestinationPath $ExtractDir -Force

    $revuMsi = @(Get-ChildItem -LiteralPath $ExtractDir -File -Recurse -Filter '*.msi' |
        Where-Object { $_.Name -match 'Bluebeam\s*Revu' -and $_.Name -notmatch 'OCR' })
    if ($revuMsi.Count -ne 1) {
        throw "Expected exactly one Revu MSI in the deployment package; found $($revuMsi.Count)."
    }
    Assert-BluebeamSignature -Path $revuMsi[0].FullName
    $packageVersion = Convert-ToVersion -Value (Get-MsiProductVersion -Path $revuMsi[0].FullName)
    if ($packageVersion.Major -ne 21) {
        throw "Unexpected package version $packageVersion; this installer only handles Revu 21."
    }
    Write-Log "Deployment package Revu version: $packageVersion"

    $installed21 = @($existing | Where-Object { (Convert-ToVersion -Value $_.DisplayVersion).Major -eq 21 })
    $shouldInstallRevu = $true
    if ($installed21.Count -gt 0) {
        $highest = @($installed21 | ForEach-Object { Convert-ToVersion -Value $_.DisplayVersion } |
            Sort-Object -Descending)[0]
        if ($highest -ge $packageVersion) {
            Write-Log "Revu $highest is already the same version or newer. Skipping the Revu MSI."
            $shouldInstallRevu = $false
        }
    }
    if ($shouldInstallRevu) {
        Invoke-MsiInstall -MsiPath $revuMsi[0].FullName -MsiLog $RevuMsiLog
    }

    if (-not $SkipOCR) {
        $ocrExisting = @(Get-ItemProperty -Path @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^Bluebeam.*OCR' })
        if ($ocrExisting.Count -gt 0) {
            Write-Log 'Bluebeam OCR already installed; skipping OCR MSI.'
        }
        else {
            $ocrMsi = @(Get-ChildItem -LiteralPath $ExtractDir -File -Recurse -Filter '*.msi' |
                Where-Object { $_.Name -match 'Bluebeam.*OCR' })
            if ($ocrMsi.Count -eq 1) {
                Assert-BluebeamSignature -Path $ocrMsi[0].FullName
                Invoke-MsiInstall -MsiPath $ocrMsi[0].FullName -MsiLog $OCRLog
            }
            elseif ($ocrMsi.Count -eq 0) {
                Write-Log 'No OCR MSI in the package; OCR-specific features may be unavailable.'
            }
            else {
                throw 'Multiple OCR MSIs found; cannot safely choose one.'
            }
        }
    }

    Start-Sleep -Seconds 5
    $after = @(Get-RevuInstalled | Where-Object {
        (Convert-ToVersion -Value $_.DisplayVersion).Major -eq 21
    })
    $verified = @($after | Where-Object {
        (Convert-ToVersion -Value $_.DisplayVersion) -ge $packageVersion
    })
    if ($verified.Count -eq 0) {
        throw "Revu 21 version $packageVersion (or newer) was not detected after installation."
    }
    Write-Log "SUCCESS: Revu 21 version $($verified[0].DisplayVersion) is installed."
    if ($RebootRequired) { Write-Log 'Reboot required: the installer returned 3010. No automatic reboot was initiated.' }
    $ExitCode = 0
}
catch {
    $message = "FAILED: $($_.Exception.Message)"
    Write-Warning $message
    if (Test-Path -LiteralPath $WorkDir) {
        try { Write-Log $message } catch { }
    }
    $ExitCode = 1
}
finally {
    # Keep MSI and deployment logs for diagnosis. Remove only the working files.
    if (Test-Path -LiteralPath $ExtractDir) {
        Remove-Item -LiteralPath $ExtractDir -Force -Recurse -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $ZipFile) {
        Remove-Item -LiteralPath $ZipFile -Force -ErrorAction SilentlyContinue
    }
}
exit $ExitCode
