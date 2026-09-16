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

function Fail {
    # Invoked via `&` from deploy-hub.ps1 in the same PowerShell process/session over a non-pty
    # SSH exec - a plain `throw` here was found (elsewhere in this same deploy pipeline) to leave
    # the whole remote process hung for tens of minutes instead of exiting, because PowerShell's
    # exception/Write-Host output travels through a separate serialized (CLIXML) channel that can
    # back up and block the process from ever actually exiting. Write straight to the console
    # stream and force-exit instead.
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Out.WriteLine($Message)
    [Environment]::Exit(1)
}

function Say {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Out.WriteLine($Message)
}

function Invoke-Docker {
    # Same fix as deploy-hub.ps1's Invoke-Docker. Every bare `docker ...` call below relied on
    # $LASTEXITCODE and on stderr staying out of PowerShell's own streams, but under
    # $ErrorActionPreference = 'Stop' a native command's stderr write is promoted to a terminating
    # PowerShell error regardless of redirection (`*> $null` included) - confirmed elsewhere in this
    # deploy pipeline. Only the `compose up` call had a try/catch to survive that; `config`,
    # `exec validate` and both `exec reload` call sites did not. Run docker directly via
    # Process.Start instead and drain stdout/stderr with ReadToEndAsync, started before
    # WaitForExit so neither OS pipe can fill and block the child - stderr then never reaches
    # PowerShell's error stream, so no call site needs its own try/catch.
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
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
        throw "Command timed out after ${TimeoutSeconds}s: docker $($Arguments -join ' ')"
    }
    $proc.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = [string]$stdoutTask.Result; StdErr = [string]$stderrTask.Result }
}

function Assert-Docker {
    # Discards output on success; on failure, prints stdout/stderr (the only way to see what went
    # wrong now that it never reaches PowerShell's own streams) and throws, so the existing outer
    # try/catch below still restores the Caddyfile backup exactly as before.
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )
    $result = Invoke-Docker -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) { Say $result.StdOut.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { Say $result.StdErr.Trim() }
        throw "Command failed ($($result.ExitCode)): docker $($Arguments -join ' ')"
    }
    return $result
}

$Caddyfile = Join-Path $MoveAiRoot 'Caddyfile'
$MoveAiCompose = Join-Path $MoveAiRoot 'docker-compose.yml'

# The shared MOVEAI Caddy stack was always assumed to pre-exist (set up by hand once) - no deploy
# script ever wrote code to create it. On a fresh/reset machine that assumption is false, so this
# bootstraps a minimal shared stack in place the first time it's missing, instead of failing.
$justBootstrapped = $false
if (-not (Test-Path $MoveAiRoot)) {
    New-Item -ItemType Directory -Force -Path $MoveAiRoot | Out-Null
}
if (-not (Test-Path $Caddyfile)) {
    Say "MOVEAI Caddyfile not found at $Caddyfile - bootstrapping a new shared Caddy stack there."
    "# Shared public reverse proxy. Managed site blocks below are added/removed by each app's deploy.`r`n" |
        Set-Content -LiteralPath $Caddyfile -Encoding ascii
    $justBootstrapped = $true
}
if (-not (Test-Path $MoveAiCompose)) {
    @'
services:
  caddy:
    image: caddy:2.10-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
'@ | Set-Content -LiteralPath $MoveAiCompose -Encoding ascii
    $justBootstrapped = $true
}

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
        Fail "$Domain is already managed by $($conflicting.Groups['name'].Value)'s route block. Pass -AllowTakeover to explicitly remove it and reassign this domain to $AppName."
    }
    Say "Removing $($conflicting.Groups['name'].Value)'s existing route for $Domain (explicit -AllowTakeover)."
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
    Say "$Domain is already defined outside any managed block. Existing route will not be overwritten."
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
    Say "Updated MOVEAI Caddyfile. Backup: $backupFile"
}

try {
    Set-Location -LiteralPath $MoveAiRoot

    Assert-Docker -Arguments @('compose', '-f', $MoveAiCompose, 'config') | Out-Null

    # Idempotent: starts the shared caddy container if it isn't running yet (bootstrap case, or it
    # was stopped), no-ops if it's already up and unchanged. A fresh bootstrap may need to pull the
    # caddy:2.10-alpine image first, so this gets more room than the default timeout.
    Assert-Docker -Arguments @('compose', '-f', $MoveAiCompose, 'up', '-d') -TimeoutSeconds 300 | Out-Null

    Assert-Docker -Arguments @('compose', '-f', $MoveAiCompose, 'exec', '-T', 'caddy', 'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile') | Out-Null

    $reload = Invoke-Docker -Arguments @('compose', '-f', $MoveAiCompose, 'exec', '-T', 'caddy', 'caddy', 'reload', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile')
    if ($reload.ExitCode -ne 0) {
        # A container just created by the `up -d` above already loaded this exact Caddyfile at
        # startup, so a failed reload here doesn't mean the route is broken - only warn.
        if ($justBootstrapped) {
            Say 'Caddy reload reported a non-zero exit right after bootstrap; the new container already started with this config, so continuing.'
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($reload.StdOut)) { Say $reload.StdOut.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($reload.StdErr)) { Say $reload.StdErr.Trim() }
            throw 'Caddy reload failed.'
        }
    }

    Say "Public route ready: https://$Domain -> host.docker.internal:$HostPort"
}
catch {
    $reason = $_.Exception.Message
    if ($changed -and $backupFile -and (Test-Path $backupFile)) {
        Say 'Caddy update failed. Restoring previous MOVEAI Caddyfile.'
        Copy-Item -LiteralPath $backupFile -Destination $Caddyfile -Force
        try {
            Set-Location -LiteralPath $MoveAiRoot
            Invoke-Docker -Arguments @('compose', '-f', $MoveAiCompose, 'exec', '-T', 'caddy', 'caddy', 'reload', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile') | Out-Null
        }
        catch {
            Say 'Previous Caddyfile was restored, but automatic reload also failed. Check MOVEAI Caddy manually.'
        }
    }
    Fail "Public route registration failed: $reason"
}
