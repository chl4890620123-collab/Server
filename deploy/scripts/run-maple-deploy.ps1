$ErrorActionPreference = "Stop"

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$ErrorFile = Join-Path $StatusRoot "maple-error.txt"
$DeployScript = Join-Path $ServerRoot "deploy\scripts\deploy-maple.ps1"
$PublishScript = Join-Path $ServerRoot "deploy\scripts\publish-maple-status.ps1"
$DockerRuntimeRoot = "D:\server-data\maple\runtime\docker-cli"

function Get-ContainerLogsSafe([string]$Name, [int]$Tail = 80) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $exists = (docker ps -a --filter "name=^/$Name$" --format "{{.Names}}" 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $exists -ne $Name) {
            return "<container not created: $Name>"
        }
        $text = (docker logs --tail $Tail $Name 2>&1 | Out-String)
        if ([string]::IsNullOrWhiteSpace($text)) {
            return "<no logs: $Name>"
        }
        return $text
    }
    catch {
        return "<failed to read logs: $Name>"
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

New-Item -ItemType Directory -Force -Path $StatusRoot | Out-Null

# Docker Desktop's default config can use the Windows credential manager.
# That credential helper is not available inside a non-interactive SSH logon.
# Resolve the already-working Docker engine endpoint first, then use an
# isolated credential-free config only for this deployment process.
$currentContext = (docker context show 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentContext)) {
    throw "Could not resolve the current Docker context."
}

$dockerHost = (docker context inspect $currentContext --format "{{.Endpoints.docker.Host}}" 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dockerHost)) {
    throw "Could not resolve the Docker engine endpoint for context '$currentContext'."
}

New-Item -ItemType Directory -Force -Path $DockerRuntimeRoot | Out-Null
'{"auths":{}}' | Set-Content -Path (Join-Path $DockerRuntimeRoot "config.json") -Encoding ascii
$env:DOCKER_CONFIG = $DockerRuntimeRoot
$env:DOCKER_HOST = $dockerHost
Remove-Item Env:DOCKER_CONTEXT -ErrorAction SilentlyContinue

Write-Host "[maple] using isolated Docker CLI config for SSH deployment"

docker version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker engine is not reachable through the isolated deployment config."
}

try {
    & $DeployScript
    if ($env:GH_TOKEN) {
        & $PublishScript -RelativePath "deploy/status/maple.txt" -CommitMessage "chore: record deployed Maple URL"
    }
}
catch {
    $failedAt = (Get-Date).ToUniversalTime().ToString("o")
    $message = $_.Exception.Message

    Write-Host "=== MAPLE DEPLOYMENT FAILURE ==="
    Write-Host "message=$message"

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $dockerPs = (docker ps -a 2>&1 | Out-String)
    }
    catch {
        $dockerPs = "<failed to run docker ps>"
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $dbLogs = Get-ContainerLogsSafe "maple-db" 80
    $appLogs = Get-ContainerLogsSafe "maple-app" 80
    $caddyLogs = Get-ContainerLogsSafe "maple-caddy" 80
    $tunnelLogs = Get-ContainerLogsSafe "maple-public-tunnel" 120

    @"
failed_at_utc=$failedAt
message=$message

=== docker ps -a ===
$dockerPs
=== maple-db ===
$dbLogs
=== maple-app ===
$appLogs
=== maple-caddy ===
$caddyLogs
=== maple-public-tunnel ===
$tunnelLogs
"@ | Set-Content -Path $ErrorFile -Encoding utf8

    Get-Content $ErrorFile | ForEach-Object { Write-Host $_ }

    if ($env:GH_TOKEN) {
        try {
            & $PublishScript -RelativePath "deploy/status/maple-error.txt" -CommitMessage "chore: record Maple deployment failure"
        }
        catch {
            Write-Warning "Could not publish Maple failure diagnostics to GitHub."
        }
    }

    throw
}
