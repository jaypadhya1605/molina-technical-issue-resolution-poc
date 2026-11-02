<#
.SYNOPSIS
  Demo 4 - Article lifecycle with no orphaned chunks. Answers "how are old chunks removed when an article is republished?"
    1. Before: KA-1003 (NEMT) is in the index as v3 with 4 chunks.
    2. vm-kms-app (stand-in for the on-prem KMS server) writes v4 (2 chunks) to ADLS with its managed identity and
       sends a ~150-byte pointer to APIM. AI Search pulls v4 over the shared private link.
    3. After: v4 with 2 chunks. The v3 chunks 3 and 4 are gone (index projections replace a parent's chunks).
    4. The agent answer now cites v4.
    5. Unpublish: KA-1012 is retired. Its blob is deleted (soft delete), deletion detection removes every chunk.
  Each VM step takes 1-2 minutes (Run Command + indexer run).
.PARAMETER SkipUnpublish
  Run only the republish scenes.
.PARAMETER Restore
  Put the baseline back (KA-1003 v3 with 4 chunks, KA-1012 in the index) so the demo can be repeated.
#>
param([switch]$SkipUnpublish, [switch]$Restore, [switch]$Pause)
. "$PSScriptRoot\_common.ps1"

function Wait-Presenter { if ($Pause) { [void](Read-Host '   (Enter to continue)') } }
$api = Get-KmsApiBase
$token = Get-KmsToken $Kms.gatewayAudience

function Get-Chunks([string]$Id) { (Invoke-KmsHttp -Uri "$api/articles/$Id/chunks" -Token $token).Json }
function Show-Chunks([string]$Id, $J) {
    if (-not $J) { $J = Get-Chunks $Id }
    $published = if ($J.lastPublished) { ([string]$J.lastPublished).Substring(0, [Math]::Min(19, ([string]$J.lastPublished).Length)) } else { '' }
    Write-Info ("GET /kms/articles/{0}/chunks  ->  inIndex={1}  v{2}  status={3}  chunks={4}  lastPublished={5}" -f $Id, $J.inIndex, $J.version, $J.status, $J.chunkCount, $published)
    foreach ($c in @($J.chunks)) { if ($c) { Write-Info ("     chunk {0}  v{1}  {2,-44} {3}" -f $c.chunk_no, $c.version, $c.heading, $c.chunk_id) } }
    return $J
}
function Wait-Chunks([string]$Id, [scriptblock]$Done, [int]$Seconds = 180) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $j = Get-Chunks $Id
        if (& $Done $j) { return $j }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $j
}
function Invoke-Vm { & "$PSScriptRoot\Invoke-KmsVm.ps1" @args }

Write-Section 'Demo 4 - Republish replaces chunks, unpublish removes them (no orphaned chunks)'

if ($Restore) {
    Write-Step 'Restoring the demo baseline: KA-1003 v3 (4 chunks) and KA-1012'
    Invoke-Vm publish KA-1003 KA-1012
    $a = Show-Chunks 'KA-1003' (Wait-Chunks 'KA-1003' { param($j) [int]$j.version -eq 3 -and $j.chunkCount -eq 4 })
    $b = Show-Chunks 'KA-1012' (Wait-Chunks 'KA-1012' { param($j) $j.inIndex })
    if ([int]$a.version -eq 3 -and $a.chunkCount -eq 4 -and $b.inIndex) { Write-Pass 'Baseline restored' } else { Write-Fail 'Baseline not restored yet. Check: .\Invoke-KmsVm.ps1 status' }
    return
}

Write-Step '1. Before: KA-1003 (NEMT transportation) as it sits in the index today'
$before = Show-Chunks 'KA-1003'
if ([int]$before.version -ne 3 -or $before.chunkCount -ne 4) {
    Write-Host '   KA-1003 is not at the v3 / 4-chunk baseline. Run .\Demo-04-Republish.ps1 -Restore first.' -ForegroundColor DarkYellow
    return
}
Wait-Presenter

Write-Step '2. KMS publishes v4 (rewritten article, 2 chunks): ADLS write with the VM managed identity + pointer to APIM'
Invoke-Vm republish KA-1003
Wait-Presenter

Write-Step '3. After: same article ID, new version, fewer chunks'
$after = Show-Chunks 'KA-1003' (Wait-Chunks 'KA-1003' { param($j) [int]$j.version -eq 4 })
$stale = @($after.chunks | Where-Object { $_ -and [int]$_.version -ne 4 })
if ([int]$after.version -eq 4 -and $after.chunkCount -eq 2 -and $stale.Count -eq 0) {
    Write-Pass 'v3 (4 chunks) replaced by v4 (2 chunks). The 2 extra v3 chunks were deleted, nothing orphaned.'
}
else { Write-Fail "Expected v4 with 2 chunks, got v$($after.version) with $($after.chunkCount) chunks ($($stale.Count) stale)" }
Wait-Presenter

Write-Step '4. The agent answer now cites v4'
$r = Invoke-KmsHttp -Method POST -Uri "$api/search" -Token $token -Body ([ordered]@{
        search = 'member needs a ride to dialysis'; queryType = 'semantic'; semanticConfiguration = 'kms-semantic'
        vectorQueries = @(@{ kind = 'text'; text = 'member needs a ride to dialysis'; fields = 'content_vector'; k = 10 })
        select = 'article_id,title,heading,version'; top = 3
    })
Show-Response $r 'POST /kms/search'
$r.Json.value | ForEach-Object { Write-Info ("{0:N2}  {1} v{2}  {3} :: {4}" -f $_.'@search.rerankerScore', $_.article_id, $_.version, $_.title, $_.heading) }
$old = @($r.Json.value | Where-Object { $_.article_id -eq 'KA-1003' -and [int]$_.version -ne 4 })
if ($r.Status -eq 200 -and $old.Count -eq 0) { Write-Pass 'No v3 content is returned to agents' } else { Write-Fail 'Stale v3 content returned' }
Wait-Presenter

if (-not $SkipUnpublish) {
    Write-Step '5. Unpublish: KMS retires KA-1012 (expired flu outreach script)'
    $null = Show-Chunks 'KA-1012'
    Invoke-Vm unpublish KA-1012
    $gone = Show-Chunks 'KA-1012' (Wait-Chunks 'KA-1012' { param($j) -not $j.inIndex })
    if (-not $gone.inIndex) { Write-Pass 'Blob soft-deleted -> AI Search deletion detection removed the parent and every chunk' }
    else { Write-Fail 'KA-1012 chunks are still in the index' }
}

Write-Host "`nReset for the next run: .\Demo-04-Republish.ps1 -Restore" -ForegroundColor DarkCyan
if ($KmsFailures) { Write-Host "$KmsFailures check(s) failed." -ForegroundColor Red } else { Write-Host 'All lifecycle checks passed.' -ForegroundColor Green }
