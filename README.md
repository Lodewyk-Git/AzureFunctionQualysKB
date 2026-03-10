# Qualys KB Data Connector

Ingests Qualys VM KnowledgeBase vulnerability data into a Log Analytics custom table (`QualysKB_CL`) via the Azure Monitor Logs Ingestion API with DCR/DCE and Managed Identity.

**Author:** BUI Engineering - Lodewyk

## Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FLodewyk-Git%2FAzureFunctionQualysKB%2Fmaster%2Fazuredeploy.json)

This deploys: Function App, Storage Account, App Insights, custom table, DCE, DCR, RBAC, and blob containers.

### Parameters you need

| Parameter | Where to find it |
|---|---|
| **WorkspaceResourceID** | Log Analytics workspace > Properties > Resource ID |
| **AppInsightsWorkspaceResourceID** | Same (or a separate workspace for App Insights) |
| **APIUsername / APIPassword** | Your Qualys API credentials |
| **Uri** | Qualys API base URL, e.g. `https://qualysapi.qualys.com/api/2.0` |

## How it works

```
Timer (every 5 min)
  -> Read checkpoint from Blob Storage
  -> Fetch KB data from Qualys API (XML)
  -> Parse, chunk into <=1 MB batches
  -> POST to Logs Ingestion API (Managed Identity auth)
  -> Update checkpoint
```

## Scripted deployment

```powershell
Connect-AzAccount
.\scripts\Deploy-Solution.ps1 `
    -ResourceGroupName "rg-qualyskb" `
    -ParametersFile ".\infra\main.parameters.json" `
    -WorkspaceResourceId "<your-workspace-resource-id>"
```

Or deploy modular templates individually from `infra/`.

## Validate

```kql
QualysKB_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, QID, Title, Severity_Level, CVE_ID
| take 20
```

## App settings

| Setting | Description |
|---|---|
| `qualysUri` | Qualys API base URI |
| `apiUsername` | Qualys API username |
| `apiPassword` | Qualys API password |
| `dceEndpoint` | DCE logs ingestion endpoint (set automatically) |
| `dcrImmutableId` | DCR immutable ID (set automatically) |
| `dcrStreamName` | `Custom-QualysKB_CL` |
| `checkpointContainerName` | `qualyskb-checkpoints` |
| `timerSchedule` | CRON expression, default `0 */5 * * * *` |

## Repo structure

```
azuredeploy.json              # One-click ARM template
functionapp/                  # Function App code
  QualysKBTimerTrigger/run.ps1
  modules/QualysKBHelpers.psm1
infra/                        # Modular ARM templates
scripts/Deploy-Solution.ps1   # Scripted deployment
docs/DESIGN.md                # Architecture details
```

## Notes

- If a classic `QualysKB_CL` table already exists, migrate it first: `az monitor log-analytics workspace table migrate --name QualysKB_CL ...`
- The deploy script includes a pre-flight check that auto-migrates classic tables.
- Qualys credentials can be stored in Key Vault - set `keyVaultName` in `main.parameters.json`.
