<#
.SYNOPSIS
    Creates (or updates) the FinOps hub Real-Time Dashboard in a Fabric workspace, connected to the Hub database.

.DESCRIPTION
    Uses dashboard/finops-hub-dashboard.json: the FinOps toolkit v14 hub dashboard template (12 pages) with the
    data source set to a placeholder and the commitment discount chargeback tiles made safe when there's no
    commitment discount usage. The script fills in the eventhouse Query URI and creates a KQLDashboard item
    through the Fabric REST API. If a dashboard with the same name exists, its definition is replaced.

    Requires Contributor (or higher) on the workspace. Users of the dashboard need Viewer on the workspace.

.EXAMPLE
    ./New-FinOpsHubDashboard.ps1 -ClusterUri https://abc123xyz.z4.kusto.fabric.microsoft.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ClusterUri,
    [string] $WorkspaceName = 'FinOps Hub',
    [string] $DashboardName = 'FinOps hub',
    [string] $TemplatePath = (Join-Path $PSScriptRoot '../dashboard/finops-hub-dashboard.json')
)

$ErrorActionPreference = 'Stop'
$api = 'https://api.fabric.microsoft.com/v1'
$token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
if (-not $token) { throw 'Run az login first.' }
$headers = @{ Authorization = "Bearer $token" }

function Wait-FabricOperation($Response) {
    if ($Response.StatusCode -ne 202) { return }
    $location = @($Response.Headers['Location'])[0]
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        $status = Invoke-RestMethod -Headers $headers -Uri $location
        if ($status.status -eq 'Succeeded') { return }
        if ($status.status -eq 'Failed') { throw "Fabric operation failed: $($status.error.message)" }
    }
    throw 'Timed out waiting for the Fabric operation.'
}

$workspace = (Invoke-RestMethod -Headers $headers -Uri "$api/workspaces").value | Where-Object displayName -eq $WorkspaceName
if (-not $workspace) { throw "Workspace '$WorkspaceName' not found, or you don't have access to it." }

$dashboard = Get-Content $TemplatePath -Raw | ConvertFrom-Json
$dashboard.dataSources[0].clusterUri = $ClusterUri.TrimEnd('/') + '/'
$dashboard.dataSources[0].database = 'Hub'
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($dashboard | ConvertTo-Json -Depth 50)))
$definition = @{ parts = @(@{ path = 'RealTimeDashboard.json'; payload = $payload; payloadType = 'InlineBase64' }) }

$existing = (Invoke-RestMethod -Headers $headers -Uri "$api/workspaces/$($workspace.id)/items?type=KQLDashboard").value |
    Where-Object displayName -eq $DashboardName

if ($existing) {
    $body = @{ definition = $definition } | ConvertTo-Json -Depth 6
    $response = Invoke-WebRequest -Method Post -Headers $headers -ContentType 'application/json' -Body $body `
        -Uri "$api/workspaces/$($workspace.id)/kqlDashboards/$($existing.id)/updateDefinition"
    Wait-FabricOperation $response
    $id = $existing.id
    Write-Host "Updated dashboard '$DashboardName'."
} else {
    $body = @{ displayName = $DashboardName; definition = $definition } | ConvertTo-Json -Depth 6
    $response = Invoke-WebRequest -Method Post -Headers $headers -ContentType 'application/json' -Body $body `
        -Uri "$api/workspaces/$($workspace.id)/kqlDashboards"
    Wait-FabricOperation $response
    $id = ((Invoke-RestMethod -Headers $headers -Uri "$api/workspaces/$($workspace.id)/items?type=KQLDashboard").value |
        Where-Object displayName -eq $DashboardName).id
    Write-Host "Created dashboard '$DashboardName'."
}

Write-Host "Open: https://app.fabric.microsoft.com/groups/$($workspace.id)/kustodashboards/$id"
