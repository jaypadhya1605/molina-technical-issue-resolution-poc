<#
.SYNOPSIS
  Tears the PoC down: deletes the resource group (every Azure resource in it) and the Entra app registration
  "kms-ai-gateway-poc" (app roles KMS.Search / KMS.Ingest). Asks for confirmation unless -Force is passed.
  Nothing outside the resource group and that one app registration is touched.
.EXAMPLE
  .\Remove-Poc.ps1
#>
param([switch]$Force)
. "$PSScriptRoot\_common.ps1"

Write-Section 'Remove the Molina KMS OAuth PoC'
Write-Info "Resource group : $($Kms.resourceGroup)  (subscription $($Kms.subscriptionId))"
Write-Info "Entra app      : kms-ai-gateway-poc  (appId $($Kms.gatewayAppId))"
if (-not $Force) {
    $answer = Read-Host "   Type the resource group name to confirm"
    if ($answer -ne $Kms.resourceGroup) { Write-Host '   Cancelled.' -ForegroundColor DarkYellow; return }
}

Write-Step '1. Delete the resource group (runs in the background in Azure, ~10-20 min)'
[void](Invoke-Az group delete -n $Kms.resourceGroup --subscription $Kms.subscriptionId --yes --no-wait)
Write-Pass "Deletion of $($Kms.resourceGroup) started"

Write-Step '2. Delete the Entra app registration (its service principal goes with it)'
[void](Invoke-Az ad app delete --id $Kms.gatewayAppId)
Write-Pass 'App registration deleted (restorable for 30 days from Entra ID > App registrations > Deleted applications)'

Write-Info 'Azure OpenAI and API Management are soft-deleted with the resource group (retained 48 h). Purge only if you need the names back:'
Write-Info "  az cognitiveservices account purge -g $($Kms.resourceGroup) -n $($Kms.aoaiName) -l $($Kms.location)"
Write-Info "  az apim deletedservice purge --service-name $($Kms.apimName) --location $($Kms.location)"
Write-Info "Track progress: az group show -n $($Kms.resourceGroup)"
