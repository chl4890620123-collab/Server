param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ServerRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
$ComposeFile = Join-Path $ServerRoot "deploy\compose\restok.yml"
$CaddyFile = Join-Path $ServerRoot "deploy\caddy\restok.Caddyfile"
$DataRoot = "D:\server-data\restok"
$RuntimeRoot = Join-Path $DataRoot "runtime"
$RuntimeEnv = Join-Path $RuntimeRoot ".env"
$DbDataRoot = Join-Path $DataRoot "mariadb"
$UploadRoot = Join-Path $DataRoot "uploads"
$BackupRoot = Join-Path $DataRoot "backups"
$MarkerFile = Join-Path $RuntimeRoot "deployed.sha"
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$StatusFile = Join-Path $StatusRoot "restok.txt"

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
            if ($parts.Count -eq 2) {
                $map[$parts[0].Trim()] = $parts[1]
            }
        }
    }
    return $map
}

function Add-EnvSetting([string]$Path, [hashtable]$Map, [string]$Key, [string]$Value) {
    if (-not $Map.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($Map[$Key])) {
        Add-Content -Path $Path -Value "$Key=$Value" -Encoding ascii
        $Map[$Key] = $Value
        Write-Host "[restok] added runtime setting: $Key"
    }
}

function Get-RuntimeValue([string]$Key, [string]$DefaultValue) {
    $map = Read-EnvFile $RuntimeEnv
    if ($map.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($map[$Key])) {
        return $map[$Key]
    }
    return $DefaultValue
}

function Get-TunnelUrl {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $logs = (cmd.exe /d /s /c "docker logs restok-public-tunnel 2>&1" | Out-String)
        $matches = [regex]::Matches($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($matches.Count -gt 0) {
            return $matches[$matches.Count - 1].Value
        }
        return $null
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Test-HealthyExistingDeployment([string]$ExpectedSha) {
    if (-not (Test-Path $MarkerFile)) { return $false }
    $deployedSha = (Get-Content $MarkerFile -Raw).Trim()
    if ($deployedSha -ne $ExpectedSha) { return $false }

    $localPort = Get-RuntimeValue "RESTOK_LOCAL_PORT" "9050"
    try {
        $health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$localPort/api/auth/health" -TimeoutSec 5
        $root = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$localPort/" -TimeoutSec 5
        if ($health.StatusCode -ne 200 -or $root.StatusCode -ne 200) {
            return $false
        }
    } catch {
        return $false
    }

    $dbHealth = (docker inspect --format "{{.State.Health.Status}}" restok-db 2>$null | Out-String).Trim()
    $backendRunning = (docker inspect --format "{{.State.Running}}" restok-backend 2>$null | Out-String).Trim()
    $frontendRunning = (docker inspect --format "{{.State.Running}}" restok-frontend 2>$null | Out-String).Trim()
    $caddyRunning = (docker inspect --format "{{.State.Running}}" restok-caddy 2>$null | Out-String).Trim()
    $tunnelRunning = (docker inspect --format "{{.State.Running}}" restok-public-tunnel 2>$null | Out-String).Trim()
    if ($dbHealth -ne "healthy" -or $backendRunning -ne "true" -or $frontendRunning -ne "true" -or $caddyRunning -ne "true" -or $tunnelRunning -ne "true") {
        return $false
    }

    $publicUrl = Get-TunnelUrl
    if ([string]::IsNullOrWhiteSpace($publicUrl)) { return $false }
    try {
        $publicHealth = Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/api/auth/health" -TimeoutSec 10
        if ($publicHealth.StatusCode -ne 200) { return $false }
    } catch {
        return $false
    }

    Write-Host "[restok] deployment already current and healthy"
    Write-Host "[restok] public URL: $publicUrl"
    Write-Host "[restok] source SHA: $ExpectedSha"
    return $true
}

Write-Host "[restok] checking mini PC runtime"
docker version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Engine is not available." }
docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Compose is not available." }
if (-not (Test-Path "D:\")) { throw "D drive is required for Restok runtime data." }
if (-not (Test-Path $ComposeFile)) { throw "Restok compose file is missing: $ComposeFile" }
if (-not (Test-Path $CaddyFile)) { throw "Restok Caddyfile is missing: $CaddyFile" }

$RestokSha = $env:RESTOK_DEPLOY_SHA
if ([string]::IsNullOrWhiteSpace($RestokSha) -or $RestokSha -notmatch '^[0-9a-f]{40}$') {
    throw "RESTOK_DEPLOY_SHA must contain the exact 40-character Restok commit SHA."
}

$requiredImages = @{
    RESTOK_AI_IMAGE = $env:RESTOK_AI_IMAGE
    RESTOK_BACKEND_IMAGE = $env:RESTOK_BACKEND_IMAGE
    RESTOK_FRONTEND_IMAGE = $env:RESTOK_FRONTEND_IMAGE
    RESTOK_MARIADB_IMAGE = $env:RESTOK_MARIADB_IMAGE
    RESTOK_CADDY_IMAGE = $env:RESTOK_CADDY_IMAGE
    RESTOK_CLOUDFLARED_IMAGE = $env:RESTOK_CLOUDFLARED_IMAGE
}
foreach ($entry in $requiredImages.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        throw "$($entry.Key) is required for a prebuilt Restok deployment."
    }
}

@($RuntimeRoot, $DbDataRoot, $UploadRoot, $BackupRoot, $StatusRoot) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

if (-not (Test-Path $RuntimeEnv)) {
    @"
RESTOK_LOCAL_PORT=9050
DB_NAME=restock_db
DB_USER=restok
DB_PASSWORD=$(New-SecretValue)
DB_ROOT_PASSWORD=$(New-SecretValue)
JWT_SECRET=$(New-SecretValue)
JWT_EXPIRATION_MS=86400000
GEMINI_API_KEY=
GEMINI_MODEL=gemini-2.5-flash
AI_MAX_IMAGE_BYTES=10485760
SPRING_PROFILES_ACTIVE=
REACT_APP_GOOGLE_OAUTH_ENABLED=false
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
APP_CORS_ALLOWED_ORIGINS=http://localhost:9050
DB_CHARSET_MIGRATION_ENABLED=false
DB_CHARSET_MIGRATION_LOCK_WAIT_SECONDS=10
"@ | Set-Content -Path $RuntimeEnv -Encoding ascii
    Write-Host "[restok] created server-local runtime env"
}

$envMap = Read-EnvFile $RuntimeEnv
$dbHasExistingData = $null -ne (Get-ChildItem $DbDataRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)

Add-EnvSetting $RuntimeEnv $envMap "RESTOK_LOCAL_PORT" "9050"
Add-EnvSetting $RuntimeEnv $envMap "DB_NAME" "restock_db"
Add-EnvSetting $RuntimeEnv $envMap "DB_USER" "restok"
Add-EnvSetting $RuntimeEnv $envMap "JWT_EXPIRATION_MS" "86400000"
Add-EnvSetting $RuntimeEnv $envMap "GEMINI_MODEL" "gemini-2.5-flash"
Add-EnvSetting $RuntimeEnv $envMap "AI_MAX_IMAGE_BYTES" "10485760"
Add-EnvSetting $RuntimeEnv $envMap "REACT_APP_GOOGLE_OAUTH_ENABLED" "false"
Add-EnvSetting $RuntimeEnv $envMap "APP_CORS_ALLOWED_ORIGINS" "http://localhost:9050"
Add-EnvSetting $RuntimeEnv $envMap "DB_CHARSET_MIGRATION_ENABLED" "false"
Add-EnvSetting $RuntimeEnv $envMap "DB_CHARSET_MIGRATION_LOCK_WAIT_SECONDS" "10"

$missingDbPassword = -not $envMap.ContainsKey("DB_PASSWORD") -or [string]::IsNullOrWhiteSpace($envMap["DB_PASSWORD"])
$missingRootPassword = -not $envMap.ContainsKey("DB_ROOT_PASSWORD") -or [string]::IsNullOrWhiteSpace($envMap["DB_ROOT_PASSWORD"])
if (($missingDbPassword -or $missingRootPassword) -and $dbHasExistingData) {
    throw "MariaDB data exists but password settings are missing. Existing Restok data was left untouched."
}
if ($missingDbPassword) { Add-EnvSetting $RuntimeEnv $envMap "DB_PASSWORD" (New-SecretValue) }
if ($missingRootPassword) { Add-EnvSetting $RuntimeEnv $envMap "DB_ROOT_PASSWORD" (New-SecretValue) }
Add-EnvSetting $RuntimeEnv $envMap "JWT_SECRET" (New-SecretValue)

foreach ($key in @("RESTOK_LOCAL_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_ROOT_PASSWORD", "JWT_SECRET")) {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Required Restok runtime setting '$key' is missing."
    }
}

$localPort = 0
if (-not [int]::TryParse($envMap["RESTOK_LOCAL_PORT"], [ref]$localPort) -or $localPort -lt 1024 -or $localPort -gt 65535) {
    throw "RESTOK_LOCAL_PORT must be between 1024 and 65535."
}
$existingCaddy = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "restok-caddy" }
$listener = Get-NetTCPConnection -State Listen -LocalPort $localPort -ErrorAction SilentlyContinue
if ($listener -and -not $existingCaddy) {
    throw "Restok local port $localPort is already in use by another service."
}

if (-not $Force -and (Test-HealthyExistingDeployment $RestokSha)) {
    return
}

Write-Host "[restok] verifying preloaded Docker images"
foreach ($entry in $requiredImages.GetEnumerator()) {
    docker image inspect $entry.Value *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Preloaded image is missing: $($entry.Value) ($($entry.Key))"
    }
}

$existingDb = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "restok-db" }
if ($existingDb) {
    Write-Host "[restok] creating pre-deploy MariaDB backup"
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    docker exec restok-db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE" > /tmp/restok_backup.sql'
    if ($LASTEXITCODE -ne 0) { throw "Pre-deploy Restok MariaDB backup failed." }
    docker cp "restok-db:/tmp/restok_backup.sql" (Join-Path $BackupRoot "restok_$stamp.sql")
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Restok MariaDB backup." }
    docker exec restok-db rm -f /tmp/restok_backup.sql | Out-Null
}
Get-ChildItem $BackupRoot -Filter "restok_*.sql" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } |
    Remove-Item -Force

$env:RESTOK_DB_DATA_DIR = ($DbDataRoot -replace "\\", "/")
$env:RESTOK_UPLOAD_DATA_DIR = ($UploadRoot -replace "\\", "/")
$env:RESTOK_CADDYFILE = ($CaddyFile -replace "\\", "/")

Write-Host "[restok] validating production compose"
docker compose --env-file $RuntimeEnv -p restok-production -f $ComposeFile config *> $null
if ($LASTEXITCODE -ne 0) { throw "Restok docker compose configuration is invalid." }

Write-Host "[restok] starting preloaded production images without registry pulls"
docker compose --env-file $RuntimeEnv -p restok-production -f $ComposeFile up -d --remove-orphans --pull never
if ($LASTEXITCODE -ne 0) { throw "Restok docker compose deployment failed." }

$localHealth = "http://127.0.0.1:$localPort/api/auth/health"
$localReady = $false
for ($attempt = 1; $attempt -le 60; $attempt++) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $localHealth -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            $localReady = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $localReady) { throw "Restok local health check failed: $localHealth" }

$root = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$localPort/" -TimeoutSec 10
if ($root.StatusCode -ne 200) { throw "Restok local frontend did not return HTTP 200." }

Write-Host "[restok] waiting for public HTTPS preview URL"
$publicUrl = $null
for ($attempt = 1; $attempt -le 36; $attempt++) {
    $publicUrl = Get-TunnelUrl
    if ($publicUrl) { break }
    Start-Sleep -Seconds 5
}
if (-not $publicUrl) { throw "Restok Cloudflare Quick Tunnel did not provide a public URL." }

$publicHealth = "$publicUrl/api/auth/health"
$publicReady = $false
for ($attempt = 1; $attempt -le 24; $attempt++) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $publicHealth -TimeoutSec 10
        if ($response.StatusCode -eq 200) {
            $publicReady = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $publicReady) { throw "Public Restok health check failed: $publicHealth" }

$publicRoot = Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/" -TimeoutSec 10
if ($publicRoot.StatusCode -ne 200) { throw "Public Restok frontend did not return HTTP 200." }

$RestokSha | Set-Content -Path $MarkerFile -Encoding ascii
$verifiedAt = (Get-Date).ToUniversalTime().ToString("o")
@"
restok_sha=$RestokSha
public_url=$publicUrl
public_health=$publicHealth
local_url=http://127.0.0.1:$localPort
verified_at_utc=$verifiedAt
"@ | Set-Content -Path $StatusFile -Encoding ascii

Write-Host "[restok] deployment complete"
Write-Host "[restok] local URL: http://127.0.0.1:$localPort"
Write-Host "[restok] public URL: $publicUrl"
Write-Host "[restok] public health: $publicHealth"
Write-Host "[restok] source SHA: $RestokSha"
