param(
    [Parameter(Mandatory = $true)]
    [string]$MapleImage,

    [Parameter(Mandatory = $true)]
    [string]$SourceSha,

    [Parameter(Mandatory = $false)]
    [string]$RegistryUser = "",

    [Parameter(Mandatory = $false)]
    [string]$RegistryToken = "",

    [Parameter(Mandatory = $false)]
    [string]$RuntimeEnv = "D:\server-data\maple\runtime\.env"
)

$ErrorActionPreference = "Stop"

$ServerRoot = "C:\home\server\app"
$ComposeFile = Join-Path $ServerRoot "deploy\compose\maple.yml"
$MapleDataRoot = "D:\server-data\maple"
$MapleDbDataRoot = Join-Path $MapleDataRoot "mariadb"
$RuntimeRoot = Join-Path $MapleDataRoot "runtime"
$MarkerFile = Join-Path $RuntimeRoot "deployed.sha"

function New-MapleSecret {
    return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
}

Write-Host "[maple] central deployment start"
Write-Host "[maple] image: $MapleImage"
Write-Host "[maple] source: $SourceSha"

if (-not (Test-Path $ComposeFile)) {
    throw "Maple production compose file not found: $ComposeFile"
}

if (-not (Test-Path "D:\")) {
    throw "D drive is not available. Maple persistent data requires D:\server-data\maple."
}

New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
New-Item -ItemType Directory -Force -Path $MapleDbDataRoot | Out-Null

if (-not (Test-Path $RuntimeEnv)) {
    $adminToken = New-MapleSecret
    $dbPassword = New-MapleSecret
    $dbRootPassword = New-MapleSecret

    @"
APP_PORT=9040
BIND_HOST=0.0.0.0
ADMIN_TOKEN=$adminToken
DEFAULT_FEE_RATE=0.05
CORS_ORIGINS=
DB_ENGINE=mariadb
DB_HOST=maple-db
DB_PORT=3306
DB_NAME=maple_craft
DB_USER=maple_app
DB_PASSWORD=$dbPassword
DB_ROOT_PASSWORD=$dbRootPassword
MARIADB_IMAGE=mariadb:11.4
"@ | Set-Content -Path $RuntimeEnv -Encoding ascii

    Write-Host "[maple] created server-local runtime env: $RuntimeEnv"
}

$envMap = @{}
Get-Content $RuntimeEnv | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) {
        return
    }

    $parts = $line -split "=", 2
    if ($parts.Count -eq 2) {
        $envMap[$parts[0].Trim()] = $parts[1]
    }
}

$requiredKeys = @(
    "APP_PORT",
    "BIND_HOST",
    "ADMIN_TOKEN",
    "DB_ENGINE",
    "DB_HOST",
    "DB_PORT",
    "DB_NAME",
    "DB_USER",
    "DB_PASSWORD",
    "DB_ROOT_PASSWORD"
)

foreach ($key in $requiredKeys) {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Required Maple runtime setting '$key' is missing in $RuntimeEnv"
    }
}

if ($envMap["DB_ENGINE"].ToLowerInvariant() -ne "mariadb") {
    throw "DB_ENGINE must be 'mariadb' in production."
}

if ($envMap["DB_HOST"] -ne "maple-db") {
    throw "DB_HOST must be 'maple-db' for the Server-managed Docker network."
}

if ($envMap["DB_PORT"] -ne "3306") {
    throw "DB_PORT must be 3306 inside the Maple Docker network."
}

$appPort = 0
if (-not [int]::TryParse($envMap["APP_PORT"], [ref]$appPort)) {
    throw "APP_PORT must be a valid integer."
}

if ($appPort -lt 1024 -or $appPort -gt 65535) {
    throw "APP_PORT must be between 1024 and 65535."
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker is not available on the mini PC."
}

$existingMapleApp = docker ps --filter "name=maple-app" --format "{{.Names}}" | Where-Object { $_ -eq "maple-app" }
$portListener = Get-NetTCPConnection -State Listen -LocalPort $appPort -ErrorAction SilentlyContinue
if ($portListener -and -not $existingMapleApp) {
    throw "Host port $appPort is already in use by another service."
}

if ($RegistryUser -and $RegistryToken) {
    $RegistryToken | docker login ghcr.io -u $RegistryUser --password-stdin
    if ($LASTEXITCODE -ne 0) {
        throw "GHCR login failed."
    }
}

$env:MAPLE_IMAGE = $MapleImage
$env:MAPLE_DB_DATA_DIR = ($MapleDbDataRoot -replace "\\", "/")

Write-Host "[maple] persistent DB path: $MapleDbDataRoot"
Write-Host "[maple] host port: $appPort"

docker pull $MapleImage
if ($LASTEXITCODE -ne 0) {
    throw "Failed to pull Maple application image."
}

docker compose --env-file $RuntimeEnv -p maple-production -f $ComposeFile pull
if ($LASTEXITCODE -ne 0) {
    throw "Failed to pull Maple production images."
}

docker compose --env-file $RuntimeEnv -p maple-production -f $ComposeFile up -d --remove-orphans
if ($LASTEXITCODE -ne 0) {
    throw "Maple docker compose deployment failed."
}

$healthUrl = "http://127.0.0.1:$appPort/api/health"
$healthy = $false

for ($attempt = 1; $attempt -le 24; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            $healthy = $true
            break
        }
    }
    catch {
        # Startup can take a little longer while MariaDB initializes for the first time.
    }

    Start-Sleep -Seconds 5
}

if (-not $healthy) {
    docker compose --env-file $RuntimeEnv -p maple-production -f $ComposeFile ps
    docker logs --tail 100 maple-app
    throw "Maple health check failed: $healthUrl"
}

$dbHealth = docker inspect --format "{{.State.Health.Status}}" maple-db
if ($LASTEXITCODE -ne 0 -or $dbHealth.Trim() -ne "healthy") {
    throw "Maple MariaDB container is not healthy."
}

$SourceSha | Set-Content -Path $MarkerFile -Encoding ascii

docker compose --env-file $RuntimeEnv -p maple-production -f $ComposeFile ps

Write-Host "[maple] health check OK: $healthUrl"
Write-Host "[maple] deployed source: $SourceSha"
Write-Host "[maple] central deployment complete"
