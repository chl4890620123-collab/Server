$ErrorActionPreference = "Stop"

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$ErrorFile = Join-Path $StatusRoot "maple-error.txt"
$DeployScript = Join-Path $ServerRoot "deploy\scripts\deploy-maple.ps1"
$DockerRuntimeRoot = "D:\server-data\maple\runtime\docker-cli"
$DockerPluginRoot = Join-Path $DockerRuntimeRoot "cli-plugins"
$TunnelRuntimeRoot = "D:\server-data\maple\runtime\cloudflared"
$CloudflaredBinary = Join-Path $TunnelRuntimeRoot "cloudflared"

function Get-ContainerLogsSafe([string]$Name, [int]$Tail = 80) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $exists = (docker ps -a --filter "name=^/$Name$" --format "{{.Names}}" 2>$null | Out-String).Trim()
        if ($exists -ne $Name) { return "<container not created: $Name>" }
        $text = (docker logs --tail $Tail $Name 2>&1 | Out-String)
        if ([string]::IsNullOrWhiteSpace($text)) { return "<no logs: $Name>" }
        return $text
    } catch { return "<failed to read logs: $Name>" }
    finally { $ErrorActionPreference = $old }
}

New-Item -ItemType Directory -Force -Path $StatusRoot | Out-Null

$currentContext = (docker context show 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentContext)) {
    throw "Could not resolve the current Docker context."
}
$dockerHost = (docker context inspect $currentContext --format "{{.Endpoints.docker.Host}}" 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dockerHost)) {
    throw "Could not resolve the Docker engine endpoint."
}

New-Item -ItemType Directory -Force -Path $DockerRuntimeRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DockerPluginRoot | Out-Null
'{"auths":{}}' | Set-Content -Path (Join-Path $DockerRuntimeRoot "config.json") -Encoding ascii

$pluginSources = @(
    (Join-Path $env:USERPROFILE ".docker\cli-plugins"),
    (Join-Path $env:ProgramFiles "Docker\Docker\resources\cli-plugins"),
    (Join-Path $env:ProgramFiles "Docker\cli-plugins")
)
$pluginCount = 0
foreach ($source in $pluginSources) {
    if (Test-Path $source) {
        Get-ChildItem $source -Filter "docker-*.exe" -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $DockerPluginRoot $_.Name) -Force
            $pluginCount++
        }
    }
}
if ($pluginCount -eq 0) { throw "Docker CLI plugins could not be found." }

$env:DOCKER_CONFIG = $DockerRuntimeRoot
$env:DOCKER_HOST = $dockerHost
Remove-Item Env:DOCKER_CONTEXT -ErrorAction SilentlyContinue

Write-Host "[maple] using credential-free Docker CLI config"
Write-Host "[maple] Docker CLI plugins: $pluginCount"
docker version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker engine is not reachable." }
docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Compose is not available." }

# All runtime container images are already present on the mini PC. The only
# external binary needed for public preview is downloaded directly from the
# official Cloudflare GitHub release, not from a container registry.
New-Item -ItemType Directory -Force -Path $TunnelRuntimeRoot | Out-Null
$download = $true
if (Test-Path $CloudflaredBinary) {
    $file = Get-Item $CloudflaredBinary -ErrorAction SilentlyContinue
    if ($file -and $file.Length -gt 1MB) { $download = $false }
}
if ($download) {
    Write-Host "[maple] downloading Cloudflared from GitHub Releases"
    $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fL --retry 3 --connect-timeout 20 --output $CloudflaredBinary $url
        if ($LASTEXITCODE -ne 0) { throw "Cloudflared binary download failed." }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $CloudflaredBinary -TimeoutSec 120
    }
}
if (-not (Test-Path $CloudflaredBinary) -or (Get-Item $CloudflaredBinary).Length -le 1MB) {
    throw "Cloudflared binary is missing or invalid."
}
$env:MAPLE_CLOUDFLARED_BINARY = ($CloudflaredBinary -replace "\\", "/")

try {
    & $DeployScript
}
catch {
    $failedAt = (Get-Date).ToUniversalTime().ToString("o")
    $message = $_.Exception.Message
    Write-Host "=== MAPLE DEPLOYMENT FAILURE ==="
    Write-Host "message=$message"

    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try { $dockerPs = (docker ps -a 2>&1 | Out-String) }
    catch { $dockerPs = "<failed to run docker ps>" }
    finally { $ErrorActionPreference = $old }

    $dbLogs = Get-ContainerLogsSafe "maple-db" 80
    $appLogs = Get-ContainerLogsSafe "maple-app" 120
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
    throw
}
