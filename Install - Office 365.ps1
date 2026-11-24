$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------- CONFIGURATION ----------------
$OfficeProductId = 'O365ProPlusRetail' # Enterprise license. For Business Standard/Premium, use 'O365BusinessRetail'.
$OfficeBitness   = '64'                # '64' or '32'
$OfficeLanguage  = 'en-us'             # e.g. 'en-us' or 'fr-ca'
$UpdateChannel   = 'MonthlyEnterprise' # 'Current' or 'MonthlyEnterprise'
$SkipIfInstalled = $true

$BaseDir = Join-Path $env:ProgramData 'Microsoft365Deployment'
$WorkDir = Join-Path $BaseDir 'Work'
$LogFile = Join-Path $BaseDir 'Install-M365-NinjaOne.log'
$SetupFile = Join-Path $WorkDir 'setup.exe'
$ConfigFile = Join-Path $WorkDir 'configuration.xml'
$OdtDownloadUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
# ------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string] $Message,
        [ValidateSet('INFO','WARN','ERROR')][string] $Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-OfficeConfiguration {
    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
}

function Test-M365Installed {
    $officeConfig = Get-OfficeConfiguration
    if (-not $officeConfig) { return $false }
    $productIds = [string]$officeConfig.ProductReleaseIds
    return ($productIds -match '(^|,)\s*O365(ProPlus|Business)Retail\s*(,|$)')
}

try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    Write-Log 'Starting Microsoft 365 Apps deployment using NinjaOne.'

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'A supported 64-bit Windows operating system is required for this deployment.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run this NinjaOne script in 64-bit PowerShell so Office registry detection works correctly.'
    }

    if (Test-M365Installed) {
        $installed = Get-OfficeConfiguration
        Write-Log ("Microsoft 365 Apps already installed. ProductReleaseIds: {0}; Version: {1}" -f $installed.ProductReleaseIds, $installed.VersionToReport)
        if ($SkipIfInstalled) {
            Write-Log 'Nothing to do. Skipping installation.'
            exit 0
        }
    }

    $existing = Get-OfficeConfiguration
    if ($existing) {
        $installedPlatform = ([string]$existing.Platform).ToLowerInvariant()
        Write-Log ("Existing Click-to-Run configuration: {0}; platform: {1}" -f $existing.ProductReleaseIds, $installedPlatform)
        if (($installedPlatform -eq 'x86' -and $OfficeBitness -eq '64') -or
            ($installedPlatform -eq 'x64' -and $OfficeBitness -eq '32')) {
            throw "Office bitness conflict: existing Click-to-Run is $installedPlatform, requested Office is $OfficeBitness-bit. No products were removed."
        }
    }

    # Windows PowerShell 5.1 defaults can lack TLS 1.2 on older systems.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Log "Downloading Microsoft Office Deployment Tool: $OdtDownloadUrl"
    $downloadSucceeded = $false
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $OdtDownloadUrl -OutFile $SetupFile -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
            if ((Get-Item -LiteralPath $SetupFile).Length -lt 100KB) {
                throw 'Downloaded ODT file appears incomplete.'
            }
            $downloadSucceeded = $true
            break
        }
        catch {
            Write-Log ("ODT download attempt {0}/3 failed: {1}" -f $i, $_.Exception.Message) 'WARN'
            if ($i -lt 3) { Start-Sleep -Seconds (5 * $i) }
        }
    }
    if (-not $downloadSucceeded) {
        throw 'Unable to download ODT after three attempts. Confirm access to officecdn.microsoft.com.'
    }

    $signature = Get-AuthenticodeSignature -FilePath $SetupFile
    if ($signature.Status -ne 'Valid' -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Downloaded ODT did not pass Microsoft signature validation. Signature status: $($signature.Status)"
    }
    Write-Log 'ODT downloaded and Microsoft signature verified.'

    # With no SourcePath, /configure downloads needed Office content from Microsoft CDN.
    # Deliberately omit RemoveMSI and FORCEAPPSHUTDOWN=TRUE to avoid disrupting users.
    $configXml = @"
<Configuration>
  <Add OfficeClientEdition="$OfficeBitness" Channel="$UpdateChannel">
    <Product ID="$OfficeProductId">
      <Language ID="$OfficeLanguage" />
    </Product>
  </Add>
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
</Configuration>
"@
    Set-Content -LiteralPath $ConfigFile -Value $configXml -Encoding UTF8
    Write-Log ("Installing product={0}, bitness={1}, language={2}, channel={3}." -f $OfficeProductId, $OfficeBitness, $OfficeLanguage, $UpdateChannel)
    Write-Log 'Do not interrupt NinjaOne while Microsoft 365 Apps downloads and installs.'

    $installProcess = Start-Process -FilePath $SetupFile `
        -ArgumentList ('/configure "{0}"' -f $ConfigFile) `
        -WorkingDirectory $WorkDir -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop

    Write-Log ("Office Deployment Tool exited with code {0}." -f $installProcess.ExitCode)
    if ($installProcess.ExitCode -notin @(0, 3010)) {
        throw "Office Deployment Tool failed with exit code $($installProcess.ExitCode). Check ODT logs in $env:TEMP."
    }

    # Verify the registered Microsoft 365 Apps product rather than trusting the exit code alone.
    $verified = $false
    for ($j = 1; $j -le 12; $j++) {
        if (Test-M365Installed) {
            $verified = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $verified) {
        throw "Office setup returned success but Microsoft 365 Apps was not detected in the Click-to-Run registry. Review ODT logs in $env:TEMP."
    }

    $installed = Get-OfficeConfiguration
    Write-Log ("SUCCESS: Microsoft 365 Apps installed. ProductReleaseIds: {0}; Version: {1}" -f $installed.ProductReleaseIds, $installed.VersionToReport)
    if ($installProcess.ExitCode -eq 3010) {
        Write-Log 'A reboot is required to finish the installation, but this script will NOT reboot the device.' 'WARN'
    }
    Write-Log "Deployment complete. Log file: $LogFile"
    exit 0
}
catch {
    Write-Log ("FAILED: {0}" -f $_.Exception.Message) 'ERROR'
    Write-Log "Review $LogFile and the Office setup logs under $env:TEMP." 'ERROR'
    exit 1
}
