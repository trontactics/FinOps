<#
.SYNOPSIS
    Azure Automation runbook that pauses or resumes the FinOps hub Fabric capacity. On resume, it reruns
    hub ingestion for every folder whose latest ingestion run failed (for example, while the capacity was paused).

.DESCRIPTION
    Runs as the Automation account's system-assigned managed identity, which needs:
      - Contributor on the Fabric capacity (suspend/resume)
      - Data Factory Contributor on the hub Data Factory (query and start pipeline runs)
    Register-FabricCapacitySchedule.ps1 imports this runbook, grants the roles, and creates the schedules.

    Resume:
      1. Resumes the capacity and waits until it is Active.
      2. Lists ingestion_ExecuteETL runs from the last RerunLookbackHours, groups them by folderPath, and reruns
         each folder whose most recent run failed. Re-ingestion is idempotent: the hub drops the extents it
         previously loaded for the same folder before ingesting.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Pause', 'Resume')]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $CapacityResourceId,

    [string] $DataFactoryResourceId,

    [int] $RerunLookbackHours = 96,

    [int] $ResumeTimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$capacityApi = 'api-version=2023-11-01'
$adfApi = 'api-version=2018-06-01'
$ingestionPipeline = 'ingestion_ExecuteETL'

Connect-AzAccount -Identity | Out-Null

function Invoke-Arm([string] $Method, [string] $Path, $Body)
{
    $params = @{ Method = $Method; Path = $Path }
    if ($null -ne $Body) { $params.Payload = ($Body | ConvertTo-Json -Depth 10) }
    $response = Invoke-AzRestMethod @params
    if ($response.StatusCode -ge 400) { throw "$Method $Path failed ($($response.StatusCode)): $($response.Content)" }
    if ($response.Content) { return $response.Content | ConvertFrom-Json }
}

function Get-CapacityState
{
    (Invoke-Arm GET "$($CapacityResourceId)?$capacityApi").properties.state
}

$state = Get-CapacityState
Write-Output "Capacity state before ${Action}: $state"

if ($Action -eq 'Pause')
{
    if ($state -eq 'Paused' -or $state -eq 'Pausing') { Write-Output 'Already paused.'; return }
    Invoke-Arm POST "$CapacityResourceId/suspend?$capacityApi" | Out-Null
    Write-Output 'Pause requested.'
    return
}

#region Resume
if ($state -ne 'Active')
{
    if ($state -ne 'Resuming') { Invoke-Arm POST "$CapacityResourceId/resume?$capacityApi" | Out-Null }
    $deadline = (Get-Date).AddMinutes($ResumeTimeoutMinutes)
    do
    {
        Start-Sleep -Seconds 20
        $state = Get-CapacityState
    } while ($state -ne 'Active' -and (Get-Date) -lt $deadline)
    if ($state -ne 'Active') { throw "Capacity is '$state' after $ResumeTimeoutMinutes minutes; not rerunning ingestion." }
}
Write-Output 'Capacity is Active.'
#endregion

#region Rerun failed ingestion
if (-not $DataFactoryResourceId) { Write-Output 'No DataFactoryResourceId; skipping ingestion rerun.'; return }

$now = (Get-Date).ToUniversalTime()
$query = @{
    lastUpdatedAfter  = $now.AddHours(-$RerunLookbackHours).ToString('o')
    lastUpdatedBefore = $now.ToString('o')
    filters           = @(@{ operand = 'PipelineName'; operator = 'Equals'; values = @($ingestionPipeline) })
}
$runs = @()
do
{
    $page = Invoke-Arm POST "$DataFactoryResourceId/queryPipelineRuns?$adfApi" $query
    $runs += $page.value
    $query.continuationToken = $page.continuationToken
} while ($page.continuationToken)

$toRerun = $runs |
    Where-Object { $_.parameters.folderPath } |
    Group-Object { $_.parameters.folderPath } |
    ForEach-Object { $_.Group | Sort-Object { [datetime] $_.runStart } -Descending | Select-Object -First 1 } |
    Where-Object { $_.status -eq 'Failed' }

Write-Output "Found $(@($runs).Count) $ingestionPipeline run(s) in the last $RerunLookbackHours hours; $(@($toRerun).Count) folder(s) to rerun."
foreach ($run in $toRerun)
{
    $folderPath = $run.parameters.folderPath
    $newRun = Invoke-Arm POST "$DataFactoryResourceId/pipelines/$ingestionPipeline/createRun?$adfApi" @{ folderPath = $folderPath }
    Write-Output "Rerunning $folderPath (failed run $($run.runId)) as run $($newRun.runId)."
}
#endregion
