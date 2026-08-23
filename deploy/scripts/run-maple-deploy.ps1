$ErrorActionPreference = "Stop"

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$ErrorFile = Join-Path $StatusRoot "maple-error.txt"
$DeployScript = Join-Path $ServerRoot "deploy\scripts\deploy-maple.ps1"
$PublishScript = Join-Path $ServerRoot "deploy\scripts\publish-maple-status.ps1"

New-Item -ItemType Directory -Force -Path $StatusRoot | Out-Null

try {
    & $DeployScript
    if ($env:GH_TOKEN) {
        & $PublishScript -RelativePath "deploy/status/maple.txt" -CommitMessage "chore: record deployed Maple URL"
    }
}
catch {
    $failedAt = (Get-Date).ToUniversalTime().ToString("o")
    $message = $_.Exception.Message
    $dockerPs = (docker ps -a 2>&1 | Out-String)
    $dbLogs = (docker logs --tail 80 maple-db 2>&1 | Out-String)
    $appLogs = (docker logs --tail 80 maple-app 2>&1 | Out-String)
    $caddyLogs = (docker logs --tail 80 maple-caddy 2>&1 | Out-String)
    $tunnelLogs = (docker logs --tail 120 maple-public-tunnel 2>&1 | Out-String)

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
