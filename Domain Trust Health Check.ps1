$ErrorActionPreference = "Stop"

Write-Output "======================================"
Write-Output "   DOMAIN TRUST HEALTH CHECK"
Write-Output "======================================"
Write-Output "Computer: $env:COMPUTERNAME"
Write-Output "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output ""

try {
    # Get computer domain information
    $Computer = Get-CimInstance Win32_ComputerSystem

    if (-not $Computer.PartOfDomain) {
        Write-Output "[INFO] Computer is not domain joined."
        Write-Output "[RESULT] NOT DOMAIN JOINED"
        exit 2
    }

    $Domain = $Computer.Domain

    Write-Output "[INFO] Domain: $Domain"
    Write-Output "[INFO] Domain membership detected."

    # Domain Controllers require a different check
    if ($Computer.DomainRole -ge 4) {
        Write-Output "[INFO] This computer is a Domain Controller."
        Write-Output "[RESULT] NOT APPLICABLE"
        exit 2
    }

    # Verify Domain Controller discovery
    Write-Output ""
    Write-Output "[CHECK] Locating Domain Controller..."

    $DCOutput = & nltest.exe "/dsgetdc:$Domain" "/force" 2>&1 | Out-String
    $DCExitCode = $LASTEXITCODE

    if ($DCExitCode -ne 0) {
        Write-Output "[WARNING] Unable to locate Domain Controller."
        Write-Output "[INFO] Check network, VPN and DNS."
        Write-Output "[RESULT] UNKNOWN - DC UNREACHABLE"
        exit 3
    }

    Write-Output "[PASS] Domain Controller discovered."

    # Check secure channel
    Write-Output ""
    Write-Output "[CHECK] Testing domain secure channel..."

    $TrustStatus = Test-ComputerSecureChannel -ErrorAction Stop

    if ($TrustStatus -eq $true) {
        Write-Output ""
        Write-Output "[PASS] Domain secure channel is healthy."
        Write-Output "[RESULT] DOMAIN TRUST HEALTHY"
        exit 0
    }
    else {
        Write-Output ""
        Write-Output "[FAIL] Domain secure channel test failed."
        Write-Output "[RESULT] DOMAIN TRUST BROKEN"
        Write-Output "[ACTION] Investigate before repairing."
        exit 1
    }
}
catch {
    Write-Output ""
    Write-Output "[ERROR] Domain trust check failed."
    Write-Output "[DETAILS] $($_.Exception.Message)"
    Write-Output "[RESULT] UNKNOWN"
    exit 3
}
