# Qualys KB Data Connector — Logs Ingestion API Migration Design

## SECTION A — Executive Summary

This document describes the complete migration of the Qualys KnowledgeBase (KB) vulnerability data ingestion pipeline from the **legacy Log Analytics HTTP Data Collector API** to the **Azure Monitor Logs Ingestion API** with **Data Collection Rules (DCRs)** and **Data Collection Endpoints (DCEs)**.

### Future-state architecture at a glance

| Component | Technology |
|---|---|
| **Ingestion API** | Azure Monitor Logs Ingestion API (`/dataCollectionRules/{dcrImmutableId}/streams/{streamName}`) |
| **Authentication** | System-assigned Managed Identity → Entra ID bearer token (resource `https://monitor.azure.com`) |
| **Schema management** | DCR-based custom table `QualysKB_CL` with explicit column definitions |
| **Data routing** | DCR `streamDeclarations` + `dataFlows` with optional `transformKql` |
| **Ingestion endpoint** | DCE `logsIngestion` endpoint (regional) |
| **Function runtime** | Azure Functions PowerShell 7.4+ on Consumption/EP1 plan |
| **Checkpoint storage** | Azure Blob Storage (replacing fragile filesystem CSV) |
| **Secret management** | Qualys credentials in Azure Key Vault; Function App references via `@Microsoft.KeyVault(...)` |
| **RBAC** | Managed Identity assigned `Monitoring Metrics Publisher` on the DCR resource |
| **Deployment** | Modular ARM templates with linked deployments |

The legacy `Build-Signature` / `Post-LogAnalyticsData` functions using workspace shared keys are fully removed. The `QualysKB_CL` table is recreated as a DCR-based custom table with explicit typed columns, and all ingestion flows through the Logs Ingestion API with proper chunking, retry, and idempotency safeguards.

---

## SECTION B — Current vs Target Architecture

| Aspect | Current (Data Collector API) | Target (Logs Ingestion API) |
|---|---|---|
| **Auth model** | Workspace ID + Shared Key (HMAC-SHA256 signature) | Entra ID OAuth2 bearer token via Managed Identity |
| **Auth rotation** | Manual key rotation | Automatic — managed identity tokens auto-rotate |
| **Table model** | Data Collector auto-creates `QualysKB_CL` with `_s`, `_d` suffixes | DCR-based custom table with explicit typed columns, no suffixes |
| **Schema control** | Implicit — schema inferred on first POST | Explicit — defined in table resource + DCR `streamDeclarations` |
| **Schema evolution** | Append-only; new fields auto-added with type suffix | Controlled — update table + DCR; mismatches rejected |
| **API endpoint** | `https://{workspaceId}.ods.opinsights.azure.com/api/logs` | `https://{dce-endpoint}.ingest.monitor.azure.com/dataCollectionRules/{dcrImmutableId}/streams/{stream}?api-version=2023-01-01` |
| **Payload limit** | ~30 MB per POST | **1 MB per POST** (compressed or uncompressed) |
| **Batching** | Single large payload | Must chunk into ≤1 MB batches; function handles splitting |
| **Transformation** | None (raw data stored) | Optional `transformKql` in DCR for reshaping, enrichment, filtering |
| **RBAC** | Shared key = full workspace access | Least-privilege: `Monitoring Metrics Publisher` on specific DCR only |
| **DCR/DCE** | Not used | DCR defines routing, schema, transform; DCE provides regional ingestion endpoint |
| **Checkpoint** | CSV on Function App filesystem (`C:\home\site\`) | Azure Blob Storage (durable, survives scale-out & restarts) |
| **Retry** | None | Exponential backoff with jitter, up to 3 retries |
| **Deprecation** | Scheduled for deprecation September 2026 | Current strategic API; GA and fully supported |

### Key differences that drive the migration

1. **Security**: Shared keys grant broad workspace access and require manual rotation. Managed Identity + DCR-scoped RBAC follows zero-trust principles.
2. **Payload size**: The Logs Ingestion API enforces a **1 MB** limit per POST. The current code sends up to 30 MB in one call — this must be chunked.
3. **Schema**: Data Collector API appends `_s`, `_d`, etc. to column names and allows unconstrained schema drift. DCR-based tables have clean, typed columns.
4. **Checkpoint durability**: The filesystem on Azure Functions Consumption plan is ephemeral. Blob storage is durable and works correctly with scale-out.
5. **Deprecation**: The Data Collector API is deprecated. Migration is mandatory.

---

## SECTION C — Recommended Future-State Design

### Component Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      Azure Resource Group                     │
│                                                               │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐  │
│  │ Key Vault   │    │ Storage Acct │    │ App Service Plan│  │
│  │ (Qualys     │    │ (func +      │    │ (Consumption/   │  │
│  │  creds)     │    │  checkpoint  │    │  EP1)           │  │
│  └──────┬──────┘    │  blobs)      │    └────────┬────────┘  │
│         │           └──────┬───────┘             │           │
│         │                  │                     │           │
│  ┌──────▼──────────────────▼─────────────────────▼────────┐  │
│  │                  Function App                           │  │
│  │  System-Assigned Managed Identity                       │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │ QualysKBTimerTrigger (every 5 min)               │   │  │
│  │  │  1. Read checkpoint from Blob                    │   │  │
│  │  │  2. Login to Qualys API                          │   │  │
│  │  │  3. Fetch KB vulns (published_after=checkpoint)  │   │  │
│  │  │  4. Parse XML → PSObjects                        │   │  │
│  │  │  5. Chunk into ≤1 MB JSON batches                │   │  │
│  │  │  6. Get Entra token for monitor.azure.com        │   │  │
│  │  │  7. POST each chunk to Logs Ingestion API        │   │  │
│  │  │  8. Update checkpoint in Blob                    │   │  │
│  │  │  9. Logout Qualys session                        │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └─────────────────────────┬──────────────────────────────┘  │
│                            │ Bearer token                     │
│                            ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ Data Collection Endpoint (DCE)                          │  │
│  │ https://{dce}.{region}.ingest.monitor.azure.com         │  │
│  └─────────────────────────┬───────────────────────────────┘  │
│                            │                                  │
│  ┌─────────────────────────▼───────────────────────────────┐  │
│  │ Data Collection Rule (DCR)  — kind: Direct              │  │
│  │  streamDeclarations: Custom-QualysKB_CL                 │  │
│  │  dataFlows: → Microsoft-Table-QualysKB_CL               │  │
│  │  transformKql: source | extend TimeGenerated = ...      │  │
│  └─────────────────────────┬───────────────────────────────┘  │
│                            │                                  │
│  ┌─────────────────────────▼───────────────────────────────┐  │
│  │ Log Analytics Workspace                                  │  │
│  │  └─ QualysKB_CL (DCR-based custom table)                │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Checkpoint Storage Decision

**Decision**: Move from filesystem CSV to **Azure Blob Storage**.

**Justification**:
1. Azure Functions Consumption plan uses a shared filesystem (`C:\home\site`) backed by Azure Files, but this is unreliable during scale-out events where multiple instances may write concurrently.
2. Blob storage supports optimistic concurrency via ETags, preventing checkpoint corruption during concurrent executions.
3. Blob storage survives function app re-creation, slot swaps, and plan changes.
4. A single small JSON blob (`qualyskb-checkpoint.json`) is trivial to read/write and costs essentially nothing.

**Implementation**: The checkpoint blob is stored in a container named `qualyskb-checkpoints` in the Function App's existing storage account. The blob contains `{"LastSuccessfulTime": "2026-03-10T00:00:00Z"}`.

### Hosting Choice

**Recommendation**: Consumption plan (Y1) for cost efficiency. The function runs every 5 minutes, typically completes within 60–120 seconds, and does not require always-on or VNET integration for most deployments. If VNET integration is needed (e.g., private Qualys API endpoints), upgrade to Elastic Premium (EP1).

### Network / Private Link

For most deployments, public endpoints are fine. If the Log Analytics workspace or Qualys API requires private connectivity:
- Deploy the DCE with a private endpoint.
- Use VNET-integrated Function App on EP1.
- Configure private DNS zones for `monitor.azure.com` and `blob.core.windows.net`.

This is out of scope for the base deployment but the ARM templates use parameters that support it.

---

## SECTION D — Target Table and Schema Design

### Table Name

`QualysKB_CL` — new DCR-based custom table. This is a **side-by-side deployment** alongside the legacy `QualysKB_CL` (which was created by the Data Collector API). The legacy table can be retained for historical queries during a transition period, then deprecated.

**Why side-by-side?** The legacy Data Collector table has type-suffixed columns (`QID_s`, `Title_s`, etc.) and its schema cannot be changed to match DCR requirements. A clean DCR-based table provides proper typing and removes suffix clutter.

> **Note:** If the legacy table name conflicts, name the new table `QualysKBv2_CL` and update DCR accordingly. The ARM template parameterises this.

### Full Schema

| Column Name | Type | Description | Notes |
|---|---|---|---|
| `TimeGenerated` | `datetime` | **Required**. Ingestion timestamp. | Set via `transformKql` from `DateValue` or `now()` |
| `QID` | `string` | Qualys vulnerability ID | String to preserve leading zeros and future format changes |
| `Title` | `string` | Vulnerability title | |
| `Category` | `string` | Qualys category | |
| `Consequence` | `string` | Plain-text consequence description | HTML stripped before ingestion |
| `Diagnosis` | `string` | Plain-text diagnosis description | HTML stripped before ingestion |
| `Last_Service_Modification_DateTime` | `datetime` | Last modification timestamp from Qualys | |
| `Patchable` | `string` | Whether a patch is available | Kept as string ("0"/"1") for compatibility |
| `Published_DateTime` | `datetime` | Publication timestamp from Qualys | |
| `Severity_Level` | `int` | Severity level (1–5) | Integer for filtering/sorting |
| `CVE_ID` | `dynamic` | CVE identifier(s) | **Changed to dynamic** — supports multi-CVE vulns as JSON array |
| `CVE_URL` | `dynamic` | CVE reference URL(s) | **Changed to dynamic** — parallel array with CVE_ID |
| `Vendor_Reference_ID` | `dynamic` | Vendor reference ID(s) | **Changed to dynamic** — supports multiple references |
| `Vendor_Reference_URL` | `dynamic` | Vendor reference URL(s) | **Changed to dynamic** |
| `PCI_Flag` | `string` | PCI compliance flag | |
| `Software_Product` | `dynamic` | Affected software product(s) | **Changed to dynamic** — supports multiple products |
| `Software_Vendor` | `dynamic` | Affected software vendor(s) | **Changed to dynamic** |
| `Solution` | `string` | Plain-text solution description | HTML stripped before ingestion |
| `Vuln_Type` | `string` | Vulnerability type | |
| `Discovery_Additional_Info` | `string` | Additional discovery information | |
| `Discovery_Auth_Type` | `dynamic` | Authentication type(s) used for discovery | **Changed to dynamic** — supports multiple types |
| `Discovery_Remote` | `string` | Remote discovery flag | |
| `THREAT_INTELLIGENCE` | `dynamic` | Threat intelligence data | Already JSON in legacy; kept as dynamic |

### Multi-value Field Handling

Fields changed from `string` to `dynamic`:
- **CVE_ID / CVE_URL**: A single QID can map to multiple CVEs. The legacy code only captures the first one via `CVE_LIST.CVE.ID`. The refactored code will collect *all* CVEs into a JSON array.
- **Vendor_Reference_ID / Vendor_Reference_URL**: Same multi-value pattern.
- **Software_Product / Software_Vendor**: Multiple software entries per vulnerability.
- **Discovery_Auth_Type**: Can contain multiple authentication types.
- **THREAT_INTELLIGENCE**: Already serialised to JSON in the legacy code; kept as `dynamic`.

### TimeGenerated Strategy

The `DateValue` field in the legacy code maps to `LAST_SERVICE_MODIFICATION_DATETIME`. In the new design:
- The Function sends a `DateValue` field in the JSON payload.
- The DCR `transformKql` sets `TimeGenerated` from `DateValue`: `source | extend TimeGenerated = todatetime(DateValue)`.
- The `DateValue` column is **not stored** in the table — it is consumed by the transform and mapped to `TimeGenerated`.
- If `DateValue` is null/empty, `TimeGenerated` defaults to ingestion time via `coalesce(todatetime(DateValue), now())`.

---

## SECTION E — DCR / DCE Design

### Stream Name

`Custom-QualysKB_CL`

Custom streams for direct ingestion must be prefixed with `Custom-`. The suffix matches the target table name.

### streamDeclarations

```json
"streamDeclarations": {
    "Custom-QualysKB_CL": {
        "columns": [
            { "name": "QID", "type": "string" },
            { "name": "Title", "type": "string" },
            { "name": "Category", "type": "string" },
            { "name": "Consequence", "type": "string" },
            { "name": "Diagnosis", "type": "string" },
            { "name": "Last_Service_Modification_DateTime", "type": "datetime" },
            { "name": "Patchable", "type": "string" },
            { "name": "CVE_ID", "type": "dynamic" },
            { "name": "CVE_URL", "type": "dynamic" },
            { "name": "Vendor_Reference_ID", "type": "dynamic" },
            { "name": "Vendor_Reference_URL", "type": "dynamic" },
            { "name": "PCI_Flag", "type": "string" },
            { "name": "Published_DateTime", "type": "datetime" },
            { "name": "Severity_Level", "type": "int" },
            { "name": "Software_Product", "type": "dynamic" },
            { "name": "Software_Vendor", "type": "dynamic" },
            { "name": "Solution", "type": "string" },
            { "name": "Vuln_Type", "type": "string" },
            { "name": "Discovery_Additional_Info", "type": "string" },
            { "name": "Discovery_Auth_Type", "type": "dynamic" },
            { "name": "Discovery_Remote", "type": "string" },
            { "name": "THREAT_INTELLIGENCE", "type": "dynamic" },
            { "name": "DateValue", "type": "string" }
        ]
    }
}
```

### Destination

```json
"destinations": {
    "logAnalytics": [
        {
            "workspaceResourceId": "[parameters('workspaceResourceId')]",
            "name": "la-destination"
        }
    ]
}
```

### Output Stream

`Microsoft-Table-QualysKB_CL`

### dataFlows

```json
"dataFlows": [
    {
        "streams": ["Custom-QualysKB_CL"],
        "destinations": ["la-destination"],
        "transformKql": "source | extend TimeGenerated = coalesce(todatetime(DateValue), now()) | project-away DateValue",
        "outputStream": "Microsoft-Table-QualysKB_CL"
    }
]
```

### DCR Kind

`"kind": "Direct"` — This DCR is used for direct ingestion (API push), not agent-based collection.

### Ingestion URI

The Logs Ingestion API URI is constructed as:

```
https://{DCE_LOGS_INGESTION_ENDPOINT}/dataCollectionRules/{DCR_IMMUTABLE_ID}/streams/Custom-QualysKB_CL?api-version=2023-01-01
```

- The **DCE** provides the `logsIngestion` endpoint (e.g., `https://dce-qualyskb-xxxx.australiaeast-1.ingest.monitor.azure.com`).
- The **DCR immutable ID** is a GUID-like identifier assigned at creation time.

### When is DCE required vs optional?

- **Required when**: Using the Logs Ingestion API for direct ingestion (our case). The DCE provides the regional ingestion endpoint URL.
- **Optional when**: Using Azure Monitor Agent (AMA) for agent-based collection — the agent has its own built-in endpoint.

In this architecture, **DCE is required** and must be deployed. The DCR's `dataCollectionEndpointId` property links the DCR to its DCE.

---

## SECTION F — Function App Refactor Plan

### What to REMOVE

| Item | Reason |
|---|---|
| `$logAnalyticsUri` global variable | No longer needed; replaced by DCE endpoint |
| `$customerId = $env:workspaceId` | Workspace ID no longer used for auth |
| `$sharedKey = $env:workspacekey` | Shared key auth removed entirely |
| `Build-Signature` function | HMAC signature is legacy pattern |
| `Post-LogAnalyticsData` function | Legacy Data Collector API POST |
| `logAnalyticsUri` validation regex | Different endpoint format |
| Filesystem checkpoint logic (`GetStartTime`, `UpdateCheckpointTime` using CSV) | Replaced by Blob storage |
| 30 MB payload size check | Replaced by 1 MB chunking logic |

### What to ADD

| Item | Purpose |
|---|---|
| `Get-ManagedIdentityToken` function | Acquires Entra bearer token from MSI endpoint for `https://monitor.azure.com` |
| `Send-LogsIngestionData` function | POSTs JSON payload to Logs Ingestion API with auth header |
| `Split-IntoChunks` function | Splits object array into batches where each serialised batch ≤ 1 MB |
| `Get-CheckpointFromBlob` function | Reads checkpoint timestamp from Azure Blob Storage |
| `Set-CheckpointToBlob` function | Writes checkpoint timestamp to Azure Blob Storage |
| `Invoke-WithRetry` function | Wraps HTTP calls with exponential backoff + jitter (3 retries) |
| Multi-value field extraction | Properly handles multiple CVEs, vendor refs, software entries per QID |

### Managed Identity Token Acquisition

```powershell
function Get-ManagedIdentityToken {
    param([string]$Resource = "https://monitor.azure.com")
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    $headers = @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }
    $response = Invoke-RestMethod -Uri $tokenUri -Headers $headers -Method Get
    return $response.access_token
}
```

### Logs Ingestion API Call

```
POST https://{dceEndpoint}/dataCollectionRules/{dcrImmutableId}/streams/Custom-QualysKB_CL?api-version=2023-01-01
Authorization: Bearer {token}
Content-Type: application/json
Body: [{...}, {...}, ...]
```

### Chunking Strategy

The Logs Ingestion API has a **1 MB** per-request payload limit. The function:
1. Converts the full object array to individual JSON records.
2. Accumulates records into a batch until adding the next record would exceed ~950 KB (safety margin).
3. Sends each batch as a separate POST.
4. Uses retry with exponential backoff for transient failures (429, 500, 503).

### Retry Strategy

- Max retries: 3
- Base delay: 1 second
- Backoff: exponential with jitter (`delay * 2^attempt + random(0, 500ms)`)
- Retry on: 429 (rate limit — honour `Retry-After` header), 500, 502, 503, 504
- No retry on: 400 (bad request), 401/403 (auth), 404

### Idempotency

The Qualys KB API returns deterministic data for a given `published_after` window. If a function execution fails mid-batch:
- The checkpoint is **not updated** (it only updates on full success).
- The next execution re-fetches and re-sends the same window.
- Log Analytics handles duplicate records naturally (same QID + TimeGenerated = same row in queries via `distinct` or `arg_max`).

### Preserved Logic

- Timer-trigger execution model
- Qualys session login/logout
- XML response parsing
- `Html-ToText` HTML sanitisation
- `Normalize-KBFilterParameters` filter validation
- `UrlValidation` URI validation
- Graceful handling of empty responses
- Per-record null-QID filtering

---

## SECTION G — Proposed File/Folder Structure

```
AzureFunctionQualysKB_rebuild/
├── docs/
│   └── DESIGN.md                          # This document
├── infra/
│   ├── main.template.json                 # Orchestrator ARM template (linked)
│   ├── main.parameters.json               # Parameters file
│   ├── table.template.json                # Log Analytics custom table
│   ├── dce.template.json                  # Data Collection Endpoint
│   ├── dcr.template.json                  # Data Collection Rule
│   ├── functionapp.template.json          # Function App + App Service Plan + Storage
│   └── roleassignments.template.json      # RBAC assignments
├── functionapp/
│   ├── host.json                          # Function App host configuration
│   ├── requirements.psd1                  # PowerShell module dependencies
│   ├── profile.ps1                        # Function App startup profile
│   ├── QualysKBTimerTrigger/
│   │   ├── function.json                  # Timer trigger binding
│   │   └── run.ps1                        # Refactored function code
│   └── modules/
│       └── QualysKBHelpers.psm1           # Shared helper functions
├── scripts/
│   └── Deploy-Solution.ps1               # End-to-end deployment script
├── run.ps1                                # LEGACY — original code (retained for reference)
├── function.json                          # LEGACY — original binding (retained for reference)
└── README.md                             # Project README
```

---

## SECTION H — Implementation Steps

### Step-by-step Migration Plan

| Step | Action | Details |
|---|---|---|
| **1** | **Deploy infrastructure** | Run ARM templates to create: Storage Account, App Service Plan, Function App with Managed Identity |
| **2** | **Create custom table** | Deploy `table.template.json` to create `QualysKB_CL` as a DCR-based table in the workspace |
| **3** | **Deploy DCE** | Deploy `dce.template.json` in the same region as the workspace |
| **4** | **Deploy DCR** | Deploy `dcr.template.json` with stream declarations, data flows, and transform KQL; link to DCE and workspace |
| **5** | **Assign RBAC** | Grant the Function App's managed identity `Monitoring Metrics Publisher` role on the DCR resource |
| **6** | **Configure Key Vault** | Store Qualys `apiUsername` and `apiPassword` in Key Vault; grant Function App identity `Key Vault Secrets User` |
| **7** | **Configure App Settings** | Set Function App settings: `qualysUri`, `qualysApiUsername` (KV ref), `qualysApiPassword` (KV ref), `dceEndpoint`, `dcrImmutableId`, `dcrStreamName`, `checkpointContainerName`, `filterParameters`, `timeInterval` |
| **8** | **Deploy function code** | Deploy the refactored `functionapp/` folder to the Function App via ZIP deploy or CI/CD |
| **9** | **Test ingestion** | Trigger the function manually; verify checkpoint blob is created; verify data appears in `QualysKB_CL` |
| **10** | **Validate data** | Run KQL queries against `QualysKB_CL` to confirm schema, data types, and `TimeGenerated` mapping |
| **11** | **Parallel run** | Keep both old and new functions running for 1–2 weeks; compare record counts and data quality |
| **12** | **Cutover** | Disable the legacy function; update any Sentinel analytics rules / workbooks to query the new table |
| **13** | **Cleanup** | Remove legacy `workspaceId`, `workspacekey` app settings; optionally delete legacy table after retention period |

### Rollback Plan

1. The legacy function code is preserved in the repo root (`run.ps1`, `function.json`).
2. If the new function fails, re-deploy the legacy code and restore `workspaceId` / `workspacekey` settings.
3. The legacy `QualysKB_CL` table remains untouched throughout migration — no data loss.
4. DCR/DCE can be deleted without affecting the workspace or other data.

---

## SECTION I — ARM Template Design

See the individual template files in `infra/`. Key design decisions:

### Template Modularity

**Modular linked templates** are preferred over a single monolithic template because:
1. Each resource type can be deployed/updated independently.
2. Easier to test and troubleshoot.
3. RBAC assignments often require a separate deployment scope.
4. Supports different deployment cadences (infra changes infrequent, code deploys frequent).

### Resource Dependencies

```
Storage Account ──┐
App Service Plan ──┤
                   ├── Function App (depends on both) ──┐
Key Vault ─────────┘                                     │
                                                         │ Managed Identity
Workspace ──── Table ──── DCR ──── DCE                   │
                           │                              │
                           └──── Role Assignment (depends on DCR + Function App identity)
```

### Parameters

All templates accept parameters for:
- `location` (region)
- `workspaceResourceId` / `workspaceName`
- Resource names (with sensible defaults)
- Tags
- `qualysUri`, `filterParameters`, `timeInterval`

### Outputs

The main template outputs:
- Function App name and resource ID
- DCR resource ID and immutable ID
- DCE resource ID and logs ingestion endpoint
- Workspace resource ID
- Table name
- Managed Identity principal ID

---

## SECTION J — ARM Template Files to Produce

| File | Purpose |
|---|---|
| `infra/main.template.json` | Orchestrator template that deploys all resources in dependency order. Uses nested deployments (inline) rather than linked templates (which require a staging URI). |
| `infra/main.parameters.json` | Parameters file with placeholder values |
| `infra/table.template.json` | `Microsoft.OperationalInsights/workspaces/tables` — `QualysKB_CL` |
| `infra/dce.template.json` | `Microsoft.Insights/dataCollectionEndpoints` |
| `infra/dcr.template.json` | `Microsoft.Insights/dataCollectionRules` with `kind: Direct` |
| `infra/functionapp.template.json` | `Microsoft.Storage/storageAccounts` + `Microsoft.Web/serverfarms` + `Microsoft.Web/sites` with managed identity and app settings |
| `infra/roleassignments.template.json` | `Microsoft.Authorization/roleAssignments` — Monitoring Metrics Publisher on DCR |

**Note**: A single monolithic ARM template is worse than modular templates for this project because:
1. The RBAC assignment depends on the Function App's managed identity principal ID, which is only known after the Function App is deployed.
2. The DCR depends on the table and DCE being created first.
3. Modular templates allow teams to own infrastructure vs. application separately.
4. Individual templates can be tested in isolation.

The `main.template.json` orchestrates these as nested inline deployments with explicit `dependsOn` chains.

---

## SECTION K — Refactored PowerShell Function

See `functionapp/QualysKBTimerTrigger/run.ps1` and `functionapp/modules/QualysKBHelpers.psm1` for the complete implementation.

Key architectural changes in the refactored code:
1. All helper functions are extracted to `QualysKBHelpers.psm1` for testability and reuse.
2. The main `run.ps1` is a thin orchestrator that reads config, calls helpers, and handles top-level error reporting.
3. Blob-based checkpointing uses the Function App's `AzureWebJobsStorage` connection and the `Az.Storage` module.
4. Token acquisition uses the managed identity endpoint built into Azure Functions.
5. Payload chunking ensures no single POST exceeds 1 MB.
6. Multi-value XML nodes (CVE list, vendor references, software list) are properly extracted as arrays.

---

## SECTION L — Validation and Test Plan

### Test Cases

| # | Test Case | Method | Expected Outcome |
|---|---|---|---|
| 1 | **Happy path — new records** | Trigger function with KB data available | Records appear in `QualysKB_CL`; checkpoint updated |
| 2 | **No new records** | Trigger with checkpoint = now | Function logs "No new records"; checkpoint updated; no API errors |
| 3 | **First run (no checkpoint)** | Delete checkpoint blob | Checkpoint blob created with `now - timeInterval`; records fetched |
| 4 | **Oversized payload** | Mock 5000+ KB records | Records chunked into ≤1 MB batches; all batches succeed |
| 5 | **Auth failure — Qualys** | Set wrong `apiPassword` | Function logs error; checkpoint NOT updated; no partial data |
| 6 | **Auth failure — Logs Ingestion** | Remove RBAC role | 403 from Logs Ingestion API; function logs error; no checkpoint update |
| 7 | **Schema mismatch** | Send field not in DCR stream | 400 from Logs Ingestion API; logged; function continues with valid records |
| 8 | **DCE/DCR endpoint wrong** | Set invalid `dceEndpoint` | Connection failure; logged; no checkpoint update |
| 9 | **Rate limiting (429)** | Simulate high-frequency calls | Retry with backoff; eventually succeeds or logs final failure |
| 10 | **Duplicate prevention** | Run function twice for same window | Same data ingested twice; KQL `summarize arg_max(TimeGenerated, *) by QID` deduplicates |
| 11 | **Multi-CVE vulnerability** | Fetch QID with multiple CVEs | `CVE_ID` contains JSON array with all CVE IDs |
| 12 | **HTML sanitization** | QID with rich HTML in Diagnosis | Plain text stored; no HTML tags in `QualysKB_CL` |

### KQL Validation Queries

```kql
// Count records ingested in last hour
QualysKB_CL
| where TimeGenerated > ago(1h)
| count

// Verify schema — all expected columns present
QualysKB_CL
| getschema

// Check TimeGenerated is populated correctly
QualysKB_CL
| where TimeGenerated > ago(1d)
| project QID, TimeGenerated, Last_Service_Modification_DateTime
| take 10

// Verify multi-value CVE fields
QualysKB_CL
| where array_length(CVE_ID) > 1
| project QID, CVE_ID
| take 5

// Check for HTML remnants in text fields
QualysKB_CL
| where Diagnosis contains "<" or Solution contains "<"
| count

// Compare legacy vs new table record counts
let legacy = QualysKB_CL | where TimeGenerated > ago(7d) | summarize LegacyCount = count();
let newTable = QualysKB_CL | where TimeGenerated > ago(7d) | summarize NewCount = count();
legacy | join newTable on 1==1

// Severity distribution
QualysKB_CL
| summarize count() by Severity_Level
| order by Severity_Level asc
```

---

## SECTION M — Risks and Gotchas

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | **Stream/table name mismatch** | DCR stream name must match `Custom-{TableName}` exactly. A mismatch causes silent ingestion failure. | ARM templates derive stream name from table name parameter. |
| 2 | **DCR/table schema mismatch** | If the DCR stream declares a column not in the table (or vice versa), ingestion fails with 400. | Both are defined from the same schema source in ARM. |
| 3 | **Region mismatch** | DCR, DCE, and workspace must be in the same region. Cross-region causes deployment errors. | All resources use the same `location` parameter. |
| 4 | **Missing RBAC role** | Without `Monitoring Metrics Publisher` on the DCR, the managed identity gets 403. | ARM template includes role assignment; deployment script verifies. |
| 5 | **DCE vs DCR endpoint confusion** | The DCR has an endpoint too (`metrics ingestion endpoint`), but Logs Ingestion API requires the DCE's `logsIngestion` endpoint. | App settings explicitly store the DCE endpoint. |
| 6 | **Payload > 1 MB** | Logs Ingestion API rejects payloads > 1 MB with 413. | Chunking function with 950 KB safety margin. |
| 7 | **Managed identity token scope** | Token must be for resource `https://monitor.azure.com`, not `https://management.azure.com`. | Hardcoded in `Get-ManagedIdentityToken`. |
| 8 | **Classic vs DCR-based table** | If `QualysKB_CL` already exists as a Data Collector table, creating a DCR-based table with the same name fails. | Use parameter to allow alternate name (e.g., `QualysKBv2_CL`). |
| 9 | **Filesystem checkpoint loss** | Legacy CSV disappears on plan change, restart, or scale-out. | Migrated to Blob Storage with ETag concurrency. |
| 10 | **Qualys API session timeout** | Long-running parsing/sending can timeout the Qualys session. | Logout is best-effort; session already captured XML data. |
| 11 | **Qualys API rate limiting** | Qualys may rate-limit frequent API calls. | 5-minute timer interval is conservative; retry logic handles 429. |
| 12 | **`DateValue` format** | If `DateValue` is not ISO 8601 parseable, `todatetime()` in transform KQL returns null, and `TimeGenerated` falls back to `now()`. | Qualys returns ISO 8601 dates; edge cases handled by `coalesce`. |
| 13 | **Dynamic column ordering** | ARM table schema column order must match DCR stream declaration order. | Both generated from same ordered list. |

---

## SECTION N — Final Recommendation

### Production Design Recommendation

Deploy this solution as follows:

1. **Use the modular ARM template approach** with `main.template.json` orchestrating nested deployments. This gives you repeatable, auditable infrastructure-as-code.

2. **Create a new DCR-based `QualysKB_CL` table** side-by-side. If the name conflicts with the legacy Data Collector table, use `QualysKBv2_CL`. Update Sentinel analytics rules after validation.

3. **Use system-assigned managed identity** on the Function App. No client secrets, no key rotation, least-privilege RBAC scoped to the DCR.

4. **Move checkpointing to Blob Storage immediately.** The filesystem approach is fundamentally fragile on Consumption plan and will cause data gaps.

5. **Implement 1 MB chunking from day one.** Even if current payloads are small, KB data grows and a Qualys full-sync can return thousands of records.

6. **Store Qualys credentials in Key Vault** with Function App Key Vault references. This eliminates plaintext secrets in app settings.

7. **Run the legacy and new functions in parallel for 1–2 weeks** to validate data completeness. Compare record counts and spot-check field values.

8. **Plan for schema evolution.** When Qualys adds new fields, update the table schema, DCR stream declaration, and function code. The modular design makes this a controlled change.

9. **Target deployment sequence**: Storage → Function App → Table → DCE → DCR → RBAC → App Settings → Code Deploy → Test → Cutover.

This design is production-ready, secure, maintainable, and aligned with Microsoft's strategic direction for log ingestion. It eliminates all deprecated patterns and positions the pipeline for long-term operational stability.
