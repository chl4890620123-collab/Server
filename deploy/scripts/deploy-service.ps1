param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('hub')]
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

# The system clock has drifted before (once ~26 days behind), which silently breaks every
# outbound TLS call this script makes - git fetch over https, `docker build --pull` against
# Docker Hub - because the far end's certificate validity window fails to check out against a
# machine that thinks it's a different day. `docker build --pull` for pgvector/pgvector:pg16
# failed exactly this way: "certificate has expired or is not yet valid: current time
# 2026-08-26T13:49:48Z is before 2026-09-05T00:51:31Z". Force an NTP resync before touching git or
# Docker at all, on every deploy, so this doesn't need a manual RDP session to notice and fix.
# Best-effort: if the machine can't reach an NTP server (or w32time isn't running), this is a
# no-op and the real failure below still surfaces with its own clear error, same as before.
try {
    Say "[time] before resync: $(Get-Date -Format o)"
    $resyncOutput = (w32tm /resync /force 2>&1 | Out-String).Trim()
    Say "[time] w32tm /resync: $resyncOutput"
    Say "[time] after resync: $(Get-Date -Format o)"
} catch {
    Say "[time] resync attempt failed: $($_.Exception.Message)"
}

$services = @{
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
$previousDockerHost = $env:DOCKER_HOST
$previousDockerContext = $env:DOCKER_CONTEXT
$previousDockerApiVersion = $env:DOCKER_API_VERSION
$dockerConfigRoot = Join-Path $env:TEMP ("server-docker-" + [guid]::NewGuid().ToString('N'))
$dockerPluginRoot = Join-Path $dockerConfigRoot 'cli-plugins'
New-Item -ItemType Directory -Force -Path $dockerPluginRoot | Out-Null
'{"auths":{}}' | Set-Content -Path (Join-Path $dockerConfigRoot 'config.json') -Encoding ascii
# `docker compose` is a CLI plugin resolved from $DOCKER_CONFIG/cli-plugins - a fresh, empty
# isolated config dir has none, so `docker compose ...` falls through unrecognized to docker's
# root parser ("unknown flag") instead of ever reaching the compose plugin. Stage ONLY
# docker-compose.exe (not a broad docker-*.exe glob): staging docker-buildx.exe as well was tried
# first and made `docker build --pull` silently switch from the classic builder to BuildKit's
# containerized `docker-container` driver, which does its own separate registry/credential
# resolution and reintroduced the already-solved Windows credential-helper failure
# ("A specified logon session does not exist") for a completely different reason.
$composePlugin = $null
foreach ($pluginSource in @(
    (Join-Path $env:USERPROFILE '.docker\cli-plugins'),
    (Join-Path $env:ProgramFiles 'Docker\Docker\resources\cli-plugins'),
    (Join-Path $env:ProgramFiles 'Docker\cli-plugins')
)) {
    $candidate = Join-Path $pluginSource 'docker-compose.exe'
    if (Test-Path $candidate) { $composePlugin = $candidate; break }
}
if (-not $composePlugin) {
    # A Docker Desktop reinstall/update moves its own install layout - these 3 fixed paths were
    # the known layout as of when this was written, not a permanent contract. Rather than fail
    # every deploy with the cryptic downstream symptom ("docker compose" falling through to the
    # root docker CLI's own parser: "unknown flag: --env-file", which does not mention compose or
    # a missing plugin at all), search for it before giving up. Bounded depth so this can't turn
    # into a slow crawl of the whole Program Files tree.
    $composePlugin = Get-ChildItem -Path $env:ProgramFiles -Filter 'docker-compose.exe' -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if ($composePlugin) {
    Copy-Item $composePlugin (Join-Path $dockerPluginRoot 'docker-compose.exe') -Force
} else {
    Say "[$Service] warning: docker-compose.exe was not found under any known Docker Desktop path or $env:ProgramFiles - 'docker compose' calls below will fail with 'unknown flag'"
}
$env:DOCKER_CONFIG = $dockerConfigRoot
# The isolated config has no Docker Desktop contexts. Point docker and its Compose plugin at
# the verified Linux engine pipe so they do not fall back to the unavailable docker_engine pipe.
$env:DOCKER_HOST = 'npipe:////./pipe/dockerDesktopLinuxEngine'
Remove-Item Env:DOCKER_CONTEXT -ErrorAction SilentlyContinue
$env:DOCKER_API_VERSION = '1.44'
Say "[$Service] using isolated Docker CLI config, Linux engine pipe and compatible API version"
try {
    Wait-DockerEngine -Name $Service
    switch ($Service) {
        'hub' {
            # A previous attempt got as far as `docker compose up` and left hub-ai unhealthy,
            # which means hub-db/hub-ai/hub-backend/hub-caddy were created (some started) and then
            # abandoned when that attempt failed - the next attempt after that hung completely
            # silently for the full 50-minute SSH timeout with zero output, even before git
            # checkout, consistent with leftover containers/state from the failed attempt
            # contending with (or wedging) this one. Force-remove any containers with these exact
            # names before doing anything else, so every attempt starts from a clean slate. try/catch
            # because a missing container's stderr write is promoted to a terminating error under
            # this script's $ErrorActionPreference='Stop' regardless of stream redirection.
            foreach ($staleContainer in @('hub-caddy', 'hub-backend', 'hub-ai', 'hub-db')) {
                try { docker rm -f $staleContainer 2>$null | Out-Null } catch {}
            }
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
    if ([string]::IsNullOrWhiteSpace($previousDockerHost)) { Remove-Item Env:DOCKER_HOST -ErrorAction SilentlyContinue } else { $env:DOCKER_HOST = $previousDockerHost }
    if ([string]::IsNullOrWhiteSpace($previousDockerContext)) { Remove-Item Env:DOCKER_CONTEXT -ErrorAction SilentlyContinue } else { $env:DOCKER_CONTEXT = $previousDockerContext }
    if ([string]::IsNullOrWhiteSpace($previousDockerApiVersion)) { Remove-Item Env:DOCKER_API_VERSION -ErrorAction SilentlyContinue } else { $env:DOCKER_API_VERSION = $previousDockerApiVersion }
    Remove-Item -Recurse -Force $dockerConfigRoot -ErrorAction SilentlyContinue
}
Say "[$Service] Server deployment complete"
Say "[$Service] source SHA: $sourceSha"
