<#
.SYNOPSIS
  Private-link-only switch: flip Azure API Management into "private-link only" mode and prove it.
  On : every /kms, /aisearch and /openai call that does NOT arrive through a private endpoint is rejected with
       403 private_link_required - even when it carries a valid Entra ID token. vm-kms-app (calls through the APIM
       private endpoint) and Azure AI Search (calls APIM through its shared private link) keep working.
  Off: internet callers are accepted again (still OAuth-only, still role-checked).
  The switch is one APIM named value (kms-require-private-link) that the policies read. No redeploy, no policy edit.
.PARAMETER ProveFromVm
  With -State On: also run the agent from vm-kms-app (private path) to show it still works (~45 s).
.EXAMPLE
  .\Set-PrivateLinkOnly.ps1 -State On -ProveFromVm
  .\Set-PrivateLinkOnly.ps1 -State Off
#>
param([Parameter(Mandatory)][ValidateSet('On', 'Off')][string]$State, [switch]$ProveFromVm, [int]$TimeoutSeconds = 180)
. "$PSScriptRoot\_common.ps1"

$value = if ($State -eq 'On') { 'true' } else { 'false' }
$expected = if ($State -eq 'On') { 403 } else { 200 }

Write-Section "Private-link-only switch (APIM named value) -> $State"

Write-Step "1. Set APIM named value kms-require-private-link = $value"
[void](Invoke-Az apim nv update -g $Kms.resourceGroup --service-name $Kms.apimName --named-value-id kms-require-private-link --value $value -o none)
Write-Info 'Read by the /kms, /aisearch and /openai policies: context.Request.PrivateEndpointConnection == null -> 403'

Write-Step '2. This laptop (public internet, valid OAuth token) calls GET /kms/whoami'
$token = Get-KmsToken $Kms.gatewayAudience
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    $r = Invoke-KmsHttp -Uri "$(Get-KmsApiBase)/whoami" -Token $token
    if ($r.Status -eq $expected) { break }
    Write-Info "HTTP $($r.Status) - waiting for the gateway to pick up the new value ..."
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $deadline)
Show-Response $r 'GET /kms/whoami from this laptop'
if ($r.Json) { Write-Info (($r.Json | Format-Json) -replace "`r?`n", "`n   ") }
$label = if ($State -eq 'On') { 'Valid token from the internet is refused (private_link_required)' } else { 'Laptop call with a valid token is accepted again' }
Assert-Status $r @($expected) $label

if ($State -eq 'On') {
    Write-Step '3. Same for the SDK pass-through endpoint'
    $s = Invoke-KmsHttp -Uri "$($Kms.apimGateway)/aisearch/indexes('$($Kms.indexName)')/docs/`$count?api-version=$($Kms.searchApiVersion)" -Token $token
    Show-Response $s "GET /aisearch/indexes('$($Kms.indexName)')/docs/`$count from this laptop"
    Assert-Status $s @(403) 'SDK endpoint refuses internet traffic too'

    if ($ProveFromVm) {
        Write-Step '4. The private path still works: agent on vm-kms-app -> APIM private endpoint -> AI Search -> (shared private link) -> APIM -> Azure OpenAI'
        & "$PSScriptRoot\Invoke-KmsVm.ps1" agent
    }
    else {
        Write-Info 'Prove the private path: .\Invoke-KmsVm.ps1 agent'
    }
    Write-Host "`nTurn it back off before the next demo run: .\Set-PrivateLinkOnly.ps1 -State Off" -ForegroundColor DarkCyan
}

if ($KmsFailures) { Write-Host "$KmsFailures check(s) failed." -ForegroundColor Red } else { Write-Host "Private-link-only is $State." -ForegroundColor Green }
