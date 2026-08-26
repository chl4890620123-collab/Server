$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host '[server] stopping managed production containers before clean restart'

$managedContainers = @(
    'maple-public-tunnel','maple-caddy','maple-app','maple-db',
    'restok-public-tunnel','restok-caddy','restok-frontend','restok-backend','restok-ai','restok-db',
    'aitm-public-tunnel','aitm-caddy','aitm-frontend','aitm-backend','aitm-ai','aitm-db'
)

foreach ($name in $managedContainers) {
    $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $name }
    if ($exists) {
        Write-Host "[server] removing container: $name"
        docker rm -f $name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to remove container: $name" }
    }
}

$managedNetworks = @('maple-internal','restok-internal','aitm-internal')
foreach ($name in $managedNetworks) {
    $networkExists = docker network ls --format '{{.Name}}' | Where-Object { $_ -eq $name }
    if ($networkExists) {
        Write-Host "[server] removing network: $name"
        docker network rm $name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not remove network $name; continuing because containers are already stopped."
        }
    } else {
        Write-Host "[server] network already absent: $name"
    }
}

Write-Host '[server] managed containers and networks are stopped; D-drive bind data was not deleted'
