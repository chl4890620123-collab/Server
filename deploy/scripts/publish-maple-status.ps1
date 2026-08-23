param(
    [string]$RelativePath = "deploy/status/maple.txt",
    [string]$CommitMessage = "chore: record Maple deployment status"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw "GH_TOKEN is required to publish Maple deployment status."
}

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$LocalPath = Join-Path $ServerRoot ($RelativePath -replace "/", "\")
if (-not (Test-Path $LocalPath)) {
    throw "Deployment status file is missing: $LocalPath"
}

$statusText = Get-Content $LocalPath -Raw
$content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusText))
$uri = "https://api.github.com/repos/chl4890620123-collab/Server/contents/$RelativePath"
$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent" = "maple-server-deployer"
}

$body = @{
    message = $CommitMessage
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
Write-Host "[maple] published $RelativePath to GitHub"
