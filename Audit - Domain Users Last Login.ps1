#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$InactiveDays = 90
$DaysBack = 365
$MeasureSize = $true
$Now = Get-Date
$Cutoff = $Now.AddDays(-$InactiveDays)
$Computer = Get-CimInstance Win32_ComputerSystem
Write-Host "PROFILE AUDIT V3 | $env:COMPUTERNAME | Domain/workgroup: $($Computer.Domain) | Threshold: $InactiveDays days"
if ($Computer.DomainRole -ge 4) { throw 'Do not run this audit on a domain controller.' }
$Local = Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object { $_.SID -match '^S-1-5-21-\d+-\d+-\d+-500$' } | Select-Object -First 1
if (-not $Local) { throw 'Cannot identify local account SID prefix safely.' }
$Prefix = $Local.SID -replace '-500$', ''
$Profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -and $_.SID -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and -not $_.SID.StartsWith($Prefix + '-') })
$Index = @{}; $SignIns = @{}; $Activity = @{}; $Names = @{}
foreach ($P in $Profiles) { $Index[$P.SID] = $true }
$HistoryOK = $false
$Oldest = $null
$Milliseconds = [int64]([timespan]::FromDays($DaysBack).TotalMilliseconds)
$Query = "*[System[EventID=4624 and TimeCreated[timediff(@SystemTime) <= $Milliseconds]] and EventData[Data[@Name='LogonType']='2' or Data[@Name='LogonType']='7' or Data[@Name='LogonType']='10' or Data[@Name='LogonType']='11' or Data[@Name='LogonType']='12' or Data[@Name='LogonType']='13']]"
try {
    $Oldest = (Get-WinEvent -LogName Security -Oldest -MaxEvents 1).TimeCreated
    Write-Host "Oldest retained Security event: $Oldest"
    Get-WinEvent -LogName Security -FilterXPath $Query | ForEach-Object {
        $Event = $_; $Fields = @{}; $Xml = [xml]$Event.ToXml()
        foreach ($Node in $Xml.Event.EventData.Data) { $Fields[$Node.GetAttribute('Name')] = $Node.InnerText }
        $Sid = $Fields['TargetUserSid']; $Time = $Event.TimeCreated
        if ($Sid -and $Index.ContainsKey($Sid) -and $Time) {
            if (-not $Activity.ContainsKey($Sid) -or $Time -gt $Activity[$Sid]) { $Activity[$Sid] = $Time; $Names[$Sid] = "$($Fields['TargetDomainName'])\$($Fields['TargetUserName'])" }
            if ($Fields['LogonType'] -in @('2','10','11','12') -and (-not $SignIns.ContainsKey($Sid) -or $Time -gt $SignIns[$Sid])) { $SignIns[$Sid] = $Time }
        }
    }
    $HistoryOK = [bool]($Oldest -and $Oldest -le $Cutoff -and $DaysBack -ge $InactiveDays)
} catch { Write-Warning "Security history unavailable or incomplete: $($_.Exception.Message)" }
if (-not $HistoryOK) { Write-Warning 'Incomplete sign-in history; no cleanup candidates will be flagged.' }
$Rows = @()
foreach ($P in $Profiles) {
    $Sid = $P.SID; $Name = "$($P.LocalPath) (unresolved SID)"; $Resolved = $false
    if ($Names.ContainsKey($Sid)) { $Name = $Names[$Sid] + ' (historical)' }
    try { $Name = ([Security.Principal.SecurityIdentifier]::new($Sid)).Translate([Security.Principal.NTAccount]).Value; $Resolved = $true } catch { }
    $Login = $SignIns[$Sid]; $LastActivity = $Activity[$Sid]; $Use = $P.LastUseTime
    if ($Use -isnot [datetime] -or $Use.Year -lt 2000) { $Use = $null }
    $LoginText = 'Unknown'; $UseText = 'Unknown'; $Days = 'Unknown'; $ActivityText = 'Unknown'
    if ($Login) { $LoginText = $Login.ToString('yyyy-MM-dd HH:mm:ss'); $Days = [math]::Max(0,[math]::Floor(($Now - $Login).TotalDays)) }
    if ($Use) { $UseText = $Use.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($LastActivity) { $ActivityText = $LastActivity.ToString('yyyy-MM-dd HH:mm:ss') }
    $Loaded = [bool]($P.Loaded -or $P.RefCount -gt 0); $Status = 'REVIEW - insufficient evidence'
    if ($Loaded) { $Status = 'KEEP - loaded' }
    elseif (($LastActivity -and $LastActivity -gt $Cutoff) -or ($Use -and $Use -gt $Cutoff)) { $Status = 'KEEP - recent activity' }
    elseif ($HistoryOK -and $Resolved -and $Login -and $Use -and $Login -le $Cutoff -and $Use -le $Cutoff) { $Status = 'CANDIDATE - verify first' }
    elseif ($Use -and $Use -le $Cutoff) { $Status = 'REVIEW - old profile use' }
    $Size = $null; $SizeNote = 'Not measured'; $Bytes = [long]0; $Skipped = 0
    if ($MeasureSize) {
        Write-Host "Measuring $($P.LocalPath)"
        $Root = Get-Item -LiteralPath $P.LocalPath -Force -ErrorAction SilentlyContinue
        if ($Root -and $Root.PSIsContainer -and -not ($Root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $Stack = New-Object 'System.Collections.Generic.Stack[string]'; $Stack.Push($Root.FullName)
            while ($Stack.Count -gt 0) {
                $ReadErrors = @(); $Items = Get-ChildItem -LiteralPath ($Stack.Pop()) -Force -ErrorAction SilentlyContinue -ErrorVariable ReadErrors
                $Skipped += @($ReadErrors).Count
                foreach ($Item in $Items) {
                    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($Item.Attributes -band [IO.FileAttributes]::Offline)) { $Skipped++; continue }
                    if ($Item.PSIsContainer) { $Stack.Push($Item.FullName) } else { $Bytes += [long]$Item.Length }
                }
            }
            $Size = [math]::Round($Bytes / 1GB,2); $SizeNote = "Logical GiB; skipped entries/errors: $Skipped"
        } else { $SizeNote = 'Missing, inaccessible or reparse-point root' }
    }
    $Rows += [pscustomobject]@{ User=$Name; LastSignIn=$LoginText; DaysSinceLogin=$Days; LastProfileUse=$UseText; LastSignInOrUnlock=$ActivityText; SizeGiB=$Size; Loaded=$Loaded; Status=$Status; Path=$P.LocalPath; SID=$Sid; SizeNote=$SizeNote }
}
$Rows = @($Rows | Sort-Object SizeGiB -Descending)
$Rows | Format-Table User,LastSignIn,DaysSinceLogin,LastProfileUse,SizeGiB,Loaded,Status -AutoSize | Out-String -Width 300 | Write-Host
$Rows | Format-List User,Path,SID,LastSignInOrUnlock,SizeNote | Out-String -Width 300 | Write-Host
$Candidates = @($Rows | Where-Object { $_.Status -like 'CANDIDATE*' })
Write-Host "Profiles: $($Rows.Count) | Cleanup review candidates: $($Candidates.Count) | Measured candidate GiB: $(($Candidates | Measure-Object SizeGiB -Sum).Sum)"
Write-Host 'Unknown sign-in is not proof of inactivity. Sizes are estimates. Verify backups and profile ownership before cleanup.'
Write-Host 'AUDIT COMPLETE - V3 - NO PROFILES DELETED'
exit 0
