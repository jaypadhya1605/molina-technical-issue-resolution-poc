<#
.SYNOPSIS
  Demo 1 - Security posture of the deployed PoC, read live from Azure Resource Manager and Microsoft Graph.
  Proves: keys/local auth disabled everywhere, private networking, managed identities, least-privilege RBAC,
  shared private links approved, and who holds which Entra app role on the gateway API.
#>
. "$PSScriptRoot\_common.ps1"

$rg = $Kms.resourceGroup
$sub = $Kms.subscriptionId
$base = "/subscriptions/$sub/resourceGroups/$rg/providers"

function Get-Arm([string]$Id, [string]$ApiVersion) {
    (Invoke-Az rest --method get --url "https://management.azure.com$Id`?api-version=$ApiVersion" -o json) -join "`n" | ConvertFrom-Json
}
function Test-Setting([string]$Label, [bool]$Ok, [string]$Detail) { if ($Ok) { Write-Pass "$Label  ($Detail)" } else { Write-Fail "$Label  ($Detail)" } }
function Get-PrincipalName([string]$Id) {
    $p = $Kms.principals.PSObject.Properties | Where-Object Name -eq $Id
    if ($p) { $p.Value } else { $Id }
}

Write-Section 'Demo 1 - Posture: no keys, private networking, managed identities, least privilege'

Write-Step 'ADLS Gen2 (article landing zone)'
$st = Get-Arm "$base/Microsoft.Storage/storageAccounts/$($Kms.storageAccount)" '2023-05-01'
Test-Setting 'Shared key / SAS disabled (OAuth only)' ($st.properties.allowSharedKeyAccess -eq $false) "allowSharedKeyAccess=$($st.properties.allowSharedKeyAccess)"
Test-Setting 'Public network access disabled' ($st.properties.publicNetworkAccess -eq 'Disabled') "publicNetworkAccess=$($st.properties.publicNetworkAccess)"
Test-Setting 'Hierarchical namespace (ADLS Gen2)' ($st.properties.isHnsEnabled -eq $true) "isHnsEnabled=$($st.properties.isHnsEnabled)"

Write-Step 'Azure OpenAI (embedding model)'
$ao = Get-Arm "$base/Microsoft.CognitiveServices/accounts/$($Kms.aoaiName)" '2024-10-01'
Test-Setting 'API keys disabled (Entra ID only)' ($ao.properties.disableLocalAuth -eq $true) "disableLocalAuth=$($ao.properties.disableLocalAuth)"
Test-Setting 'Public network access disabled' ($ao.properties.publicNetworkAccess -eq 'Disabled') "publicNetworkAccess=$($ao.properties.publicNetworkAccess)"
$dep = Get-Arm "$base/Microsoft.CognitiveServices/accounts/$($Kms.aoaiName)/deployments/$($Kms.embeddingDeployment)" '2024-10-01'
Write-Info "Deployment: $($dep.name) -> model $($dep.properties.model.name) v$($dep.properties.model.version) ($($dep.sku.name))"

Write-Step 'Azure AI Search'
$sr = Get-Arm "$base/Microsoft.Search/searchServices/$($Kms.searchService)" '2025-05-01'
Test-Setting 'API keys disabled (Entra ID RBAC only)' ($sr.properties.disableLocalAuth -eq $true) "disableLocalAuth=$($sr.properties.disableLocalAuth)"
Test-Setting 'System-assigned managed identity' ($sr.identity.type -match 'SystemAssigned') "identity=$($sr.identity.type)"
Write-Info "Public network access: $($sr.properties.publicNetworkAccess)  (Disabled after lockdown - see Set-SearchPublicAccess.ps1)"
$spls = (Get-Arm "$base/Microsoft.Search/searchServices/$($Kms.searchService)/sharedPrivateLinkResources" '2025-05-01').value
foreach ($s in $spls) {
    Test-Setting "Shared private link $($s.name) -> $($s.properties.groupId)" ($s.properties.status -eq 'Approved') "status=$($s.properties.status), target=$(($s.properties.privateLinkResourceId -split '/')[-1])"
}

Write-Step 'Azure API Management (AI gateway)'
$ap = Get-Arm "$base/Microsoft.ApiManagement/service/$($Kms.apimName)" '2024-05-01'
Write-Info "SKU: $($ap.sku.name)   VNet integration (outbound): $($ap.properties.virtualNetworkType) -> $(($ap.properties.virtualNetworkConfiguration.subnetResourceId -split '/')[-1])"
Test-Setting 'System-assigned managed identity (calls backends without keys)' ($ap.identity.type -match 'SystemAssigned') "identity=$($ap.identity.type)"
$pecs = (Get-Arm "$base/Microsoft.ApiManagement/service/$($Kms.apimName)/privateEndpointConnections" '2024-05-01').value
foreach ($p in $pecs) {
    $who = if ($p.name -like 'spl-*') { 'AI Search shared private link' } else { 'VNet private endpoint (on-prem / VM path)' }
    Test-Setting "Private endpoint connection $($p.name) [$who]" ($p.properties.privateLinkServiceConnectionState.status -eq 'Approved') "status=$($p.properties.privateLinkServiceConnectionState.status)"
}
$nv = Get-Arm "$base/Microsoft.ApiManagement/service/$($Kms.apimName)/namedValues/kms-require-private-link" '2024-05-01'
Write-Info "Private-link-only switch (named value kms-require-private-link): $($nv.properties.value)"

Write-Step 'KMS server stand-in (vm-kms-app)'
$vm = Get-Arm "$base/Microsoft.Compute/virtualMachines/$($Kms.vmName)" '2024-07-01'
$nicId = $vm.properties.networkProfile.networkInterfaces[0].id
$nic = Get-Arm $nicId '2024-05-01'
$pip = $nic.properties.ipConfigurations[0].properties.publicIPAddress
Test-Setting 'No public IP (reached only via Azure Run Command)' ($null -eq $pip) "privateIp=$($nic.properties.ipConfigurations[0].properties.privateIPAddress)"
Test-Setting 'Managed identities (system + agent app user-assigned)' ($vm.identity.type -match 'SystemAssigned') "identity=$($vm.identity.type)"

Write-Step 'Azure RBAC - data-plane roles held by workload identities (least privilege)'
try {
    $ra = (Invoke-Az role assignment list --all --query "[].{p:principalId,role:roleDefinitionName,scope:scope}" -o json) -join "`n" | ConvertFrom-Json
    $ra | Where-Object { $_.scope -like "*/resourceGroups/$rg*" -and $Kms.principals.PSObject.Properties.Name -contains $_.p } |
        Sort-Object p, role |
        ForEach-Object { [pscustomobject]@{ identity = Get-PrincipalName $_.p; role = $_.role; scope = (($_.scope -split '/providers/')[-1]) } } |
        Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}
catch { Write-Info "Could not list role assignments right now (transient Azure CLI token error). Re-run, or show Access control (IAM) on the resource group." }

Write-Step "Entra ID app roles on the gateway API ($($Kms.gatewayAudience))"
try {
    $sp = (Invoke-Az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($Kms.gatewaySpObjectId)?`$select=appRoles,displayName" -o json) -join "`n" | ConvertFrom-Json
    $roleNames = @{}
    foreach ($r in $sp.appRoles) { $roleNames[$r.id] = $r.value }
    $assigned = ((Invoke-Az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($Kms.gatewaySpObjectId)/appRoleAssignedTo" -o json) -join "`n" | ConvertFrom-Json).value
    $assigned | ForEach-Object { [pscustomobject]@{ principal = $_.principalDisplayName; type = $_.principalType; appRole = $roleNames[$_.appRoleId] } } |
        Sort-Object appRole, principal | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}
catch { Write-Info "Could not read Microsoft Graph right now (transient Azure CLI token error). Re-run, or show Entra ID > Enterprise applications > kms-ai-gateway-poc > Users and groups." }

if ($KmsFailures) { Write-Host "$KmsFailures posture check(s) failed." -ForegroundColor Red } else { Write-Host 'All posture checks passed.' -ForegroundColor Green }
