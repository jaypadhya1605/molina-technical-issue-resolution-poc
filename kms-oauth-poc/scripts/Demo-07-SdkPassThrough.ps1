<#
.SYNOPSIS
  Demo 7 - Drop-in endpoint for the existing Python app (azure-search-documents SDK).
  The app keeps its SearchClient code and changes two settings:
    endpoint   = https://<apim>/aisearch           (instead of https://<search>.search.windows.net)
    credential = DefaultAzureCredential(), audience = api://<gateway app>   (instead of AzureKeyCredential)
  This script sends the exact URL shapes the SDK sends:
    1. SearchClient.search()          POST /indexes('<index>')/docs/search.post.search -> 200, guardrail applied
    2. SearchClient.get_document_count()  GET /indexes('<index>')/docs/$count           -> 200
    3. SearchIndexerClient.get_indexer_status()                                          -> 200
    4. Everything the app must NOT do through the gateway                                -> 403 operation_not_allowed
#>
param([switch]$Pause)
. "$PSScriptRoot\_common.ps1"

function Wait-Presenter { if ($Pause) { [void](Read-Host '   (Enter to continue)') } }
$base = "$($Kms.apimGateway)/aisearch"
$index = $Kms.indexName
$v = 'api-version=' + $Kms.searchApiVersion
$token = Get-KmsToken $Kms.gatewayAudience

Write-Section 'Demo 7 - Python SDK drop-in: same SearchClient, endpoint = APIM /aisearch, Entra token instead of an api-key'
Write-Info "endpoint = $base"
Write-Info "audience = $($Kms.gatewayAudience)   (azure-search-documents: SearchClient(..., audience=...))"

Write-Step "1. SearchClient.search()  ->  POST /indexes('$index')/docs/search.post.search"
$body = [ordered]@{
    search = 'member needs a ride to dialysis'; queryType = 'semantic'; semanticConfiguration = 'kms-semantic'
    vectorQueries = @(@{ kind = 'text'; text = 'member needs a ride to dialysis'; fields = 'content_vector'; k = 10 })
    filter = "lob/any(l: l eq 'Medicaid')"; select = 'article_id,title,heading,version,status'; top = 3; count = $true
}
$r = Invoke-KmsHttp -Method POST -Uri "$base/indexes('$index')/docs/search.post.search?$v" -Token $token -Body $body
Show-Response $r 'SDK search through APIM'
foreach ($d in @($r.Json.value)) { if ($d) { Write-Info ("{0:N2}  {1} v{2}  {3} :: {4}  [{5}]" -f $d.'@search.rerankerScore', $d.article_id, $d.version, $d.title, $d.heading, $d.status) } }
Assert-Status $r 200 'Search with the SDK URL shape'
if ($r.Headers['x-kms-guardrail']) { Write-Pass "Gateway ANDed the published-only guardrail onto the app's filter" } else { Write-Fail 'Guardrail header missing' }
Wait-Presenter

Write-Step "2. SearchClient.get_document_count()  ->  GET /indexes('$index')/docs/`$count"
$r = Invoke-KmsHttp -Uri ("$base/indexes('$index')/docs/" + '$count' + "?$v") -Token $token
Show-Response $r 'document count'
Write-Info "count = $($r.Body)  (all chunks, inventory view)"
Assert-Status $r 200 'Count'

Write-Step "3. SearchIndexerClient.get_indexer_status()  ->  GET /indexers('$($Kms.indexerName)')/search.status"
$r = Invoke-KmsHttp -Uri "$base/indexers('$($Kms.indexerName)')/search.status?$v" -Token $token
Show-Response $r 'indexer status'
if ($r.Json) { Write-Info ("status={0}  lastResult={1}  itemsProcessed={2}" -f $r.Json.status, $r.Json.lastResult.status, $r.Json.lastResult.itemsProcessed) }
Assert-Status $r 200 'Indexer status'
Wait-Presenter

Write-Step '4. Operations the KMS app must NOT perform through the gateway (allow-list, default deny)'
$denied = @(
    @{ m = 'GET'; p = "/indexes?$v"; what = 'list all indexes' }
    @{ m = 'GET'; p = "/indexes('$index')?$v"; what = 'read the index schema' }
    @{ m = 'DELETE'; p = "/indexes('kms-demo-nonexistent-denial-probe')?$v"; what = 'delete an index (safe nonexistent target)' }
    @{ m = 'POST'; p = "/indexes('$index')/docs/search.index?$v"; what = 'upload/overwrite documents (bypasses KMS publishing)'; b = '{"value":[{"@search.action":"upload","chunk_id":"x"}]}' }
    @{ m = 'GET'; p = "/indexes('$index')/docs('KA-1015_0')?$v"; what = 'lookup by key (would bypass the guardrail)' }
    @{ m = 'GET'; p = "/skillsets?$v"; what = 'read skillsets' }
    @{ m = 'GET'; p = "/servicestats?$v"; what = 'service statistics' }
)
foreach ($d in $denied) {
    $resp = Invoke-KmsHttp -Method $d.m -Uri ($base + $d.p) -Token $token -Body $d.b
    if ($resp.Status -eq 403 -and $resp.Json.error -eq 'operation_not_allowed') { Write-Pass "$($d.m) $($d.p.Split('?')[0]) -> 403 ($($d.what))" }
    else { Write-Fail "$($d.m) $($d.p.Split('?')[0]) -> HTTP $($resp.Status) (expected 403 operation_not_allowed)" }
}
Write-Info 'The Search admin/query keys are disabled at the service, so there is no key to leak either.'

if ($KmsFailures) { Write-Host "`n$KmsFailures check(s) failed." -ForegroundColor Red } else { Write-Host "`nAll SDK pass-through checks passed." -ForegroundColor Green }
