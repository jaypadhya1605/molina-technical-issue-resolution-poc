<#
.SYNOPSIS
  Demo 6 - Audit trail in Log Analytics. Every hop is attributable to an Entra identity:
    1. Gateway calls by identity (APIM trace records: who, which operation, roles, private endpoint or not)
    2. Calls the gateway rejected, and why (no token, wrong audience, tampered token, missing role)
    3. Embedding calls through the AI gateway (only the AI Search managed identity, via the shared private link)
    4. ADLS Gen2 access (OAuth only - no account keys, no SAS)
    5. Azure OpenAI access (only APIM's managed identity)
  Log Analytics ingestion lags 2-5 minutes behind the calls.
.PARAMETER Minutes
  Look-back window (default 120).
.PARAMETER Kql
  Run an ad-hoc KQL query instead of the canned scenes (add -List for wide rows).
#>
param([int]$Minutes = 120, [string]$Kql, [switch]$List, [switch]$Pause)
. "$PSScriptRoot\_common.ps1"

function Wait-Presenter { if ($Pause) { [void](Read-Host '   (Enter to continue)') } }
$laToken = Get-KmsToken 'https://api.loganalytics.io'

function Invoke-LaQuery([string]$Query) {
    $r = Invoke-KmsHttp -Method POST -Uri "https://api.loganalytics.io/v1/workspaces/$($Kms.logAnalyticsCustomerId)/query" -Token $laToken -Body @{ query = $Query; timespan = "PT$($Minutes)M" }
    if ($r.Status -ne 200) { Write-Fail "Log Analytics query failed: HTTP $($r.Status) $($r.Body)"; return @() }
    $t = $r.Json.tables[0]
    foreach ($row in $t.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $t.columns.Count; $i++) { $o[$t.columns[$i].name] = $row[$i] }
        [pscustomobject]$o
    }
}
function Get-Friendly([string]$Id) {
    if (-not $Id) { return '' }
    $p = $Kms.principals.PSObject.Properties | Where-Object Name -eq $Id
    if ($p) { return $p.Value }
    return $Id
}
function Show-Table($Rows) {
    if (-not $Rows) { Write-Host '   (no rows yet - ingestion lags 2-5 minutes; rerun shortly)' -ForegroundColor DarkYellow; return }
    $Rows | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
}

if ($Kql) {
    $res = Invoke-LaQuery $Kql
    if ($List) { $res | Format-List | Out-String -Width 4000 | Write-Host } else { Show-Table $res }
    return
}

Write-Section "Demo 6 - Audit trail in Log Analytics ($($Kms.logAnalyticsWorkspace), last $Minutes min)"

Write-Step '1. Every accepted gateway call, attributed to an Entra identity (APIM trace records)'
$q1 = @'
ApiManagementGatewayLogs
| mv-expand t = parse_json(TraceRecords)
| where tostring(t.source) in ('kms-audit', 'kms-ai-gateway', 'kms-ingest-pointer')
| extend m = parse_json(tostring(t.message))
| extend caller = coalesce(tostring(m.callerObjectId), tostring(m.requestedByObjectId))
| summarize calls = count(), lastSeen = max(TimeGenerated) by api = ApiId, operation = OperationId, caller, roles = tostring(m.roles), viaPrivateEndpoint = tostring(m.viaPrivateEndpoint), status = ResponseCode
| order by lastSeen desc
'@
$rows = Invoke-LaQuery $q1 | Group-Object api, operation, caller, status | ForEach-Object {
    $f = $_.Group[0]
    [pscustomobject]@{
        lastSeenUtc        = ([string]($_.Group | Sort-Object lastSeen -Descending | Select-Object -First 1).lastSeen).Substring(0, 19)
        api                = $f.api
        operation          = $f.operation
        caller             = Get-Friendly $f.caller
        roles              = ($_.Group | Where-Object roles | Select-Object -First 1).roles
        viaPrivateEndpoint = ($_.Group | Where-Object viaPrivateEndpoint | Select-Object -First 1).viaPrivateEndpoint
        status             = $f.status
        calls              = ($_.Group | Measure-Object calls -Maximum).Maximum
    }
} | Sort-Object lastSeenUtc -Descending
Show-Table $rows
Wait-Presenter

Write-Step '2. Calls the gateway rejected - and the policy that rejected them'
$q2 = @'
ApiManagementGatewayLogs
| where ResponseCode >= 400
| summarize calls = count(), lastSeen = max(TimeGenerated) by api = ApiId, operation = OperationId, status = ResponseCode, rejectedBy = LastErrorSource, reason = LastErrorReason, clientIp = CallerIpAddress
| order by lastSeen desc
'@
Show-Table (Invoke-LaQuery $q2 | Select-Object @{ n = 'lastSeenUtc'; e = { ([string]$_.lastSeen).Substring(0, 19) } }, api, operation, status, rejectedBy, reason, clientIp, calls)
Wait-Presenter

Write-Step '3. AI gateway: embedding calls (index time = skill, query time = vectorizer)'
$q3 = @'
ApiManagementGatewayLogs
| where ApiId == 'azure-openai'
| mv-expand t = parse_json(TraceRecords)
| extend m = parse_json(tostring(t.message))
| summarize calls = count(), firstSeen = min(TimeGenerated), lastSeen = max(TimeGenerated) by caller = tostring(m.callerObjectId), deployment = tostring(m.deployment), viaPrivateEndpoint = tostring(m.viaPrivateEndpoint), status = ResponseCode
| order by lastSeen desc
'@
Show-Table (Invoke-LaQuery $q3 | Select-Object @{ n = 'caller'; e = { Get-Friendly $_.caller } }, deployment, viaPrivateEndpoint, status, calls, @{ n = 'lastSeenUtc'; e = { ([string]$_.lastSeen).Substring(0, 19) } })
Wait-Presenter

Write-Step '4. ADLS Gen2: who touched the articles, and how they authenticated'
$q4 = @'
StorageBlobLogs
| summarize calls = count(), lastSeen = max(TimeGenerated) by AuthenticationType, requester = RequesterObjectId, OperationName, StatusCode
| order by lastSeen desc
'@
Show-Table (Invoke-LaQuery $q4 | Select-Object AuthenticationType, @{ n = 'requester'; e = { Get-Friendly $_.requester } }, OperationName, StatusCode, calls)
Wait-Presenter

Write-Step '5. Azure OpenAI: the only successful caller is the APIM managed identity, over the private endpoint'
$q5 = @'
AzureDiagnostics
| where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES' and Category == 'RequestResponse'
| extend p = parse_json(properties_s), status = toint(resultSignature_d)
| where isnotempty(tostring(p.objectId)) or status >= 400
| summarize calls = count(), lastSeen = max(TimeGenerated) by caller = tostring(p.objectId), operation = OperationName, callerIp = CallerIPAddress, status
| order by lastSeen desc
'@
Show-Table (Invoke-LaQuery $q5 | Select-Object @{ n = 'caller'; e = { Get-Friendly $_.caller } }, operation, callerIp, status, calls, @{ n = 'lastSeenUtc'; e = { ([string]$_.lastSeen).Substring(0, 19) } })
Write-Info 'callerIp 10.60.2.x = APIM outbound subnet -> AOAI private endpoint. Any other caller is rejected (403).'

if ($KmsFailures) { Write-Host "`n$KmsFailures query(ies) failed." -ForegroundColor Red }
