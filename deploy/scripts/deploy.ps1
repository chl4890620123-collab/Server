param(
    [Parameter(Mandatory = $true)]
    [string]$ServerImage,

    [Parameter(Mandatory = $false)]
    [string]$RegistryUser = "",

    [Parameter(Mandatory = $false)]
    [string]$RegistryToken = "",

    [Parameter(Mandatory = $false)]
    [int]$HostPort = 9010
)

$ErrorActionPreference = "Stop"

$AppRoot = "C:\home\server\app"

Write-Host "[server] deploy start"
Write-Host "[server] app root: $AppRoot"
Write-Host "[server] host port: $HostPort"

Set-Location $AppRoot

if ($RegistryUser -and $RegistryToken) {
    $RegistryToken | docker login ghcr.io -u $RegistryUser --password-stdin
}

$env:SERVER_IMAGE = $ServerImage
$env:SERVER_HOST_PORT = "$HostPort"

docker pull $ServerImage

docker compose up -d --remove-orphans

Start-Sleep -Seconds 3

docker compose ps

$rootUrl = "http://127.0.0.1:$HostPort/"
$response = Invoke-WebRequest -Uri $rootUrl -Method Get -TimeoutSec 10 -UseBasicParsing

if ($response.StatusCode -ne 200) {
    throw "Root page check failed: $rootUrl (status $($response.StatusCode))"
}

Write-Host "[server] root page check OK: $rootUrl"
Write-Host "[server] deploy complete"
