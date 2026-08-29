param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('maple', 'aitm', 'restok')]
    [string]$Service,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SourcesRoot = 'C:\home\server\sources'
New-Item -ItemType Directory -Force -Path $SourcesRoot | Out-Null

function Test-DockerEngine {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $output = docker version 2>&1 | Out-String
        return [pscustomobject]@{ Ready = ($LASTEXITCODE -eq 0); Output = $output.Trim() }
    } finally { $ErrorActionPreference = $previousPreference }
}

function Wait-DockerEngine {
    param([string]$Name)
    $serviceRestartAttempted = $false
    $desktopStartAttempted = $false
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $probe = Test-DockerEngine
        if ($probe.Ready) { Write-Host "[$Name] Docker Linux Engine ready on attempt $attempt"; return }
        if ($attempt -eq 3 -and -not $serviceRestartAttempted) {
            $serviceRestartAttempted = $true
            try {
                $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction Stop
                if ($dockerService.Status -eq 'Running') { Restart-Service -Name 'com.docker.service' -Force -ErrorAction Stop } else { Start-Service -Name 'com.docker.service' -ErrorAction Stop }
            } catch { Write-Warning "[$Name] Docker service restart was not available: $($_.Exception.Message)" }
        }
        if ($attempt -eq 7 -and -not $desktopStartAttempted) {
            $desktopStartAttempted = $true
            $desktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
            if (Test-Path $desktopExe) { try { Start-Process -FilePath $desktopExe -WindowStyle Hidden -ErrorAction Stop | Out-Null } catch { Write-Warning "[$Name] Docker Desktop startup request failed: $($_.Exception.Message)" } }
        }
        if ($attempt -eq 18) { throw "Docker Linux Engine did not become ready. Last response: $($probe.Output)" }
        Start-Sleep -Seconds 5
    }
}

$services = @{
    maple = @{ Repository = 'https://github.com/chl4890620123-collab/maple.git'; SourceDir = Join-Path $SourcesRoot 'maple' }
    aitm = @{ Repository = 'https://github.com/chl4890620123-collab/Aitm.git'; SourceDir = Join-Path $SourcesRoot 'aitm' }
    restok = @{ Repository = 'https://github.com/chl4890620123-collab/Restok-Rangchain.git'; SourceDir = Join-Path $SourcesRoot 'restok' }
}

$spec = $services[$Service]
$sourceDir = [string]$spec.SourceDir
$repository = [string]$spec.Repository
Write-Host "[$Service] isolated source: $sourceDir"
if (-not (Test-Path (Join-Path $sourceDir '.git'))) {
    if (Test-Path $sourceDir) { Remove-Item -Recurse -Force $sourceDir }
    git clone $repository $sourceDir
    if ($LASTEXITCODE -ne 0) { throw "[$Service] clone failed" }
}

git -C $sourceDir remote set-url origin $repository
if ($LASTEXITCODE -ne 0) { throw "[$Service] remote reset failed" }
git -C $sourceDir reset --hard HEAD
if ($LASTEXITCODE -ne 0) { throw "[$Service] reset failed" }
git -C $sourceDir clean -fd
if ($LASTEXITCODE -ne 0) { throw "[$Service] clean failed" }
git -C $sourceDir fetch --force --prune origin '+refs/heads/main:refs/remotes/origin/main'
if ($LASTEXITCODE -ne 0) { throw "[$Service] fetch failed" }
$remoteSha = (git -C $sourceDir rev-parse refs/remotes/origin/main | Out-String).Trim()
if ($remoteSha -notmatch '^[0-9a-f]{40}$') { throw "[$Service] invalid remote main SHA" }
git -C $sourceDir checkout -B main $remoteSha
if ($LASTEXITCODE -ne 0) { throw "[$Service] checkout failed" }
git -C $sourceDir reset --hard $remoteSha
if ($LASTEXITCODE -ne 0) { throw "[$Service] main reset failed" }
git -C $sourceDir clean -fd
if ($LASTEXITCODE -ne 0) { throw "[$Service] final clean failed" }
$sourceSha = (git -C $sourceDir rev-parse HEAD | Out-String).Trim()
if ($sourceSha -ne $remoteSha) { throw "[$Service] checkout mismatch: local=$sourceSha remote=$remoteSha" }
Write-Host "[$Service] source SHA: $sourceSha"
Write-Host "[$Service] verified remote main SHA: $remoteSha"

$previousDockerConfig = $env:DOCKER_CONFIG
$previousDockerApiVersion = $env:DOCKER_API_VERSION
$dockerConfigRoot = Join-Path $env:TEMP ("server-docker-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dockerConfigRoot | Out-Null
'{"auths":{}}' | Set-Content -Path (Join-Path $dockerConfigRoot 'config.json') -Encoding ascii
$env:DOCKER_CONFIG = $dockerConfigRoot
$env:DOCKER_API_VERSION = '1.44'
Write-Host "[$Service] using isolated Docker CLI config and compatible API version"
try {
    Wait-DockerEngine -Name $Service
    switch ($Service) {
        'maple' {
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t maple-production-app:latest $sourceDir
            if ($LASTEXITCODE -ne 0) { throw '[maple] Docker build failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-maple.ps1') -ExpectedSha $sourceSha
            if (-not $?) { throw '[maple] deployment failed' }
        }
        'aitm' {
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t aitm-production-ai:latest (Join-Path $sourceDir 'demo\ai')
            if ($LASTEXITCODE -ne 0) { throw '[aitm] AI build failed' }
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t aitm-production-backend:latest (Join-Path $sourceDir 'demo')
            if ($LASTEXITCODE -ne 0) { throw '[aitm] backend build failed' }
            docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t aitm-production-frontend:latest (Join-Path $sourceDir 'front')
            if ($LASTEXITCODE -ne 0) { throw '[aitm] frontend build failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-aitm.ps1') -ExpectedSha $sourceSha -Force:$Force
            if (-not $?) { throw '[aitm] deployment failed' }
        }
        'restok' {
            docker build --pull -t restok-production-ai:latest (Join-Path $sourceDir 'ai_server')
            if ($LASTEXITCODE -ne 0) { throw '[restok] AI build failed' }
            docker build --pull -t restok-production-backend:latest (Join-Path $sourceDir 'backend')
            if ($LASTEXITCODE -ne 0) { throw '[restok] backend build failed' }
            docker build --pull --build-arg REACT_APP_API_URL= -t restok-production-frontend:latest (Join-Path $sourceDir 'frontend')
            if ($LASTEXITCODE -ne 0) { throw '[restok] frontend build failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\check-restok-legacy-data.ps1')
            if (-not $?) { throw '[restok] legacy-data preflight failed' }
            & (Join-Path $ServerRoot 'deploy\scripts\deploy-restok.ps1') -Force:$Force -Prebuilt
            if (-not $?) { throw '[restok] deployment failed' }
        }
    }
} finally {
    if ([string]::IsNullOrWhiteSpace($previousDockerConfig)) { Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue } else { $env:DOCKER_CONFIG = $previousDockerConfig }
    if ([string]::IsNullOrWhiteSpace($previousDockerApiVersion)) { Remove-Item Env:DOCKER_API_VERSION -ErrorAction SilentlyContinue } else { $env:DOCKER_API_VERSION = $previousDockerApiVersion }
    Remove-Item -Recurse -Force $dockerConfigRoot -ErrorAction SilentlyContinue
}
Write-Host "[$Service] Server deployment complete"
Write-Host "[$Service] source SHA: $sourceSha"
