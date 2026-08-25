param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedSha,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedServerSha
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DeployScript = Join-Path $ServerRoot 'deploy\scripts\deploy-aitm.ps1'
$SourceRoot = 'C:\home\server\source\aitm'
$SourceParent = Split-Path $SourceRoot -Parent
$DockerConfigRoot = Join-Path $env:TEMP ("aitm-docker-config-" + [guid]::NewGuid().ToString('N'))
$PreviousDockerConfig = $env:DOCKER_CONFIG
$PreviousBuildkitProgress = $env:BUILDKIT_PROGRESS
$ExitCode = 0

function Assert-LastExitCode([string]$Message) {
    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

try {
    if (-not (Test-Path $DeployScript)) {
        throw "Aitm deployment script is missing: $DeployScript"
    }

    $actualServerSha = (git -C $ServerRoot rev-parse HEAD | Out-String).Trim()
    Assert-LastExitCode 'Could not resolve current Server revision.'
    if ($actualServerSha -ne $ExpectedServerSha) {
        throw "Server SHA mismatch: expected=$ExpectedServerSha actual=$actualServerSha"
    }

    New-Item -ItemType Directory -Force -Path $SourceParent | Out-Null
    if (-not (Test-Path (Join-Path $SourceRoot '.git'))) {
        if (Test-Path $SourceRoot) {
            Remove-Item -Recurse -Force $SourceRoot
        }
        git clone 'https://github.com/chl4890620123-collab/Aitm.git' $SourceRoot
        Assert-LastExitCode 'Aitm clone failed.'
    }

    Set-Location $SourceRoot
    git reset --hard HEAD
    Assert-LastExitCode 'Aitm reset failed.'
    git clean -fd
    Assert-LastExitCode 'Aitm clean failed.'
    git fetch --prune origin main
    Assert-LastExitCode 'Aitm fetch failed.'
    git checkout -B main origin/main
    Assert-LastExitCode 'Aitm main checkout failed.'
    git reset --hard $ExpectedSha
    Assert-LastExitCode 'Aitm exact revision checkout failed.'
    git clean -fd
    Assert-LastExitCode 'Aitm final clean failed.'

    $actualSourceSha = (git rev-parse HEAD | Out-String).Trim()
    Assert-LastExitCode 'Could not resolve current Aitm revision.'
    if ($actualSourceSha -ne $ExpectedSha) {
        throw "Aitm SHA mismatch: expected=$ExpectedSha actual=$actualSourceSha"
    }

    # Docker Desktop credential helpers can depend on an interactive Windows
    # logon session. Production recovery only pulls public images, so use an
    # isolated empty Docker config rather than mutating the user's real config.
    New-Item -ItemType Directory -Force -Path $DockerConfigRoot | Out-Null
    '{"auths":{}}' | Set-Content -Path (Join-Path $DockerConfigRoot 'config.json') -Encoding ascii
    $env:DOCKER_CONFIG = $DockerConfigRoot
    $env:BUILDKIT_PROGRESS = 'plain'

    docker version *> $null
    Assert-LastExitCode 'Docker Engine is not available.'
    docker compose version *> $null
    Assert-LastExitCode 'Docker Compose is not available.'

    Write-Host '[aitm-recovery] building exact AI image'
    docker build --pull -t aitm-production-ai:latest (Join-Path $SourceRoot 'demo\ai')
    Assert-LastExitCode 'Aitm AI image build failed.'

    Write-Host '[aitm-recovery] building exact backend image'
    docker build --pull -t aitm-production-backend:latest (Join-Path $SourceRoot 'demo')
    Assert-LastExitCode 'Aitm backend image build failed.'

    Write-Host '[aitm-recovery] building exact frontend image'
    docker build --pull -t aitm-production-frontend:latest (Join-Path $SourceRoot 'front')
    Assert-LastExitCode 'Aitm frontend image build failed.'

    foreach ($image in @('mariadb:10.11', 'caddy:2.10-alpine')) {
        docker image inspect $image *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[aitm-recovery] pulling missing runtime image: $image"
            docker pull $image
            Assert-LastExitCode "Required runtime image pull failed: $image"
        }
    }

    Set-Location $ServerRoot
    & $DeployScript -ExpectedSha $ExpectedSha -Force
    if (-not $?) {
        throw 'Aitm deployment script failed.'
    }
} catch {
    Write-Error $_
    $ExitCode = 1
} finally {
    if ([string]::IsNullOrWhiteSpace($PreviousDockerConfig)) {
        Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue
    } else {
        $env:DOCKER_CONFIG = $PreviousDockerConfig
    }
    if ([string]::IsNullOrWhiteSpace($PreviousBuildkitProgress)) {
        Remove-Item Env:BUILDKIT_PROGRESS -ErrorAction SilentlyContinue
    } else {
        $env:BUILDKIT_PROGRESS = $PreviousBuildkitProgress
    }
    Remove-Item -Recurse -Force $DockerConfigRoot -ErrorAction SilentlyContinue
}

exit $ExitCode
