# Qualys KB Data Connector — Azure Monitor Logs Ingestion API

## Overview

This project implements a Qualys KnowledgeBase (KB) vulnerability data ingestion pipeline for Microsoft Sentinel / Log Analytics using the **Azure Monitor Logs Ingestion API** with **Data Collection Rules (DCRs)** and **Data Collection Endpoints (DCEs)**.

It replaces the legacy HTTP Data Collector API pattern (workspace shared key) with modern Entra ID-based authentication via Managed Identity.

## Architecture

```
Azure Function (Timer Trigger, 5 min)
  │
  ├── Reads checkpoint from Azure Blob Storage
  ├── Authenticates to Qualys API (session login)
  ├── Fetches KB vulnerability data (XML)
  ├── Parses XML → PSCustomObjects
  ├── Chunks payload into ≤1 MB batches
  ├── Acquires Entra ID token (Managed Identity)
  ├── POSTs each batch to Logs Ingestion API
  ├── Updates checkpoint in Blob Storage
  └── Logs out of Qualys session
         │
         ▼
  DCE → DCR (transformKql) → QualysKB_CL table (Log Analytics)
```

## Portal Deployment (Custom Template)

Deploy directly to Azure via the portal using `azuredeploy.json` — the same pattern as the original Sentinel Qualys KB connector:

1. In the Azure Portal, go to **Deploy a custom template**.
2. Click **Build your own template in the editor**.
3. Load `azuredeploy.json` from this repository.
4. Fill in the parameters (Function Name, Workspace Name, Workspace Resource ID, Qualys credentials, API URI, App Insights workspace resource ID).
5. Select the resource group and region (must match your Log Analytics workspace region).
6. Click **Review + create**.

This single template deploys everything: Storage Account, App Service Plan, Function App with Managed Identity, Application Insights, custom `QualysKB_CL` table, Data Collection Endpoint, Data Collection Rule, RBAC role assignments, and blob containers.

> **Note**: Update the `FunctionCodePackageUri` parameter to point to your rebuilt function code ZIP package hosted in blob storage or a release URL. The default still references the legacy Sentinel code package.

## Repository Structure

```
├── azuredeploy.json                       # Portal-deployable ARM template (like the Sentinel connector)
├── docs/
│   └── DESIGN.md                          # Full architecture & migration design
├── infra/
│   ├── main.template.json                 # All-in-one ARM template
│   ├── main.parameters.json               # Parameters file (edit before deployment)
│   ├── table.template.json                # Custom table (standalone)
│   ├── dce.template.json                  # Data Collection Endpoint (standalone)
│   ├── dcr.template.json                  # Data Collection Rule (standalone)
│   ├── functionapp.template.json          # Function App + dependencies (standalone)
│   └── roleassignments.template.json      # RBAC assignments (standalone)
├── functionapp/
│   ├── host.json                          # Function App host config
│   ├── requirements.psd1                  # PowerShell module dependencies
│   ├── profile.ps1                        # Startup profile
│   ├── QualysKBTimerTrigger/
│   │   ├── function.json                  # Timer trigger binding
│   │   └── run.ps1                        # Main function code
│   └── modules/
│       └── QualysKBHelpers.psm1           # Shared helper functions
├── scripts/
│   └── Deploy-Solution.ps1               # Automated deployment script
├── run.ps1                                # LEGACY (retained for reference)
├── function.json                          # LEGACY (retained for reference)
└── README.md                             # This file
```

## Deployment Options

### Option A: Azure Portal Custom Template (Recommended for quick setup)

Use `azuredeploy.json` as described in [Portal Deployment](#portal-deployment-custom-template) above.

### Option B: Scripted Deployment

See the options below using the modular `infra/` templates and the deployment script.

## Prerequisites

- Azure subscription with Contributor access
- Existing Log Analytics workspace (Sentinel-enabled recommended)
- Qualys VM subscription with API access
- Azure PowerShell (`Az` module) installed
- Azure Functions Core Tools (for local testing)

## Deployment

### Option 1: Automated (Recommended)

1. Edit `infra/main.parameters.json` with your values:
   - `workspaceName` and `workspaceResourceId`
   - `functionAppName` and `storageAccountName`
   - `qualysUri`, `qualysApiUsername`, `qualysApiPassword`
   - `location` (must match workspace region)

2. Run the deployment script:

```powershell
Connect-AzAccount
Set-AzContext -SubscriptionId "<your-subscription-id>"

.\scripts\Deploy-Solution.ps1 `
    -ResourceGroupName "rg-qualyskb-prod" `
    -ParametersFile ".\infra\main.parameters.json"
```

### Option 2: Step-by-Step

Deploy individual ARM templates in this order:

```powershell
# 1. Function App infrastructure
New-AzResourceGroupDeployment -ResourceGroupName $rg `
    -TemplateFile .\infra\functionapp.template.json `
    -TemplateParameterFile .\infra\main.parameters.json

# 2. Custom table
New-AzResourceGroupDeployment -ResourceGroupName $rg `
    -TemplateFile .\infra\table.template.json `
    -workspaceName "law-qualyskb-prod" -tableName "QualysKB_CL"

# 3. Data Collection Endpoint
New-AzResourceGroupDeployment -ResourceGroupName $rg `
    -TemplateFile .\infra\dce.template.json `
    -dceName "dce-qualyskb-prod"

# 4. Data Collection Rule
New-AzResourceGroupDeployment -ResourceGroupName $rg `
    -TemplateFile .\infra\dcr.template.json `
    -dcrName "dcr-qualyskb-prod" `
    -dceResourceId "<dce-resource-id>" `
    -workspaceResourceId "<workspace-resource-id>"

# 5. RBAC assignments
New-AzResourceGroupDeployment -ResourceGroupName $rg `
    -TemplateFile .\infra\roleassignments.template.json `
    -dcrResourceId "<dcr-resource-id>" `
    -dcrName "dcr-qualyskb-prod" `
    -functionAppPrincipalId "<managed-identity-principal-id>" `
    -storageAccountName "stqualyskbprod"

# 6. Deploy function code
Compress-Archive -Path .\functionapp\* -DestinationPath func.zip
Publish-AzWebapp -ResourceGroupName $rg -Name "func-qualyskb-prod" -ArchivePath func.zip
```

## App Settings Reference

| Setting | Description | Example |
|---|---|---|
| `qualysUri` | Qualys API base URI | `https://qualysapi.qualys.com/api/2.0` |
| `apiUsername` | Qualys API username (or Key Vault reference) | `scanner-svc` |
| `apiPassword` | Qualys API password (or Key Vault reference) | `••••••` |
| `dceEndpoint` | DCE logs ingestion endpoint | `https://dce-xxx.region.ingest.monitor.azure.com` |
| `dcrImmutableId` | DCR immutable ID | `dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `dcrStreamName` | DCR stream name | `Custom-QualysKB_CL` |
| `checkpointContainerName` | Blob container for checkpoint | `qualyskb-checkpoints` |
| `filterParameters` | Optional Qualys KB filters | `details=All` |
| `timeInterval` | Default lookback in minutes | `5` |
| `timerSchedule` | CRON expression | `0 */5 * * * *` |

## Validation

After deployment, verify data ingestion with KQL:

```kql
QualysKB_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, QID, Title, Severity_Level, CVE_ID
| take 20
```

## Key Vault Integration

To use Azure Key Vault for Qualys credentials:

1. Create secrets `qualys-api-username` and `qualys-api-password` in your Key Vault.
2. Set the `keyVaultName` parameter in the ARM deployment.
3. Grant the Function App managed identity the `Key Vault Secrets User` role on the Key Vault.

The ARM template automatically generates Key Vault reference app settings when `keyVaultName` is provided.

## Migration from Legacy Data Collector API

See [docs/DESIGN.md](docs/DESIGN.md) for the full migration design, including:
- Architecture comparison
- Schema mapping
- DCR/DCE configuration details
- Step-by-step migration plan
- Risks and gotchas
- Validation queries
