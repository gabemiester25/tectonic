# NinjaOne - Install Microsoft Power BI Desktop (64-bit)
# Run as SYSTEM in 64-bit Windows PowerShell 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Url = 'https://download.microsoft.com/download/8/8/0/880bca75-79dd-466a-927d-1abf1f5454b0/PBIDesktopSetup_x64.exe'
$ProgramFiles64 = $env:ProgramW6432
if (-not $ProgramFiles64) { $ProgramFiles64 = $env:ProgramFiles }
$AppPath = Join-Path $ProgramFiles64 'Microsoft Power BI Desktop\bin\PBIDesktop.exe'
$Stage = Join-Path $ProgramFiles64 ('PowerBI-Stage-' + [guid]::NewGuid().ToString('N'))
$Installer = Join-Path $Stage 'PBIDesktopSetup_x64.exe'
$LogDir = Join-Path $env:ProgramData 'PowerBI-Deployment'
$LogPath = Join-Path $LogDir ('Install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$Result = 1

try {
    Write-Output 'Starting Power BI Desktop deployment...'
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'A 64-bit Windows operating system is required.'
    }

    if (Test-Path -LiteralPath $AppPath -PathType Leaf) {
        $Version = (Get-Item -LiteralPath $AppPath).VersionInfo.ProductVersion
        Write-Output "SUCCESS: Power BI Desktop is already installed. Version: $Version"
        exit 0
    }

    New-Item -Path $Stage, $LogDir -ItemType Directory -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Output 'Downloading Power BI Desktop from Microsoft...'
    Invoke-WebRequest -Uri $Url -OutFile $Installer -UseBasicParsing -TimeoutSec 1800

    Write-Output 'Validating Microsoft digital signature...'
    $Signature = Get-AuthenticodeSignature -FilePath $Installer
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Installer signature validation failed. Status: $($Signature.Status). Details: $($Signature.StatusMessage)"
    }
    Write-Output "Verified signer: $($Signature.SignerCertificate.Subject)"

    Write-Output 'Installing Power BI Desktop silently...'
    $Arguments = '-quiet -norestart ACCEPT_EULA=1 INSTALLDESKTOPSHORTCUT=1 -log "{0}"' -f $LogPath
    $Process = Start-Process -FilePath $Installer -ArgumentList $Arguments -Wait -PassThru
    $Code = $Process.ExitCode
    Write-Output "Installer exit code: $Code"

    if ($Code -notin @(0, 3010, 1641)) {
        throw "Power BI Desktop installer failed with exit code $Code."
    }
    if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
        throw 'Installer returned success, but the expected application executable was not found.'
    }

    $Version = (Get-Item -LiteralPath $AppPath).VersionInfo.ProductVersion
    Write-Output "SUCCESS: Power BI Desktop installed. Version: $Version"
    if ($Code -in @(3010, 1641)) {
        Write-Output 'WARNING: Installer reported a restart requirement or initiation.'
    }
    $Result = 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $Stage) {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $LogPath) {
        Write-Output "Installation log: $LogPath"
    }
}
exit $Result
