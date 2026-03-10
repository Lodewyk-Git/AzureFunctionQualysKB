<#
.SYNOPSIS
    Shared helper functions for the Qualys KB Data Connector.
.DESCRIPTION
    Contains reusable functions for HTML sanitisation, Qualys filter normalisation,
    URL validation, Logs Ingestion API interaction, checkpoint management, and retry logic.
#>

function ConvertFrom-HtmlToText {
    param([System.String] $Html)

    if ([string]::IsNullOrEmpty($Html)) {
        return ""
    }

    # Remove line breaks, replace with spaces
    $Html = $Html -replace "(`r|`n|`t)", " "

    # Remove invisible content
    @('head', 'style', 'script', 'object', 'embed', 'applet', 'noframes', 'noscript', 'noembed') | ForEach-Object {
        $Html = $Html -replace "<$_[^>]*?>.*?</$_>", ""
    }

    # Condense extra whitespace
    $Html = $Html -replace "( )+", " "

    # Add line breaks for block-level elements
    @('div','p','blockquote','h[1-9]') | ForEach-Object {
        $Html = $Html -replace "</?$_[^>]*?>.*?</$_>", ("`n" + '$0')
    }

    # Add line breaks for self-closing tags
    @('div','p','blockquote','h[1-9]','br') | ForEach-Object {
        $Html = $Html -replace "<$_[^>]*?/>", ('$0' + "`n")
    }

    # Strip all remaining tags
    $Html = $Html -replace "<[^>]*?>", ""

    # Replace common HTML entities
    @(
        @("&amp;bull;", " * "),
        @("&amp;lsaquo;", "<"),
        @("&amp;rsaquo;", ">"),
        @("&amp;(rsquo|lsquo);", "'"),
        @("&amp;(quot|ldquo|rdquo);", '"'),
        @("&amp;trade;", "(tm)"),
        @("&amp;frasl;", "/"),
        @("&amp;(quot|#34|#034|#x22);", '"'),
        @('&amp;(amp|#38|#038|#x26);', "&amp;"),
        @("&amp;(lt|#60|#060|#x3c);", "<"),
        @("&amp;(gt|#62|#062|#x3e);", ">"),
        @('&amp;(copy|#169);', "(c)"),
        @("&amp;(reg|#174);", "(r)"),
        @("&amp;nbsp;", " "),
        @("&amp;(.{2,6});", "")
    ) | ForEach-Object { $Html = $Html -replace $_[0], $_[1] }

    return $Html
}

function Test-QualysUri {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    if ($Uri -match '^https:\/\/qualysapi\.([\w\.]+)\/api\/2\.0$') {
        return $true
    }
    return $false
}

function Format-KBFilterParameters {
    param(
        [string]$RawFilterParameters
    )

    if ([string]::IsNullOrWhiteSpace($RawFilterParameters)) {
        return ""
    }

    $sanitized = $RawFilterParameters.Trim().TrimStart("&").TrimStart("?")
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return ""
    }

    $normalizedParams = @{}
    $pairs = $sanitized -split '&' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($pair in $pairs) {
        $parts = $pair -split '=', 2
        if ($parts.Count -ne 2) {
            Write-Warning "Ignoring malformed filter parameter '$pair'."
            continue
        }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if ($key -ieq "details") {
            $normalizedParams["details"] = [System.Uri]::EscapeDataString($value)
        }
        else {
            Write-Warning "Ignoring unsupported KB filter parameter '$key'."
        }
    }

    if ($normalizedParams.Count -eq 0) {
        return ""
    }

    return "&details=$($normalizedParams["details"])"
}

function Get-ManagedIdentityToken {
    param(
        [string]$Resource = "https://monitor.azure.com"
    )

    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    $headers = @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }

    try {
        $response = Invoke-RestMethod -Uri $tokenUri -Headers $headers -Method Get -ErrorAction Stop
        return $response.access_token
    }
    catch {
        Write-Error "Failed to acquire managed identity token for resource '$Resource': $($_.Exception.Message)"
        throw
    }
}

function Get-CheckpointFromBlob {
    param(
        [Parameter(Mandatory)]
        [string]$StorageConnectionString,

        [Parameter(Mandatory)]
        [string]$ContainerName,

        [string]$BlobName = "qualyskb-checkpoint.json",

        [int]$DefaultLookbackMinutes = 5
    )

    $defaultTime = [datetime]::UtcNow.AddMinutes(-$DefaultLookbackMinutes).ToString("yyyy-MM-ddTHH:mm:ssZ")

    try {
        $context = New-AzStorageContext -ConnectionString $StorageConnectionString
        $blob = Get-AzStorageBlob -Container $ContainerName -Blob $BlobName -Context $context -ErrorAction Stop

        $memStream = New-Object System.IO.MemoryStream
        $blob.ICloudBlob.DownloadToStream($memStream)
        $memStream.Position = 0
        $reader = New-Object System.IO.StreamReader($memStream)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $memStream.Close()

        $checkpoint = $content | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace($checkpoint.LastSuccessfulTime)) {
            Write-Host "Checkpoint loaded: $($checkpoint.LastSuccessfulTime)"
            return $checkpoint.LastSuccessfulTime
        }
    }
    catch {
        if ($_.Exception.Message -like "*BlobNotFound*" -or $_.Exception.Message -like "*The specified blob does not exist*" -or $_.Exception.Message -like "*Can not find blob*" -or $_.Exception.Message -like "*404*") {
            Write-Host "No checkpoint blob found. Using default lookback of $DefaultLookbackMinutes minutes."
        }
        else {
            Write-Warning "Error reading checkpoint blob: $($_.Exception.Message). Using default lookback."
        }
    }

    return $defaultTime
}

function Set-CheckpointToBlob {
    param(
        [Parameter(Mandatory)]
        [string]$StorageConnectionString,

        [Parameter(Mandatory)]
        [string]$ContainerName,

        [Parameter(Mandatory)]
        [datetime]$LastSuccessfulTime,

        [string]$BlobName = "qualyskb-checkpoint.json"
    )

    $checkpointData = @{
        LastSuccessfulTime = $LastSuccessfulTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
        UpdatedAt          = [datetime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Compress

    try {
        $context = New-AzStorageContext -ConnectionString $StorageConnectionString
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($checkpointData)
        $memStream = New-Object System.IO.MemoryStream(, $bytes)

        Set-AzStorageBlobContent -Container $ContainerName -Blob $BlobName -BlobType Block `
            -Context $context -Stream $memStream -Force -ErrorAction Stop | Out-Null

        $memStream.Close()
        Write-Host "Checkpoint updated to: $($LastSuccessfulTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    }
    catch {
        Write-Error "Failed to update checkpoint blob: $($_.Exception.Message)"
        throw
    }
}

function Split-IntoChunks {
    param(
        [Parameter(Mandatory)]
        [array]$Objects,

        [int]$MaxChunkSizeBytes = 950000  # ~950 KB safety margin under 1 MB API limit
    )

    $chunks = [System.Collections.Generic.List[array]]::new()
    $currentChunk = [System.Collections.Generic.List[object]]::new()
    $currentSize = 2  # Start at 2 for the JSON array brackets "[]"

    foreach ($obj in $Objects) {
        $objJson = ($obj | ConvertTo-Json -Depth 6 -Compress)
        $objSize = [System.Text.Encoding]::UTF8.GetByteCount($objJson)

        # If a single object exceeds the limit, send it alone (will likely fail but logged)
        if ($objSize -gt $MaxChunkSizeBytes) {
            Write-Warning "Single record (QID: $($obj.QID)) exceeds chunk size limit at $([math]::Round($objSize/1024, 1)) KB. Sending as standalone batch."
            if ($currentChunk.Count -gt 0) {
                $chunks.Add($currentChunk.ToArray())
                $currentChunk = [System.Collections.Generic.List[object]]::new()
                $currentSize = 2
            }
            $chunks.Add(@($obj))
            continue
        }

        # Account for comma separator between objects in JSON array
        $separatorSize = if ($currentChunk.Count -gt 0) { 1 } else { 0 }
        $projectedSize = $currentSize + $objSize + $separatorSize

        if ($projectedSize -gt $MaxChunkSizeBytes) {
            # Flush current chunk and start a new one
            $chunks.Add($currentChunk.ToArray())
            $currentChunk = [System.Collections.Generic.List[object]]::new()
            $currentSize = 2
        }

        $currentChunk.Add($obj)
        $currentSize += $objSize + $(if ($currentChunk.Count -gt 1) { 1 } else { 0 })
    }

    if ($currentChunk.Count -gt 0) {
        $chunks.Add($currentChunk.ToArray())
    }

    return $chunks
}

function Send-LogsIngestionData {
    param(
        [Parameter(Mandatory)]
        [string]$DceEndpoint,

        [Parameter(Mandatory)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory)]
        [string]$StreamName,

        [Parameter(Mandatory)]
        [string]$BearerToken,

        [Parameter(Mandatory)]
        [array]$Records
    )

    $uri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"
    $jsonPayload = $Records | ConvertTo-Json -Depth 6 -Compress

    # Ensure payload is a JSON array even for single records
    if ($Records.Count -eq 1) {
        $jsonPayload = "[$jsonPayload]"
    }

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
    $payloadSizeKB = [math]::Round($bodyBytes.Length / 1024, 1)

    $headers = @{
        "Authorization" = "Bearer $BearerToken"
        "Content-Type"  = "application/json"
    }

    Write-Host "Sending $($Records.Count) records ($payloadSizeKB KB) to Logs Ingestion API..."

    Invoke-WithRetry -ScriptBlock {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $bodyBytes -UseBasicParsing -ErrorAction Stop
        if ($response.StatusCode -notin @(200, 204)) {
            throw "Unexpected status code: $($response.StatusCode)"
        }
    } -MaxRetries 3 -ActivityDescription "POST to Logs Ingestion API"
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [int]$MaxRetries = 3,

        [int]$BaseDelayMs = 1000,

        [string]$ActivityDescription = "operation"
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            & $ScriptBlock
            return
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $retryableStatusCodes = @(429, 500, 502, 503, 504)
            $isRetryable = ($null -ne $statusCode) -and ($statusCode -in $retryableStatusCodes)

            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                Write-Error "$ActivityDescription failed after $attempt attempt(s). Status: $statusCode. Error: $($_.Exception.Message)"
                throw
            }

            # Calculate delay: exponential backoff with jitter
            $delay = $BaseDelayMs * [math]::Pow(2, ($attempt - 1))

            # Honour Retry-After header for 429 responses
            if ($statusCode -eq 429 -and $_.Exception.Response.Headers) {
                $retryAfter = $_.Exception.Response.Headers["Retry-After"]
                if ($retryAfter) {
                    $retrySeconds = 0
                    if ([int]::TryParse($retryAfter, [ref]$retrySeconds)) {
                        $delay = [math]::Max($delay, $retrySeconds * 1000)
                    }
                }
            }

            # Add jitter (0-500ms)
            $jitter = Get-Random -Minimum 0 -Maximum 500
            $totalDelayMs = $delay + $jitter

            Write-Warning "$ActivityDescription attempt $attempt/$MaxRetries failed (Status: $statusCode). Retrying in $([math]::Round($totalDelayMs/1000, 1))s..."
            Start-Sleep -Milliseconds $totalDelayMs
        }
    }
}

function ConvertFrom-QualysVulnXml {
    param(
        [Parameter(Mandatory)]
        $VulnNode
    )

    # Extract multi-value CVE list
    $cveIds = @()
    $cveUrls = @()
    if ($null -ne $VulnNode.CVE_LIST -and $null -ne $VulnNode.CVE_LIST.CVE) {
        $cves = @($VulnNode.CVE_LIST.CVE)
        foreach ($cve in $cves) {
            $id = $cve.ID
            if ($id -is [System.Xml.XmlElement]) { $id = $id."#cdata-section" }
            if (-not [string]::IsNullOrWhiteSpace($id)) { $cveIds += $id }

            $url = $cve.URL
            if ($url -is [System.Xml.XmlElement]) { $url = $url."#cdata-section" }
            if (-not [string]::IsNullOrWhiteSpace($url)) { $cveUrls += $url }
        }
    }

    # Extract multi-value vendor references
    $vendorRefIds = @()
    $vendorRefUrls = @()
    if ($null -ne $VulnNode.VENDOR_REFERENCE_LIST -and $null -ne $VulnNode.VENDOR_REFERENCE_LIST.VENDOR_REFERENCE) {
        $refs = @($VulnNode.VENDOR_REFERENCE_LIST.VENDOR_REFERENCE)
        foreach ($ref in $refs) {
            $id = $ref.ID
            if ($id -is [System.Xml.XmlElement]) { $id = $id."#cdata-section" }
            if (-not [string]::IsNullOrWhiteSpace($id)) { $vendorRefIds += $id }

            $url = $ref.URL
            if ($url -is [System.Xml.XmlElement]) { $url = $url."#cdata-section" }
            if (-not [string]::IsNullOrWhiteSpace($url)) { $vendorRefUrls += $url }
        }
    }

    # Extract multi-value software list
    $softwareProducts = @()
    $softwareVendors = @()
    if ($null -ne $VulnNode.SOFTWARE_LIST -and $null -ne $VulnNode.SOFTWARE_LIST.SOFTWARE) {
        $swList = @($VulnNode.SOFTWARE_LIST.SOFTWARE)
        foreach ($sw in $swList) {
            $product = $sw.PRODUCT
            if ($product -is [System.Xml.XmlElement]) { $product = $product."#cdata-section" }
            if (-not [string]::IsNullOrWhiteSpace($product)) { $softwareProducts += $product }

            $vendor = $sw.VENDOR
            if ($vendor -is [System.Xml.XmlElement]) { $vendor = $vendor."#cdata-section" }
            if (-not [string]::IsNullOrWhiteSpace($vendor)) { $softwareVendors += $vendor }
        }
    }

    # Extract multi-value discovery auth types
    $authTypes = @()
    if ($null -ne $VulnNode.DISCOVERY -and $null -ne $VulnNode.DISCOVERY.AUTH_TYPE_LIST -and $null -ne $VulnNode.DISCOVERY.AUTH_TYPE_LIST.AUTH_TYPE) {
        $authTypes = @($VulnNode.DISCOVERY.AUTH_TYPE_LIST.AUTH_TYPE)
    }

    # Extract threat intelligence
    $threatIntel = $null
    if ($null -ne $VulnNode.THREAT_INTELLIGENCE -and $null -ne $VulnNode.THREAT_INTELLIGENCE.THREAT_INTEL) {
        $threatIntel = @($VulnNode.THREAT_INTELLIGENCE.THREAT_INTEL) | ForEach-Object {
            @{
                id    = $_.id
                text  = $_."#cdata-section"
            }
        }
    }

    # Extract text content from CDATA sections
    $title = $VulnNode.TITLE
    if ($title -is [System.Xml.XmlElement]) { $title = $title."#cdata-section" }

    $diagnosisHtml = $VulnNode.DIAGNOSIS
    if ($diagnosisHtml -is [System.Xml.XmlElement]) { $diagnosisHtml = $diagnosisHtml."#cdata-section" }

    $consequenceHtml = $VulnNode.CONSEQUENCE
    if ($consequenceHtml -is [System.Xml.XmlElement]) { $consequenceHtml = $consequenceHtml."#cdata-section" }

    $solutionHtml = $VulnNode.SOLUTION
    if ($solutionHtml -is [System.Xml.XmlElement]) { $solutionHtml = $solutionHtml."#cdata-section" }

    # Parse severity as integer
    $severityLevel = 0
    [int]::TryParse($VulnNode.SEVERITY_LEVEL, [ref]$severityLevel) | Out-Null

    return [PSCustomObject]@{
        QID                                = [string]$VulnNode.QID
        Title                              = [string]$title
        Category                           = [string]$VulnNode.CATEGORY
        Consequence                        = ConvertFrom-HtmlToText -Html $consequenceHtml
        Diagnosis                          = ConvertFrom-HtmlToText -Html $diagnosisHtml
        Last_Service_Modification_DateTime = $VulnNode.LAST_SERVICE_MODIFICATION_DATETIME
        Patchable                          = [string]$VulnNode.PATCHABLE
        CVE_ID                             = $cveIds
        CVE_URL                            = $cveUrls
        Vendor_Reference_ID                = $vendorRefIds
        Vendor_Reference_URL               = $vendorRefUrls
        PCI_Flag                           = [string]$VulnNode.PCI_FLAG
        Published_DateTime                 = $VulnNode.PUBLISHED_DATETIME
        Severity_Level                     = $severityLevel
        Software_Product                   = $softwareProducts
        Software_Vendor                    = $softwareVendors
        Solution                           = ConvertFrom-HtmlToText -Html $solutionHtml
        Vuln_Type                          = [string]$VulnNode.VULN_TYPE
        Discovery_Additional_Info          = [string]$VulnNode.DISCOVERY.ADDITIONAL_INFO
        Discovery_Auth_Type                = $authTypes
        Discovery_Remote                   = [string]$VulnNode.DISCOVERY.REMOTE
        THREAT_INTELLIGENCE                = $threatIntel
        DateValue                          = [string]$VulnNode.LAST_SERVICE_MODIFICATION_DATETIME
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-HtmlToText',
    'Test-QualysUri',
    'Format-KBFilterParameters',
    'Get-ManagedIdentityToken',
    'Get-CheckpointFromBlob',
    'Set-CheckpointToBlob',
    'Split-IntoChunks',
    'Send-LogsIngestionData',
    'Invoke-WithRetry',
    'ConvertFrom-QualysVulnXml'
)
