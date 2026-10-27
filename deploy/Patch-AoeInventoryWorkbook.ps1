<#
.SYNOPSIS
    Makes the AOE "Resources Inventory" workbook tolerate resource types that don't exist in the monitored subscriptions.

.DESCRIPTION
    AOE only creates a Log Analytics table (for example AzureOptimizationVMsV1_CL) after it has collected at least
    one resource of that type. The upstream workbook queries several of those tables directly, so its tabs show
    "Failed to resolve table" in subscriptions without VMs, scale sets, disks, load balancers, application gateways,
    App Service plans, NSGs, or (without Entra Global Reader) RBAC data.

    This script edits views/workbooks/resources-inventory.json in place:
      - adds hidden Has<Type> parameters that return 1 when the table exists and 0 otherwise
        (union isfuzzy=true with a print fallback, so the check itself never fails)
      - shows each affected tab only when its table exists, and a "No <type> found" note otherwise
      - hides the RBAC charts on the Overview tab until RBAC data exists
      - makes the Overview resource tiles start from a table that always exists
    Upstream queries are otherwise unchanged. The script is idempotent; re-run it after upgrading AOE, then redeploy
    the workbook (see DEPLOYMENT-RUNBOOK.md).
#>
[CmdletBinding()]
param(
    [string] $WorkbookPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'optimization-engine/views/workbooks/resources-inventory.json')
)

$ErrorActionPreference = 'Stop'
$wb = Get-Content $WorkbookPath -Raw | ConvertFrom-Json -Depth 100

# Tab group name -> (parameter name, table, friendly label)
$checks = [ordered]@{
    vmGroup              = @('HasVMs', 'AzureOptimizationVMsV1_CL', 'virtual machines')
    diskGroup            = @('HasDisks', 'AzureOptimizationDisksV1_CL', 'managed disks')
    vmssGroup            = @('HasVMSS', 'AzureOptimizationVMSSV1_CL', 'virtual machine scale sets')
    vmssDisksGroup       = @('HasVMSS', 'AzureOptimizationVMSSV1_CL', 'virtual machine scale sets')
    nsgGroup             = @('HasNSGs', 'AzureOptimizationNSGsV1_CL', 'network security groups')
    lbGroup              = @('HasLBs', 'AzureOptimizationLoadBalancersV1_CL', 'load balancers')
    appGWGroup           = @('HasAppGWs', 'AzureOptimizationAppGatewaysV1_CL', 'application gateways')
    appServicePlansGroup = @('HasASPs', 'AzureOptimizationAppServicePlansV1_CL', 'App Service plans')
}
$rbac = @('HasRBAC', 'AzureOptimizationRBACAssignmentsV1_CL')

function New-ExistsParameter($Name, $Table)
{
    [pscustomobject]@{
        id                       = [guid]::NewGuid().ToString()
        version                  = 'KqlParameterItem/1.0'
        name                     = $Name
        type                     = 1
        query                    = "union isfuzzy=true ($Table | take 1 | project Has = 1), (print Has = 0) | summarize Has = max(Has)"
        isHiddenWhenLocked       = $true
        timeContext              = [pscustomobject]@{ durationMs = 0 }
        timeContextFromParameter = 'ResourcesTimeRange'
        queryType                = 0
        resourceType             = 'microsoft.operationalinsights/workspaces'
    }
}

function Get-Condition($Name, $Value) { [pscustomobject]@{ parameterName = $Name; comparison = 'isEqualTo'; value = $Value } }

# 1. Hidden parameters
$params = $wb.items[0].content.parameters
$wanted = [ordered]@{}
foreach ($v in $checks.Values) { $wanted[$v[0]] = $v[1] }
$wanted[$rbac[0]] = $rbac[1]
foreach ($name in $wanted.Keys)
{
    if (-not ($params | Where-Object name -eq $name)) { $params += New-ExistsParameter $name $wanted[$name] }
}
$wb.items[0].content.parameters = $params

# 2. Tab groups: visible only when the table exists, plus an empty-state note
$newItems = [System.Collections.Generic.List[object]]::new()
foreach ($item in $wb.items)
{
    if ($item.name -like '*-empty') { continue }   # drop notes from a previous run; re-added below
    $newItems.Add($item)
    if (-not $checks.Contains($item.name)) { continue }

    $param, $null, $label = $checks[$item.name]
    $tab = if ($item.conditionalVisibility) { $item.conditionalVisibility.value } else { ($item.conditionalVisibilities | Where-Object parameterName -eq 'SelectedTab').value }
    $item.PSObject.Properties.Remove('conditionalVisibility')
    $item | Add-Member -Force -NotePropertyName conditionalVisibilities -NotePropertyValue @((Get-Condition 'SelectedTab' $tab), (Get-Condition $param '1'))

    $newItems.Add([pscustomobject]@{
        type                    = 1
        content                 = [pscustomobject]@{ json = "No $label were found in the AOE data for the selected subscriptions. This tab populates automatically after AOE collects the first $label." }
        conditionalVisibilities = @((Get-Condition 'SelectedTab' $tab), (Get-Condition $param '0'))
        name                    = "$($item.name)-empty"
    })
}
$wb.items = $newItems.ToArray()

# 3. Overview: hide RBAC charts until RBAC data exists; make the tiles query start from an always-present table
$overview = $wb.items | Where-Object name -eq 'overviewGroup'
foreach ($chart in $overview.content.items | Where-Object { $_.content.query -match $rbac[1] })
{
    $chart.PSObject.Properties.Remove('conditionalVisibilities')
    $chart | Add-Member -Force -NotePropertyName conditionalVisibility -NotePropertyValue (Get-Condition $rbac[0] '1')
}
$tiles = $overview.content.items | Where-Object name -eq 'resourcesTiles'
$prefix = "AzureOptimizationResourceContainersV1_CL | take 0 | project ResourceType = '', TileValue = long(0)`n| union isfuzzy=true ( "
if ($tiles.content.query.StartsWith('AzureOptimizationVMsV1_CL'))
{
    $firstLineEnd = $tiles.content.query.IndexOf("`n")
    $tiles.content.query = $prefix + $tiles.content.query.Substring(0, $firstLineEnd).TrimEnd("`r") + ' )' + $tiles.content.query.Substring($firstLineEnd)
}

$wb | ConvertTo-Json -Depth 100 | Set-Content -Path $WorkbookPath -Encoding utf8
Write-Host "Patched $WorkbookPath" -ForegroundColor Green
