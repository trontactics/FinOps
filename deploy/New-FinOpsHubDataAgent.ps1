<#
.SYNOPSIS
    Creates (or updates) a Fabric data agent that answers FinOps questions from the FinOps hub Hub KQL database.

.DESCRIPTION
    Builds the data agent definition from the files in data-agent/:
      - agent-instructions.md       FinOps rules for the agent (metrics, dates, dimensions, output)
      - datasource-instructions.md  Notes on the Hub database functions
      - example-queries.json        Question-and-KQL pairs the agent learns from (each one tested against a hub)
    It adds the Hub KQL database as the data source, with Costs_v1_2, Prices_v1_2, Recommendations_v1_2,
    and CommitmentDiscountUsage_v1_2 selected. If an agent with the same name exists, its draft is replaced.

    Requires a paid Fabric capacity (F2 or higher), the tenant setting "Users can use Copilot, AI Agents and other
    AI experiences powered by Azure OpenAI", and Contributor (or higher) on the workspace. After the script runs,
    test the agent in Fabric and select Publish. Agent users need Viewer on the workspace.

.EXAMPLE
    ./New-FinOpsHubDataAgent.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkspaceName = 'FinOps Hub',
    [string] $DatabaseName = 'Hub',
    [string] $AgentName = 'FinOps Hub Data Agent',
    [string[]] $Functions = @('Costs_v1_2', 'Prices_v1_2', 'Recommendations_v1_2', 'CommitmentDiscountUsage_v1_2'),
    [string] $SourcePath = (Join-Path $PSScriptRoot '../data-agent')
)

$ErrorActionPreference = 'Stop'
$api = 'https://api.fabric.microsoft.com/v1'
$schemaBase = 'https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition'
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

function New-Part([string] $Path, $Object) {
    @{ path = $Path; payloadType = 'InlineBase64'
       payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 20))) }
}

$workspace = (Invoke-RestMethod -Headers $headers -Uri "$api/workspaces").value | Where-Object displayName -eq $WorkspaceName
if (-not $workspace) { throw "Workspace '$WorkspaceName' not found, or you don't have access to it." }
$items = (Invoke-RestMethod -Headers $headers -Uri "$api/workspaces/$($workspace.id)/items").value
$database = $items | Where-Object { $_.type -eq 'KQLDatabase' -and $_.displayName -eq $DatabaseName }
if (-not $database) { throw "KQL database '$DatabaseName' not found in workspace '$WorkspaceName'." }

$dataSource = [ordered]@{
    '$schema'              = "$schemaBase/dataSource/1.0.0/schema.json"
    artifactId             = $database.id
    workspaceId            = $workspace.id
    displayName            = $DatabaseName
    type                   = 'kusto'
    userDescription        = 'FinOps hub cost, price, and recommendation data (FOCUS 1.2)'
    dataSourceInstructions = (Get-Content (Join-Path $SourcePath 'datasource-instructions.md') -Raw).Trim()
    elements               = @([ordered]@{
        id = [guid]::NewGuid().ToString(); is_selected = $false; display_name = 'Functions'; type = 'function_grouping'
        children = @($Functions | ForEach-Object {
            [ordered]@{ id = [guid]::NewGuid().ToString(); is_selected = $true; display_name = $_; type = 'kusto.function'; children = @() }
        })
    })
}
$fewShots = Get-Content (Join-Path $SourcePath 'example-queries.json') -Raw | ConvertFrom-Json | ForEach-Object {
    [ordered]@{ id = [guid]::NewGuid().ToString(); question = $_.question; query = $_.query }
}
$folder = "Files/Config/draft/kusto-$DatabaseName"
$parts = @(
    New-Part 'Files/Config/data_agent.json' ([ordered]@{ '$schema' = "$schemaBase/dataAgent/2.1.0/schema.json" })
    New-Part 'Files/Config/draft/stage_config.json' ([ordered]@{
        '$schema' = "$schemaBase/stageConfiguration/1.0.0/schema.json"
        aiInstructions = (Get-Content (Join-Path $SourcePath 'agent-instructions.md') -Raw).Trim() })
    New-Part "$folder/datasource.json" $dataSource
    New-Part "$folder/fewshots.json" ([ordered]@{ '$schema' = "$schemaBase/fewShots/1.0.0/schema.json"; fewShots = @($fewShots) })
)

$existing = $items | Where-Object { $_.type -eq 'DataAgent' -and $_.displayName -eq $AgentName }
if ($existing) {
    $response = Invoke-WebRequest -Method Post -Headers $headers -ContentType 'application/json' `
        -Uri "$api/workspaces/$($workspace.id)/items/$($existing.id)/updateDefinition" `
        -Body (@{ definition = @{ parts = $parts } } | ConvertTo-Json -Depth 8)
    Wait-FabricOperation $response
    Write-Host "Updated the draft of data agent '$AgentName'. Test it in Fabric, then select Publish."
} else {
    $response = Invoke-WebRequest -Method Post -Headers $headers -ContentType 'application/json' `
        -Uri "$api/workspaces/$($workspace.id)/items" `
        -Body (@{ displayName = $AgentName; type = 'DataAgent'; description = 'Answers FinOps cost questions from the FinOps hub.'; definition = @{ parts = $parts } } | ConvertTo-Json -Depth 8)
    Wait-FabricOperation $response
    Write-Host "Created data agent '$AgentName' with $(@($fewShots).Count) example queries. Test it in Fabric, then select Publish."
}
