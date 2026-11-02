<#
.SYNOPSIS
  Creates (or updates) the Azure AI Search objects for the KMS PoC:
  data source (ADLS Gen2, managed identity) -> skillset (built-in Azure OpenAI embedding skill pointed at APIM)
  -> index (vectorizer also pointed at APIM) -> indexer (private execution environment, on-demand).
.PARAMETER Recreate
  Deletes the indexer, skillset and index first (clean slate). The data source is kept.
.PARAMETER ResetIndexer
  After the update, resets and runs the indexer so every article is reprocessed, then reports the run result.
.NOTES
  Requires Search public network access to be Enabled while it runs (see Set-SearchPublicAccess.ps1),
  because the laptop talks to the Search management/data plane directly.
#>
param([switch]$Recreate, [switch]$ResetIndexer)
. "$PSScriptRoot\_common.ps1"

$storageId = "/subscriptions/$($Kms.subscriptionId)/resourceGroups/$($Kms.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Kms.storageAccount)"
$placeholders = [ordered]@{
    '__STORAGE_ACCOUNT_ID__'  = $storageId
    '__CONTAINER_NAME__'      = $Kms.container
    '__INDEX_NAME__'          = $Kms.indexName
    '__APIM_GATEWAY_URL__'    = $Kms.apimGateway
    '__EMBEDDING_DEPLOYMENT__' = $Kms.embeddingDeployment
    '__SKILLSET_NAME__'       = $Kms.skillsetName
    '__INDEXER_NAME__'        = $Kms.indexerName
    '__DATASOURCE_NAME__'     = $Kms.dataSourceName
}

$token = Get-KmsToken 'https://search.azure.com'
$base = Get-SearchBase
$v = $Kms.searchApiVersion

Write-Section "Azure AI Search objects on $($Kms.searchService) (api-version $v)"

if ($Recreate) {
    foreach ($o in @(@('indexers', $Kms.indexerName), @('skillsets', $Kms.skillsetName), @('indexes', $Kms.indexName))) {
        $r = Invoke-KmsHttp -Method DELETE -Uri "$base/$($o[0])/$($o[1])?api-version=$v" -Token $token
        Assert-Status $r @(204, 404) "DELETE $($o[0])/$($o[1])"
    }
}

$objects = @(
    @{ File = 'datasource.json'; Collection = 'datasources'; Name = $Kms.dataSourceName },
    @{ File = 'index.json'; Collection = 'indexes'; Name = $Kms.indexName },
    @{ File = 'skillset.json'; Collection = 'skillsets'; Name = $Kms.skillsetName },
    @{ File = 'indexer.json'; Collection = 'indexers'; Name = $Kms.indexerName }
)

foreach ($o in $objects) {
    $json = Get-Content -Raw -Path (Join-Path $KmsRoot "search\$($o.File)")
    foreach ($k in $placeholders.Keys) { $json = $json.Replace($k, $placeholders[$k]) }
    if ($json -match '__[A-Z_]+__') { throw "Unreplaced placeholder in $($o.File): $($Matches[0])" }
    $r = Invoke-KmsHttp -Method PUT -Uri "$base/$($o.Collection)/$($o.Name)?api-version=$v" -Token $token -Body $json -Headers @{ Prefer = 'return=minimal' }
    Assert-Status $r @(200, 201, 204) "PUT $($o.Collection)/$($o.Name)"
}

if ($KmsFailures) { throw "$KmsFailures Search object(s) failed." }

if ($ResetIndexer) {
    $ix = "$base/indexers/$($Kms.indexerName)"
    function Get-IndexerStatus { (Invoke-KmsHttp -Uri "$ix/status?api-version=$v" -Token $token).Json }
    Write-Step 'Reset + run the indexer so every article is reprocessed with the updated skillset'
    for ($i = 0; $i -lt 60 -and (Get-IndexerStatus).lastResult.status -eq 'inProgress'; $i++) { Start-Sleep -Seconds 5 }
    Assert-Status (Invoke-KmsHttp -Method POST -Uri "$ix/reset?api-version=$v" -Token $token) @(204) 'POST indexer reset'
    for ($i = 0; $i -lt 30; $i++) {
        $run = Invoke-KmsHttp -Method POST -Uri "$ix/run?api-version=$v" -Token $token
        if ($run.Status -ne 409) { break }
        Start-Sleep -Seconds 10
    }
    Assert-Status $run @(202) 'POST indexer run'
    $started = Get-Date
    do {
        Start-Sleep -Seconds 10
        $st = Get-IndexerStatus
        $last = $st.lastResult
    } while (((-not $last) -or $last.status -eq 'inProgress' -or ([datetime]$last.startTime).ToUniversalTime() -lt $started.ToUniversalTime().AddSeconds(-60)) -and ((Get-Date) - $started).TotalSeconds -lt 600)
    $warnings = @($last.warnings).Where({ $_ }).Count
    Write-Info ("run {0}: processed={1} failed={2} warnings={3}" -f $last.status, $last.itemsProcessed, $last.itemsFailed, $warnings)
    foreach ($w in @($last.warnings | Select-Object -First 5)) { if ($w) { Write-Info "  warning: $($w.message)" } }
    foreach ($e in @($last.errors | Select-Object -First 5)) { if ($e) { Write-Info "  error: $($e.errorMessage)" } }
    if ($last.status -eq 'success' -and $last.itemsFailed -eq 0) { Write-Pass 'Indexer run succeeded' } else { Write-Fail "Indexer run status: $($last.status)" }
}
