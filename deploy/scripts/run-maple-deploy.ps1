param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$ErrorFile = Join-Path $StatusRoot "maple-error.txt"
$DeployScript = Join-Path $ServerRoot "deploy\scripts\deploy-maple.ps1"
$VerifyScript = Join-Path $ServerRoot "deploy\scripts\verify-maple-rules.py"
$DockerRuntimeRoot = "D:\server-data\maple\runtime\docker-cli"
$DockerPluginRoot = Join-Path $DockerRuntimeRoot "cli-plugins"
$TunnelRuntimeRoot = "D:\server-data\maple\runtime\cloudflared"
$CloudflaredBinary = Join-Path $TunnelRuntimeRoot "cloudflared"
$MapleSourceRoot = "C:\home\server\sources\maple"
$RuntimeEnv = "D:\server-data\maple\runtime\.env"
$MarkerFile = "D:\server-data\maple\runtime\deployed.sha"

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

function Get-ContainerInspectSafe([string]$Name) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $exists = (docker ps -a --filter "name=^/$Name$" --format "{{.Names}}" 2>$null | Out-String).Trim()
        if ($exists -ne $Name) { return "<container not created: $Name>" }
        return (docker inspect --format "state={{json .State}}`ncmd={{json .Config.Cmd}}`nentrypoint={{json .Config.Entrypoint}}" $Name 2>&1 | Out-String)
    } catch { return "<failed to inspect: $Name>" }
    finally { $ErrorActionPreference = $old }
}

function Get-RuntimeValue([string]$Key, [string]$DefaultValue) {
    if (-not (Test-Path $RuntimeEnv)) { return $DefaultValue }
    foreach ($line in Get-Content $RuntimeEnv) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("$Key=")) {
            return ($trimmed -split "=", 2)[1]
        }
    }
    return $DefaultValue
}

function Get-TunnelUrl {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $logs = (cmd.exe /d /s /c "docker logs maple-public-tunnel 2>&1" | Out-String)
        $matches = [regex]::Matches($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($matches.Count -gt 0) { return $matches[$matches.Count - 1].Value }
        return $null
    } catch { return $null }
    finally { $ErrorActionPreference = $old }
}

function Invoke-RuleVerification {
    if (-not (Test-Path $VerifyScript)) {
        throw "Maple rule verification script is missing."
    }
    $appRunning = (docker inspect --format "{{.State.Running}}" maple-app 2>$null | Out-String).Trim()
    if ($appRunning -ne "true") {
        throw "Maple app is not running for rule verification."
    }
    Get-Content $VerifyScript -Raw | docker exec -i maple-app python -
    if ($LASTEXITCODE -ne 0) {
        throw "Maple fixed-rule verification failed."
    }
}

function Test-ReadyExistingDeployment([string]$ExpectedSha) {
    if (-not (Test-Path $MarkerFile)) { return $false }
    $deployedSha = (Get-Content $MarkerFile -Raw).Trim()
    if ($deployedSha -ne $ExpectedSha) { return $false }

    $port = Get-RuntimeValue "MAPLE_LOCAL_PORT" "9040"
    try {
        $meta = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$port/api/meister/meta" -TimeoutSec 5
        $root = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/" -TimeoutSec 5
        if ([int]$meta.total_recipe_count -lt 50 -or $root.StatusCode -ne 200) { return $false }
    } catch { return $false }

    $dbHealth = (docker inspect --format "{{.State.Health.Status}}" maple-db 2>$null | Out-String).Trim()
    $appRunning = (docker inspect --format "{{.State.Running}}" maple-app 2>$null | Out-String).Trim()
    $caddyRunning = (docker inspect --format "{{.State.Running}}" maple-caddy 2>$null | Out-String).Trim()
    $tunnelRunning = (docker inspect --format "{{.State.Running}}" maple-public-tunnel 2>$null | Out-String).Trim()
    if ($dbHealth -ne "healthy" -or $appRunning -ne "true" -or $caddyRunning -ne "true" -or $tunnelRunning -ne "true") {
        return $false
    }

    $publicUrl = Get-TunnelUrl
    if ([string]::IsNullOrWhiteSpace($publicUrl)) { return $false }
    try {
        $publicMeta = Invoke-RestMethod -Method Get -Uri "$publicUrl/api/meister/meta" -TimeoutSec 10
        $publicRoot = Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/" -TimeoutSec 10
        if ([int]$publicMeta.total_recipe_count -lt 50 -or $publicRoot.StatusCode -ne 200) { return $false }
    } catch { return $false }

    Invoke-RuleVerification
    Write-Host "[maple] deployment already current and responsive"
    Write-Host "[maple] public URL: $publicUrl"
    Write-Host "[maple] source SHA: $ExpectedSha"
    return $true
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

if (-not $Force -and (Test-Path (Join-Path $MapleSourceRoot ".git"))) {
    Write-Host "[maple] checking whether a new Maple revision exists"
    $fetchCommand = 'git -C "' + $MapleSourceRoot + '" fetch --prune origin main >NUL 2>&1'
    cmd.exe /d /s /c $fetchCommand
    if ($LASTEXITCODE -ne 0) { throw "Failed to check latest Maple revision." }
    $latestSha = (git -C $MapleSourceRoot rev-parse origin/main | Out-String).Trim()
    if ($latestSha -and (Test-ReadyExistingDeployment $latestSha)) {
        return
    }
}

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

$existingPublicUrl = Get-TunnelUrl
if ([string]::IsNullOrWhiteSpace($existingPublicUrl)) {
    Write-Host "[maple] no live public tunnel found; compose will create one if needed"
} else {
    Write-Host "[maple] preserving existing public URL: $existingPublicUrl"
}

try {
    & $DeployScript
    Invoke-RuleVerification
}
catch {
    $failedAt = (Get-Date).ToUniversalTime().ToString("o")
    $message = $_.Exception.Message
    Write-Host "=== MAPLE DEPLOYMENT FAILURE ==="
    Write-Host "message=$message"
    Start-Sleep -Seconds 3

    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try { $dockerPs = (docker ps -a 2>&1 | Out-String) }
    catch { $dockerPs = "<failed to run docker ps>" }
    finally { $ErrorActionPreference = $old }

    $appInspect = Get-ContainerInspectSafe "maple-app"
    $dbLogs = Get-ContainerLogsSafe "maple-db" 80
    $appLogs = Get-ContainerLogsSafe "maple-app" 160
    $caddyLogs = Get-ContainerLogsSafe "maple-caddy" 80
    $tunnelLogs = Get-ContainerLogsSafe "maple-public-tunnel" 120

    @"
failed_at_utc=$failedAt
message=$message

=== docker ps -a ===
$dockerPs
=== maple-app inspect ===
$appInspect
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