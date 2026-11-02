<#
.SYNOPSIS
  Turns Azure AI Search public network access on or off.
  Disabled (the demo/production posture): the service is reachable only through its private endpoint, so the only
  way for people and apps to query it is through Azure API Management. AI Search's own outbound calls (ADLS, APIM)
  are unaffected because they use shared private links.
  Enabled: only needed to run Setup-SearchObjects.ps1 or to use Search Explorer in the Azure portal from a laptop.
.EXAMPLE
  .\Set-SearchPublicAccess.ps1 -State Disabled
#>
param([Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string]$State)
. "$PSScriptRoot\_common.ps1"

Write-Section "Azure AI Search public network access -> $State"
$url = "https://management.azure.com/subscriptions/$($Kms.subscriptionId)/resourceGroups/$($Kms.resourceGroup)/providers/Microsoft.Search/searchServices/$($Kms.searchService)?api-version=2025-05-01"
$bodyFile = Join-Path $env:TEMP 'kms-search-pna.json'
Set-Content -Path $bodyFile -Value (@{ properties = @{ publicNetworkAccess = $State } } | ConvertTo-Json -Compress) -Encoding ascii
try {
    [void](Invoke-Az rest --method patch --url $url --body "@$bodyFile" --headers 'Content-Type=application/json' -o json)
} finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }

for ($i = 0; $i -lt 40; $i++) {
    try { $s = (Invoke-Az rest --method get --url $url -o json) -join "`n" | ConvertFrom-Json }
    catch { Write-Info 'status check failed (transient az error) - retrying'; Start-Sleep -Seconds 15; continue }
    Write-Info ("provisioningState={0}  status={1}  publicNetworkAccess={2}" -f $s.properties.provisioningState, $s.properties.status, $s.properties.publicNetworkAccess)
    if ($s.properties.provisioningState -eq 'succeeded' -and $s.properties.status -eq 'running' -and $s.properties.publicNetworkAccess -eq $State) { break }
    Start-Sleep -Seconds 15
}
if ($s.properties.publicNetworkAccess -eq $State -and $s.properties.status -eq 'running') { Write-Pass "AI Search public network access is $State" } else { Write-Fail 'Update did not complete; check the Azure portal.' }
