<#
.SYNOPSIS
  Demo 2 - OAuth 2.0 everywhere. Runs from the presenter's laptop (public internet) and proves:
    - APIM accepts only signed Entra ID tokens issued for the KMS gateway API (no token, wrong audience
      or a tampered token = 401),
    - the embedding API on APIM accepts ONLY the AI Search managed identity,
    - Azure OpenAI, ADLS Gen2 and AI Search cannot be reached directly at all (keys disabled + private only),
    - the one supported path (Entra token -> APIM -> AI Search with APIM's managed identity) works.
.PARAMETER Pause
  Waits for Enter between scenes.
#>
param([switch]$Pause)
. "$PSScriptRoot\_common.ps1"

function Wait-Presenter { if ($Pause) { [void](Read-Host '   (Enter to continue)') } }
$matrix = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$Caller, [string]$Call, [int[]]$Expected, $Response) {
    $ok = $Expected -contains $Response.Status
    if ($ok) { Write-Pass "$Call -> HTTP $($Response.Status)" } else { Write-Fail "$Call -> HTTP $($Response.Status) (expected $($Expected -join '/'))" }
    $matrix.Add([pscustomobject]@{ caller = $Caller; call = $Call; expected = ($Expected -join '/'); actual = $Response.Status; result = $(if ($ok) { 'PASS' } else { 'FAIL' }) })
}
function Show-Error($Response) {
    $msg = if ($Response.Json.message) { $Response.Json.message } elseif ($Response.Json.error.message) { $Response.Json.error.message } elseif ($Response.Json.error) { $Response.Json.error } else { $Response.Body }
    if ($msg) { $m = [string]$msg; Write-Info ('response: ' + $m.Substring(0, [Math]::Min(220, $m.Length))) }
}
function New-TamperedToken([string]$Token) {
    $parts = $Token.Split('.')
    $claims = Get-JwtClaims $Token
    $claims | Add-Member -NotePropertyName roles -NotePropertyValue @('KMS.Search', 'KMS.Ingest', 'KMS.Admin') -Force
    $json = $claims | ConvertTo-Json -Compress -Depth 10
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "$($parts[0]).$b64.$($parts[2])"
}

$api = Get-KmsApiBase
$me = 'Jay (laptop, internet)'
Write-Section 'Demo 2 - OAuth 2.0 everywhere: the gateway only trusts Entra ID, the backends trust nobody outside'

Write-Step '1. No token'
$r = Invoke-KmsHttp -Uri "$api/whoami"
Show-Response $r 'GET /kms/whoami  (no Authorization header)'
Add-Row 'anonymous' 'APIM /kms/whoami, no token' 401 $r
Show-Error $r
Wait-Presenter

Write-Step '2. A real Entra ID token - but issued for a different API (Azure Resource Manager)'
$armToken = Get-KmsToken 'https://management.azure.com'
Write-Info "token aud = $((Get-JwtClaims $armToken).aud)"
$r = Invoke-KmsHttp -Uri "$api/whoami" -Token $armToken
Show-Response $r 'GET /kms/whoami  (ARM token)'
Add-Row $me 'APIM /kms/whoami, wrong-audience token' 401 $r
Wait-Presenter

Write-Step '3. Correct token, but the caller edits the roles claim to grant itself KMS.Admin'
$token = Get-KmsToken $Kms.gatewayAudience
$forged = New-TamperedToken $token
Write-Info "forged roles = $((Get-JwtClaims $forged).roles -join ', ')  (signature no longer matches)"
$r = Invoke-KmsHttp -Uri "$api/whoami" -Token $forged
Show-Response $r 'GET /kms/whoami  (tampered token)'
Add-Row $me 'APIM /kms/whoami, tampered token' 401 $r
Wait-Presenter

Write-Step "4. The supported path: Entra ID access token for the KMS gateway API ($($Kms.gatewayAudience))"
$c = Get-JwtClaims $token
Write-Info ("token: aud={0}  ver={1}  name={2}  scp={3}  roles={4}" -f $c.aud, $c.ver, $c.name, $c.scp, ($c.roles -join ','))
$r = Invoke-KmsHttp -Uri "$api/whoami" -Token $token
Show-Response $r 'GET /kms/whoami'
Add-Row $me 'APIM /kms/whoami, valid gateway token' 200 $r
if ($r.Status -eq 200) {
    $r.Json | Select-Object validatedBy, audience, callerType, callerName, appRoles, viaPrivateEndpoint, clientIp |
        Format-List | Out-String -Width 200 | ForEach-Object { $_.Trim() } | Write-Host -ForegroundColor Gray
}
$q = @{ search = 'member needs a ride to dialysis'; select = 'article_id,title,heading'; top = 1; queryType = 'semantic'; semanticConfiguration = 'kms-semantic'; vectorQueries = @(@{ kind = 'text'; text = 'member needs a ride to dialysis'; fields = 'content_vector'; k = 10 }) }
$r = Invoke-KmsHttp -Method POST -Uri "$api/search" -Token $token -Body $q
Show-Response $r 'POST /kms/search'
Add-Row $me 'APIM /kms/search, valid token + KMS.Search role' 200 $r
if ($r.Status -eq 200 -and $r.Json.value) { Write-Info ("top hit: {0} - {1} :: {2}" -f $r.Json.value[0].article_id, $r.Json.value[0].title, $r.Json.value[0].heading) }
Wait-Presenter

Write-Step '5. The embedding API on APIM is reserved for the AI Search managed identity'
$cogToken = Get-KmsToken 'https://cognitiveservices.azure.com'
Write-Info "token aud = $((Get-JwtClaims $cogToken).aud)  (correct audience, but the caller is a person, not AI Search)"
$embedBody = @{ input = 'member needs a ride to dialysis' }
$r = Invoke-KmsHttp -Method POST -Uri "$($Kms.apimGateway)/openai/deployments/$($Kms.embeddingDeployment)/embeddings?api-version=2024-10-21" -Token $cogToken -Body $embedBody
Show-Response $r 'POST /openai/deployments/.../embeddings'
Add-Row $me 'APIM /openai embeddings (not the AI Search MI)' 401 $r
Show-Error $r
Wait-Presenter

Write-Step '6. Going around the gateway: every backend refuses (keys disabled + public network access disabled)'
$aoai = "https://$($Kms.aoaiName).openai.azure.com/openai/deployments/$($Kms.embeddingDeployment)/embeddings?api-version=2024-10-21"
$r = Invoke-KmsHttp -Method POST -Uri $aoai -Body $embedBody -Headers @{ 'api-key' = '00000000000000000000000000000000' }
Show-Response $r 'Azure OpenAI direct, API key'
Add-Row $me 'Azure OpenAI direct, API key' 401, 403 $r
Show-Error $r
$r = Invoke-KmsHttp -Method POST -Uri $aoai -Token $cogToken -Body $embedBody
Show-Response $r 'Azure OpenAI direct, Entra token'
Add-Row $me 'Azure OpenAI direct, Entra token' 401, 403 $r
Show-Error $r

$stToken = Get-KmsToken 'https://storage.azure.com'
$r = Invoke-KmsHttp -Uri "https://$($Kms.storageAccount).blob.core.windows.net/$($Kms.container)?restype=container&comp=list&maxresults=5" -Token $stToken -Headers @{ 'x-ms-version' = '2023-11-03' }
Show-Response $r 'ADLS Gen2 direct, Entra token'
Add-Row $me 'ADLS Gen2 direct, Entra token' 403 $r
if ($r.Body -match '<Code>([^<]+)</Code>') { Write-Info "response: $($Matches[1])" }

$searchUri = "$(Get-SearchBase)/indexes/$($Kms.indexName)/docs/search?api-version=$($Kms.searchApiVersion)"
$r = Invoke-KmsHttp -Method POST -Uri $searchUri -Body @{ search = '*'; top = 1 } -Headers @{ 'api-key' = '00000000000000000000000000000000' }
Show-Response $r 'AI Search direct, API key'
Add-Row $me 'AI Search direct, API key' 401, 403 $r
$srToken = Get-KmsToken 'https://search.azure.com'
$r = Invoke-KmsHttp -Method POST -Uri $searchUri -Token $srToken -Body @{ search = '*'; top = 1 }
Show-Response $r 'AI Search direct, Entra token (presenter holds Search RBAC)'
Add-Row $me 'AI Search direct, Entra token' 403 $r
if ($r.Status -eq 200) { Write-Info 'AI Search public access is still Enabled. Lock it down: .\Set-SearchPublicAccess.ps1 -State Disabled' }

Write-Section 'Result matrix'
$matrix | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
if ($KmsFailures) { Write-Host "$KmsFailures check(s) failed." -ForegroundColor Red } else { Write-Host 'All OAuth checks passed: the only way in is an Entra token through Azure API Management.' -ForegroundColor Green }
