<#
.SYNOPSIS
  Runs the KMS publisher (scripts\vm\kms_publisher.py) on vm-kms-app through Azure Run Command.
  vm-kms-app stands in for Molina's on-prem KMS server: no public IP, no SSH, no keys. Every call it
  makes uses an OAuth token from its managed identity.
.EXAMPLE
  .\Invoke-KmsVm.ps1 dns
  .\Invoke-KmsVm.ps1 posture
  .\Invoke-KmsVm.ps1 publish all
  .\Invoke-KmsVm.ps1 republish KA-1003
  .\Invoke-KmsVm.ps1 unpublish KA-1012
  .\Invoke-KmsVm.ps1 status
  .\Invoke-KmsVm.ps1 agent "member needs a ride to dialysis"
  .\Invoke-KmsVm.ps1 payload
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('dns', 'posture', 'publish', 'republish', 'unpublish', 'status', 'agent', 'payload')]
    [string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)
. "$PSScriptRoot\_common.ps1"
Add-Type -AssemblyName System.IO.Compression

# Bundle the publisher, its names-only config and the demo corpus in memory (zip -> base64).
$vmConfig = [ordered]@{
    storageAccount      = $Kms.storageAccount
    container           = $Kms.container
    apimGateway         = $Kms.apimGateway
    gatewayAudience     = $Kms.gatewayAudience
    searchEndpoint      = "https://$($Kms.searchService).search.windows.net"
    aoaiEndpoint        = "https://$($Kms.aoaiName).openai.azure.com"
    agentClientId       = $Kms.agentClientId
    indexName           = $Kms.indexName
    embeddingDeployment = $Kms.embeddingDeployment
} | ConvertTo-Json

$files = [ordered]@{
    'kms_publisher.py' = Get-Content -Raw -Encoding UTF8 -Path (Join-Path $PSScriptRoot 'vm\kms_publisher.py')
    'config.json'      = $vmConfig
}
foreach ($folder in 'articles', 'republish') {
    Get-ChildItem -Path (Join-Path $KmsRoot "data\$folder") -Filter *.json | ForEach-Object {
        $files["$folder/$($_.Name)"] = Get-Content -Raw -Encoding UTF8 -Path $_.FullName
    }
}

$ms = New-Object System.IO.MemoryStream
$zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
foreach ($name in $files.Keys) {
    $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
    $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
    $writer.Write(($files[$name] -replace "`r`n", "`n"))
    $writer.Dispose()
}
$zip.Dispose()
$bundle = [Convert]::ToBase64String($ms.ToArray())

function ConvertTo-BashArg([string]$s) { "'" + $s.Replace("'", "'\''") + "'" }
$cmdLine = (@($Command) + @($Arguments | Where-Object { $_ })) | ForEach-Object { ConvertTo-BashArg $_ }

$bash = @"
#!/bin/bash
set -e
mkdir -p /opt/kms
echo '$bundle' | base64 -d > /tmp/kms-bundle.zip
python3 -m zipfile -e /tmp/kms-bundle.zip /opt/kms/
rm -f /tmp/kms-bundle.zip
cd /opt/kms
python3 -u kms_publisher.py $($cmdLine -join ' ') 2>&1
"@

$tmp = Join-Path $env:TEMP ("kms-vm-{0}.sh" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($tmp, ($bash -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("[{0}] vm-kms-app (no public IP) via Azure Run Command  ->  kms_publisher.py {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Command, ($Arguments -join ' ')) -ForegroundColor DarkCyan
try {
    $raw = Invoke-Az vm run-command invoke -g $Kms.resourceGroup -n $Kms.vmName --command-id RunShellScript --scripts "@$tmp" -o json
}
finally {
    Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
}

$message = (($raw -join "`n") | ConvertFrom-Json).value[0].message
$stdout = $message
$stderr = ''
if ($message -match '(?s)\[stdout\]\r?\n(.*?)\r?\n?\[stderr\]\r?\n?(.*)$') { $stdout = $Matches[1]; $stderr = $Matches[2].Trim() }
foreach ($line in ($stdout -split "`n")) {
    $color = if ($line -match '\[FAIL\]|error|=> HTTP (4|5)\d\d') { 'Magenta' } elseif ($line -match '\[PASS\]|HTTP 20\d|success') { 'Green' } else { 'Gray' }
    Write-Host $line -ForegroundColor $color
}
if ($stderr) { Write-Host $stderr -ForegroundColor Red }
