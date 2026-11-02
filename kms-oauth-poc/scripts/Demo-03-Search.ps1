<#
.SYNOPSIS
  Demo 3 - Query side: hybrid (keyword + vector) + semantic ranking through APIM, LOB / State / Effective Date
  filters, and the gateway-enforced "published + currently effective" guardrail.
  Query vectors are created by AI Search's vectorizer, which calls Azure OpenAI THROUGH APIM (same model as indexing).
.PARAMETER Pause
  Waits for Enter between scenes (useful when presenting).
#>
param([switch]$Pause)
. "$PSScriptRoot\_common.ps1"

function Wait-Presenter { if ($Pause) { [void](Read-Host '   (Enter to continue)') } }
function Format-Day($d) {
    if ($d -is [datetime]) { return $d.ToUniversalTime().ToString('yyyy-MM-dd') }
    if ($d) { return ([string]$d).Substring(0, 10) }
    return ''
}

$api = Get-KmsApiBase
$token = Get-KmsToken $Kms.gatewayAudience

function Search-Kms {
    param([string]$Label, [string]$Query, [string]$Filter, [int]$Top = 3, [switch]$KeywordOnly)
    $body = [ordered]@{ search = $Query; select = 'article_id,title,heading,version,lob,state,effective_date,expiration_date,status'; top = $Top }
    if (-not $KeywordOnly) {
        $body.queryType = 'semantic'
        $body.semanticConfiguration = 'kms-semantic'
        $body.vectorQueries = @(@{ kind = 'text'; text = $Query; fields = 'content_vector'; k = 10 })
    }
    if ($Filter) { $body.filter = $Filter }
    Write-Step $Label
    Write-Info "query : $Query"
    if ($Filter) { Write-Info "filter: $Filter" }
    $r = Invoke-KmsHttp -Method POST -Uri "$api/search" -Token $token -Body $body
    Show-Response $r 'POST /kms/search'
    Assert-Status $r 200 $Label
    if ($r.Status -ne 200) { Write-Info $r.Body; return $r }
    if (@($r.Json.value).Count -eq 0) { Write-Host '   (no results)' -ForegroundColor DarkYellow; return $r }
    $r.Json.value | ForEach-Object {
        $score = if ($_.'@search.rerankerScore') { $_.'@search.rerankerScore' } else { $_.'@search.score' }
        [pscustomobject]@{
            score     = '{0:N2}' -f $score
            article   = "$($_.article_id) v$($_.version)"
            title     = $_.title
            section   = $_.heading
            lob       = ($_.lob -join '/')
            state     = ($_.state -join '/')
            effective = Format-Day $_.effective_date
        }
    } | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    return $r
}

Write-Section 'Demo 3 - Search through APIM: hybrid + semantic, filters, published-only guardrail'
$claims = Get-JwtClaims $token
$who = @($claims.name, $claims.preferred_username, $claims.upn, $claims.oid) | Where-Object { $_ } | Select-Object -First 1
Write-Info "Caller: $who (delegated token for $($Kms.gatewayAudience), roles: $($claims.roles -join ', '))"
Write-Info 'Path  : laptop -> APIM (validate-azure-ad-token, role check, guardrail) -> AI Search (APIM managed identity)'

$r = Search-Kms -Label '1. Hybrid + semantic: natural-language agent question' -Query 'member needs a ride to dialysis'
if ($r.Json.value[0].article_id -eq 'KA-1003') { Write-Pass 'Top hit is KA-1003 NEMT (vector + keyword + semantic reranker)' } else { Write-Fail 'Expected KA-1003 as the top hit' }
if ($r.Json.value[0].'@search.rerankerScore' -gt 0 -and $r.Json.value[0].'@search.score' -gt 0) { Write-Pass 'Search returned both retrieval and semantic reranker scores' } else { Write-Fail 'Expected retrieval and semantic reranker scores' }
Wait-Presenter

$r = Search-Kms -Label '2. Same question, LOB filter = Medicare (NEMT article is Medicaid-only)' -Query 'member needs a ride to dialysis' -Filter "lob/any(l: l eq 'Medicare')"
if (@($r.Json.value).Count -gt 0 -and @($r.Json.value | Where-Object { $_.lob -notcontains 'Medicare' }).Count -eq 0) { Write-Pass 'Every returned article satisfies the Medicare LOB filter' } else { Write-Fail 'LOB filtering returned empty or incorrect results' }
if (-not ($r.Json.value | Where-Object article_id -eq 'KA-1003')) { Write-Pass 'KA-1003 filtered out for Medicare' } else { Write-Fail 'KA-1003 should not match a Medicare filter' }
Wait-Presenter

$r = Search-Kms -Label '3. LOB + State: Medicare member in California got a bill' -Query 'member has Medicare and Medicaid and the doctor sent them a bill' -Filter "lob/any(l: l eq 'Medicare') and state/any(s: s eq 'CA')"
if (@($r.Json.value).Count -gt 0 -and @($r.Json.value | Where-Object { $_.lob -notcontains 'Medicare' -or $_.state -notcontains 'CA' }).Count -eq 0) { Write-Pass 'Every returned article satisfies both LOB and State filters' } else { Write-Fail 'LOB/State filtering returned empty or incorrect results' }
if ($r.Json.value[0].article_id -eq 'KA-1006') { Write-Pass 'Top hit is KA-1006 Dual-Eligible / balance billing' } else { Write-Fail 'Expected KA-1006 as the top hit' }
Wait-Presenter

$r = Search-Kms -Label '4. Effective Date filter: articles that took effect in 2026' -Query '*' -KeywordOnly -Top 10 -Filter 'effective_date ge 2026-01-01T00:00:00Z'
if (@($r.Json.value).Count -gt 0 -and @($r.Json.value | Where-Object { [datetime]$_.effective_date -lt [datetime]'2026-01-01T00:00:00Z' }).Count -eq 0) { Write-Pass 'Every result satisfies the Effective Date filter' } else { Write-Fail 'Effective Date filtering returned empty or incorrect results' }
Wait-Presenter

Write-Section 'Guardrail: only published, currently effective articles reach agents'
$r = Search-Kms -Label '5a. Future-effective article (KA-1011 adult dental, effective 2027-01-01)' -Query 'adult dental cleanings and x-rays' -Top 3
if (-not ($r.Json.value | Where-Object article_id -eq 'KA-1011')) { Write-Pass 'KA-1011 hidden until its effective date' } else { Write-Fail 'KA-1011 should be hidden' }
$r = Search-Kms -Label '5b. Expired article (KA-1012 flu outreach script, expired 2026-06-30)' -Query 'flu vaccine outreach script' -Top 3
if (-not ($r.Json.value | Where-Object article_id -eq 'KA-1012')) { Write-Pass 'KA-1012 hidden after expiration' } else { Write-Fail 'KA-1012 should be hidden' }
$r = Search-Kms -Label "5c. Client tries to bypass: filter status eq 'out-for-validation' (KA-1015 draft)" -Query '*' -KeywordOnly -Filter "status eq 'out-for-validation'"
if (@($r.Json.value).Count -eq 0) { Write-Pass 'Gateway ANDs the guardrail onto any client filter - drafts never leak' } else { Write-Fail 'Draft content leaked' }
Wait-Presenter

Write-Step '5d. ...yet all three ARE in the index (the guardrail is a query-time policy, not missing data)'
foreach ($id in 'KA-1011', 'KA-1012', 'KA-1015') {
    $c = Invoke-KmsHttp -Uri "$api/articles/$id/chunks" -Token $token
    Assert-Status $c 200 "Inventory for $id"
    $j = $c.Json
    if ($j.inIndex -eq $true -and $j.chunkCount -gt 0) { Write-Pass "$id is present in the index" } else { Write-Fail "$id is missing, so its exclusion is not guardrail proof" }
    Write-Info ("{0}  inIndex={1}  status={2}  chunks={3}  v{4}" -f $id, $j.inIndex, $j.status, $j.chunkCount, $j.version)
}
Wait-Presenter

Write-Step '6. Index statistics (facets) through GET /kms/stats'
$s = Invoke-KmsHttp -Uri "$api/stats" -Token $token
Show-Response $s 'GET /kms/stats'
Assert-Status $s 200 'Inventory facets'
function Format-Facet($o) { (($o.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ') }
Write-Info ("index={0} totalChunks={1} (inventory view - includes hidden drafts/expired)" -f $s.Json.index, $s.Json.totalChunks)
Write-Info ('LOB    : ' + (Format-Facet $s.Json.lob))
Write-Info ('State  : ' + (Format-Facet $s.Json.state))
Write-Info ('Status : ' + (Format-Facet $s.Json.status))
Write-Info ('Chunks : ' + (Format-Facet $s.Json.chunksPerArticle))

if ($KmsFailures) { Write-Host "`n$KmsFailures check(s) failed." -ForegroundColor Red } else { Write-Host "`nAll search checks passed." -ForegroundColor Green }
