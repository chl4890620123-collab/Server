$ErrorActionPreference = "Stop"

$DbDataRoot = "D:\server-data\restok\mariadb"
New-Item -ItemType Directory -Force -Path $DbDataRoot | Out-Null

$hasBindData = $null -ne (Get-ChildItem $DbDataRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($hasBindData) {
    Write-Host "[restok] production database directory already contains data"
    exit 0
}

$legacyVolumes = @(
    docker volume ls --format "{{.Name}}" 2>$null |
        Where-Object {
            $_ -match '(?i)restok.*(mariadb|database|_db|db_)' -or
            $_ -match '(?i)(mariadb|database|_db|db_).*restok'
        }
)

if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect Docker volumes before Restok deployment."
}

if ($legacyVolumes.Count -gt 0) {
    $names = $legacyVolumes -join ', '
    throw "Legacy Restok database volume(s) detected while $DbDataRoot is empty: $names. Existing data was not modified. Migrate or explicitly archive the legacy volume before first Server-managed deployment."
}

$legacyContainers = @(
    docker ps -a --format "{{.Names}}" 2>$null |
        Where-Object { $_ -match '(?i)restok|restock' }
)
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect existing Docker containers before Restok deployment."
}

if ($legacyContainers.Count -gt 0) {
    Write-Host "[restok] existing Restok-like containers found: $($legacyContainers -join ', ')"
    Write-Host "[restok] no legacy database volume matched; deployment will continue without deleting those containers explicitly"
}

Write-Host "[restok] no legacy database volume conflict detected"
