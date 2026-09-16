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

function Invoke-Docker {
    # Started as a Start-Process-based helper (Invoke-NativeProcess), but Start-Process-spawned
    # docker children were observed not resolving the same config/context as directly-invoked
    # docker commands on this machine - a `docker image inspect` through it reported an image as
    # missing moments after a direct `docker build` had put it in the local cache. Invoke docker
    # directly via Process.Start instead (the same mechanism proven reliable for build/pull
    # elsewhere in this deploy).
    #
    # First version read StdOut then StdErr synchronously via .ReadToEnd() after WaitForExit,
    # which deadlocked (timed out) the moment output was large enough to fill the OS pipe buffer
    # while nothing was draining it - hit immediately by `docker image inspect` on a large,
    # multi-stage image. A second version drained both streams via DataReceived events
    # (BeginOutputReadLine/AppendLine per line), which fixed the deadlock but reordered/interleaved
    # lines under load badly enough to corrupt JSON output (reproduced locally - a `docker image
    # inspect` blob came back with shuffled lines and mismatched brackets). Use Task-based
    # ReadToEndAsync on both streams instead, started before WaitForExit so neither pipe can fill
    # and block the child, each returning one intact, correctly-ordered string - verified locally
    # against the same large image with no deadlock and valid, parseable JSON.
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60,
        [switch]$AllowFailure
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'docker'
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch {}
        Fail "Command timed out after ${TimeoutSeconds}s: docker $($Arguments -join ' ')"
    }
    $proc.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if ($proc.ExitCode -ne 0 -and -not $AllowFailure) {
        Fail "Command failed ($($proc.ExitCode)): docker $($Arguments -join ' ')`n$stderr"
    }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = [string]$stdout; StdErr = [string]$stderr }
}

Say '[hub] checking isolated runtime'
if (-not (Test-Path 'D:\')) { Fail 'D drive is required for Hub runtime data.' }
if (-not (Test-Path $ComposeFile)) { Fail "Hub compose file is missing: $ComposeFile" }
if (-not (Test-Path $CaddyFile)) { Fail "Hub Caddyfile is missing: $CaddyFile" }
Say '[hub] checking Docker Compose plugin'
# --short isn't supported by every Compose CLI build (seen rejected outright as "unknown flag" on
# the production machine) and this is purely a log line, not a version gate - AllowFailure so a
# flag/version quirk here can never abort the whole deploy.
$composeVersion = Invoke-Docker -Arguments @('compose', 'version') -TimeoutSeconds 30 -AllowFailure
# -AllowFailure means StdOut can legitimately be $null (Get-Content -Raw returns $null, not '',
# for a zero-byte file) - calling .Trim() on that directly throws "cannot call a method on a
# null-valued expression" and aborts the deploy on what is only ever a log line.
$composeVersionText = if ([string]::IsNullOrEmpty($composeVersion.StdOut)) { '(no output)' } else { $composeVersion.StdOut.Trim() }
Say "[hub] Docker Compose ready: $composeVersionText"

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
    # `docker image inspect` via Invoke-NativeProcess/Start-Process reported an image as missing
    # moments after deploy-service.ps1 had just built it into the local cache via
    # `docker build --pull` (direct invocation) - Start-Process-spawned docker children appear not
    # to resolve the same config/context as directly-invoked ones on this machine. Use a direct
    # native call here too, matching every other docker invocation that's proven reliable. try/catch
    # (not *>$null/2>&1) because a missing image's stderr write is promoted to a terminating error
    # under this script's $ErrorActionPreference='Stop' regardless of stream redirection.
    $imageExists = $true
    try {
        docker image inspect $image 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $imageExists = $false }
    } catch { $imageExists = $false }
    if (-not $imageExists) {
        Say "[hub] pulling runtime image $image"
        docker pull $image
        if ($LASTEXITCODE -ne 0) { Fail "Failed to pull runtime image: $image" }
    }
}
foreach ($image in @('hub-production-ai:latest', 'hub-production-backend:latest')) {
    # Same Start-Process-vs-direct-invocation visibility issue as above: these were built via a
    # direct `docker build` call in deploy-service.ps1, so check for them the same way.
    $imageExists = $true
    try {
        docker image inspect $image 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $imageExists = $false }
    } catch { $imageExists = $false }
    if (-not $imageExists) { Fail "Hub application image is missing: $image" }
}

$inspect = Invoke-Docker -Arguments @('image', 'inspect', 'hub-production-backend:latest') -TimeoutSeconds 45
$inspectData = $inspect.StdOut | ConvertFrom-Json
$revision = [string]$inspectData[0].Config.Labels.'org.opencontainers.image.revision'
if ($revision -ne $ExpectedSha) {
    Fail "Hub backend image revision mismatch: expected=$ExpectedSha actual=$revision"
}

$psResult = Invoke-Docker -Arguments @('ps', '--format', '{{.Names}}') -TimeoutSeconds 45
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
Invoke-Docker -Arguments @('compose', '--env-file', $RuntimeEnv, '-p', 'hub-production', '-f', $ComposeFile, 'config', '--quiet') -TimeoutSeconds 60 | Out-Null

Say '[hub] starting production containers'
$composeUp = Invoke-Docker -Arguments @('compose', '--env-file', $RuntimeEnv, '-p', 'hub-production', '-f', $ComposeFile, 'up', '-d', '--no-build', '--pull', 'never', '--remove-orphans') -TimeoutSeconds 180 -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($composeUp.StdOut)) { Say $composeUp.StdOut.Trim() }
if (-not [string]::IsNullOrWhiteSpace($composeUp.StdErr)) { Say $composeUp.StdErr.Trim() }
if ($composeUp.ExitCode -ne 0) {
    # `up` failing (eg. a dependency container reporting unhealthy) previously called Fail here
    # immediately, before the actually-useful in-container error was ever captured - every failure
    # just showed compose's generic "dependency failed to start" message. Dump each service's
    # recent logs and health state first so the real cause is visible in the CI log.
    foreach ($container in @('hub-db', 'hub-ai', 'hub-backend', 'hub-caddy')) {
        Say "--- docker logs $container (last 100 lines) ---"
        $logs = Invoke-Docker -Arguments @('logs', '--tail', '100', $container) -TimeoutSeconds 30 -AllowFailure
        Say $(if ([string]::IsNullOrWhiteSpace($logs.StdOut) -and [string]::IsNullOrWhiteSpace($logs.StdErr)) { '(no logs / container not created)' } else { ($logs.StdOut + $logs.StdErr).Trim() })
        Say "--- docker inspect $container health/state ---"
        $inspectHealth = Invoke-Docker -Arguments @('inspect', '--format', '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}(none){{end}} exitcode={{.State.ExitCode}}', $container) -TimeoutSeconds 15 -AllowFailure
        Say $(if ([string]::IsNullOrWhiteSpace($inspectHealth.StdOut)) { '(container not created)' } else { $inspectHealth.StdOut.Trim() })
    }
    Fail "Command failed ($($composeUp.ExitCode)): docker compose up`n$($composeUp.StdErr)"
}

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
$moveAiRoot = if ($envMap.ContainsKey('MOVEAI_ROOT') -and -not [string]::IsNullOrWhiteSpace([string]$envMap['MOVEAI_ROOT'])) { [string]$envMap['MOVEAI_ROOT'] } else { 'C:/saver' }

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
