param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail {
    # A plain `throw` can leave this whole script hung for tens of minutes instead of exiting -
    # PowerShell's exception/Write-Host output travels through a separate serialized (CLIXML)
    # channel from a native command's own stdout, and over a non-pty SSH exec that channel can
    # back up and block the process from ever actually exiting. Write straight to the console
    # stream and force-exit instead, so a real failure here ends the deploy in seconds.
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Out.WriteLine($Message)
    [Environment]::Exit(1)
}

function Say {
    # Write-Host/Write-Warning were found to suffer the exact same CLIXML-buffering problem as a
    # bare `throw` (see Fail, above) - not just on failure, but for ordinary progress output too.
    # A run that went silent for ~39 minutes right after this script's first line turned out to be
    # indistinguishable from real progress, because every subsequent Write-Host call was simply
    # never flushed until the process was killed. Use this everywhere instead so progress is
    # actually visible in real time, the same way native command output already is.
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Out.WriteLine($Message)
}

if ($ExpectedSha -notmatch '^[0-9a-f]{40}$') {
    Fail 'ExpectedSha must be a 40-character Git SHA.'
}

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ComposeFile = Join-Path $ServerRoot 'deploy\compose\hub.yml'
$CaddyFile = Join-Path $ServerRoot 'deploy\caddy\hub.Caddyfile'
$PublicRoutePath = Join-Path $ServerRoot 'deploy\scripts\ensure-public-route.ps1'
$DataRoot = 'D:\server-data\hub'
$RuntimeRoot = Join-Path $DataRoot 'runtime'
$RuntimeEnv = Join-Path $RuntimeRoot '.env'
$DbDataRoot = Join-Path $DataRoot 'postgres'
$StorageDataRoot = Join-Path $DataRoot 'storage'
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
        Say "[hub] added runtime setting: $Key"
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
    $stdoutPath = Join-Path $env:TEMP "hub-native-$token.out"
    $stderrPath = Join-Path $env:TEMP "hub-native-$token.err"
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            Fail "Command timed out after ${TimeoutSeconds}s: $FilePath $($Arguments -join ' ')"
        }
        $process.WaitForExit()
        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            Fail "Command failed ($($process.ExitCode)): $FilePath $($Arguments -join ' ')`n$stderr"
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = [string]$stdout; StdErr = [string]$stderr }
    } finally {
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

Say '[hub] checking isolated runtime'
if (-not (Test-Path 'D:\')) { Fail 'D drive is required for Hub runtime data.' }
if (-not (Test-Path $ComposeFile)) { Fail "Hub compose file is missing: $ComposeFile" }
if (-not (Test-Path $CaddyFile)) { Fail "Hub Caddyfile is missing: $CaddyFile" }
Say '[hub] checking Docker Compose plugin'
$composeVersion = Invoke-NativeProcess -FilePath 'docker' -Arguments @('compose', 'version', '--short') -TimeoutSeconds 30
Say "[hub] Docker Compose ready: $($composeVersion.StdOut.Trim())"

@($RuntimeRoot, $DbDataRoot, $StorageDataRoot, $BackupRoot) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

if (-not (Test-Path $RuntimeEnv)) {
    @"
HUB_HOST_PORT=9070
DB_NAME=hub
DB_USER=hub
DB_PASSWORD=$(New-SecretValue)
HUB_JWT_SECRET=$(New-SecretValue)
HUB_ADMIN_SETUP_KEY=$(New-SecretValue)
HUB_STT_PII_HASH_KEY=$(New-SecretValue)
HUB_COOKIE_SECURE=false
HUB_ENFORCE_SECURE_CONFIG=false
HUB_PUBLIC_DOMAIN=yellow.it.kr
HUB_PUBLIC_BASE_URL=
HUB_OUTER_CADDY_AUTO_CONFIGURE=true
HUB_ALLOW_DOMAIN_TAKEOVER=true
HUB_AI_MODE=mock
GEMINI_API_KEY=
HUB_EMBED_MODE=e5
"@ | Set-Content -Path $RuntimeEnv -Encoding ascii
    Say '[hub] created server-local runtime env - fill in GEMINI_API_KEY and set HUB_AI_MODE=gemini (and any connector tokens) at:'
    Say "[hub] $RuntimeEnv"
}

$envMap = Read-EnvFile $RuntimeEnv
$dbHasExistingData = $null -ne (Get-ChildItem $DbDataRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
Add-EnvSetting $RuntimeEnv $envMap 'HUB_HOST_PORT' '9070'
Add-EnvSetting $RuntimeEnv $envMap 'DB_NAME' 'hub'
Add-EnvSetting $RuntimeEnv $envMap 'DB_USER' 'hub'

$missingDbPassword = -not $envMap.ContainsKey('DB_PASSWORD') -or [string]::IsNullOrWhiteSpace([string]$envMap['DB_PASSWORD'])
if ($missingDbPassword -and $dbHasExistingData) {
    Fail 'Postgres data exists but DB_PASSWORD is missing. Existing data was left untouched.'
}
if ($missingDbPassword) { Add-EnvSetting $RuntimeEnv $envMap 'DB_PASSWORD' (New-SecretValue) }
if (-not $envMap.ContainsKey('HUB_JWT_SECRET') -or [string]::IsNullOrWhiteSpace([string]$envMap['HUB_JWT_SECRET'])) {
    Add-EnvSetting $RuntimeEnv $envMap 'HUB_JWT_SECRET' (New-SecretValue)
}
if (-not $envMap.ContainsKey('HUB_ADMIN_SETUP_KEY') -or [string]::IsNullOrWhiteSpace([string]$envMap['HUB_ADMIN_SETUP_KEY'])) {
    Add-EnvSetting $RuntimeEnv $envMap 'HUB_ADMIN_SETUP_KEY' (New-SecretValue)
}
if (-not $envMap.ContainsKey('HUB_STT_PII_HASH_KEY') -or [string]::IsNullOrWhiteSpace([string]$envMap['HUB_STT_PII_HASH_KEY'])) {
    Add-EnvSetting $RuntimeEnv $envMap 'HUB_STT_PII_HASH_KEY' (New-SecretValue)
}

# ai-service crashes on startup (RuntimeError, not a slow failure) when HUB_AI_MODE=gemini has no
# GEMINI_API_KEY - and backend's `depends_on: ai: condition: service_healthy` means it would then
# never start at all. Force mock mode until a real key is present so the stack can actually come
# up; switch this back to gemini once GEMINI_API_KEY is filled in.
$aiMode = [string]$envMap['HUB_AI_MODE']
$geminiKeyBlank = -not $envMap.ContainsKey('GEMINI_API_KEY') -or [string]::IsNullOrWhiteSpace([string]$envMap['GEMINI_API_KEY'])
if ($aiMode -eq 'gemini' -and $geminiKeyBlank) {
    Say '[hub] HUB_AI_MODE=gemini but GEMINI_API_KEY is blank - the AI service would crash-loop and backend would never start. Forcing HUB_AI_MODE=mock for this deploy; set GEMINI_API_KEY and change HUB_AI_MODE back to gemini in the runtime .env once ready.'
    $envMap['HUB_AI_MODE'] = 'mock'
    $envContent = Get-Content $RuntimeEnv
    $envContent = $envContent -replace '^\s*HUB_AI_MODE\s*=.*$', 'HUB_AI_MODE=mock'
    Set-Content -Path $RuntimeEnv -Value $envContent -Encoding ascii
}

foreach ($key in @('HUB_HOST_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD', 'HUB_JWT_SECRET')) {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$envMap[$key])) {
        Fail "Required Hub setting '$key' is missing."
    }
}

$publicPort = 0
if (-not [int]::TryParse([string]$envMap['HUB_HOST_PORT'], [ref]$publicPort) -or $publicPort -lt 1024 -or $publicPort -gt 65535) {
    Fail 'HUB_HOST_PORT must be between 1024 and 65535.'
}

Say '[hub] checking runtime base images'
foreach ($image in @('pgvector/pgvector:pg16', 'caddy:2.10-alpine')) {
    $imageProbe = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', $image) -TimeoutSeconds 45 -AllowFailure
    if ($imageProbe.ExitCode -ne 0) {
        Say "[hub] pulling runtime image $image"
        Invoke-NativeProcess -FilePath 'docker' -Arguments @('pull', $image) -TimeoutSeconds 180 | Out-Null
    }
}
foreach ($image in @('hub-production-ai:latest', 'hub-production-backend:latest')) {
    $imageProbe = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', $image) -TimeoutSeconds 45 -AllowFailure
    if ($imageProbe.ExitCode -ne 0) { Fail "Hub application image is missing: $image" }
}

$inspect = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', 'hub-production-backend:latest') -TimeoutSeconds 45
$inspectData = $inspect.StdOut | ConvertFrom-Json
$revision = [string]$inspectData[0].Config.Labels.'org.opencontainers.image.revision'
if ($revision -ne $ExpectedSha) {
    Fail "Hub backend image revision mismatch: expected=$ExpectedSha actual=$revision"
}

$psResult = Invoke-NativeProcess -FilePath 'docker' -Arguments @('ps', '--format', '{{.Names}}') -TimeoutSeconds 45
$existingDb = @($psResult.StdOut -split "`r?`n" | Where-Object { $_ -eq 'hub-db' })
if ($existingDb.Count -gt 0) {
    Say '[hub] creating pre-deploy Postgres backup'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    docker exec hub-db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > /tmp/hub_backup.sql'
    if ($LASTEXITCODE -ne 0) { Fail 'Pre-deploy Postgres backup failed.' }
    docker cp 'hub-db:/tmp/hub_backup.sql' (Join-Path $BackupRoot "hub_$stamp.sql")
    if ($LASTEXITCODE -ne 0) { Fail 'Failed to copy Postgres backup.' }
    docker exec hub-db rm -f /tmp/hub_backup.sql | Out-Null
}
Get-ChildItem $BackupRoot -Filter 'hub_*.sql' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } | Remove-Item -Force

$env:HUB_DB_DATA_DIR = ($DbDataRoot -replace '\\', '/')
$env:HUB_STORAGE_DATA_DIR = ($StorageDataRoot -replace '\\', '/')
$env:HUB_CADDYFILE = ($CaddyFile -replace '\\', '/')

Say '[hub] validating production compose'
Invoke-NativeProcess -FilePath 'docker' -Arguments @('compose', '--env-file', $RuntimeEnv, '-p', 'hub-production', '-f', $ComposeFile, 'config', '--quiet') -TimeoutSeconds 60 | Out-Null

Say '[hub] starting production containers'
$composeUp = Invoke-NativeProcess -FilePath 'docker' -Arguments @('compose', '--env-file', $RuntimeEnv, '-p', 'hub-production', '-f', $ComposeFile, 'up', '-d', '--no-build', '--pull', 'never', '--remove-orphans') -TimeoutSeconds 180
if (-not [string]::IsNullOrWhiteSpace($composeUp.StdOut)) { Say $composeUp.StdOut.Trim() }
if (-not [string]::IsNullOrWhiteSpace($composeUp.StdErr)) { Say $composeUp.StdErr.Trim() }

$localBase = "http://127.0.0.1:$publicPort"
$localReady = $false
for ($attempt = 1; $attempt -le 48; $attempt++) {
    try {
        $health = Invoke-RestMethod -Method Get -Uri "$localBase/actuator/health" -TimeoutSec 5
        $root = Invoke-WebRequest -UseBasicParsing -Uri "$localBase/" -TimeoutSec 5
        if ([string]$health.status -eq 'UP' -and $root.StatusCode -eq 200) { $localReady = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $localReady) { Fail 'Hub local functional check failed.' }

$publicDomain = [string]$envMap['HUB_PUBLIC_DOMAIN']
if ([string]::IsNullOrWhiteSpace($publicDomain)) { $publicDomain = 'yellow.it.kr' }
$autoConfigureOuterCaddy = ([string]$envMap['HUB_OUTER_CADDY_AUTO_CONFIGURE']).ToLowerInvariant() -eq 'true'
$allowDomainTakeover = ([string]$envMap['HUB_ALLOW_DOMAIN_TAKEOVER']).ToLowerInvariant() -eq 'true'
$moveAiRoot = if ($envMap.ContainsKey('MOVEAI_ROOT') -and -not [string]::IsNullOrWhiteSpace([string]$envMap['MOVEAI_ROOT'])) { [string]$envMap['MOVEAI_ROOT'] } else { 'C:/MOVEAI' }

if ($autoConfigureOuterCaddy) {
    Say "[hub] registering public route on the shared MOVEAI Caddy: $publicDomain -> :$publicPort"
    & $PublicRoutePath -MoveAiRoot $moveAiRoot -Domain $publicDomain -HostPort $publicPort -AppName 'hub' -AllowTakeover:$allowDomainTakeover
    if (-not $?) { Fail 'Public route registration failed.' }
} else {
    Say '[hub] HUB_OUTER_CADDY_AUTO_CONFIGURE=false; existing MOVEAI Caddyfile was not modified.'
}

$ExpectedSha | Set-Content -Path $MarkerFile -Encoding ascii
Say '[hub] deployment complete'
Say "[hub] local URL: $localBase"
if ($autoConfigureOuterCaddy) {
    Say "[hub] forwarded URL: https://$publicDomain"
} else {
    Say '[hub] HUB_OUTER_CADDY_AUTO_CONFIGURE=false; no public URL yet - only the local URL above is reachable.'
}
Say "[hub] source SHA: $ExpectedSha"
