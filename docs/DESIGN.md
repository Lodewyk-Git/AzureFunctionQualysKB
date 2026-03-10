# Qualys KB Data Connector - Architecture Design

> Author: BUI Engineering - Lodewyk

## Overview

Migrates the Qualys KnowledgeBase ingestion pipeline from the deprecated Log Analytics HTTP Data Collector API to the Azure Monitor Logs Ingestion API using DCRs and DCEs. Removes shared-key auth, adds managed identity, blob-based checkpointing, and 1 MB payload chunking.

## Components

| Component | Technology |
|---|---|
| Ingestion API | Azure Monitor Logs Ingestion API |
| Auth | System-assigned Managed Identity (Entra ID token for `https://monitor.azure.com`) |
| Table | `QualysKB_CL` - DCR-based custom table with explicit columns |
| Routing | DCR `streamDeclarations` + `dataFlows` with `transformKql` |
| Endpoint | Data Collection Endpoint (DCE) - regional |
| Runtime | Azure Functions PowerShell 7.4, Consumption Y1 |
| Checkpoint | Azure Blob Storage (`qualyskb-checkpoints` container) |
| Secrets | Key Vault with `@Microsoft.KeyVault(...)` references |
| RBAC | `Monitoring Metrics Publisher` on the DCR |

## Table Schema (QualysKB_CL)

| Column | Type | Notes |
|---|---|---|
| TimeGenerated | datetime | Set by DCR transform from DateValue or now() |
| QID | string | Qualys vulnerability ID |
| Title | string | |
| Category | string | |
| Consequence | string | HTML stripped |
| Diagnosis | string | HTML stripped |
| Last_Service_Modification_DateTime | datetime | |
| Patchable | string | |
| Published_DateTime | datetime | |
| Severity_Level | int | 1-5 |
| CVE_ID | dynamic | Array of CVE IDs |
| CVE_URL | dynamic | Array of CVE URLs |
| Vendor_Reference_ID | dynamic | |
| Vendor_Reference_URL | dynamic | |
| PCI_Flag | string | |
| Software_Product | dynamic | |
| Software_Vendor | dynamic | |
| Solution | string | HTML stripped |
| Vuln_Type | string | |
| Discovery_Additional_Info | string | |
| Discovery_Auth_Type | dynamic | |
| Discovery_Remote | string | |
| THREAT_INTELLIGENCE | dynamic | |

## DCR Configuration

- **Kind**: Direct
- **Stream**: `Custom-QualysKB_CL`
- **Output stream**: `Custom-QualysKB_CL`
- **Transform**: `source | extend TimeGenerated = iif(isnotempty(DateValue), todatetime(DateValue), now()) | project-away DateValue`
- **Ingestion URI**: `https://{dce-endpoint}/dataCollectionRules/{dcrImmutableId}/streams/Custom-QualysKB_CL?api-version=2023-01-01`

## Function Flow

1. Read checkpoint from blob storage
2. Login to Qualys API
3. Fetch KB vulnerabilities (`published_after=checkpoint`)
4. Parse XML, strip HTML, extract multi-value fields as arrays
5. Chunk records into <=1 MB JSON batches (950 KB safety margin)
6. Acquire Entra token via managed identity
7. POST each chunk to Logs Ingestion API with retry (exponential backoff, max 3)
8. Update checkpoint blob on success
9. Logout Qualys session

## Deployment Order

Storage Account -> Function App (with managed identity) -> Custom Table -> DCE -> DCR -> RBAC role assignment -> App Settings -> Code Deploy

## Key Risks

| Risk | Mitigation |
|---|---|
| Stream/table name mismatch causes silent failure | ARM templates derive names from the same parameter |
| DCR/table schema mismatch returns 400 | Both defined from the same schema source |
| Region mismatch between DCR, DCE, workspace | All use the same location parameter |
| Missing RBAC role returns 403 | ARM template includes role assignment |
| Payload > 1 MB rejected with 413 | Chunking at 950 KB safety margin |
| Token scope must be `monitor.azure.com` not `management.azure.com` | Hardcoded in token function |
| Legacy table name conflict | Deploy script includes pre-flight migration check |
