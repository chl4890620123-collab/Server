param(
    [Parameter(Mandatory = $true)][string]$MoveAiRoot,
    [Parameter(Mandatory = $true)][string]$Domain,
    [Parameter(Mandatory = $true)][int]$HostPort,
    [Parameter(Mandatory = $true)][string]$AppName,
    [switch]$AllowTakeover
)

# Generic version of saver's deploy/scripts/ensure_public_route.ps1 (which is hardcoded to Dahum).
# Adds/updates one marked site block in the existing shared MOVEAI Caddyfile so a Server-owned app
# gets real public HTTPS for free from that already-running Caddy instance.
#
# By default this never touches a domain some OTHER app's managed block already owns - it throws
# instead, so a domain never changes hands silently. Pass -AllowTakeover only for a deliberate,
# explicit reassignment (e.g. moving yellow.it.kr from one app to another); it removes that other
# app's entire managed block for this domain before adding this one's.

$ErrorActionPreference = 'Stop'

$Caddyfile = Join-Path $MoveAiRoot 'Caddyfile'
$MoveAiCompose = Join-Path $MoveAiRoot 'docker-compose.yml'

if (-not (Test-Path $Caddyfile)) { throw "MOVEAI Caddyfile not found: $Caddyfile" }
if (-not (Test-Path $MoveAiCompose)) { throw "MOVEAI docker-compose.yml not found: $MoveAiCompose" }

$tag = $AppName.ToUpperInvariant()
$beginMarker = "# BEGIN $tag ROUTE - managed by $AppName deploy"
$endMarker = "# END $tag ROUTE - managed by $AppName deploy"
$escapedBegin = [regex]::Escape($beginMarker)
$escapedEnd = [regex]::Escape($endMarker)
$escapedDomain = [regex]::Escape($Domain)

$managedBlock = @"
$beginMarker
$Domain {
    encode zstd gzip
    reverse_proxy host.docker.internal:$HostPort
}
$endMarker
"@

$content = [System.IO.File]::ReadAllText($Caddyfile)
$changed = $false

# Any app's managed block looks like "# BEGIN <TAG> ROUTE - managed by <name> deploy ... # END <TAG>
# ROUTE - managed by <name> deploy". Find one that is not ours but defines this exact domain.
$anyBlockPattern = '(?s)# BEGIN (?<tag>[A-Z0-9_]+) ROUTE - managed by (?<name>[^\r\n]+?) deploy\r?\n(?<body>.*?)# END \k<tag> ROUTE - managed by \k<name> deploy'
$conflicting = [regex]::Matches($content, $anyBlockPattern) |
    Where-Object { $_.Groups['tag'].Value -ne $tag -and $_.Value -match "(?m)^\s*$escapedDomain\s*\{" } |
    Select-Object -First 1

if ($conflicting) {
    if (-not $AllowTakeover) {
        throw "$Domain is already managed by $($conflicting.Groups['name'].Value)'s route block. Pass -AllowTakeover to explicitly remove it and reassign this domain to $AppName."
    }
    Write-Host "Removing $($conflicting.Groups['name'].Value)'s existing route for $Domain (explicit -AllowTakeover)."
    $content = $content.Remove($conflicting.Index, $conflicting.Length)
    $content = [regex]::Replace($content, '(?:\r?\n){3,}', "`r`n`r`n")
    $changed = $true
}

if ($content -match "(?s)$escapedBegin.*?$escapedEnd") {
    $updated = [regex]::Replace(
        $content,
        "(?s)$escapedBegin.*?$escapedEnd",
        [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $managedBlock }
    )
    if ($updated -ne $content) { $changed = $true }
    $content = $updated
}
elseif ($content -match "(?m)^\s*$escapedDomain\s*\{") {
    Write-Host "$Domain is already defined outside any managed block. Existing route will not be overwritten."
}
else {
    $separator = if ($content.EndsWith("`n")) { "`n" } else { "`r`n`r`n" }
    $content = $content + $separator + $managedBlock + "`r`n"
    $changed = $true
}

$backupFile = $null
if ($changed) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFile = "$Caddyfile.$AppName-backup-$timestamp"
    Copy-Item -LiteralPath $Caddyfile -Destination $backupFile -Force
    [System.IO.File]::WriteAllText($Caddyfile, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated MOVEAI Caddyfile. Backup: $backupFile"
}

try {
    Set-Location -LiteralPath $MoveAiRoot

    docker compose -f $MoveAiCompose config *> $null
    if ($LASTEXITCODE -ne 0) { throw 'MOVEAI docker compose config failed.' }

    docker compose -f $MoveAiCompose exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Caddy validation failed.' }

    docker compose -f $MoveAiCompose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Caddy reload failed.' }

    Write-Host "Public route ready: https://$Domain -> host.docker.internal:$HostPort"
}
catch {
    if ($changed -and $backupFile -and (Test-Path $backupFile)) {
        Write-Warning 'Caddy update failed. Restoring previous MOVEAI Caddyfile.'
        Copy-Item -LiteralPath $backupFile -Destination $Caddyfile -Force
        try {
            Set-Location -LiteralPath $MoveAiRoot
            docker compose -f $MoveAiCompose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile *> $null
        }
        catch {
            Write-Warning 'Previous Caddyfile was restored, but automatic reload also failed. Check MOVEAI Caddy manually.'
        }
    }
    throw
}
