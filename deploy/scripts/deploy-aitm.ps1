param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ServerRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
$ComposeFile = Join-Path $ServerRoot "deploy\compose\aitm.yml"
$CaddyFile = Join-Path $ServerRoot "deploy\caddy\aitm.Caddyfile"
$DataRoot = "D:\server-data\aitm"
$RuntimeRoot = Join-Path $DataRoot "runtime"
$RuntimeEnv = Join-Path $RuntimeRoot ".env"
$DbDataRoot = Join-Path $DataRoot "mariadb"
$VideoDataRoot = Join-Path $DataRoot "videos"
$BackupRoot = Join-Path $DataRoot "backups"
$MarkerFile = Join-Path $RuntimeRoot "deployed.sha"
$TunnelRuntimeRoot = Join-Path $RuntimeRoot "cloudflared"
$CloudflaredBinary = Join-Path $TunnelRuntimeRoot "cloudflared"
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$StatusFile = Join-Path $StatusRoot "aitm.txt"

function New-SecretValue {
    return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
}

function Read-EnvFile([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) { $map[$parts[0].Trim()] = $parts[1] }
        }
    }
    return $map
}

function Add-EnvSetting([string]$Path, [hashtable]$Map, [string]$Key, [string]$Value) {
    if (-not $Map.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($Map[$Key])) {
        Add-Content -Path $Path -Value "$Key=$Value" -Encoding ascii
        $Map[$Key] = $Value
        Write-Host "[aitm] added runtime setting: $Key"
    }
}

function Get-TunnelUrl {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $logs = (cmd.exe /d /s /c "docker logs aitm-public-tunnel 2>&1" | Out-String)
        $matches = [regex]::Matches($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($matches.Count -gt 0) { return $matches[$matches.Count - 1].Value }
        return $null
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Assert-PrebuiltImages {
    $requiredImages = @(
        "aitm-production-ai:latest",
        "aitm-production-backend:latest",
        "aitm-production-frontend:latest",
        "mariadb:10.11",
        "caddy:2.10-alpine"
    )
    foreach ($image in $requiredImages) {
        docker image inspect $image *> $null
        if ($LASTEXITCODE -ne 0) { throw "Required Aitm prebuilt image is missing: $image" }
    }
    Write-Host "[aitm] verified prebuilt application and runtime images"
}

function Test-HealthyExistingDeployment([string]$Sha, [int]$Port) {
    if (-not (Test-Path $MarkerFile)) { return $false }
    $deployedSha = (Get-Content $MarkerFile -Raw).Trim()
    if ($deployedSha -ne $Sha) { return $false }

    try {
        $health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 5
        $root = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 5
        if ($health.StatusCode -ne 200 -or $root.StatusCode -ne 200) { return $false }
    } catch {
        return $false
    }

    $dbHealth = (docker inspect --format "{{.State.Health.Status}}" aitm-db 2>$null | Out-String).Trim()
    $aiHealth = (docker inspect --format "{{.State.Health.Status}}" aitm-ai 2>$null | Out-String).Trim()
    $backendRunning = (docker inspect --format "{{.State.Running}}" aitm-backend 2>$null | Out-String).Trim()
    $frontendRunning = (docker inspect --format "{{.State.Running}}" aitm-frontend 2>$null | Out-String).Trim()
    $caddyRunning = (docker inspect --format "{{.State.Running}}" aitm-caddy 2>$null | Out-String).Trim()
    $tunnelRunning = (docker inspect --format "{{.State.Running}}" aitm-public-tunnel 2>$null | Out-String).Trim()
    if ($dbHealth -ne "healthy" -or $aiHealth -ne "healthy" -or $backendRunning -ne "true" -or $frontendRunning -ne "true" -or $caddyRunning -ne "true" -or $tunnelRunning -ne "true") {
        return $false
    }

    $publicUrl = Get-TunnelUrl
    if ([string]::IsNullOrWhiteSpace($publicUrl)) { return $false }
    try {
        $publicHealth = Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/api/health" -TimeoutSec 10
        if ($publicHealth.StatusCode -ne 200) { return $false }
    } catch {
        return $false
    }

    Write-Host "[aitm] deployment already current and healthy"
    Write-Host "[aitm] public URL: $publicUrl"
    Write-Host "[aitm] source SHA: $Sha"
    return $true
}

if ($ExpectedSha -notmatch '^[0-9a-f]{40}$') {
    throw "ExpectedSha must be a 40-character Git SHA."
}

Write-Host "[aitm] checking mini PC runtime"
docker version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Engine is not available." }
docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Compose is not available." }
if (-not (Test-Path "D:\")) { throw "D drive is required for Aitm runtime data." }
if (-not (Test-Path $ComposeFile)) { throw "Aitm compose file is missing: $ComposeFile" }
if (-not (Test-Path $CaddyFile)) { throw "Aitm Caddyfile is missing: $CaddyFile" }

@($RuntimeRoot, $DbDataRoot, $VideoDataRoot, $BackupRoot, $TunnelRuntimeRoot, $StatusRoot) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

if (-not (Test-Path $RuntimeEnv)) {
    @"
AITM_LOCAL_PORT=9060
DB_NAME=aitm_db
DB_USER=aitm
AITM_DB_PASSWORD=$(New-SecretValue)
AITM_DB_ROOT_PASSWORD=$(New-SecretValue)
AITM_AI_SECURE_TOKEN=$(New-SecretValue)
OPENAI_API_KEY=
AITM_ALLOWED_VIDEO_HOSTS=storage.googleapis.com
DB_CHARSET_MIGRATION_ENABLED=false
DB_CHARSET_MIGRATION_LOCK_WAIT_SECONDS=10
"@ | Set-Content -Path $RuntimeEnv -Encoding ascii
    Write-Host "[aitm] created server-local runtime env"
}

$envMap = Read-EnvFile $RuntimeEnv
$dbHasExistingData = $null -ne (Get-ChildItem $DbDataRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)

Add-EnvSetting $RuntimeEnv $envMap "AITM_LOCAL_PORT" "9060"
Add-EnvSetting $RuntimeEnv $envMap "DB_NAME" "aitm_db"
Add-EnvSetting $RuntimeEnv $envMap "DB_USER" "aitm"
Add-EnvSetting $RuntimeEnv $envMap "AITM_ALLOWED_VIDEO_HOSTS" "storage.googleapis.com"
Add-EnvSetting $RuntimeEnv $envMap "DB_CHARSET_MIGRATION_ENABLED" "false"
Add-EnvSetting $RuntimeEnv $envMap "DB_CHARSET_MIGRATION_LOCK_WAIT_SECONDS" "10"

$missingDbPassword = -not $envMap.ContainsKey("AITM_DB_PASSWORD") -or [string]::IsNullOrWhiteSpace($envMap["AITM_DB_PASSWORD"])
$missingRootPassword = -not $envMap.ContainsKey("AITM_DB_ROOT_PASSWORD") -or [string]::IsNullOrWhiteSpace($envMap["AITM_DB_ROOT_PASSWORD"])
if (($missingDbPassword -or $missingRootPassword) -and $dbHasExistingData) {
    throw "MariaDB data exists but Aitm password settings are missing. Existing data was left untouched."
}
if ($missingDbPassword) { Add-EnvSetting $RuntimeEnv $envMap "AITM_DB_PASSWORD" (New-SecretValue) }
if ($missingRootPassword) { Add-EnvSetting $RuntimeEnv $envMap "AITM_DB_ROOT_PASSWORD" (New-SecretValue) }
Add-EnvSetting $RuntimeEnv $envMap "AITM_AI_SECURE_TOKEN" (New-SecretValue)

foreach ($key in @("AITM_LOCAL_PORT", "DB_NAME", "DB_USER", "AITM_DB_PASSWORD", "AITM_DB_ROOT_PASSWORD", "AITM_AI_SECURE_TOKEN")) {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Required Aitm runtime setting '$key' is missing."
    }
}

$localPort = 0
if (-not [int]::TryParse($envMap["AITM_LOCAL_PORT"], [ref]$localPort) -or $localPort -lt 1024 -or $localPort -gt 65535) {
    throw "AITM_LOCAL_PORT must be between 1024 and 65535."
}

if (-not $Force -and (Test-HealthyExistingDeployment $ExpectedSha $localPort)) {
    return
}

$existingCaddy = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "aitm-caddy" }
$listener = Get-NetTCPConnection -State Listen -LocalPort $localPort -ErrorAction SilentlyContinue
if ($listener -and -not $existingCaddy) {
    throw "Aitm local port $localPort is already in use by another service."
}

if (-not (Test-Path $CloudflaredBinary) -or (Get-Item $CloudflaredBinary -ErrorAction SilentlyContinue).Length -le 1MB) {
    Write-Host "[aitm] downloading Cloudflared runtime"
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

$existingDb = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "aitm-db" }
if ($existingDb) {
    Write-Host "[aitm] creating pre-deploy MariaDB backup"
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    docker exec aitm-db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE" > /tmp/aitm_backup.sql'
    if ($LASTEXITCODE -ne 0) { throw "Pre-deploy Aitm MariaDB backup failed." }
    docker cp "aitm-db:/tmp/aitm_backup.sql" (Join-Path $BackupRoot "aitm_$stamp.sql")
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Aitm MariaDB backup." }
    docker exec aitm-db rm -f /tmp/aitm_backup.sql | Out-Null
}
Get-ChildItem $BackupRoot -Filter "aitm_*.sql" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } | Remove-Item -Force

$env:AITM_DB_DATA_DIR = ($DbDataRoot -replace "\\", "/")
$env:AITM_VIDEO_DATA_DIR = ($VideoDataRoot -replace "\\", "/")
$env:AITM_CADDYFILE = ($CaddyFile -replace "\\", "/")
$env:AITM_CLOUDFLARED_BINARY = ($CloudflaredBinary -replace "\\", "/")

Assert-PrebuiltImages

Write-Host "[aitm] validating production compose"
docker compose --env-file $RuntimeEnv -p aitm-production -f $ComposeFile config *> $null
if ($LASTEXITCODE -ne 0) { throw "Aitm docker compose configuration is invalid." }

Write-Host "[aitm] starting production containers without registry access"
docker compose --env-file $RuntimeEnv -p aitm-production -f $ComposeFile up -d --no-build --pull never --remove-orphans
if ($LASTEXITCODE -ne 0) { throw "Aitm docker compose deployment failed." }

$localHealth = "http://127.0.0.1:$localPort/api/health"
$localReady = $false
for ($attempt = 1; $attempt -le 60; $attempt++) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $localHealth -TimeoutSec 5
        if ($response.StatusCode -eq 200) { $localReady = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $localReady) { throw "Aitm local health check failed: $localHealth" }

$standards = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$localPort/api/standards" -TimeoutSec 10
if ($standards.StatusCode -ne 200) { throw "Aitm backend/database route validation failed." }

$root = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$localPort/" -TimeoutSec 10
if ($root.StatusCode -ne 200) { throw "Aitm local frontend did not return HTTP 200." }

Write-Host "[aitm] waiting for public HTTPS preview URL"
$publicUrl = $null
for ($attempt = 1; $attempt -le 36; $attempt++) {
    $publicUrl = Get-TunnelUrl
    if ($publicUrl) { break }
    Start-Sleep -Seconds 5
}
if (-not $publicUrl) { throw "Aitm Cloudflare Quick Tunnel did not provide a public URL." }

$publicHealth = "$publicUrl/api/health"
$publicReady = $false
for ($attempt = 1; $attempt -le 24; $attempt++) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $publicHealth -TimeoutSec 10
        if ($response.StatusCode -eq 200) { $publicReady = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $publicReady) { throw "Public Aitm health check failed: $publicHealth" }

$publicRoot = Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/" -TimeoutSec 10
if ($publicRoot.StatusCode -ne 200) { throw "Public Aitm frontend did not return HTTP 200." }

$ExpectedSha | Set-Content -Path $MarkerFile -Encoding ascii
$verifiedAt = (Get-Date).ToUniversalTime().ToString("o")
@"
aitm_sha=$ExpectedSha
public_url=$publicUrl
public_health=$publicHealth
local_url=http://127.0.0.1:$localPort
verified_at_utc=$verifiedAt
"@ | Set-Content -Path $StatusFile -Encoding ascii

Write-Host "[aitm] deployment complete"
Write-Host "[aitm] local URL: http://127.0.0.1:$localPort"
Write-Host "[aitm] public URL: $publicUrl"
Write-Host "[aitm] public health: $publicHealth"
Write-Host "[aitm] source SHA: $ExpectedSha"
