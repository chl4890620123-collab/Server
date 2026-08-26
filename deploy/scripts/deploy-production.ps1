param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DeployScript = Join-Path $ServerRoot 'deploy\scripts\deploy-service.ps1'
$ResetScript = Join-Path $ServerRoot 'deploy\scripts\reset-production.ps1'
$ResultRoot = 'D:\server-data\deployment-results'
New-Item -ItemType Directory -Force -Path $ResultRoot | Out-Null

Write-Host '[server] production deployment order: maple(1), restok(2), aitm(3)'
Write-Host '[server] long-running concurrency limit: 2'
Write-Host '[server] resetting managed containers; D-drive data is preserved'
& $ResetScript
if (-not $?) { throw 'Production reset failed.' }

$forceSwitch = if ($Force) { '-Force' } else { '' }
$jobs = @()
foreach ($service in @('maple', 'restok')) {
    $resultFile = Join-Path $ResultRoot "$service.txt"
    Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
    $jobs += Start-Job -Name "deploy-$service" -ArgumentList $DeployScript, $service, $forceSwitch, $resultFile -ScriptBlock {
        param($scriptPath, $serviceName, $forceArg, $resultPath)
        $ErrorActionPreference = 'Stop'
        try {
            if ($forceArg) { & $scriptPath -Service $serviceName -Force *>&1 | Tee-Object -FilePath $resultPath }
            else { & $scriptPath -Service $serviceName *>&1 | Tee-Object -FilePath $resultPath }
            if (-not $?) { throw "$serviceName deployment failed" }
        } catch {
            "[$serviceName] ERROR: $($_.Exception.Message)" | Add-Content -Path $resultPath
            throw
        }
    }
}

Wait-Job -Job $jobs | Out-Null
$waveFailed = $false
foreach ($job in $jobs) {
    Receive-Job -Job $job
    if ($job.State -ne 'Completed') { $waveFailed = $true }
    Remove-Job -Job $job -Force
}
if ($waveFailed) { throw 'Maple/Restok priority wave failed; Aitm was not started.' }

Write-Host '[server] priority wave complete; starting Aitm as priority 3'
$aitmResult = Join-Path $ResultRoot 'aitm.txt'
Remove-Item $aitmResult -Force -ErrorAction SilentlyContinue
try {
    if ($Force) { & $DeployScript -Service aitm -Force *>&1 | Tee-Object -FilePath $aitmResult }
    else { & $DeployScript -Service aitm *>&1 | Tee-Object -FilePath $aitmResult }
    if (-not $?) { throw 'Aitm deployment failed.' }
} catch {
    "[aitm] ERROR: $($_.Exception.Message)" | Add-Content -Path $aitmResult
    throw
}

Write-Host '[server] all prioritized production deployments completed'
