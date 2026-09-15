param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('maple', 'aitm', 'restok', 'hub')]
    [string]$Service,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SourcesRoot = 'C:\home\server\sources'
New-Item -ItemType Directory -Force -Path $SourcesRoot | Out-Null

function Fail {
    # A plain `throw` was observed to leave the whole remote script hung for tens of minutes even
    # after the real failure had already happened - PowerShell's exception/Write-Host output
    # travels through a separate serialized (CLIXML) channel from a native command's own stdout,
    # and over this non-pty SSH exec that channel can back up and block the process from ever
    # actually exiting. Every failure path in this script goes through here instead: write straight
    # to the already-unbuffered console stream and force-exit, so a real error ends the deploy in
    # seconds rather than only surfacing once the outer 50-minute SSH timeout gives up on it.
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Out.WriteLine($Message)
    [Environment]::Exit(1)
}

function Say {
    # Write-Host/Write-Warning were found to suffer the exact same CLIXML-buffering problem as a
    # bare `throw` (see Fail, above) - not just on failure, but for ordinary progress output too.
    # A run that went silent for ~39 minutes turned out to have made real progress the whole time;
    # every Write-Host line in that window was simply never flushed until the process was killed,
    # making a hang indistinguishable from normal progress in the log. Use this everywhere instead
    # so progress is actually visible in real time, the same way native command output already is.
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Out.WriteLine($Message)
}

function Test-DockerEngine {
    # `docker version` has no built-in timeout. If the engine backend is wedged (eg. left over
    # from a previous deploy attempt whose SSH client was killed without the remote process
    # actually terminating), this call can hang indefinitely instead of erroring - which used to
    # silently eat the entire 50-minute SSH budget with zero output. Bound it explicitly so a
    # hung engine is detected in seconds and the existing restart-service/restart-desktop
    # recovery below actually gets a chance to run.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'docker'
    $psi.Arguments = 'version'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(15000)) {
        try { $proc.Kill() } catch {}
        return [pscustomobject]@{ Ready = $false; Output = 'docker version did not respond within 15s - engine appears hung' }
    }
    $output = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
    return [pscustomobject]@{ Ready = ($proc.ExitCode -eq 0); Output = $output.Trim() }
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-TimedBuild {
    # A bare `docker build` call has no timeout of its own - a stalled base-image pull or a
    # daemon that stops responding mid-build used to hang silently until the outer 50-minute SSH
    # timeout killed the whole deploy with zero diagnostics. Bound each build explicitly so a
    # hang fails fast with a clear reason instead. Output streams through normally (no
    # redirection) since only the wait is bounded, not the process's own I/O.
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutMinutes,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'docker'
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($TimeoutMinutes * 60000)) {
        try { $proc.Kill() } catch {}
        Fail "$Label timed out after ${TimeoutMinutes}m - build appears hung (possibly a stalled registry pull)"
    }
    if ($proc.ExitCode -ne 0) { Fail "$Label failed (exit $($proc.ExitCode))" }
}

function Wait-DockerEngine {
    param([string]$Name)
    $serviceRestartAttempted = $false
    $desktopStartAttempted = $false
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $probe = Test-DockerEngine
        if ($probe.Ready) { Say "[$Name] Docker Linux Engine ready on attempt $attempt"; return }
        if ($attempt -eq 3 -and -not $serviceRestartAttempted) {
            $serviceRestartAttempted = $true
            try {
                $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction Stop
                if ($dockerService.Status -eq 'Running') { Restart-Service -Name 'com.docker.service' -Force -ErrorAction Stop } else { Start-Service -Name 'com.docker.service' -ErrorAction Stop }
            } catch { Say "[$Name] Docker service restart was not available: $($_.Exception.Message)" }
        }
        if ($attempt -eq 7 -and -not $desktopStartAttempted) {
            $desktopStartAttempted = $true
            $desktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
            if (Test-Path $desktopExe) { try { Start-Process -FilePath $desktopExe -WindowStyle Hidden -ErrorAction Stop | Out-Null } catch { Say "[$Name] Docker Desktop startup request failed: $($_.Exception.Message)" } }
        }
        if ($attempt -eq 18) { Fail "Docker Linux Engine did not become ready. Last response: $($probe.Output)" }
        Start-Sleep -Seconds 5
    }
}

$services = @{
    maple = @{ Repository = 'https://github.com/chl4890620123-collab/maple.git'; SourceDir = Join-Path $SourcesRoot 'maple' }
    aitm = @{ Repository = 'https://github.com/chl4890620123-collab/Aitm.git'; SourceDir = Join-Path $SourcesRoot 'aitm' }
    restok = @{ Repository = 'https://github.com/chl4890620123-collab/Restok-Rangchain.git'; SourceDir = Join-Path $SourcesRoot 'restok' }
    hub = @{ Repository = 'https://github.com/chl4890620123-collab/hub.git'; SourceDir = Join-Path $SourcesRoot 'hub' }
}

$spec = $services[$Service]
$sourceDir = [string]$spec.SourceDir
$repository = [string]$spec.Repository
Say "[$Service] isolated source: $sourceDir"
$staleLock = Join-Path $sourceDir '.git\index.lock'
if (Test-Path $staleLock) {
    # Left behind by a previous git operation whose SSH client was killed mid-command (eg. by the
    # outer 50-minute timeout) without the remote process actually terminating. git refuses to run
    # while this exists; removing it is git's own documented recovery for a stale lock.
    Say "[$Service] removing stale git lock from an interrupted previous attempt: $staleLock"
    Remove-Item -Force $staleLock -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $sourceDir '.git'))) {
    if (Test-Path $sourceDir) { Remove-Item -Recurse -Force $sourceDir }
    git clone $repository $sourceDir
    if ($LASTEXITCODE -ne 0) { Fail "[$Service] clone failed" }
}

git -C $sourceDir remote set-url origin $repository
if ($LASTEXITCODE -ne 0) { Fail "[$Service] remote reset failed" }
git -C $sourceDir reset --hard HEAD
if ($LASTEXITCODE -ne 0) { Fail "[$Service] reset failed" }
git -C $sourceDir clean -fd
if ($LASTEXITCODE -ne 0) { Fail "[$Service] clean failed" }
git -C $sourceDir fetch --force --prune origin '+refs/heads/main:refs/remotes/origin/main'
if ($LASTEXITCODE -ne 0) { Fail "[$Service] fetch failed" }
$remoteSha = (git -C $sourceDir rev-parse refs/remotes/origin/main | Out-String).Trim()
if ($remoteSha -notmatch '^[0-9a-f]{40}$') { Fail "[$Service] invalid remote main SHA" }
git -C $sourceDir checkout -B main $remoteSha
if ($LASTEXITCODE -ne 0) { Fail "[$Service] checkout failed" }
git -C $sourceDir reset --hard $remoteSha
if ($LASTEXITCODE -ne 0) { Fail "[$Service] main reset failed" }
git -C $sourceDir clean -fd
if ($LASTEXITCODE -ne 0) { Fail "[$Service] final clean failed" }
$sourceSha = (git -C $sourceDir rev-parse HEAD | Out-String).Trim()
if ($sourceSha -ne $remoteSha) { Fail "[$Service] checkout mismatch: local=$sourceSha remote=$remoteSha" }
Say "[$Service] source SHA: $sourceSha"
Say "[$Service] verified remote main SHA: $remoteSha"

$previousDockerConfig = $env:DOCKER_CONFIG
$previousDockerApiVersion = $env:DOCKER_API_VERSION
$dockerConfigRoot = Join-Path $env:TEMP ("server-docker-" + [guid]::NewGuid().ToString('N'))
$dockerPluginRoot = Join-Path $dockerConfigRoot 'cli-plugins'
New-Item -ItemType Directory -Force -Path $dockerPluginRoot | Out-Null
'{"auths":{}}' | Set-Content -Path (Join-Path $dockerConfigRoot 'config.json') -Encoding ascii
# `docker compose` (and any other `docker-*` subcommand) is a CLI plugin resolved from
# $DOCKER_CONFIG/cli-plugins - a fresh, empty isolated config dir has none, so `docker compose ...`
# falls through unrecognized to docker's root parser ("unknown flag") instead of ever reaching the
# compose plugin. run-maple-deploy.ps1 already solved this for maple's own separate isolated
# config; stage the same plugin binaries here so every app using this shared isolation can resolve
# `docker compose` too - hub is simply the first to actually call it through this path.
foreach ($pluginSource in @(
    (Join-Path $env:USERPROFILE '.docker\cli-plugins'),
    (Join-Path $env:ProgramFiles 'Docker\Docker\resources\cli-plugins'),
    (Join-Path $env:ProgramFiles 'Docker\cli-plugins')
)) {
    if (Test-Path $pluginSource) {
        Get-ChildItem $pluginSource -Filter 'docker-*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $dockerPluginRoot $_.Name) -Force
        }
    }
}
$env:DOCKER_CONFIG = $dockerConfigRoot
$env:DOCKER_API_VERSION = '1.44'
Say "[$Service] using isolated Docker CLI config and compatible API version"
try {
    Wait-DockerEngine -Name $Service
    switch ($Service) {
        'maple' {
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t maple-production-app:latest $sourceDir
            if ($LASTEXITCODE -ne 0) { Fail '[maple] Docker build failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-maple.ps1') -ExpectedSha $sourceSha
            if (-not $?) { Fail '[maple] deployment failed' }
        }
        'aitm' {
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t aitm-production-ai:latest (Join-Path $sourceDir 'demo\ai')
            if ($LASTEXITCODE -ne 0) { Fail '[aitm] AI build failed' }
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t aitm-production-backend:latest (Join-Path $sourceDir 'demo')
            if ($LASTEXITCODE -ne 0) { Fail '[aitm] backend build failed' }
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t aitm-production-frontend:latest (Join-Path $sourceDir 'front')
            if ($LASTEXITCODE -ne 0) { Fail '[aitm] frontend build failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-aitm.ps1') -ExpectedSha $sourceSha -Force:$Force
            if (-not $?) { Fail '[aitm] deployment failed' }
        }
        'restok' {
            docker build --pull -t restok-production-ai:latest (Join-Path $sourceDir 'ai_server')
            if ($LASTEXITCODE -ne 0) { Fail '[restok] AI build failed' }
            docker build --pull -t restok-production-backend:latest (Join-Path $sourceDir 'backend')
            if ($LASTEXITCODE -ne 0) { Fail '[restok] backend build failed' }
            docker build --pull --build-arg REACT_APP_API_URL= -t restok-production-frontend:latest (Join-Path $sourceDir 'frontend')
            if ($LASTEXITCODE -ne 0) { Fail '[restok] frontend build failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\check-restok-legacy-data.ps1')
            if (-not $?) { Fail '[restok] legacy-data preflight failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-restok.ps1') -Force:$Force -Prebuilt
            if (-not $?) { Fail '[restok] deployment failed' }
        }
        'hub' {
            # A bare `docker pull` of these small runtime images (used later by docker compose,
            # not built from source) fails immediately with a Windows credential-helper error ("A
            # specified logon session does not exist") on this machine - reproduced regardless of
            # invocation method (Start-Process vs. direct) or timing (seconds vs. minutes into the
            # SSH session). The one thing that's reliably worked throughout this whole deploy is
            # `docker build --pull`, which has fetched several other public base images
            # (python/node/gradle/temurin) without ever hitting this error - those were apparently
            # already cached locally, so a real registry contact by that path was never actually
            # exercised before now. Route these two through the same `docker build --pull`
            # mechanism via a throwaway single-line Dockerfile instead of calling `docker pull`
            # directly, so they land in the local cache the same reliable way.
            foreach ($runtimeImage in @('pgvector/pgvector:pg16', 'caddy:2.10-alpine')) {
                $warmDir = Join-Path $env:TEMP ("hub-warm-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Force -Path $warmDir | Out-Null
                try {
                    "FROM $runtimeImage" | Set-Content -Path (Join-Path $warmDir 'Dockerfile') -Encoding ascii
                    docker build --pull -t hub-runtime-warm:latest $warmDir
                    if ($LASTEXITCODE -ne 0) { Fail "Failed to pull runtime image via build: $runtimeImage" }
                } finally {
                    Remove-Item -Recurse -Force $warmDir -ErrorAction SilentlyContinue
                }
            }
            # Clear images left over from any previous interrupted build so a corrupted/partial
            # layer cannot silently poison this attempt - forces a genuinely fresh rebuild.
            foreach ($staleImage in @('hub-production-ai:latest', 'hub-production-backend:latest')) {
                # Under $ErrorActionPreference='Stop' (set script-wide), a native command writing
                # to stderr is promoted to a terminating error the instant it's written,
                # regardless of stream redirection (2>&1, *>$null - neither stops it, only try/catch
                # does). Without this, the very first hub deploy - or any deploy where a previous
                # attempt never left an image behind - aborts here simply because there was nothing
                # to remove.
                try { docker image rm -f $staleImage 2>$null | Out-Null } catch {}
            }
            # backend/Dockerfile expects the repo root as build context (it COPYs frontend/ and
            # backend/ side by side), unlike the other apps' self-contained per-service Dockerfiles.
            Invoke-TimedBuild -TimeoutMinutes 20 -Label '[hub] AI build' -Arguments @(
                'build', '--pull', '--label', "org.opencontainers.image.revision=$sourceSha",
                '-t', 'hub-production-ai:latest', (Join-Path $sourceDir 'ai-service')
            )
            Invoke-TimedBuild -TimeoutMinutes 20 -Label '[hub] backend build' -Arguments @(
                'build', '--pull', '--label', "org.opencontainers.image.revision=$sourceSha",
                '-f', (Join-Path $sourceDir 'backend\Dockerfile'), '-t', 'hub-production-backend:latest', $sourceDir
            )
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-hub.ps1') -ExpectedSha $sourceSha -Force:$Force
            if (-not $?) { Fail '[hub] deployment failed' }
        }
    }
} finally {
    if ([string]::IsNullOrWhiteSpace($previousDockerConfig)) { Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue } else { $env:DOCKER_CONFIG = $previousDockerConfig }
    if ([string]::IsNullOrWhiteSpace($previousDockerApiVersion)) { Remove-Item Env:DOCKER_API_VERSION -ErrorAction SilentlyContinue } else { $env:DOCKER_API_VERSION = $previousDockerApiVersion }
    Remove-Item -Recurse -Force $dockerConfigRoot -ErrorAction SilentlyContinue
}
Say "[$Service] Server deployment complete"
Say "[$Service] source SHA: $sourceSha"
