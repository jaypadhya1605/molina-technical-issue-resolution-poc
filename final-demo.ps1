#requires -Version 5.1
<#
.SYNOPSIS
    One-command Molina KMS architecture proof, using the existing deployed PoC.
.DESCRIPTION
    Runs all seven demos, the private VM tests, lifecycle reset, and audit evidence.
    No infrastructure is deployed and no credentials or certificate files are written.
    The gateway's original private-link setting and the synthetic corpus baseline
    are restored in finally. A stopped PoC VM is started for the demo and returned
    to its original power state. Search public access is never enabled.
    Requires Azure CLI login, ARM/Graph read access, VM Run Command permission,
    Log Analytics query access, and both gateway roles for the presenter.
.PARAMETER Pause
    Pause between scenes for a live presentation.
.PARAMETER EvidenceDirectory
    Directory for the timestamped, token-free summary and scene output.
.PARAMETER AuditWaitSeconds
    Delay before querying logs, allowing diagnostic ingestion to catch up.
.EXAMPLE
    .\final-demo.ps1
.EXAMPLE
    .\final-demo.ps1 -Pause
#>
[CmdletBinding()]
param(
    [switch]$Pause,
    [string]$EvidenceDirectory = (Join-Path $PSScriptRoot 'demo-evidence'),
    [ValidateRange(0, 900)]
    [int]$AuditWaitSeconds = 180
)

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PSScriptRoot 'kms-oauth-poc\scripts'
$configPath = Join-Path $scripts 'kms-poc.config.json'
$started = [DateTime]::UtcNow
$runId = $started.ToString('yyyyMMddTHHmmssfffZ')
$results = New-Object 'System.Collections.Generic.List[object]'
$originalPrivateLink = $null
$gatewayChanged = $false
$baselineTouched = $false
$vmStarted = $false
$originalVmPowerState = $null
$fatal = $null
$http = $null

function Add-Result {
    param([string]$Scene, [bool]$Passed, [string]$Detail)
    $result = [pscustomobject]@{
        scene = $Scene
        result = $(if ($Passed) { 'PASS' } else { 'FAIL' })
        detail = $Detail
        utc = [DateTime]::UtcNow.ToString('o')
    }
    $results.Add($result)
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}: {2}" -f $result.result, $Scene, $Detail) -ForegroundColor $color
}

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& az @Arguments --only-show-errors 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) {
        # Do not echo arguments or arbitrary CLI output: either could contain a token.
        throw "Azure CLI failed (exit $exitCode; command $($Arguments[0])). Check Azure login, permissions and connectivity."
    }
    return (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n")
}

function Get-AzureJson {
    param([string[]]$Arguments)
    $raw = Invoke-Azure -Arguments ($Arguments + @('-o', 'json'))
    if (-not $raw) { throw 'Azure CLI returned no JSON evidence.' }
    return ($raw | ConvertFrom-Json)
}

function Get-Arm {
    param([string]$ResourceId, [string]$Version)
    $token = Invoke-Azure -Arguments @('account', 'get-access-token',
        '--resource', 'https://management.azure.com', '--tenant', $cfg.tenantId,
        '--query', 'accessToken', '-o', 'tsv')
    $uri = "https://management.azure.com$ResourceId`?api-version=$Version"
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $uri)
    [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($token.Trim())")
    try {
        try { $response = $http.SendAsync($request).GetAwaiter().GetResult() }
        catch { throw "ARM GET $ResourceId failed before an HTTP response: $($_.Exception.Message)" }
        try {
            # APIM policy responses can include a UTF-8 BOM that az rest cannot decode.
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
            if (-not $response.IsSuccessStatusCode) {
                $detail = $response.ReasonPhrase
                try {
                    $errorBody = $text | ConvertFrom-Json -ErrorAction Stop
                    if ($errorBody.error.code) { $detail += " / $($errorBody.error.code)" }
                    if ($errorBody.error.message) { $detail += ": $($errorBody.error.message)" }
                }
                catch { $detail += ' (response was not valid ARM error JSON)' }
                throw "ARM GET $ResourceId failed (HTTP $([int]$response.StatusCode)): $detail"
            }
            if ([string]::IsNullOrWhiteSpace($text)) { throw "ARM GET $ResourceId returned an empty JSON response." }
            try { return ($text | ConvertFrom-Json -ErrorAction Stop) }
            catch { throw "ARM GET $ResourceId returned invalid JSON: $($_.Exception.Message)" }
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

function Set-DemoVmPowerState {
    param([ValidateSet('running', 'stopped', 'deallocated')][string]$State)
    $operation = @{ running = 'start'; stopped = 'stop'; deallocated = 'deallocate' }[$State]
    [void](Invoke-Azure -Arguments @('vm', $operation, '-g', $cfg.resourceGroup,
        '-n', $cfg.vmName, '--subscription', $cfg.subscriptionId, '-o', 'none'))
    $view = Get-AzureJson -Arguments @('vm', 'get-instance-view', '-g', $cfg.resourceGroup,
        '-n', $cfg.vmName, '--subscription', $cfg.subscriptionId)
    if (@($view.instanceView.statuses | Where-Object code -eq "PowerState/$State").Count -ne 1) {
        throw "The PoC VM did not reach its requested power state: $State."
    }
}

function Invoke-Scene {
    param(
        [string]$Name,
        [string]$Script,
        [hashtable]$Arguments = @{},
        [string[]]$Required = @(),
        [int]$MinimumPasses = 1
    )
    Write-Host "`n$('=' * 76)`n$Name`n$('=' * 76)" -ForegroundColor Cyan
    if ($Pause) { [void](Read-Host 'Press Enter to run this scene') }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $sceneError = $null
    try {
        & (Join-Path $scripts $Script) @Arguments *>&1 | ForEach-Object {
            $text = $_.ToString()
            $lines.Add($text)
            Write-Host $text
        }
    }
    catch {
        $sceneError = $_.Exception.Message
        $lines.Add("Scene terminated: $sceneError")
        Write-Host $sceneError -ForegroundColor Red
    }
    $text = $lines -join "`n"
    $logName = ($Name -replace '[^A-Za-z0-9-]', '-') + '.txt'
    [IO.File]::WriteAllText((Join-Path $runDirectory $logName), $text,
        (New-Object Text.UTF8Encoding($false)))
    $failures = [regex]::Matches($text, '(?im)\[FAIL\]|could not (list|read)|not restored|not at the v3|still running \(check later|^\s*error:|=> HTTP 0\b').Count
    $passes = [regex]::Matches($text, '\[PASS\]').Count
    $missing = @($Required | Where-Object { $text -notmatch $_ })
    $ok = (-not $sceneError) -and $failures -eq 0 -and $passes -ge $MinimumPasses -and $missing.Count -eq 0
    $detail = "assertions=$passes; failures=$failures; missing evidence=$($missing.Count)"
    if ($sceneError) { $detail += "; $sceneError" }
    Add-Result $Name $ok $detail
    if (-not $ok) { throw "Scene failed: $Name. See $logName." }
}

function Test-LogEvidence {
    $token = Invoke-Azure -Arguments @('account', 'get-access-token', '--resource', 'https://api.loganalytics.io',
        '--tenant', $cfg.tenantId, '--query', 'accessToken', '-o', 'tsv')
    $since = $started.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $apimId = "$resourceBase/Microsoft.ApiManagement/service/$($cfg.apimName)"
    $storageId = "$resourceBase/Microsoft.Storage/storageAccounts/$($cfg.storageAccount)"
    $aoaiId = "$resourceBase/Microsoft.CognitiveServices/accounts/$($cfg.aoaiName)"
    $query = @"
let gateway = ApiManagementGatewayLogs
| where TimeGenerated >= datetime($since) and _ResourceId =~ '$apimId';
let storage = StorageBlobLogs
| where TimeGenerated >= datetime($since) and _ResourceId startswith '$storageId';
let models = AzureDiagnostics
| where TimeGenerated >= datetime($since) and _ResourceId =~ '$aoaiId'
| where Category == 'RequestResponse'
| extend p = parse_json(properties_s), code = toint(resultSignature_d);
union
(gateway | where ResponseCode between (200 .. 299)
 | summarize observed=count() | extend proof='gateway-accepted'),
(gateway | where ResponseCode in (400,401,403,413)
 | summarize observed=count() | extend proof='gateway-rejected'),
(gateway | where ApiId == 'azure-openai' and ResponseCode == 200
 | mv-expand t=parse_json(TraceRecords)
 | where tostring(t.source) == 'kms-ai-gateway'
 | extend m=parse_json(tostring(t.message))
 | where tostring(m.callerObjectId) == '$searchPrincipal'
     and tobool(m.viaPrivateEndpoint) == true
     and tostring(m.deployment) == '$($cfg.embeddingDeployment)'
 | summarize observed=count() | extend proof='search-mi-private-embeddings'),
(storage | where AuthenticationType == 'OAuth' and toint(StatusCode) between (200 .. 299)
 | where RequesterObjectId == '$publisherPrincipal'
 | summarize observed=count() | extend proof='publisher-storage-oauth'),
(models | where code between (200 .. 299) and tostring(p.objectId) == '$gatewayPrincipal'
 | summarize observed=count() | extend proof='gateway-mi-openai'),
(models | where code between (200 .. 299) and tostring(p.objectId) != '$gatewayPrincipal'
 | summarize observed=count() | extend proof='unexpected-openai-caller')
| project proof, observed
"@
    $deadline = [DateTime]::UtcNow.AddSeconds($AuditWaitSeconds)
    do {
        $request = New-Object Net.Http.HttpRequestMessage(
            [Net.Http.HttpMethod]::Post,
            "https://api.loganalytics.io/v1/workspaces/$($cfg.logAnalyticsCustomerId)/query")
        [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $token")
        $request.Content = New-Object Net.Http.StringContent(
            (@{ query = $query } | ConvertTo-Json -Compress),
            [Text.Encoding]::UTF8, 'application/json')
        try {
            $response = $http.SendAsync($request).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) {
                    throw "Audit evidence query failed: HTTP $([int]$response.StatusCode)."
                }
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            }
            finally { $response.Dispose() }
        }
        finally { $request.Dispose() }
        if ($body.error) { throw 'Log Analytics returned partial or failed query evidence.' }
        $counts = @{}
        foreach ($row in $body.tables[0].rows) { $counts[[string]$row[0]] = [int]$row[1] }
        $required = @('gateway-accepted', 'gateway-rejected', 'search-mi-private-embeddings',
            'publisher-storage-oauth', 'gateway-mi-openai')
        $missing = @($required | Where-Object { -not $counts.ContainsKey($_) -or $counts[$_] -lt 1 })
        if ($missing.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Write-Host 'Waiting for current-run audit evidence (diagnostic ingestion is asynchronous)...' -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } while ($true)
    foreach ($name in $required) {
        Add-Result "Audit/$name" ($counts.ContainsKey($name) -and $counts[$name] -gt 0) "current-run records=$($counts[$name])"
    }
    Add-Result 'Audit/no-unexpected-model-caller' (
        $counts.ContainsKey('unexpected-openai-caller') -and $counts['unexpected-openai-caller'] -eq 0
    ) "unexpected successful callers=$($counts['unexpected-openai-caller'])"
}

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required. Install it and run az login first.' }
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Missing PoC configuration: $configPath" }
    $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    if ($cfg.resourceGroup -notmatch '(?i)poc') { throw 'This demo only permits a resource group whose name identifies it as a PoC.' }
    $runDirectory = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) $runId
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $resourceBase = "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.resourceGroup)/providers"
    $context = Get-AzureJson -Arguments @('account', 'show', '--subscription', $cfg.subscriptionId)
    if ($context.tenantId -ne $cfg.tenantId -or $context.id -ne $cfg.subscriptionId) { throw 'Azure subscription or tenant does not match the PoC configuration.' }
    # Existing scripts use the current CLI subscription; do not silently change it.
    $current = Get-AzureJson -Arguments @('account', 'show')
    if ($current.id -ne $cfg.subscriptionId) { throw "Select the PoC subscription first: az account set --subscription $($cfg.subscriptionId)" }
    Add-Result 'Preflight/Azure context' $true 'Signed-in subscription and tenant match the PoC.'
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $proxyUrl = @($env:HTTPS_PROXY, $env:HTTP_PROXY) | Where-Object { $_ } | Select-Object -First 1
    if ($proxyUrl) { $handler.Proxy = New-Object Net.WebProxy($proxyUrl); $handler.UseProxy = $true }
    $http = New-Object Net.Http.HttpClient($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(60)
    $vm = Get-Arm "$resourceBase/Microsoft.Compute/virtualMachines/$($cfg.vmName)" '2024-07-01'
    $gateway = Get-Arm "$resourceBase/Microsoft.ApiManagement/service/$($cfg.apimName)" '2024-05-01'
    $search = Get-Arm "$resourceBase/Microsoft.Search/searchServices/$($cfg.searchService)" '2025-05-01'
    $publisherPrincipal = $vm.identity.principalId
    $gatewayPrincipal = $gateway.identity.principalId
    $searchPrincipal = $search.identity.principalId
    if (-not $publisherPrincipal -or -not $gatewayPrincipal -or -not $searchPrincipal) { throw 'A required managed identity is missing.' }
    $deployment = Get-Arm "$resourceBase/Microsoft.CognitiveServices/accounts/$($cfg.aoaiName)/deployments/$($cfg.embeddingDeployment)" '2024-10-01'
    if ($deployment.properties.model.name -ne 'text-embedding-3-large') { throw 'The live embedding deployment does not use text-embedding-3-large.' }
    $modelPolicy = Get-Arm "$resourceBase/Microsoft.ApiManagement/service/$($cfg.apimName)/apis/azure-openai/policies/policy" '2024-05-01'
    foreach ($pin in @('client-application-ids', $cfg.searchMiAppId, $cfg.embeddingDeployment,
            'deployment_not_allowed', 'authentication-managed-identity')) {
        if ($modelPolicy.properties.value -notmatch [regex]::Escape($pin)) { throw "The deployed embedding policy is missing its expected identity/deployment control: $pin" }
    }
    Add-Result 'Model/live-deployment-and-policy' $true 'Live 3-large deployment; APIM policy pins the Search identity and embedding deployment.'
    $skillset = Get-Content -Raw (Join-Path $scripts '..\search\skillset.json') | ConvertFrom-Json
    $index = Get-Content -Raw (Join-Path $scripts '..\search\index.json') | ConvertFrom-Json
    $indexer = Get-Content -Raw (Join-Path $scripts '..\search\indexer.json') | ConvertFrom-Json
    $embedding = @($skillset.skills | Where-Object { $_.'@odata.type' -eq '#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill' })
    $vectorizer = @($index.vectorSearch.vectorizers | Where-Object kind -eq 'azureOpenAI')
    if ($skillset.skills.Count -ne 1 -or $embedding.Count -ne 1 -or $vectorizer.Count -ne 1 -or
        $embedding[0].context -ne '/document/chunks/*' -or
        $embedding[0].resourceUri -ne '__APIM_GATEWAY_URL__' -or
        $vectorizer[0].azureOpenAIParameters.resourceUri -ne '__APIM_GATEWAY_URL__' -or
        $embedding[0].modelName -ne $vectorizer[0].azureOpenAIParameters.modelName -or
        $embedding[0].deploymentId -ne $vectorizer[0].azureOpenAIParameters.deploymentId -or
        $embedding[0].dimensions -ne 3072 -or
        $indexer.parameters.configuration.executionEnvironment -ne 'private') {
        throw 'Search design assets do not consistently use the built-in skill/vectorizer, preserved chunks and private execution.'
    }
    Add-Result 'Design/built-in-vectorization' $true 'Repository definitions: built-in embedding skill, same APIM/model/deployment at index/query time, 3072 dimensions, preserved chunk context, private indexer. Live calls are proved in later scenes.'
    if ($search.properties.publicNetworkAccess -ne 'Disabled') {
        throw 'Search public access must already be Disabled. This script never opens the Search data plane.'
    }
    $state = Get-AzureJson -Arguments @('vm', 'get-instance-view', '-g', $cfg.resourceGroup, '-n', $cfg.vmName)
    $powerStates = @($state.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' })
    if ($powerStates.Count -ne 1) { throw 'Could not determine the PoC VM power state.' }
    $originalVmPowerState = $powerStates[0].code -replace '^PowerState/', ''
    if ($originalVmPowerState -in @('stopped', 'deallocated')) {
        Write-Host "The existing PoC VM is $originalVmPowerState; starting it for this demo and restoring that state on exit." -ForegroundColor Yellow
        $vmStarted = $true
        Set-DemoVmPowerState 'running'
    }
    elseif ($originalVmPowerState -ne 'running') { throw "The PoC VM is transitioning ($originalVmPowerState); wait for that operation to finish and retry." }
    Add-Result 'Preflight/VM readiness' $true "PoC VM running; original power state=$originalVmPowerState."
    $namedValueId = "$resourceBase/Microsoft.ApiManagement/service/$($cfg.apimName)/namedValues/kms-require-private-link"
    $namedValue = Get-Arm $namedValueId '2024-05-01'
    $originalPrivateLink = [string]$namedValue.properties.value
    if ($originalPrivateLink -notin @('true', 'false')) { throw 'Unexpected private-link switch value; refusing to change it.' }
    Add-Result 'Preflight/Search network' $true 'Search public access remains disabled.'
    Write-Host @'

MOLINA KMS - ARCHITECTURE PROOF
Data:       KMS identity -> ADLS article JSON -> Search indexer (private links)
Control:    KMS identity -> OAuth + pointer -> APIM -> Search (gateway identity)
Embeddings: Search identity -> APIM -> pinned OpenAI deployment (gateway identity)
Retrieval:  agent identity -> APIM guardrail -> hybrid/BM25/semantic Search

This is a synthetic PoC, not production approval or a load test.
The ingest route carries pointers, not vectors. Embedding responses DO carry
vectors through the AI gateway. Model throttling and indexer limits still apply.
The demo briefly allows OAuth-authenticated public APIM calls, then proves
private-only operation, and restores the original gateway setting on exit.
'@ -ForegroundColor Cyan

    $gatewayChanged = $true
    Invoke-Scene '00-Presenter-access' 'Set-PrivateLinkOnly.ps1' @{ State = 'Off' } @('HTTP 200') 1
    Invoke-Scene '01-Keyless-posture-and-identities' 'Demo-01-Posture.ps1' @{} @('All posture checks passed', 'KMS.Ingest', 'KMS.Search') 8
    $baselineTouched = $true
    Invoke-Scene '02-Automatic-baseline' 'Invoke-KmsVm.ps1' @{ Command = 'publish'; Arguments = @('all') } @('indexer run: success', 'failed=0', 'ADLS PUT published/KA-1015.json') 0
    Invoke-Scene '03-OAuth-negative-and-positive-matrix' 'Demo-02-OAuthMatrix.ps1' @{} @('All OAuth checks passed') 11
    Invoke-Scene '04-Private-DNS' 'Invoke-KmsVm.ps1' @{ Command = 'dns' } @(
        '(?m)blob\.core\.windows\.net\s+10\.\S+\s+PRIVATE',
        '(?m)dfs\.core\.windows\.net\s+10\.\S+\s+PRIVATE',
        '(?m)search\.windows\.net\s+10\.\S+\s+PRIVATE',
        '(?m)openai\.azure\.com\s+10\.\S+\s+PRIVATE',
        '(?m)azure-api\.net\s+10\.\S+\s+PRIVATE') 0
    Invoke-Scene '05-VM-identity-and-least-privilege' 'Invoke-KmsVm.ps1' @{ Command = 'posture' } @('viaPrivateEndpoint=True') 10
    Invoke-Scene '06-Pointer-size-and-contract' 'Demo-05-Payload.ps1' @{ FromVm = $true } @('All payload checks passed', 'HTTP 413', 'HTTP 400', 'HTTP 202') 3
    Invoke-Scene '07-Hybrid-filters-and-published-guardrail' 'Demo-03-Search.ps1' @{} @('All search checks passed', 'KA-1011\s+inIndex=True', 'KA-1012\s+inIndex=True', 'KA-1015\s+inIndex=True') 7
    Invoke-Scene '08-Republish-and-unpublish' 'Demo-04-Republish.ps1' @{} @('All lifecycle checks passed', '0 stale|nothing orphaned', 'removed the parent and every chunk') 3
    Invoke-Scene '09-Agent-identity-current-version' 'Invoke-KmsVm.ps1' @{ Command = 'agent' } @('POST /kms/search => HTTP 200', 'KA-1003 v4', 'trigger ingestion => HTTP 403 insufficient_role') 0
    Invoke-Scene '10-SDK-protocol-and-default-deny' 'Demo-07-SdkPassThrough.ps1' @{} @('All SDK pass-through checks passed') 11
    Invoke-Scene '11-Private-only-positive-and-negative-paths' 'Set-PrivateLinkOnly.ps1' @{ State = 'On'; ProveFromVm = $true } @(
        'private_link_required', 'POST /kms/search => HTTP 200', 'trigger ingestion => HTTP 403 insufficient_role') 2
    # Current-run logs must contain records, not merely return HTTP 200 with an empty table.
    Test-LogEvidence
    Invoke-Scene '12-Readable-audit-trail' 'Demo-06-Logs.ps1' @{ Minutes = 120 } @('Azure OpenAI', 'ADLS Gen2', 'embedding calls') 0
}
catch {
    $fatal = $_.Exception.Message
    Add-Result 'Run/completion' $false $fatal
}
finally {
    if ($gatewayChanged) {
        # Restore presenter access only for the baseline reset; restore the original
        # setting even if either reset step fails.
        try {
            if ($baselineTouched) {
                Invoke-Scene 'Cleanup-presenter-access' 'Set-PrivateLinkOnly.ps1' @{ State = 'Off' } @('HTTP 200') 1
                Invoke-Scene 'Cleanup-corpus-baseline' 'Demo-04-Republish.ps1' @{ Restore = $true } @('Baseline restored') 1
            }
        }
        catch { Add-Result 'Cleanup/baseline' $false $_.Exception.Message }
        finally {
            try {
                $restore = if ($originalPrivateLink -eq 'true') { 'On' } else { 'Off' }
                Invoke-Scene 'Cleanup-original-gateway-setting' 'Set-PrivateLinkOnly.ps1' @{ State = $restore } @() 1
                $restored = Get-Arm $namedValueId '2024-05-01'
                Add-Result 'Cleanup/verified-setting' ($restored.properties.value -eq $originalPrivateLink) "private-link-only restored to $originalPrivateLink"
            }
            catch { Add-Result 'Cleanup/gateway' $false $_.Exception.Message }
        }
    }
    if ($vmStarted) {
        try {
            Set-DemoVmPowerState $originalVmPowerState
            Add-Result 'Cleanup/VM power state' $true "PoC VM returned to $originalVmPowerState."
        }
        catch { Add-Result 'Cleanup/VM power state' $false $_.Exception.Message }
    }
    if ($http) { $http.Dispose() }
    $failed = @($results | Where-Object result -eq 'FAIL')
    $verdict = if ($failed.Count -eq 0 -and $results.Count -gt 0) { 'PASS' } else { 'FAIL' }
    $gates = @(
        'Synthetic 15-article corpus only; no real Molina or 12,000-chunk load proof.',
        'SDK URL protocol is exercised; the installed azure-search-documents binary is not tested.',
        'The model deployment is pinned; legacy-index model compatibility still requires a full re-embed.',
        'KMS chunk boundaries are preserved; the fixture does not benchmark 700-token chunking.',
        'Shared Key and account/service SAS are disabled; user-delegation SAS is not disabled by that setting.',
        'Production APIM tier/private-endpoint compatibility, dedicated Search sizing, tenant roles and DNS require approval.',
        'On-prem Arc/federated identity, real KMS integration, portal TLS, OCR/PDFs and AKS are production/phase-two gates.',
        'RBAC without APIM is an alternative requiring Molina Security approval, not a bypass enabled by this demo.'
    )
    $summary = [ordered]@{
        runId = $runId
        startedUtc = $started.ToString('o')
        finishedUtc = [DateTime]::UtcNow.ToString('o')
        verdict = $verdict
        scope = 'Synthetic deployed PoC architecture; not production sign-off'
        results = @($results.ToArray())
        productionGates = $gates
    }
    if ($runDirectory) {
        $jsonPath = Join-Path $runDirectory 'summary.json'
        $textPath = Join-Path $runDirectory 'summary.txt'
        [IO.File]::WriteAllText($jsonPath, ($summary | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        $table = $results | Format-Table scene, result, detail -Wrap | Out-String -Width 180
        [IO.File]::WriteAllText($textPath, "$verdict`r`n$table`r`nPRODUCTION GATES`r`n$($gates -join "`r`n")",
            (New-Object Text.UTF8Encoding($false)))
        Write-Host "`nEvidence: $runDirectory"
    }
    $results | Format-Table scene, result, detail -Wrap | Out-Host
    Write-Host "`nPOC ARCHITECTURE VERDICT: $verdict"
    Write-Host 'Production gates (not claimed as proved):' -ForegroundColor Yellow
    $gates | ForEach-Object { Write-Host " - $_" }
}
if ($verdict -ne 'PASS') { throw 'The final demo did not pass. Review summary.json and failed scene output before presenting.' }
