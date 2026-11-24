#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Url = 'https://dds.autodesk.com/NetSWDLD/ODIS/prd/2027/NAVFREE/52AC45A2-3099-370C-8394-8B347967768B/SFX/Autodesk_Navisworks_Freedom_2027_Win_64bit_db.sfx.exe'
$LogDir = 'C:\ArkWorking'
$LogFile = Join-Path $LogDir 'NavisworksFreedom2027_Install.log'
$Stage = $null
# Reuse the retained download from the reported failure, if present.
# Set to an empty string for a fresh download.
$PreviousStage = 'C:\Program Files\Navisworks2027-Stage-6c4b5def238a452d97217df80407cae5'
$InstallerName = 'Autodesk_Navisworks_Freedom_2027_Win_64bit_db.sfx.exe'

function Write-Log ($Message) {
    $Line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $Line
    Add-Content -LiteralPath $LogFile -Value $Line
}

try {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    Write-Log 'Starting Navisworks Freedom 2027 deployment V3.'
    if (-not [Environment]::Is64BitProcess) { throw 'Select 64-bit PowerShell in NinjaOne.' }
    $Exe = Join-Path $env:ProgramFiles 'Autodesk\Navisworks Freedom 2027\roamer.exe'
    if (Test-Path -LiteralPath $Exe -PathType Leaf) { Write-Log 'SUCCESS: Already installed.'; exit 0 }
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator or SYSTEM permissions required.' }
    Write-Log "Running as: $($Identity.Name)"
    if ($PreviousStage -and (Test-Path -LiteralPath (Join-Path $PreviousStage $InstallerName) -PathType Leaf)) {
        $Stage = $PreviousStage
        $Installer = Join-Path $Stage $InstallerName
        Write-Log 'Reusing retained installer for verification.'
    }
    else {
        $Drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
        if ($Drive.Free -lt 20GB) { throw 'Less than 20 GB of free system-drive space.' }
        $Stage = Join-Path $env:ProgramFiles ('Navisworks2027-Stage-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $Stage -ItemType Directory -Force | Out-Null
        $Installer = Join-Path $Stage $InstallerName
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Log 'Downloading Autodesk installer...'
        Invoke-WebRequest -Uri $Url -OutFile $Installer -UseBasicParsing -TimeoutSec 3600
    }
    $File = Get-Item -LiteralPath $Installer
    Write-Log "Installer path: $Installer"
    Write-Log "File size (bytes): $($File.Length)"
    Write-Log "SHA256: $((Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash)"
    $Signature = Get-AuthenticodeSignature -LiteralPath $Installer
    Write-Log "Signature status: $($Signature.Status)"
    Write-Log "Signature message: $($Signature.StatusMessage)"
    $Publisher = ''
    if ($Signature.SignerCertificate) {
        $Cert = $Signature.SignerCertificate
        $Publisher = $Cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        Write-Log "Publisher: $Publisher"
        Write-Log "Subject: $($Cert.Subject)"
        Write-Log "Issuer: $($Cert.Issuer)"
        Write-Log "Thumbprint: $($Cert.Thumbprint)"
    }
    else { Write-Log 'No signer certificate returned.' }
    if ($Signature.Status -ne 'Valid') { throw "Windows signature verification failed: $($Signature.Status). $($Signature.StatusMessage)" }
    if ($Publisher -notmatch '^Autodesk,? Inc\.?$') { throw "Unexpected signer: $Publisher. Verify the publisher independently before proceeding." }
    $Drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    if ($Drive.Free -lt 10GB) { throw 'Less than 10 GB of free system-drive space remaining after download.' }
    Write-Log 'Signature verified. Starting silent installation...'
    $Process = Start-Process -FilePath $Installer -ArgumentList '-q' -WorkingDirectory $Stage -Wait -PassThru
    $Code = $Process.ExitCode
    Write-Log "Installer exit code: $Code"
    if ($Code -notin @(0, 3010, 1641)) { throw "Installation failed with exit code $Code." }
    if ($Code -eq 3010) { Write-Log 'WARNING: Restart required. Script will not restart the PC.' }
    if ($Code -eq 1641) { Write-Log 'WARNING: Installer reported a restart was initiated.' }
    $Deadline = (Get-Date).AddMinutes(15)
    while (-not (Test-Path -LiteralPath $Exe -PathType Leaf) -and (Get-Date) -lt $Deadline) { Start-Sleep -Seconds 15 }
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw 'Installer returned success, but roamer.exe was not found.' }
    Write-Log 'SUCCESS: Autodesk Navisworks Freedom 2027 executable detected.'
    if ($Stage -ne $PreviousStage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Log 'Retained previous staging folder for manual cleanup.' }
    exit 0
}
catch {
    $Message = $_.Exception.Message
    Write-Host "ERROR: $Message"
    Add-Content -LiteralPath $LogFile -Value "ERROR: $Message" -ErrorAction SilentlyContinue
    Write-Host "Staging directory: $Stage"
    Write-Host "Autodesk ODIS logs: $env:LOCALAPPDATA\Autodesk\ODIS"
    exit 1
}
