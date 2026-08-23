$ErrorActionPreference = "Stop"

$ServerRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
$ComposeFile = Join-Path $ServerRoot "deploy\compose\maple.yml"
$CaddyFile = Join-Path $ServerRoot "deploy\caddy\maple.Caddyfile"
$MapleSourceRoot = "C:\home\server\sources\maple"
$DataRoot = "D:\server-data\maple"
$RuntimeRoot = Join-Path $DataRoot "runtime"
$RuntimeEnv = Join-Path $RuntimeRoot ".env"
$DbDataRoot = Join-Path $DataRoot "mariadb"
$PythonDepsRoot = Join-Path $DataRoot "python-deps"
$BackupRoot = Join-Path $DataRoot "backups"
$MarkerFile = Join-Path $RuntimeRoot "deployed.sha"
$StatusRoot = Join-Path $ServerRoot "deploy\status"
$StatusFile = Join-Path $StatusRoot "maple.txt"

function New-SecretValue { return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")) }

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
        Write-Host "[maple] added runtime setting: $Key"
    }
}

Write-Host "[maple] checking mini PC runtime"
docker version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Engine is not available." }
docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Compose is not available." }
if (-not (Test-Path "D:\")) { throw "D drive is required for Maple runtime data." }
if (-not (Test-Path $ComposeFile)) { throw "Maple compose file is missing: $ComposeFile" }
if (-not (Test-Path $CaddyFile)) { throw "Maple Caddyfile is missing: $CaddyFile" }
if ([string]::IsNullOrWhiteSpace($env:MAPLE_CLOUDFLARED_BINARY) -or -not (Test-Path ($env:MAPLE_CLOUDFLARED_BINARY -replace "/", "\"))) {
    throw "Cloudflared runtime binary is missing."
}

@($RuntimeRoot, $DbDataRoot, $PythonDepsRoot, $BackupRoot, $StatusRoot, (Split-Path $MapleSourceRoot -Parent)) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

if (-not (Test-Path $RuntimeEnv)) {
    @"
MAPLE_LOCAL_PORT=9040
ADMIN_TOKEN=$(New-SecretValue)
DEFAULT_FEE_RATE=0.05
CORS_ORIGINS=
DB_NAME=maple_craft
DB_USER=maple_app
DB_PASSWORD=$(New-SecretValue)
DB_ROOT_PASSWORD=$(New-SecretValue)
"@ | Set-Content -Path $RuntimeEnv -Encoding ascii
    Write-Host "[maple] created server-local runtime env"
}

$envMap = Read-EnvFile $RuntimeEnv
$dbHasExistingData = $null -ne (Get-ChildItem $DbDataRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)

if (-not $envMap.ContainsKey("MAPLE_LOCAL_PORT") -or [string]::IsNullOrWhiteSpace($envMap["MAPLE_LOCAL_PORT"])) {
    $legacyPort = if ($envMap.ContainsKey("APP_PORT") -and -not [string]::IsNullOrWhiteSpace($envMap["APP_PORT"])) { $envMap["APP_PORT"] } else { "9040" }
    Add-EnvSetting $RuntimeEnv $envMap "MAPLE_LOCAL_PORT" $legacyPort
}
Add-EnvSetting $RuntimeEnv $envMap "DEFAULT_FEE_RATE" "0.05"
Add-EnvSetting $RuntimeEnv $envMap "DB_NAME" "maple_craft"
Add-EnvSetting $RuntimeEnv $envMap "DB_USER" "maple_app"

$missingDbPassword = -not $envMap.ContainsKey("DB_PASSWORD") -or [string]::IsNullOrWhiteSpace($envMap["DB_PASSWORD"])
$missingRootPassword = -not $envMap.ContainsKey("DB_ROOT_PASSWORD") -or [string]::IsNullOrWhiteSpace($envMap["DB_ROOT_PASSWORD"])
if (($missingDbPassword -or $missingRootPassword) -and $dbHasExistingData) {
    throw "MariaDB data exists but password settings are missing. Existing data was left untouched."
}
if ($missingDbPassword) { Add-EnvSetting $RuntimeEnv $envMap "DB_PASSWORD" (New-SecretValue) }
if ($missingRootPassword) { Add-EnvSetting $RuntimeEnv $envMap "DB_ROOT_PASSWORD" (New-SecretValue) }

foreach ($key in @("MAPLE_LOCAL_PORT", "ADMIN_TOKEN", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_ROOT_PASSWORD")) {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) { throw "Required setting '$key' is missing." }
}

$localPort = 0
if (-not [int]::TryParse($envMap["MAPLE_LOCAL_PORT"], [ref]$localPort) -or $localPort -lt 1024 -or $localPort -gt 65535) {
    throw "MAPLE_LOCAL_PORT must be between 1024 and 65535."
}
$existingCaddy = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "maple-caddy" }
$listener = Get-NetTCPConnection -State Listen -LocalPort $localPort -ErrorAction SilentlyContinue
if ($listener -and -not $existingCaddy) { throw "Maple local port $localPort is already in use." }

if (-not (Test-Path (Join-Path $MapleSourceRoot ".git"))) {
    if (Test-Path $MapleSourceRoot) { Remove-Item -Recurse -Force $MapleSourceRoot }
    git clone https://github.com/chl4890620123-collab/maple.git $MapleSourceRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to clone Maple repository." }
}
Write-Host "[maple] updating application source"
git -C $MapleSourceRoot fetch --prune origin main
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch Maple main." }
git -C $MapleSourceRoot checkout -B main origin/main
if ($LASTEXITCODE -ne 0) { throw "Failed to checkout Maple main." }
git -C $MapleSourceRoot reset --hard origin/main
if ($LASTEXITCODE -ne 0) { throw "Failed to reset Maple source." }
git -C $MapleSourceRoot clean -fd
if ($LASTEXITCODE -ne 0) { throw "Failed to clean Maple source." }
$MapleSha = (git -C $MapleSourceRoot rev-parse HEAD).Trim()
if (-not $MapleSha) { throw "Could not resolve Maple source SHA." }

$existingDb = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "maple-db" }
if ($existingDb) {
    Write-Host "[maple] creating pre-deploy MariaDB backup"
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    docker exec maple-db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE" > /tmp/maple_backup.sql'
    if ($LASTEXITCODE -ne 0) { throw "Pre-deploy MariaDB backup failed." }
    docker cp "maple-db:/tmp/maple_backup.sql" (Join-Path $BackupRoot "maple_$stamp.sql")
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy MariaDB backup." }
    docker exec maple-db rm -f /tmp/maple_backup.sql | Out-Null
}
Get-ChildItem $BackupRoot -Filter "maple_*.sql" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } | Remove-Item -Force

$env:MAPLE_SOURCE_DIR = ($MapleSourceRoot -replace "\\", "/")
$env:MAPLE_DB_DATA_DIR = ($DbDataRoot -replace "\\", "/")
$env:MAPLE_PYTHON_DEPS_DIR = ($PythonDepsRoot -replace "\\", "/")
$env:MAPLE_CADDYFILE = ($CaddyFile -replace "\\", "/")

Write-Host "[maple] validating compose"
docker compose --env-file $RuntimeEnv -p maple-production -f $ComposeFile config *> $null
if ($LASTEXITCODE -ne 0) { throw "Maple docker compose configuration is invalid." }

Write-Host "[maple] starting local-runtime containers"
docker compose --env-file $RuntimeEnv -p maple-production -f $ComposeFile up -d --remove-orphans
if ($LASTEXITCODE -ne 0) { throw "Maple docker compose deployment failed." }

$localHealth = "http://127.0.0.1:$localPort/api/health"
$localReady = $false
for ($attempt = 1; $attempt -le 48; $attempt++) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $localHealth -TimeoutSec 5
        if ($response.StatusCode -eq 200) { $localReady = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $localReady) { throw "Maple local health check failed: $localHealth" }

Write-Host "[maple] waiting for public preview URL"
$publicUrl = $null
for ($attempt = 1; $attempt -le 36; $attempt++) {
    $logs = (docker logs maple-public-tunnel 2>&1 | Out-String)
    $matches = [regex]::Matches($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($matches.Count -gt 0) { $publicUrl = $matches[$matches.Count - 1].Value; break }
    Start-Sleep -Seconds 5
}
if (-not $publicUrl) { throw "Cloudflare Quick Tunnel did not provide a public URL." }

$publicHealth = "$publicUrl/api/health"
$publicReady = $false
for ($attempt = 1; $attempt -le 24; $attempt++) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $publicHealth -TimeoutSec 10
        if ($response.StatusCode -eq 200) { $publicReady = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $publicReady) { throw "Public Maple health check failed: $publicHealth" }

$root = Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/" -TimeoutSec 10
if ($root.StatusCode -ne 200 -or $root.Content -notmatch "Maple Craft Analytics") { throw "Public Maple page validation failed." }

$MapleSha | Set-Content -Path $MarkerFile -Encoding ascii
$verifiedAt = (Get-Date).ToUniversalTime().ToString("o")
@"
maple_sha=$MapleSha
public_url=$publicUrl
public_health=$publicHealth
local_url=http://127.0.0.1:$localPort
verified_at_utc=$verifiedAt
"@ | Set-Content -Path $StatusFile -Encoding ascii

Write-Host "[maple] deployment complete"
Write-Host "[maple] public URL: $publicUrl"
Write-Host "[maple] public health: $publicHealth"
Write-Host "[maple] source SHA: $MapleSha"
