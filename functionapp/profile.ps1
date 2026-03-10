# Azure Functions profile.ps1
#
# This profile runs on every cold start of the Function App.
# Use it to perform one-time initialisation tasks.

# Authenticate with Azure PowerShell using the managed identity (for Az.Storage operations)
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Write-Host "Connected to Azure using Managed Identity."
}
