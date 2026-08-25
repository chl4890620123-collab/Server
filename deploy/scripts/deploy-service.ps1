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

$services = @{
    maple = @{
        Repository = 'https://github.com/chl4890620123-collab/maple.git'
        SourceDir = Join-Path $SourcesRoot 'maple'
    }
    aitm = @{
        Repository = 'https://github.com/chl4890620123-collab/Aitm.git'
        SourceDir = Join-Path $SourcesRoot 'aitm'
    }
    restok = @{
        Repository = 'https://github.com/chl4890620123-collab/Restok-Rangchain.git'
        SourceDir = Join-Path $SourcesRoot 'restok'
    }
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

git -C $sourceDir reset --hard HEAD
if ($LASTEXITCODE -ne 0) { throw "[$Service] reset failed" }
git -C $sourceDir clean -fd
if ($LASTEXITCODE -ne 0) { throw "[$Service] clean failed" }
git -C $sourceDir fetch --prune origin main
if ($LASTEXITCODE -ne 0) { throw "[$Service] fetch failed" }
git -C $sourceDir checkout -B main origin/main
if ($LASTEXITCODE -ne 0) { throw "[$Service] checkout failed" }
git -C $sourceDir reset --hard origin/main
if ($LASTEXITCODE -ne 0) { throw "[$Service] main reset failed" }
git -C $sourceDir clean -fd
if ($LASTEXITCODE -ne 0) { throw "[$Service] final clean failed" }
$sourceSha = (git -C $sourceDir rev-parse HEAD | Out-String).Trim()
if ($sourceSha -notmatch '^[0-9a-f]{40}$') { throw "[$Service] invalid source SHA" }
Write-Host "[$Service] source SHA: $sourceSha"

docker version *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Engine is not available.' }

switch ($Service) {
    'maple' {
        Write-Host '[maple] building isolated application image'
        docker build --pull --label "org.opencontainers.image.revision=$sourceSha" -t maple-production-app:latest $sourceDir
        if ($LASTEXITCODE -ne 0) { throw '[maple] Docker build failed' }
        & (Join-Path $ServerRoot 'deploy\scripts\run-maple-deploy.ps1') -Force:$Force
        if (-not $?) { throw '[maple] deployment failed' }
    }
    'aitm' {
        Write-Host '[aitm] building isolated service images'
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
        Write-Host '[restok] building isolated service images'
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

Write-Host "[$Service] Server deployment complete"
Write-Host "[$Service] source SHA: $sourceSha"
