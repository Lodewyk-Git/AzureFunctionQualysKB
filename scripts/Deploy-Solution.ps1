<#
.SYNOPSIS
    Deploys the Qualys KB Logs Ingestion pipeline infrastructure and function code.

.DESCRIPTION
    This script deploys all ARM templates in the correct dependency order:
    1. Function App infrastructure (storage, plan, function app with managed identity)
    2. Custom table in Log Analytics workspace
    3. Data Collection Endpoint (DCE)
    4. Data Collection Rule (DCR) linked to DCE and workspace
    5. RBAC role assignments (Monitoring Metrics Publisher on DCR)
    6. Updates Function App settings with DCE/DCR values
    7. Deploys function code via ZIP deploy

.PARAMETER ResourceGroupName
    Target Azure resource group.

.PARAMETER ParametersFile
    Path to the main.parameters.json file.

.PARAMETER FunctionAppPath
    Path to the functionapp directory to ZIP and deploy.

.EXAMPLE
    .\Deploy-Solution.ps1 -ResourceGroupName "rg-qualyskb-prod" -ParametersFile "..\infra\main.parameters.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$ParametersFile,

    [string]$FunctionAppPath = "$PSScriptRoot\..\functionapp",

    [string]$TemplatesPath = "$PSScriptRoot\..\infra"
)

$ErrorActionPreference = "Stop"

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Qualys KB Logs Ingestion Pipeline — Deployment Script" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Verify Azure login
$context = Get-AzContext
if (-not $context) {
    throw "Not logged in to Azure. Run Connect-AzAccount first."
}
Write-Host "Azure context: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Gray

# Verify resource group exists
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    throw "Resource group '$ResourceGroupName' not found."
}

# ─── Step 1: Deploy main ARM template ─────────────────────────────────────────
Write-Host "`n[Step 1/3] Deploying infrastructure (main.template.json)..." -ForegroundColor Yellow

$mainDeployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile "$TemplatesPath\main.template.json" `
    -TemplateParameterFile $ParametersFile `
    -Name "qualyskb-infra-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    -Verbose

if ($mainDeployment.ProvisioningState -ne "Succeeded") {
    throw "Infrastructure deployment failed: $($mainDeployment.ProvisioningState)"
}

Write-Host "  Function App:        $($mainDeployment.Outputs.functionAppName.Value)" -ForegroundColor Green
Write-Host "  DCR Immutable ID:    $($mainDeployment.Outputs.dcrImmutableId.Value)" -ForegroundColor Green
Write-Host "  DCE Endpoint:        $($mainDeployment.Outputs.dceLogsIngestionEndpoint.Value)" -ForegroundColor Green
Write-Host "  Table:               $($mainDeployment.Outputs.tableName.Value)" -ForegroundColor Green
Write-Host "  Managed Identity:    $($mainDeployment.Outputs.managedIdentityPrincipalId.Value)" -ForegroundColor Green

# ─── Step 2: ZIP Deploy Function Code ─────────────────────────────────────────
Write-Host "`n[Step 2/3] Packaging and deploying function code..." -ForegroundColor Yellow

$zipPath = Join-Path $env:TEMP "qualyskb-functionapp-$(Get-Date -Format 'yyyyMMddHHmmss').zip"
$resolvedFunctionAppPath = Resolve-Path $FunctionAppPath

Write-Host "  Zipping $resolvedFunctionAppPath -> $zipPath"
Compress-Archive -Path "$resolvedFunctionAppPath\*" -DestinationPath $zipPath -Force

$functionAppName = $mainDeployment.Outputs.functionAppName.Value
Write-Host "  Deploying to Function App: $functionAppName"

Publish-AzWebapp -ResourceGroupName $ResourceGroupName -Name $functionAppName -ArchivePath $zipPath -Force

Write-Host "  Function code deployed successfully." -ForegroundColor Green

# Clean up temp zip
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# ─── Step 3: Validation ───────────────────────────────────────────────────────
Write-Host "`n[Step 3/3] Post-deployment validation..." -ForegroundColor Yellow

# Verify function app is running
$app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $functionAppName
Write-Host "  Function App state: $($app.State)" -ForegroundColor $(if ($app.State -eq "Running") { "Green" } else { "Red" })

# Verify managed identity
$identity = $app.Identity
if ($identity -and $identity.Type -match "SystemAssigned") {
    Write-Host "  Managed Identity: Enabled (PrincipalId: $($identity.PrincipalId))" -ForegroundColor Green
} else {
    Write-Warning "  Managed Identity: NOT enabled. RBAC assignments will not work."
}

# Output summary
Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Deployment Complete!" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Verify Qualys API credentials are configured (app settings or Key Vault)."
Write-Host "  2. Trigger the function manually or wait for the timer schedule."
Write-Host "  3. Check logs in Application Insights or Function App log stream."
Write-Host "  4. Run KQL query: QualysKB_CL | take 10"
Write-Host "  5. Compare with legacy table during parallel-run period."
