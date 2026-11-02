#requires -Version 5.1
# Offline regressions; no Azure requests or credential files.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'final-demo.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-Arm', 'Set-DemoVmPowerState')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false)
    if (-not $definition) { throw "Missing function under test: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$cfg = [pscustomobject]@{ tenantId = 'test-tenant' }
$tokenRequests = New-Object 'System.Collections.Generic.List[object]'
function Invoke-Azure {
    param([string[]]$Arguments)
    $tokenRequests.Add($Arguments)
    return 'test-access-token'
}

$http = [pscustomobject]@{
    Payload = ''
    StatusCode = 200
    LastUri = ''
    LastMethod = ''
    LastAuthorization = ''
}
$http | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
    param($request)
    $this.LastUri = $request.RequestUri.AbsoluteUri
    $this.LastMethod = $request.Method.Method
    $this.LastAuthorization = $request.Headers.Authorization.ToString()
    $response = New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]$this.StatusCode)
    $response.Content = New-Object Net.Http.StringContent($this.Payload, [Text.Encoding]::UTF8, 'application/json')
    $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]'
    $completion.SetResult($response)
    return $completion.Task
}

$checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:checks++
    Write-Host "PASS: $Label"
}
function Assert-ArmFailure {
    param([string[]]$Expected)
    $failure = $null
    try { $null = Get-Arm '/subscriptions/test/policies/policy' '2024-05-01' }
    catch { $failure = $_.Exception.Message }
    Assert-True ([bool]$failure) 'Invalid ARM response is a terminating failure'
    foreach ($pattern in $Expected) {
        Assert-True ($failure -match $pattern) "Failure identifies $pattern"
    }
    Assert-True ($failure -notmatch 'test-access-token') 'Failure does not disclose the access token'
}

$http.Payload = '{"properties":{"format":"xml","value":"policy"}}'
$result = Get-Arm '/subscriptions/test/policies/policy' '2024-05-01'
Assert-True ($result.properties.value -eq 'policy') 'Plain ARM JSON is decoded'
Assert-True ($http.LastMethod -eq 'GET') 'ARM request uses GET'
Assert-True ($http.LastUri -eq 'https://management.azure.com/subscriptions/test/policies/policy?api-version=2024-05-01') 'ARM resource and API version are retained'
Assert-True ($http.LastAuthorization -eq 'Bearer test-access-token') 'In-memory bearer credential is attached'
Assert-True (($tokenRequests[0] -join ' ') -eq 'account get-access-token --resource https://management.azure.com --tenant test-tenant --query accessToken -o tsv') 'Azure CLI is used only to obtain the ARM token'

$http.Payload = ([string][char]0xFEFF) + '{"properties":{"format":"xml","value":"policy"}}'
$result = Get-Arm '/subscriptions/test/policies/policy' '2024-05-01'
Assert-True ($result.properties.value -eq 'policy') 'UTF-8 BOM response reproduces and fixes the APIM preflight regression'

$http.Payload = '{"name":"caf' + [char]0xE9 + '"}'
$result = Get-Arm '/subscriptions/test/policies/policy' '2024-05-01'
Assert-True ($result.name -eq ('caf' + [char]0xE9)) 'Unicode content is independent of the console code page'

$http.StatusCode = 403
$http.Payload = '{"error":{"code":"AuthorizationFailed","message":"Missing policy read permission."}}'
Assert-ArmFailure @('HTTP 403', 'AuthorizationFailed', '/subscriptions/test/policies/policy')

$http.StatusCode = 502
$http.Payload = '<html>upstream unavailable</html>'
Assert-ArmFailure @('HTTP 502', 'not valid ARM error JSON')

$http.StatusCode = 200
$http.Payload = '{invalid'
Assert-ArmFailure @('invalid JSON', '/subscriptions/test/policies/policy')
$http.Payload = ''
Assert-ArmFailure @('empty JSON', '/subscriptions/test/policies/policy')

$cfg = [pscustomobject]@{
    subscriptionId = 'test-subscription'
    resourceGroup = 'rg-demo-poc'
    vmName = 'vm-demo'
}
$vmCommands = New-Object 'System.Collections.Generic.List[object]'
function Invoke-Azure {
    param([string[]]$Arguments)
    $vmCommands.Add($Arguments)
}
function Get-AzureJson {
    param([string[]]$Arguments)
    return [pscustomobject]@{
        instanceView = [pscustomobject]@{
            statuses = @([pscustomobject]@{ code = "PowerState/$script:reportedPowerState" })
        }
    }
}
foreach ($case in @(
    @{ State = 'running'; Operation = 'start' },
    @{ State = 'stopped'; Operation = 'stop' },
    @{ State = 'deallocated'; Operation = 'deallocate' }
)) {
    $script:reportedPowerState = $case.State
    Set-DemoVmPowerState $case.State
    $command = $vmCommands[$vmCommands.Count - 1]
    Assert-True ($command[1] -eq $case.Operation) "VM $($case.State) maps to $($case.Operation)"
    Assert-True (($command -join ' ') -match '--subscription test-subscription') 'VM operation is scoped to the configured subscription'
}
$script:reportedPowerState = 'stopped'
$stateFailure = $null
try { Set-DemoVmPowerState 'running' }
catch { $stateFailure = $_.Exception.Message }
Assert-True ($stateFailure -match 'did not reach.*running') 'An unverified VM state transition cannot pass'
Write-Host "$checks offline ARM and VM regression checks passed."
