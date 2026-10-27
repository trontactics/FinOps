<#
.SYNOPSIS
    Pauses the FinOps hub Fabric capacity outside working hours and resumes it on weekday mornings, rerunning
    any hub ingestion that failed while it was paused.

.DESCRIPTION
    Uses the AOE Automation account so no new resources are created:
      1. Grants its managed identity Contributor on the capacity and Data Factory Contributor on the hub
         Data Factory (both scoped to the single resource).
      2. Imports and publishes runbooks/Set-FabricCapacityState.ps1.
      3. Creates two weekly schedules (Monday-Friday) in the given time zone and links them to the runbook:
         <capacity>-resume at ResumeTime and <capacity>-pause at PauseTime. The capacity stays paused over
         the weekend. Daylight saving time is handled by the schedule's time zone.
    Re-running the script replaces the runbook and schedules.

.EXAMPLE
    ./Register-FabricCapacitySchedule.ps1 -NamePrefix finopsaoe01 -CapacityName finopshubcap01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $NamePrefix,
    [Parameter(Mandatory = $true)]
    [string] $CapacityName,
    [string] $AutomationResourceGroupName = "$NamePrefix-rg",
    [string] $AutomationAccountName = "$NamePrefix-auto",
    [string] $HubResourceGroupName = 'rg-finops-hub',
    [string] $ResumeTime = '08:00',
    [string] $PauseTime = '17:00',
    [string] $TimeZone = 'America/Chicago',
    [System.DayOfWeek[]] $DaysOfWeek = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
)

$ErrorActionPreference = 'Stop'
if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first.' }

$runbookName = 'Set-FabricCapacityState'
$runbookPath = Join-Path $PSScriptRoot "runbooks/$runbookName.ps1"

$automation = Get-AzAutomationAccount -ResourceGroupName $AutomationResourceGroupName -Name $AutomationAccountName
$principalId = $automation.Identity.PrincipalId
$capacityId = (Get-AzResource -ResourceGroupName $HubResourceGroupName -ResourceType Microsoft.Fabric/capacities -Name $CapacityName).ResourceId
$dataFactory = Get-AzDataFactoryV2 -ResourceGroupName $HubResourceGroupName | Select-Object -First 1
if (-not $dataFactory) { throw "No Data Factory found in $HubResourceGroupName." }
$automationArgs = @{ ResourceGroupName = $AutomationResourceGroupName; AutomationAccountName = $AutomationAccountName }

#region Role assignments
foreach ($assignment in @(
        @{ Role = 'Contributor'; Scope = $capacityId },
        @{ Role = 'Data Factory Contributor'; Scope = $dataFactory.DataFactoryId }))
{
    if (Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $assignment.Role -Scope $assignment.Scope)
    {
        Write-Host "$($assignment.Role) already assigned on $($assignment.Scope)."
        continue
    }
    New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $assignment.Role -Scope $assignment.Scope | Out-Null
    Write-Host "Assigned $($assignment.Role) on $($assignment.Scope)."
}
#endregion

#region Runbook
Import-AzAutomationRunbook @automationArgs -Name $runbookName -Path $runbookPath -Type PowerShell -Force `
    -Description 'Pauses or resumes the FinOps hub Fabric capacity; reruns failed hub ingestion on resume.' | Out-Null
Publish-AzAutomationRunbook @automationArgs -Name $runbookName | Out-Null
Write-Host "Published runbook $runbookName."
#endregion

#region Schedules
try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) }
catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Central Standard Time') }

function Get-NextStart([string] $Time)
{
    # First occurrence at least 10 minutes from now, expressed in the target time zone.
    $nowInTz = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tz)
    $local = [datetime]::SpecifyKind($nowInTz.Date + [timespan]::Parse($Time), 'Unspecified')
    if ($local -le $nowInTz.DateTime.AddMinutes(10)) { $local = $local.AddDays(1) }
    [DateTimeOffset]::new($local, $tz.GetUtcOffset($local))
}

foreach ($schedule in @(
        @{ Name = "$CapacityName-resume"; Time = $ResumeTime; Action = 'Resume' },
        @{ Name = "$CapacityName-pause"; Time = $PauseTime; Action = 'Pause' }))
{
    if (Get-AzAutomationSchedule @automationArgs -Name $schedule.Name -ErrorAction SilentlyContinue)
    {
        Remove-AzAutomationSchedule @automationArgs -Name $schedule.Name -Force
    }
    $start = Get-NextStart $schedule.Time
    New-AzAutomationSchedule @automationArgs -Name $schedule.Name -StartTime $start -WeekInterval 1 `
        -DaysOfWeek $DaysOfWeek -TimeZone $TimeZone `
        -Description "$($schedule.Action) Fabric capacity $CapacityName at $($schedule.Time) $TimeZone" | Out-Null

    $parameters = @{ Action = $schedule.Action; CapacityResourceId = $capacityId }
    if ($schedule.Action -eq 'Resume') { $parameters.DataFactoryResourceId = $dataFactory.DataFactoryId }
    Register-AzAutomationScheduledRunbook @automationArgs -RunbookName $runbookName -ScheduleName $schedule.Name `
        -Parameters $parameters | Out-Null
    Write-Host "Schedule $($schedule.Name): $($schedule.Action) at $($schedule.Time) $TimeZone ($($DaysOfWeek -join ', ')), first run $start."
}
#endregion
