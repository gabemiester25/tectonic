$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$url = 'https://up.autodesk.com/2017/CDX/AB4AADCC-F890-4B4F-A7A6-B0FBD2386796/DesktopConnector-x64.exe'
$dir = Join-Path $env:ProgramData 'Autodesk\DesktopConnectorZeroTouch'
$exe = Join-Path $dir 'DesktopConnector-x64.exe'
$log = Join-Path $dir 'Install.log'

function Write-Log([string]$message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Write-Output $line
    Add-Content -LiteralPath $log -Value $line
}
function Get-DC {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^(Autodesk )?Desktop Connector(\s|$)' }
}

try {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Write-Log 'Starting Autodesk Desktop Connector deployment.'

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw '64-bit Windows is required.'
    }
    if (Get-DC) {
        Write-Log 'Desktop Connector already installed; skipping.'
        exit 0
    }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $valid = $false
    if (Test-Path -LiteralPath $exe) {
        $sig = Get-AuthenticodeSignature -FilePath $exe
        $valid = ($sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate -and
                  $sig.SignerCertificate.Subject -match 'Autodesk')
    }
    if (-not $valid) {
        Write-Log 'Downloading EXE from Autodesk...'
        $tmp = Join-Path $dir 'DesktopConnector-x64.download'
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 1800
        $sig = Get-AuthenticodeSignature -FilePath $tmp
        if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate -or
            $sig.SignerCertificate.Subject -notmatch 'Autodesk') {
            throw 'Installer download has an invalid or unexpected digital signature.'
        }
        Move-Item -LiteralPath $tmp -Destination $exe -Force
    }

    Write-Log 'Starting silent install (DesktopConnector-x64.exe -q)...'
    $p = Start-Process -FilePath $exe -ArgumentList '-q' -WorkingDirectory $dir -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(2700000)) {
        throw 'Installer has not exited after 45 minutes; check Autodesk installer logs.'
    }
    $p.Refresh()
    Write-Log "Installer exit code: $($p.ExitCode)"
    if ($p.ExitCode -notin @(0, 3010, 1641)) {
        throw "Autodesk installer failed with exit code $($p.ExitCode)."
    }

    # Some Autodesk launchers exit before their child setup finishes.
    $installed = $false
    for ($i = 0; $i -lt 40; $i++) {
        if (Get-DC) { $installed = $true; break }
        Start-Sleep -Seconds 15
    }
    if (-not $installed) {
        throw 'Installer exited, but Desktop Connector is not yet registered as installed.'
    }
    Write-Log 'SUCCESS: Desktop Connector installed.'
    if ($p.ExitCode -in @(3010, 1641)) { Write-Log 'A reboot may be required.' }
    exit 0
}
catch {
    $msg = $_.Exception.Message
    Write-Output "FAILED: $msg"
    if (Test-Path -LiteralPath $dir) {
        Add-Content -LiteralPath $log -Value "FAILED: $msg"
    }
    exit 1
}
