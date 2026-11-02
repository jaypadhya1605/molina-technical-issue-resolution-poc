<#
.SYNOPSIS
  Demo 5 - Pointer, not payload. Answers the 413 / payload-size problem with the current push model.
    1. Legacy pattern: push a 4-chunk article with its 3072-dim vectors through the gateway -> 413 (8 KB cap)
    2. Malformed pointer -> 400 invalid_pointer (the gateway validates the contract, not just the size)
    3. Valid pointer (~120 bytes) -> 202. AI Search pulls the article from ADLS over Private Link.
    4. Indexer status through the gateway
  Article bodies and vectors never cross the gateway. Embeddings are created inside Azure (skill -> APIM -> Azure OpenAI).
.PARAMETER FromVm
  Also run the same comparison from vm-kms-app (on-prem stand-in) with its managed identity.
#>
param([switch]$FromVm, [switch]$Pause)
. "$PSScriptRoot\_common.ps1"

function Wait-Presenter { if ($Pause) { [void](Read-Host '   (Enter to continue)') } }
$api = Get-KmsApiBase
$token = Get-KmsToken $Kms.gatewayAudience
$claims = Get-JwtClaims $token

Write-Section 'Demo 5 - Pointer, not payload'
Write-Info "Caller: $($claims.name) (roles: $($claims.roles -join ', '))"

Write-Step '1. Legacy push: one article (4 chunks) WITH 3072-dimension vectors, straight through the gateway'
$vector = foreach ($i in 0..3071) { [Math]::Round((($i % 97) / 97.0) - 0.5, 8) }
$oneVector = ($vector | ConvertTo-Json -Compress)
$docs = foreach ($n in 1..4) { [ordered]@{ '@search.action' = 'mergeOrUpload'; chunk_id = "KA-1003_$n"; content_vector = $vector } }
$payload = @{ value = @($docs) } | ConvertTo-Json -Depth 5 -Compress
$payloadBytes = [Text.Encoding]::UTF8.GetByteCount($payload)
Write-Info ("one embedding as JSON = {0:N0} bytes; this 4-chunk article = {1:N0} bytes" -f $oneVector.Length, $payloadBytes)
Write-Info ("12,000 chunks x {0:N0} bytes = ~{1:N0} MB of vectors per full reindex" -f $oneVector.Length, (12000 * $oneVector.Length / 1MB))
$r = Invoke-KmsHttp -Method POST -Uri "$api/ingest/run" -Token $token -Body $payload
Show-Response $r 'POST /kms/ingest/run  (vectors in the body)'
Write-Info $r.Body
Assert-Status $r 413 'Gateway rejects article/vector payloads'
Wait-Presenter

Write-Step '2. A malformed pointer (unknown action, bad ID) is rejected by contract validation'
$r = Invoke-KmsHttp -Method POST -Uri "$api/ingest/run" -Token $token -Body '{"action":"drop-index","articleIds":["KA-1003; DROP"]}'
Show-Response $r 'POST /kms/ingest/run  (bad pointer)'
Write-Info $r.Body
Assert-Status $r 400 'Gateway validates the pointer contract'
Wait-Presenter

Write-Step '3. The pointer: which articles changed. KMS has already written them to ADLS with its own identity.'
$pointer = [ordered]@{ source = 'demo-laptop'; action = 'publish'; articleIds = @('KA-1003'); correlationId = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
$pointerBytes = [Text.Encoding]::UTF8.GetByteCount($pointer)
Write-Info "$pointer  ($pointerBytes bytes, $([Math]::Floor($payloadBytes / $pointerBytes))x smaller)"
$deadline = (Get-Date).AddSeconds(120)
do {
    $r = Invoke-KmsHttp -Method POST -Uri "$api/ingest/run" -Token $token -Body $pointer
    if ($r.Status -ne 409) { break }
    Write-Info 'indexer already running - retrying in 10 s'
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $deadline)
Show-Response $r 'POST /kms/ingest/run  (pointer)'
if ($r.Json) { Write-Info ("status={0}  indexer={1}" -f $r.Json.status, $r.Json.indexer); Write-Info $r.Json.note }
Assert-Status $r 202 'Pointer accepted; AI Search pulls the content over Private Link'
Wait-Presenter

Write-Step '4. Indexer status through the gateway (no Search keys, no Search RBAC for the caller)'
Start-Sleep -Seconds 5
$s = Invoke-KmsHttp -Uri "$api/ingest/status" -Token $token
Show-Response $s 'GET /kms/ingest/status'
Write-Info ("indexer={0}  status={1}  lastRun={2}" -f $s.Json.indexer, $s.Json.indexerStatus, $s.Json.lastRunStatus)
foreach ($run in @($s.Json.recentRuns | Select-Object -First 3)) {
    if ($run) { Write-Info ("  {0}  {1,-12} processed={2} failed={3}" -f ([string]$run.startTime).Substring(0, 19), $run.status, $run.itemsProcessed, $run.itemsFailed) }
}

if ($FromVm) {
    Write-Step '5. Same comparison from vm-kms-app (on-prem stand-in), managed identity, through the APIM private endpoint'
    & "$PSScriptRoot\Invoke-KmsVm.ps1" payload
}

if ($KmsFailures) { Write-Host "`n$KmsFailures check(s) failed." -ForegroundColor Red } else { Write-Host "`nAll payload checks passed." -ForegroundColor Green }
