# Shared helpers for the Molina KMS OAuth PoC demo scripts.
# Dot-source from other scripts:  . "$PSScriptRoot\_common.ps1"
# Works in Windows PowerShell 5.1 and PowerShell 7. No secrets are stored on disk:
# every token is fetched just-in-time from Entra ID through the signed-in Azure CLI.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$script:Kms = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'kms-poc.config.json') | ConvertFrom-Json
$script:KmsRoot = Split-Path -Parent $PSScriptRoot
if (-not $script:KmsHttp) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    # Windows PowerShell's HttpClient ignores HTTPS_PROXY; honour it when a proxy is set in the environment.
    $proxyUrl = @($env:HTTPS_PROXY, $env:HTTP_PROXY) | Where-Object { $_ } | Select-Object -First 1
    if ($proxyUrl) { $handler.Proxy = New-Object System.Net.WebProxy($proxyUrl); $handler.UseProxy = $true }
    $script:KmsHttp = New-Object System.Net.Http.HttpClient($handler)
    $script:KmsHttp.Timeout = [TimeSpan]::FromSeconds(120)
}

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Yellow }
function Write-Pass([string]$Text) { Write-Host "   [PASS] $Text" -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host "   [FAIL] $Text" -ForegroundColor Red; $script:KmsFailures++ }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Gray }
$script:KmsFailures = 0

function Invoke-Az {
    # Runs az and returns stdout only. az writes harmless MSAL cache warnings to stderr, which
    # Windows PowerShell 5.1 would otherwise turn into terminating errors under ErrorAction Stop.
    # Retries because the az token cache / Windows broker occasionally fails a call transiently.
    $ErrorActionPreference = 'Continue'
    for ($i = 1; $i -le 5; $i++) {
        $out = & az @args --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0) { return $out }
        if ($i -lt 5) { Start-Sleep -Seconds (3 * $i) }
    }
    throw "Azure CLI command $($args[0]) failed (exit $LASTEXITCODE). Check login, permissions and connectivity."
}

function Get-KmsToken([Parameter(Mandatory)][string]$Resource) {
    $t = Invoke-Az account get-access-token --resource $Resource --tenant $script:Kms.tenantId --query accessToken -o tsv
    if (-not $t) { throw "Could not get a token for $Resource. Run: az login --tenant $($script:Kms.tenantId)" }
    return ($t | Select-Object -First 1).Trim()
}

function Get-JwtClaims([Parameter(Mandatory)][string]$Token) {
    $p = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($p.Length % 4) { $p += '=' }
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json)
}

function Invoke-KmsHttp {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [string]$Token,
        $Body,
        [hashtable]$Headers = @{},
        [string]$ContentType = 'application/json'
    )
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Uri)
    if ($Token) { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") }
    foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
    if ($null -ne $Body) {
        if ($Body -isnot [string]) { $Body = $Body | ConvertTo-Json -Depth 20 -Compress }
        $req.Content = New-Object System.Net.Http.StringContent($Body, [Text.Encoding]::UTF8, $ContentType)
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $script:KmsHttp.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $sw.Stop()
    $hdrs = @{}
    foreach ($h in $resp.Headers) { $hdrs[$h.Key.ToLowerInvariant()] = ($h.Value -join ',') }
    foreach ($h in $resp.Content.Headers) { $hdrs[$h.Key.ToLowerInvariant()] = ($h.Value -join ',') }
    $json = $null
    if ($text -and ($text.TrimStart().StartsWith('{') -or $text.TrimStart().StartsWith('['))) {
        try { $json = $text | ConvertFrom-Json } catch { $json = $null }
    }
    [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $text; Json = $json; Headers = $hdrs; Ms = $sw.ElapsedMilliseconds }
}

function Format-Json([Parameter(ValueFromPipeline)]$InputObject, [int]$Depth = 20) {
    process {
        $raw = if ($InputObject -is [string]) { $InputObject | ConvertFrom-Json | ConvertTo-Json -Depth $Depth } else { $InputObject | ConvertTo-Json -Depth $Depth }
        $indent = 0
        $lines = foreach ($line in ($raw -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -match '^[\}\]]') { $indent-- }
            ('  ' * [Math]::Max($indent, 0)) + ($t -replace '":\s{2,}', '": ')
            if ($t -match '[\{\[]$') { $indent++ }
        }
        $lines -join [Environment]::NewLine
    }
}

function Show-Response($Response, [string]$Label) {
    $color = if ($Response.Status -lt 300) { 'Green' } elseif ($Response.Status -lt 500) { 'Magenta' } else { 'Red' }
    Write-Host ("   HTTP {0}  ({1} ms)  {2}" -f $Response.Status, $Response.Ms, $Label) -ForegroundColor $color
    foreach ($h in @('x-kms-gateway', 'x-kms-guardrail', 'x-kms-request-id', 'www-authenticate', 'retry-after')) {
        if ($Response.Headers.ContainsKey($h)) { Write-Host "   $h : $($Response.Headers[$h])" -ForegroundColor DarkGray }
    }
}

function Assert-Status($Response, [int[]]$Expected, [string]$What) {
    if ($Expected -contains $Response.Status) { Write-Pass "$What -> HTTP $($Response.Status)" }
    else {
        Write-Fail "$What -> HTTP $($Response.Status) (expected $($Expected -join '/'))"
        if ($Response.Body) { Write-Info ($Response.Body.Substring(0, [Math]::Min(600, $Response.Body.Length))) }
    }
}

function Get-SearchBase { "https://$($script:Kms.searchService).search.windows.net" }
function Get-KmsApiBase { "$($script:Kms.apimGateway)/kms" }
