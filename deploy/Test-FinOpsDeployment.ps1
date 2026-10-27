<#
.SYNOPSIS
    Read-only post-deployment smoke test for the FinOps hub (Fabric/ADX), the Copilot Studio agent
    queries, and the Azure Optimization Engine (AOE) workbooks.

.DESCRIPTION
    Nothing is created or changed. The script:
      1. Runs every executable KQL block in copilot-studio-agent (agent instructions + knowledge files)
         against the Hub database, so the agent's templates are proven to run on your data.
      2. Checks that every Log Analytics table referenced by each AOE workbook exists in the AOE
         workspace (a missing table is what makes a workbook show "Failed to resolve table").
      3. Checks that each AOE workbook resource is deployed.
    Exits with code 1 if any check fails.

.EXAMPLE
    ./Test-FinOpsDeployment.ps1 -ClusterUri https://abc123.z4.kusto.fabric.microsoft.com `
        -AoeResourceGroupName finopsaoe01-rg -AoeWorkspaceName finopsaoe01-la
#>
[CmdletBinding()]
param(
    # Fabric eventhouse Query URI or Data Explorer cluster URI. Omit to skip hub checks.
    [string] $ClusterUri,
    [string] $HubDatabase = 'Hub',
    # Token audience for Kusto. Falls back to the cluster URI if this audience is rejected.
    [string] $KustoAudience = 'https://kusto.kusto.windows.net',
    # AOE resource group and Log Analytics workspace. Omit to skip AOE checks.
    [string] $AoeResourceGroupName,
    [string] $AoeWorkspaceName,
    [string] $AoeWorkspaceResourceGroupName
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($Area, $Check, [bool] $Passed, $Detail = '')
{
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Result = $(if ($Passed) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first.' }

#region Hub / Copilot agent queries
if ($ClusterUri)
{
    if ($ClusterUri -notmatch '^https://') { $ClusterUri = "https://$ClusterUri" }
    $ClusterUri = $ClusterUri.TrimEnd('/')

    function Get-KustoToken($Audience)
    {
        (Get-AzAccessToken -ResourceUrl $Audience -AsSecureString).Token | ConvertFrom-SecureString -AsPlainText
    }
    $token = Get-KustoToken $KustoAudience

    function Invoke-Kql([string] $Query)
    {
        $body = @{ db = $HubDatabase; csl = $Query; properties = @{ Options = @{ servertimeout = '00:03:00' } } } | ConvertTo-Json -Depth 5
        $params = @{ Method = 'Post'; Uri = "$ClusterUri/v1/rest/query"; ContentType = 'application/json; charset=utf-8'; Body = $body }
        try
        {
            Invoke-RestMethod @params -Headers @{ Authorization = "Bearer $script:token" }
        }
        catch
        {
            if ($_.Exception.Response.StatusCode.value__ -ne 401) { throw }
            $script:token = Get-KustoToken $ClusterUri
            Invoke-RestMethod @params -Headers @{ Authorization = "Bearer $script:token" }
        }
    }

    try
    {
        $count = (Invoke-Kql 'Costs_v1_2() | count').Tables[0].Rows[0][0]
        Add-Result 'Hub' 'Costs_v1_2() has data' ($count -gt 0) "$count rows"
    }
    catch
    {
        Add-Result 'Hub' 'Costs_v1_2() has data' $false $_.Exception.Message
    }

    # Extract ```kusto blocks; run only complete queries (not "| ..." fragments or let-only snippets).
    $files = @("$root/copilot-studio-agent/agent-instructions.md") + (Get-ChildItem "$root/copilot-studio-agent/knowledge/*.md").FullName
    foreach ($file in $files)
    {
        $blocks = [regex]::Matches((Get-Content $file -Raw), '(?ms)^```kusto\r?\n(.*?)^```')
        $i = 0
        foreach ($block in $blocks)
        {
            $i++
            $kql = $block.Groups[1].Value.TrimEnd()
            $code = @($kql -split '\r?\n' | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^//' })
            if (-not $code -or $code[0].Trim().StartsWith('|') -or $code[-1].Trim().EndsWith(';') -or $kql -notmatch 'Costs_v1_2\(\)|Recommendations\(\)') { continue }
            $title = ([regex]::Match($kql, '//\s*Query:\s*(.+)')).Groups[1].Value.Trim()
            $label = "$(Split-Path $file -Leaf) #$i$(if ($title) { " ($title)" })"
            try
            {
                $rows = (Invoke-Kql $kql).Tables[0].Rows.Count
                Add-Result 'Agent KQL' $label $true "$rows rows"
            }
            catch
            {
                $msg = $_.ErrorDetails.Message
                if (-not $msg) { $msg = $_.Exception.Message }
                $msg = $msg -replace '\s+', ' '
                Add-Result 'Agent KQL' $label $false $msg.Substring(0, [Math]::Min(300, $msg.Length))
            }
        }
    }
}
#endregion

#region AOE workbooks
if ($AoeResourceGroupName -and $AoeWorkspaceName)
{
    if (-not $AoeWorkspaceResourceGroupName) { $AoeWorkspaceResourceGroupName = $AoeResourceGroupName }
    $la = Get-AzOperationalInsightsWorkspace -ResourceGroupName $AoeWorkspaceResourceGroupName -Name $AoeWorkspaceName

    $existing = @{}
    $tableRows = (Invoke-AzOperationalInsightsQuery -WorkspaceId $la.CustomerId -Query 'union withsource=TableName AzureOptimization*_CL | where TimeGenerated > ago(30d) | distinct TableName' -Timespan (New-TimeSpan -Days 30)).Results
    foreach ($row in $tableRows) { $existing[$row.TableName] = $true }

    $deployed = Get-AzResource -ResourceGroupName $AoeResourceGroupName -ResourceType 'microsoft.insights/workbooks' -ExpandProperties -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Properties.displayName }

    # A table is required only when a query references it outside "union isfuzzy=true (...)" and the query isn't in
    # an item hidden by a Has<Type> existence check (see Patch-AoeInventoryWorkbook.ps1).
    $fuzzyUnion = '(?s)union\s+isfuzzy\s*=\s*true\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)'
    function Get-RequiredTables($Node, [bool] $Guarded)
    {
        if ($Node -is [System.Management.Automation.PSCustomObject])
        {
            $conditions = @($Node.PSObject.Properties['conditionalVisibility']?.Value) + @($Node.PSObject.Properties['conditionalVisibilities']?.Value)
            if ($conditions | Where-Object { $_.parameterName -like 'Has*' }) { $Guarded = $true }
            foreach ($p in $Node.PSObject.Properties)
            {
                if ($p.Name -eq 'query' -and $p.Value -is [string])
                {
                    if (-not $Guarded) { [regex]::Matches(([regex]::Replace($p.Value, $fuzzyUnion, '')), 'AzureOptimization[A-Za-z]+V\d+_CL') | ForEach-Object Value }
                }
                else { Get-RequiredTables $p.Value $Guarded }
            }
        }
        elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) { foreach ($i in $Node) { Get-RequiredTables $i $Guarded } }
    }

    foreach ($wb in Get-ChildItem "$root/optimization-engine/views/workbooks/*.json")
    {
        $name = ([regex]::Match((Get-Content ($wb.FullName -replace '\.json$', '.bicep') -Raw), "param workbookDisplayName string = '([^']+)'")).Groups[1].Value
        Add-Result 'AOE workbook' "$name deployed" ($deployed -contains $name)

        $tables = @(Get-RequiredTables (Get-Content $wb.FullName -Raw | ConvertFrom-Json -Depth 100) $false | Sort-Object -Unique)
        $missing = $tables | Where-Object { -not $existing[$_] }
        Add-Result 'AOE workbook' "$name data tables" (-not $missing) $(if ($missing) { "missing: $($missing -join ', ')" } else { "$($tables.Count) required tables present" })
    }
}
#endregion

$results | Format-Table Result, Area, Check, Detail -AutoSize -Wrap
$failures = @($results | Where-Object Result -eq 'FAIL')
foreach ($f in $failures) { Write-Host "FAIL [$($f.Area)] $($f.Check): $($f.Detail)" -ForegroundColor Red }
$failed = $failures.Count
Write-Host "$($results.Count - $failed) passed, $failed failed" -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
if ($failed) { exit 1 }
