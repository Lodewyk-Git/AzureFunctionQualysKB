<#
    Title:          Qualys KnowledgeBase (KB) Data Connector
    Language:       PowerShell
    Version:        2.0
    Author:         BUI Engineering - Lodewyk
    Last Modified:  2026-03-10
    Comment:        Rebuilt for Azure Monitor Logs Ingestion API (DCR/DCE)

    DESCRIPTION
    This Function App calls the Qualys VM KnowledgeBase (KB) API to pull vulnerability
    data and ingests it into a Log Analytics custom table via the Azure Monitor Logs
    Ingestion API using Data Collection Rules (DCRs) and Managed Identity authentication.
#>

param($Timer)

# Import helper module
Import-Module "$PSScriptRoot\..\modules\QualysKBHelpers.psm1" -Force

$currentUTCtime = (Get-Date).ToUniversalTime()

if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# ─── Configuration ───────────────────────────────────────────────────────────────
$qualysUri              = $env:qualysUri
$username               = $env:apiUsername
$password               = $env:apiPassword
$filterParameters       = $env:filterParameters
$dceEndpoint            = $env:dceEndpoint
$dcrImmutableId         = $env:dcrImmutableId
$dcrStreamName          = $env:dcrStreamName
$checkpointContainer    = $env:checkpointContainerName
$storageConnectionStr   = $env:AzureWebJobsStorage
$timeInterval           = 5

# Parse time interval
$parsedInterval = 0
if ([int]::TryParse($env:timeInterval, [ref]$parsedInterval) -and $parsedInterval -gt 0) {
    $timeInterval = $parsedInterval
}

# ─── Input Validation ────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
    throw "Qualys KB: Missing required app settings 'apiUsername' or 'apiPassword'."
}

if ([string]::IsNullOrWhiteSpace($dceEndpoint) -or [string]::IsNullOrWhiteSpace($dcrImmutableId) -or [string]::IsNullOrWhiteSpace($dcrStreamName)) {
    throw "Qualys KB: Missing required Logs Ingestion settings 'dceEndpoint', 'dcrImmutableId', or 'dcrStreamName'."
}

if (-not (Test-QualysUri -Uri $qualysUri)) {
    throw "Qualys KB: Invalid Qualys API URI format: $qualysUri"
}

# Normalize filter parameters
$filterParameters = Normalize-KBFilterParameters -RawFilterParameters $filterParameters

# ─── Checkpoint: Read ─────────────────────────────────────────────────────────────
$endTime = [datetime]::UtcNow
$startDate = Get-CheckpointFromBlob -StorageConnectionString $storageConnectionStr `
    -ContainerName $checkpointContainer -DefaultLookbackMinutes $timeInterval

# ─── Qualys API: Login ────────────────────────────────────────────────────────────
$hdrs = @{ "X-Requested-With" = "powershell" }
$base = "$qualysUri/fo"
$loginBody = @{
    action   = "login"
    username = $username
    password = $password
}

try {
    Invoke-RestMethod -Headers $hdrs -Uri "$base/session/" -Method Post -Body $loginBody `
        -ContentType "application/x-www-form-urlencoded" -SessionVariable qualysSession -ErrorAction Stop
}
catch {
    $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "N/A" }
    Write-Error "Qualys KB: Login failed (Status: $statusCode). $($_.Exception.Message)"
    throw
}

try {
    # ─── Qualys API: Fetch KB Data ────────────────────────────────────────────────
    Write-Host "Start Time: $startDate"
    Write-Host "UTC Current Time: $($endTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

    $requestUri = "$base/knowledge_base/vuln/?action=list&published_after=$($startDate)$filterParameters"
    Write-Host "Request URI: $requestUri"

    $response = try {
        Invoke-RestMethod -Headers $hdrs -Uri $requestUri -WebSession $qualysSession -ErrorAction Stop
    }
    catch {
        $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "N/A" }
        Write-Error "Qualys KB: API call failed (Status: $statusCode). $($_.Exception.Message)"
        throw
    }

    # ─── Process Response ─────────────────────────────────────────────────────────
    $vulnList = $response.KNOWLEDGE_BASE_VULN_LIST_OUTPUT.RESPONSE.VULN_LIST.VULN
    $endInterval = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

    if ($null -eq $vulnList) {
        Write-Host "INFO: No new Qualys KB vulnerability records between $startDate and $endInterval."
        Set-CheckpointToBlob -StorageConnectionString $storageConnectionStr `
            -ContainerName $checkpointContainer -LastSuccessfulTime $endTime
        return
    }

    # Ensure vulnList is always an array
    $vulnArray = @($vulnList)
    Write-Host "Records returned: $($vulnArray.Count)"

    # Parse each vulnerability record
    $records = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($vuln in $vulnArray) {
        if ($null -eq $vuln.QID) {
            Write-Host "Skipping null QID entry."
            continue
        }

        $record = ConvertFrom-QualysVulnXml -VulnNode $vuln
        $records.Add($record)
    }

    Write-Host "Records parsed: $($records.Count)"

    if ($records.Count -eq 0) {
        Write-Host "INFO: All returned records had null QIDs. No data to ingest."
        Set-CheckpointToBlob -StorageConnectionString $storageConnectionStr `
            -ContainerName $checkpointContainer -LastSuccessfulTime $endTime
        return
    }

    # ─── Acquire Entra ID Token ───────────────────────────────────────────────────
    $bearerToken = Get-ManagedIdentityToken -Resource "https://monitor.azure.com"

    # ─── Chunk and Send ───────────────────────────────────────────────────────────
    $chunks = Split-IntoChunks -Objects $records.ToArray()
    Write-Host "Payload split into $($chunks.Count) chunk(s)."

    $chunkIndex = 0
    $failedChunks = 0
    foreach ($chunk in $chunks) {
        $chunkIndex++
        try {
            Send-LogsIngestionData -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
                -StreamName $dcrStreamName -BearerToken $bearerToken -Records $chunk
            Write-Host "Chunk $chunkIndex/$($chunks.Count) sent successfully ($($chunk.Count) records)."
        }
        catch {
            $failedChunks++
            Write-Error "Chunk $chunkIndex/$($chunks.Count) failed: $($_.Exception.Message)"
        }
    }

    # ─── Update Checkpoint ────────────────────────────────────────────────────────
    if ($failedChunks -eq 0) {
        Set-CheckpointToBlob -StorageConnectionString $storageConnectionStr `
            -ContainerName $checkpointContainer -LastSuccessfulTime $endTime
        Write-Host "SUCCESS: $($records.Count) Qualys KB records ingested between $startDate and $endInterval." -ForegroundColor Green
    }
    elseif ($failedChunks -lt $chunks.Count) {
        # Partial success: do NOT update checkpoint so next run re-fetches the full window
        Write-Warning "$failedChunks of $($chunks.Count) chunks failed. Checkpoint NOT updated - next run will retry."
    }
    else {
        Write-Error "All $($chunks.Count) chunks failed. Checkpoint NOT updated."
    }
}
finally {
    # ─── Qualys API: Logout ───────────────────────────────────────────────────────
    try {
        Invoke-RestMethod -Headers $hdrs -Uri "$base/session/" -Method Post -Body "action=logout" `
            -WebSession $qualysSession -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Qualys session logged out."
    }
    catch {
        Write-Warning "Failed to logout Qualys session: $($_.Exception.Message)"
    }
}

Write-Host "PowerShell timer trigger function completed. TIME: $currentUTCtime"
