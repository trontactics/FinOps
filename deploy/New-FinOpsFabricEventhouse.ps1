<#
.SYNOPSIS
    Creates (idempotently) the Fabric workspace, eventhouse, and Ingestion/Hub KQL databases for a FinOps hub,
    then runs the FinOps hub v14 Fabric setup scripts. Outputs the eventhouse Query URI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $CapacityName,
    [string] $WorkspaceName = 'FinOps Hub',
    [string] $EventhouseName = 'FinOpsHub',
    [string] $ToolkitVersion = 'v14',
    [int] $RawRetentionInDays = 0
)
$ErrorActionPreference = 'Stop'
$api = 'https://api.fabric.microsoft.com/v1'
function Get-Token($Resource) { (az account get-access-token --resource $Resource --query accessToken -o tsv) }
$fabricHeaders = @{ Authorization = "Bearer $(Get-Token 'https://api.fabric.microsoft.com')" }

function Invoke-Fabric($Method, $Path, $Body)
{
    $params = @{ Method = $Method; Uri = "$api$Path"; Headers = $fabricHeaders; ContentType = 'application/json' }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    $resp = Invoke-WebRequest @params -SkipHttpErrorCheck
    if ($resp.StatusCode -eq 202 -and $resp.Headers.Location)
    {
        $op = [string]$resp.Headers.Location[0]
        do { Start-Sleep -Seconds 5; $s = Invoke-RestMethod -Uri $op -Headers $fabricHeaders } while ($s.status -in 'NotStarted', 'Running')
        if ($s.status -ne 'Succeeded') { throw "$Method $Path failed: $($s | ConvertTo-Json -Depth 5)" }
        return $null
    }
    if ($resp.StatusCode -ge 300) { throw "$Method $Path failed ($($resp.StatusCode)): $($resp.Content)" }
    if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
}

$capacity = (Invoke-Fabric GET '/capacities').value | Where-Object displayName -eq $CapacityName
$ws = (Invoke-Fabric GET '/workspaces').value | Where-Object displayName -eq $WorkspaceName
if (-not $capacity -and -not ($ws -and $ws.capacityId)) {
    throw "Capacity $CapacityName isn't visible in Fabric for the signed-in user. Add yourself as a capacity admin (Azure portal > the capacity > Capacity administrators) and try again."
}
if (-not $ws) { $ws = Invoke-Fabric POST '/workspaces' @{ displayName = $WorkspaceName; capacityId = $capacity.id }; Write-Host "Created workspace $WorkspaceName" }
elseif ($capacity -and $ws.capacityId -ne $capacity.id) { Invoke-Fabric POST "/workspaces/$($ws.id)/assignToCapacity" @{ capacityId = $capacity.id } | Out-Null }

function Get-Eventhouse { (Invoke-Fabric GET "/workspaces/$($ws.id)/eventhouses").value | Where-Object displayName -eq $EventhouseName }
$eh = Get-Eventhouse
if (-not $eh) { Invoke-Fabric POST "/workspaces/$($ws.id)/eventhouses" @{ displayName = $EventhouseName } | Out-Null; $eh = Get-Eventhouse; Write-Host "Created eventhouse $EventhouseName" }
$eh = Invoke-Fabric GET "/workspaces/$($ws.id)/eventhouses/$($eh.id)"
$queryUri = $eh.properties.queryServiceUri

foreach ($db in 'Ingestion', 'Hub')
{
    $existing = (Invoke-Fabric GET "/workspaces/$($ws.id)/kqlDatabases").value | Where-Object displayName -eq $db
    if (-not $existing)
    {
        Invoke-Fabric POST "/workspaces/$($ws.id)/kqlDatabases" @{ displayName = $db; creationPayload = @{ databaseType = 'ReadWrite'; parentEventhouseItemId = $eh.id } } | Out-Null
        Write-Host "Created KQL database $db"
    }
}

# Run the official setup scripts (Ingestion first; Hub functions reference Ingestion tables)
$kustoToken = Get-Token 'https://kusto.kusto.windows.net'
foreach ($db in 'Ingestion', 'Hub')
{
    $script = (Invoke-WebRequest "https://github.com/microsoft/finops-toolkit/releases/download/$ToolkitVersion/finops-hub-fabric-setup-$db.kql").Content
    if ($script -is [byte[]]) { $script = [System.Text.Encoding]::UTF8.GetString($script) }
    $script = $script.Replace('$$rawRetentionInDays$$', "$RawRetentionInDays")
    $body = @{ db = $db; csl = ".execute database script with (ContinueOnErrors = false) <|`n$script" } | ConvertTo-Json
    $res = Invoke-RestMethod -Method Post -Uri "$queryUri/v1/rest/mgmt" -Headers @{ Authorization = "Bearer $kustoToken" } -ContentType 'application/json; charset=utf-8' -Body $body
    $rows = $res.Tables[0].Rows
    $resultIdx = [array]::IndexOf(@($res.Tables[0].Columns.ColumnName), 'Result')
    $failed = @($rows | Where-Object { $_[$resultIdx] -ne 'Completed' })
    Write-Host "$db setup: $($rows.Count) commands, $($failed.Count) not completed"
    if ($failed) { $failed | Select-Object -First 5 | ForEach-Object { Write-Host ($_ -join ' | ') -ForegroundColor Red }; throw "$db setup script failed" }
}

[pscustomobject]@{ WorkspaceId = $ws.id; EventhouseId = $eh.id; QueryUri = $queryUri }
