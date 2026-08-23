$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw "GH_TOKEN is required to publish Maple deployment status."
}

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$StatusFile = Join-Path $ServerRoot "deploy\status\maple.txt"
if (-not (Test-Path $StatusFile)) {
    throw "Maple deployment status file is missing: $StatusFile"
}

$statusText = Get-Content $StatusFile -Raw
$content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusText))
$uri = "https://api.github.com/repos/chl4890620123-collab/Server/contents/deploy/status/maple.txt"
$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent" = "maple-server-deployer"
}

$body = @{
    message = "chore: record deployed Maple URL"
    content = $content
    branch = "main"
}

try {
    $existing = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 20
    if ($existing.sha) {
        $body.sha = $existing.sha
    }
}
catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -ne 404) {
        throw
    }
}

$json = $body | ConvertTo-Json -Depth 4
Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType "application/json" -Body $json -TimeoutSec 30 | Out-Null
Write-Host "[maple] published deployment status to GitHub"
