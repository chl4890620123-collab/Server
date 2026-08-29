param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($ExpectedSha -notmatch '^[0-9a-f]{40}$') {
    throw 'ExpectedSha must be a 40-character Git SHA.'
}

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ComposeFile = Join-Path $ServerRoot 'deploy\compose\maple.yml'
$CaddyFile = Join-Path $ServerRoot 'deploy\caddy\maple.Caddyfile'
$VerifyScript = Join-Path $ServerRoot 'deploy\scripts\verify-maple-rules.py'
$DataRoot = 'D:\server-data\maple'
$RuntimeRoot = Join-Path $DataRoot 'runtime'
$RuntimeEnv = Join-Path $RuntimeRoot '.env'
$DbDataRoot = Join-Path $DataRoot 'mariadb'
$PythonDepsRoot = Join-Path $DataRoot 'python-deps'
$BackupRoot = Join-Path $DataRoot 'backups'
$MarkerFile = Join-Path $RuntimeRoot 'deployed.sha'

function New-SecretValue {
    return ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
}

function Read-EnvFile([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) { $map[$parts[0].Trim()] = $parts[1] }
        }
    }
    return $map
}

function Add-EnvSetting([string]$Path, [hashtable]$Map, [string]$Key, [string]$Value) {
    if (-not $Map.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace([string]$Map[$Key])) {
        Add-Content -Path $Path -Value "$Key=$Value" -Encoding ascii
        $Map[$Key] = $Value
        Write-Host "[maple] added runtime setting: $Key"
    }
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60,
        [switch]$AllowFailure
    )

    $token = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "maple-native-$token.out"
    $stderrPath = Join-Path $env:TEMP "maple-native-$token.err"
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Command timed out after ${TimeoutSeconds}s: $FilePath $($Arguments -join ' ')"
        }
        $process.WaitForExit()
        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "Command failed ($($process.ExitCode)): $FilePath $($Arguments -join ' ')`n$stderr"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = [string]$stdout
            StdErr = [string]$stderr
        }
    } finally {
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '[maple] checking isolated runtime'
if (-not (Test-Path 'D:\')) { throw 'D drive is required for Maple runtime data.' }
if (-not (Test-Path $ComposeFile)) { throw "Maple compose file is missing: $ComposeFile" }
if (-not (Test-Path $CaddyFile)) { throw "Maple Caddyfile is missing: $CaddyFile" }
if (-not (Test-Path $VerifyScript)) { throw "Maple verification script is missing: $VerifyScript" }
Write-Host '[maple] checking Docker Compose plugin'
$composeVersion = Invoke-NativeProcess -FilePath 'docker' -Arguments @('compose', 'version', '--short') -TimeoutSeconds 30
Write-Host "[maple] Docker Compose ready: $($composeVersion.StdOut.Trim())"

@($RuntimeRoot, $DbDataRoot, $PythonDepsRoot, $BackupRoot) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

if (-not (Test-Path $RuntimeEnv)) {
    @"
MAPLE_LOCAL_PORT=9040
MAPLE_PUBLIC_PORT=9040
ADMIN_TOKEN=$(New-SecretValue)
DEFAULT_FEE_RATE=0.05
CORS_ORIGINS=
DB_NAME=maple_craft
DB_USER=maple_app
DB_PASSWORD=$(New-SecretValue)
DB_ROOT_PASSWORD=$(New-SecretValue)
"@ | Set-Content -Path $RuntimeEnv -Encoding ascii
    Write-Host '[maple] created server-local runtime env'
}

$envMap = Read-EnvFile $RuntimeEnv
$dbHasExistingData = $null -ne (Get-ChildItem $DbDataRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
Add-EnvSetting $RuntimeEnv $envMap 'MAPLE_LOCAL_PORT' '9040'
Add-EnvSetting $RuntimeEnv $envMap 'MAPLE_PUBLIC_PORT' '9040'
Add-EnvSetting $RuntimeEnv $envMap 'DEFAULT_FEE_RATE' '0.05'
Add-EnvSetting $RuntimeEnv $envMap 'DB_NAME' 'maple_craft'
Add-EnvSetting $RuntimeEnv $envMap 'DB_USER' 'maple_app'
Add-EnvSetting $RuntimeEnv $envMap 'ADMIN_TOKEN' (New-SecretValue)

$missingDbPassword = -not $envMap.ContainsKey('DB_PASSWORD') -or [string]::IsNullOrWhiteSpace([string]$envMap['DB_PASSWORD'])
$missingRootPassword = -not $envMap.ContainsKey('DB_ROOT_PASSWORD') -or [string]::IsNullOrWhiteSpace([string]$envMap['DB_ROOT_PASSWORD'])
if (($missingDbPassword -or $missingRootPassword) -and $dbHasExistingData) {
    throw 'MariaDB data exists but password settings are missing. Existing data was left untouched.'
}
if ($missingDbPassword) { Add-EnvSetting $RuntimeEnv $envMap 'DB_PASSWORD' (New-SecretValue) }
if ($missingRootPassword) { Add-EnvSetting $RuntimeEnv $envMap 'DB_ROOT_PASSWORD' (New-SecretValue) }

foreach ($key in @('MAPLE_PUBLIC_PORT', 'ADMIN_TOKEN', 'DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_ROOT_PASSWORD')) {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$envMap[$key])) {
        throw "Required Maple setting '$key' is missing."
    }
}

$publicPort = 0
if (-not [int]::TryParse([string]$envMap['MAPLE_PUBLIC_PORT'], [ref]$publicPort) -or $publicPort -lt 1024 -or $publicPort -gt 65535) {
    throw 'MAPLE_PUBLIC_PORT must be between 1024 and 65535.'
}

Write-Host '[maple] checking runtime images'
foreach ($image in @('maple-production-app:latest', 'mariadb:11.4', 'caddy:2.10-alpine')) {
    $imageProbe = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', $image) -TimeoutSeconds 45 -AllowFailure
    if ($imageProbe.ExitCode -ne 0) {
        if ($image -eq 'maple-production-app:latest') { throw 'Maple application image is missing.' }
        Write-Host "[maple] pulling runtime image $image"
        Invoke-NativeProcess -FilePath 'docker' -Arguments @('pull', $image) -TimeoutSeconds 180 | Out-Null
    }
}

$inspect = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', 'maple-production-app:latest') -TimeoutSeconds 45
$inspectData = $inspect.StdOut | ConvertFrom-Json
$revision = [string]$inspectData[0].Config.Labels.'org.opencontainers.image.revision'
if ($revision -ne $ExpectedSha) {
    throw "Maple image revision mismatch: expected=$ExpectedSha actual=$revision"
}

$psResult = Invoke-NativeProcess -FilePath 'docker' -Arguments @('ps', '--format', '{{.Names}}') -TimeoutSeconds 45
$existingDb = @($psResult.StdOut -split "`r?`n" | Where-Object { $_ -eq 'maple-db' })
if ($existingDb.Count -gt 0) {
    Write-Host '[maple] creating pre-deploy MariaDB backup'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    docker exec maple-db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE" > /tmp/maple_backup.sql'
    if ($LASTEXITCODE -ne 0) { throw 'Pre-deploy MariaDB backup failed.' }
    docker cp 'maple-db:/tmp/maple_backup.sql' (Join-Path $BackupRoot "maple_$stamp.sql")
    if ($LASTEXITCODE -ne 0) { throw 'Failed to copy MariaDB backup.' }
    docker exec maple-db rm -f /tmp/maple_backup.sql | Out-Null
}
Get-ChildItem $BackupRoot -Filter 'maple_*.sql' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } | Remove-Item -Force

$env:MAPLE_DB_DATA_DIR = ($DbDataRoot -replace '\\', '/')
$env:MAPLE_PYTHON_DEPS_DIR = ($PythonDepsRoot -replace '\\', '/')
$env:MAPLE_CADDYFILE = ($CaddyFile -replace '\\', '/')

Write-Host '[maple] validating production compose'
Invoke-NativeProcess -FilePath 'docker' -Arguments @('compose', '--env-file', $RuntimeEnv, '-p', 'maple-production', '-f', $ComposeFile, 'config', '--quiet') -TimeoutSeconds 60 | Out-Null

Write-Host '[maple] starting production containers'
$composeUp = Invoke-NativeProcess -FilePath 'docker' -Arguments @('compose', '--env-file', $RuntimeEnv, '-p', 'maple-production', '-f', $ComposeFile, 'up', '-d', '--no-build', '--pull', 'never', '--remove-orphans') -TimeoutSeconds 180
if (-not [string]::IsNullOrWhiteSpace($composeUp.StdOut)) { Write-Host $composeUp.StdOut.Trim() }
if (-not [string]::IsNullOrWhiteSpace($composeUp.StdErr)) { Write-Host $composeUp.StdErr.Trim() }

$localBase = "http://127.0.0.1:$publicPort"
$localReady = $false
for ($attempt = 1; $attempt -le 48; $attempt++) {
    try {
        $meta = Invoke-RestMethod -Method Get -Uri "$localBase/api/meister/meta" -TimeoutSec 5
        $root = Invoke-WebRequest -UseBasicParsing -Uri "$localBase/" -TimeoutSec 5
        if ([int]$meta.total_recipe_count -ge 50 -and $root.StatusCode -eq 200) { $localReady = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $localReady) { throw 'Maple local functional check failed.' }

$categories = Invoke-RestMethod -Method Get -Uri "$localBase/api/meister/categories" -TimeoutSec 10
$categoryKeys = @($categories | ForEach-Object { $_.key })
foreach ($key in @('herbalism', 'mining', 'equipment', 'accessory', 'alchemy')) {
    if ($categoryKeys -notcontains $key) { throw "Meisterville category validation failed: missing $key" }
}
$priceProbe = Invoke-RestMethod -Method Get -Uri "$localBase/api/market-prices?category_key=mining" -TimeoutSec 10
if (@($priceProbe).Count -lt 1) { throw 'Market price API validation failed.' }

Write-Host '[maple] verifying fixed Meisterville rules'
Get-Content $VerifyScript -Raw | docker exec -i maple-app python -
if ($LASTEXITCODE -ne 0) { throw 'Maple fixed-rule verification failed.' }

$ExpectedSha | Set-Content -Path $MarkerFile -Encoding ascii
Write-Host '[maple] deployment complete'
Write-Host "[maple] local URL: $localBase"
Write-Host "[maple] forwarded URL: http://yellow.it.kr:$publicPort"
Write-Host "[maple] source SHA: $ExpectedSha"
Write-Host "[maple] Meisterville categories: $($categoryKeys -join ', ')"
Write-Host "[maple] Meisterville recipes: $($meta.total_recipe_count)"
