<#
.SYNOPSIS
    Deploys the whole FinOps solution in one command: Fabric capacity and eventhouse, FinOps hub, Cost Management
    export, Azure Optimization Engine, Fabric Real-Time Dashboard, and Fabric data agent, then verifies it.

.DESCRIPTION
    Runs the DEPLOYMENT-RUNBOOK.md steps in order and is safe to re-run. Each step checks what already exists and
    skips work that's done:
      1. Resource group, Fabric F-SKU capacity (resumed if paused), workspace, eventhouse, and Ingestion/Hub databases
      2. FinOps hub v14 template (skipped if the hub Data Factory exists, unless -Force)
      3. Data Factory managed identity as admin on the Ingestion and Hub databases
      4. FOCUS cost export at subscription scope with backfill (skipped if it exists)
      5. Azure Optimization Engine plus first-run initialization (skipped if the Automation account exists)
      6. Waits for the first cost data to reach the Hub database
      7. Real-Time Dashboard and data agent (skipped if they exist, unless -UpdateExisting)
      8. Read-only verification (Test-FinOpsDeployment.ps1)
    Two pieces remain manual because they're portal-only: Power BI reports and the Copilot Studio agent. The script
    prints instructions for both at the end.

    Before running: sign in with both Az PowerShell and the Azure CLI to the same tenant, and have Owner (or
    Contributor + Role Based Access Control Administrator) on the subscription. If your tenant applies Azure Policy
    that disables storage shared-key or public network access, get an exemption first, and pass any exemption tag
    with -Tags.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>; az login --tenant <tenant-id>
    ./deploy/Deploy-FinOpsSolution.ps1 -SubscriptionId <subscription-id> -HubRegion westus2 -AoeRegion westus3 `
        -CapacityName finopshubcap01 -AoePrefix finopsaoe01 -GrantGlobalReader

.EXAMPLE
    # Re-run to finish or repair a deployment, refreshing the dashboard and data agent from the repo
    ./deploy/Deploy-FinOpsSolution.ps1 -SubscriptionId <subscription-id> -HubRegion westus2 -AoeRegion westus3 `
        -CapacityName finopshubcap01 -AoePrefix finopsaoe01 -UpdateExisting
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $HubRegion,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[a-z][a-z0-9]{2,62}$')] [string] $CapacityName,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[a-z][a-z0-9]{1,12}$')] [string] $AoePrefix,
    # AOE region. Use a region where Azure SQL Database is available to your subscription. Defaults to HubRegion.
    [string] $AoeRegion = $HubRegion,
    # Fabric capacity admin. Defaults to the signed-in Azure CLI user.
    [string] $CapacityAdmin,
    [ValidateSet('F2', 'F4', 'F8', 'F16', 'F32', 'F64')] [string] $CapacitySku = 'F2',
    [string] $HubResourceGroupName = 'rg-finops-hub',
    [string] $HubName = 'finops-hub',
    [string] $WorkspaceName = 'FinOps Hub',
    [ValidateRange(0, 13)] [int] $BackfillMonths = 13,
    # Extra tags for every resource group and resource, such as a policy exemption tag: @{ MyExemptionTag = 'value' }
    [hashtable] $Tags = @{},
    # Grant Microsoft Entra Global Reader to the AOE identity (needs Privileged Role Administrator or Global Administrator).
    [switch] $GrantGlobalReader,
    # Redeploy the hub template even if the hub exists.
    [switch] $Force,
    # Replace the dashboard and the data agent draft with the versions in this repo if they already exist.
    [switch] $UpdateExisting,
    [switch] $SkipAoe,
    [switch] $SkipDashboard,
    [switch] $SkipDataAgent,
    # How long to wait for the first cost data before continuing. 0 skips the wait.
    [int] $DataWaitMinutes = 60
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$fabricApi = 'https://api.fabric.microsoft.com/v1'
$started = Get-Date

function Write-Step([string] $Number, [string] $Title) { Write-Host "`n=== Step $Number. $Title ===" -ForegroundColor Cyan }
function Write-Skip([string] $Message) { Write-Host "  Skipped: $Message" -ForegroundColor DarkGray }
function Write-Done([string] $Message) { Write-Host "  $Message" -ForegroundColor Green }

function Get-CliToken([string] $Resource) {
    $token = az account get-access-token --resource $Resource --query accessToken -o tsv
    if (-not $token) { throw "Couldn't get an Azure CLI token for $Resource. Run az login." }
    $token
}

function Invoke-Kusto([string] $ClusterUri, [string] $Database, [string] $Command, [switch] $Management) {
    $endpoint = if ($Management) { 'mgmt' } else { 'query' }
    $body = @{ db = $Database; csl = $Command } | ConvertTo-Json
    $result = Invoke-RestMethod -Method Post -Uri "$($ClusterUri.TrimEnd('/'))/v1/rest/$endpoint" -ContentType 'application/json' `
        -Headers @{ Authorization = "Bearer $(Get-CliToken 'https://kusto.kusto.windows.net')" } -Body $body -TimeoutSec 120
    , @($result.Tables[0].Rows)
}

#region Preflight
Write-Step 0 'Preflight'
foreach ($module in 'Az.Accounts', 'Az.Resources', 'Az.DataFactory', 'Az.Storage', 'FinOpsToolkit') {
    if (-not (Get-Module -ListAvailable $module)) { throw "PowerShell module $module isn't installed. Run Install-Module $module." }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) is required.' }
$env:PATH = "$HOME\.azure\bin;$env:PATH"
if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) { throw 'The Bicep CLI is required. Run: az bicep install' }

if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first.' }
Set-AzContext -Subscription $SubscriptionId | Out-Null
az account set --subscription $SubscriptionId
if ($LASTEXITCODE) { throw 'Run az login first (same tenant as Connect-AzAccount).' }
$tenantId = (Get-AzContext).Tenant.Id
$cliTenant = az account show --query tenantId -o tsv
if ($cliTenant -ne $tenantId) { throw "Az PowerShell ($tenantId) and the Azure CLI ($cliTenant) are signed in to different tenants." }
if (-not $CapacityAdmin) { $CapacityAdmin = az account show --query user.name -o tsv }
Write-Done "Subscription $SubscriptionId, tenant $tenantId, capacity admin $CapacityAdmin"

foreach ($provider in 'Microsoft.CostManagementExports', 'Microsoft.EventGrid', 'Microsoft.Fabric') {
    if ((Get-AzResourceProvider -ProviderNamespace $provider).RegistrationState -contains 'NotRegistered') {
        Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
        Write-Done "Registered $provider"
    }
}
$tagArgs = @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
#endregion

#region 1. Fabric capacity and eventhouse
Write-Step 1 'Fabric capacity, workspace, and eventhouse'
if ((az group exists -n $HubResourceGroupName) -eq 'true') { Write-Skip "resource group $HubResourceGroupName exists" }
else {
    if ($tagArgs) { az group create -n $HubResourceGroupName -l $HubRegion --tags @tagArgs -o none } else { az group create -n $HubResourceGroupName -l $HubRegion -o none }
    Write-Done "Created resource group $HubResourceGroupName"
}

$capacity = Get-AzResource -ResourceGroupName $HubResourceGroupName -ResourceType Microsoft.Fabric/capacities -Name $CapacityName -ErrorAction SilentlyContinue
if (-not $capacity) {
    $properties = @{ location = $HubRegion; sku = @{ name = $CapacitySku; tier = 'Fabric' }; properties = @{ administration = @{ members = @($CapacityAdmin) } } }
    if ($Tags.Count) { $properties.tags = $Tags }
    $propertiesFile = New-TemporaryFile
    $properties | ConvertTo-Json -Depth 6 | Set-Content $propertiesFile
    az resource create -g $HubResourceGroupName -n $CapacityName --resource-type Microsoft.Fabric/capacities --api-version 2023-11-01 `
        --is-full-object --properties "@$propertiesFile" -o none
    Remove-Item $propertiesFile
    if ($LASTEXITCODE) { throw "Creating Fabric capacity $CapacityName failed." }
    Write-Done "Created Fabric capacity $CapacityName ($CapacitySku)"
    $capacity = Get-AzResource -ResourceGroupName $HubResourceGroupName -ResourceType Microsoft.Fabric/capacities -Name $CapacityName
}
$state = (Get-AzResource -ResourceId $capacity.ResourceId -ExpandProperties).Properties.state
if ($state -ne 'Active') {
    Write-Host "  Capacity is $state; resuming..."
    Invoke-AzRestMethod -Method POST -Path "$($capacity.ResourceId)/resume?api-version=2023-11-01" | Out-Null
    for ($i = 0; $i -lt 40 -and $state -ne 'Active'; $i++) { Start-Sleep 15; $state = (Get-AzResource -ResourceId $capacity.ResourceId -ExpandProperties).Properties.state }
    if ($state -ne 'Active') { throw "Capacity $CapacityName didn't become Active (state: $state)." }
    Write-Done 'Capacity is Active'
}

$eventhouse = & (Join-Path $PSScriptRoot 'New-FinOpsFabricEventhouse.ps1') -CapacityName $CapacityName -WorkspaceName $WorkspaceName |
    Where-Object { $_.QueryUri } | Select-Object -Last 1
$queryUri = $eventhouse.QueryUri
if (-not $queryUri) { throw "Couldn't read the eventhouse Query URI." }
Write-Done "Eventhouse Query URI: $queryUri"
#endregion

#region 2. FinOps hub
Write-Step 2 'FinOps hub'
$dataFactory = Get-AzDataFactoryV2 -ResourceGroupName $HubResourceGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dataFactory -and -not $Force) { Write-Skip "hub exists (Data Factory $($dataFactory.DataFactoryName)); use -Force to redeploy" }
else {
    $work = Join-Path ([IO.Path]::GetTempPath()) "finops-hub-v14-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory $work | Out-Null
    Invoke-WebRequest https://github.com/microsoft/finops-toolkit/releases/download/v14/finops-hub-v14.zip -OutFile "$work/hub.zip"
    Expand-Archive "$work/hub.zip" -DestinationPath $work -Force
    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'
        parameters = @{ hubName = @{ value = $HubName }; location = @{ value = $HubRegion }; fabricQueryUri = @{ value = $queryUri }
                        fabricCapacityUnits = @{ value = [int]($CapacitySku.Substring(1)) }; tags = @{ value = $Tags } }
    }
    $parameters | ConvertTo-Json -Depth 6 | Set-Content "$work/parameters.json"
    Write-Host '  Deploying the hub template (about 10-15 minutes)...'
    az deployment group create -g $HubResourceGroupName -n finops-hub-v14 --template-file "$work/main.bicep" --parameters "@$work/parameters.json" -o none
    if ($LASTEXITCODE) { throw 'The FinOps hub deployment failed. Check the deployment in the Azure portal.' }
    Remove-Item $work -Recurse -Force
    $dataFactory = Get-AzDataFactoryV2 -ResourceGroupName $HubResourceGroupName | Select-Object -First 1
    Write-Done "Deployed hub $HubName"
}
#endregion

#region 3. Data Factory access to Fabric
Write-Step 3 'Data Factory access to the Ingestion and Hub databases'
$adfPrincipalId = $dataFactory.Identity.PrincipalId
$adfAppId = az ad sp show --id $adfPrincipalId --query appId -o tsv
foreach ($database in 'Ingestion', 'Hub') {
    $admins = Invoke-Kusto $queryUri $database ".show database $database principals | where Role endswith 'Admin' and PrincipalObjectId == '$adfPrincipalId'" -Management
    if ($admins.Count) { Write-Skip "Data Factory is already an admin on $database"; continue }
    Invoke-Kusto $queryUri $database ".add database $database admins ('aadapp=$adfAppId;$tenantId') 'FinOps hub Data Factory'" -Management | Out-Null
    Write-Done "Added Data Factory as admin on $database"
}
#endregion

#region 4. Cost Management export
Write-Step 4 'Cost Management FOCUS export'
$scope = "/subscriptions/$SubscriptionId"
$exportName = "$HubName-costs"
if (Get-FinOpsCostExport -Scope $scope -Name $exportName -ErrorAction SilentlyContinue) { Write-Skip "export $exportName exists" }
else {
    # The hub template creates a Data Lake (hierarchical namespace) account, Premium BlockBlobStorage by default,
    # tagged ftk-tool = 'FinOps hubs'. Prefer the tag; fall back to any Data Lake account in the resource group.
    $lakeAccounts = @(Get-AzStorageAccount -ResourceGroupName $HubResourceGroupName | Where-Object EnableHierarchicalNamespace)
    $storage = $lakeAccounts | Where-Object { $_.Tags -and $_.Tags['ftk-tool'] -eq 'FinOps hubs' } | Select-Object -First 1
    if (-not $storage) { $storage = $lakeAccounts | Select-Object -First 1 }
    if (-not $storage) { throw "No hub storage account (Data Lake, hierarchical namespace) found in $HubResourceGroupName. Check that step 2 deployed the hub." }
    Write-Host "  Using hub storage account $($storage.StorageAccountName)"
    New-FinOpsCostExport -Name $exportName -Scope $scope -Dataset FocusCost -StorageAccountId $storage.Id -StorageContainer msexports `
        -StoragePath "subscriptions/$SubscriptionId" -DoNotOverwrite -Backfill $BackfillMonths -Execute | Out-Null
    Write-Done "Created export $exportName and started a $BackfillMonths-month backfill"
}
#endregion

#region 5. Azure Optimization Engine
Write-Step 5 'Azure Optimization Engine'
if ($SkipAoe) { Write-Skip '-SkipAoe' }
elseif (Get-AzResource -ResourceGroupName "$AoePrefix-rg" -ResourceType Microsoft.Automation/automationAccounts -Name "$AoePrefix-auto" -ErrorAction SilentlyContinue) {
    Write-Skip "AOE exists ($AoePrefix-auto)"
}
else {
    $settingsFile = Join-Path ([IO.Path]::GetTempPath()) "aoe-settings-$AoePrefix.json"
    [ordered]@{ SubscriptionId = $SubscriptionId; NamePrefix = $AoePrefix; WorkspaceReuse = 'n'; DeployWorkbooks = 'y'
                TargetLocation = $AoeRegion; DeployBenefitsUsageDependencies = 'n' } | ConvertTo-Json | Set-Content $settingsFile
    $aoeTags = @{ purpose = 'finops-toolkit' } + $Tags
    Write-Host '  Deploying AOE (about 20-40 minutes)...'
    Push-Location (Join-Path $repoRoot 'optimization-engine')
    try {
        ./Deploy-AzureOptimizationEngine.ps1 -SilentDeploymentSettingsPath $settingsFile `
            -TemplateUri https://microsoft.github.io/finops-toolkit/deploy/optimization-engine/14.0/azuredeploy.bicep -ResourceTags $aoeTags
    } finally { Pop-Location; Remove-Item $settingsFile -ErrorAction SilentlyContinue }
    Write-Done 'Deployed AOE. Running first-run initialization (about 30-90 minutes)...'
    $initArgs = @{ NamePrefix = $AoePrefix }
    if ($GrantGlobalReader) { $initArgs.GrantGlobalReader = $true }
    & (Join-Path $PSScriptRoot 'Initialize-AoeData.ps1') @initArgs
    Write-Done 'AOE initialized'
}
#endregion

#region 6. First cost data
Write-Step 6 'Waiting for cost data in the Hub database'
$rows = [long](Invoke-Kusto $queryUri 'Hub' 'Costs_v1_2() | count')[0][0]
$deadline = (Get-Date).AddMinutes($DataWaitMinutes)
while ($rows -eq 0 -and (Get-Date) -lt $deadline) {
    Write-Host "  No cost rows yet; checking again in 2 minutes (until $($deadline.ToString('HH:mm')))..."
    Start-Sleep 120
    $rows = [long](Invoke-Kusto $queryUri 'Hub' 'Costs_v1_2() | count')[0][0]
}
if ($rows) { Write-Done "$rows cost rows in Hub" }
else { Write-Warning "No cost data yet. Exports can take a few hours to run the first time. Re-run this script later to finish verification." }
#endregion

#region 7. Dashboard and data agent
Write-Step 7 'Real-Time Dashboard and data agent'
$fabricHeaders = @{ Authorization = "Bearer $(Get-CliToken 'https://api.fabric.microsoft.com')" }
$workspace = (Invoke-RestMethod -Headers $fabricHeaders -Uri "$fabricApi/workspaces").value | Where-Object displayName -eq $WorkspaceName
$items = (Invoke-RestMethod -Headers $fabricHeaders -Uri "$fabricApi/workspaces/$($workspace.id)/items").value
if ($SkipDashboard) { Write-Skip '-SkipDashboard' }
elseif (($items | Where-Object { $_.type -eq 'KQLDashboard' -and $_.displayName -eq 'FinOps hub' }) -and -not $UpdateExisting) { Write-Skip 'dashboard exists; use -UpdateExisting to replace it' }
else { & (Join-Path $PSScriptRoot 'New-FinOpsHubDashboard.ps1') -ClusterUri $queryUri -WorkspaceName $WorkspaceName }
if ($SkipDataAgent) { Write-Skip '-SkipDataAgent' }
elseif (($items | Where-Object { $_.type -eq 'DataAgent' -and $_.displayName -eq 'FinOps Hub Data Agent' }) -and -not $UpdateExisting) { Write-Skip 'data agent exists; use -UpdateExisting to replace its draft' }
else { & (Join-Path $PSScriptRoot 'New-FinOpsHubDataAgent.ps1') -WorkspaceName $WorkspaceName }
#endregion

#region 8. Verify
Write-Step 8 'Verify'
$testArgs = @{ ClusterUri = $queryUri }
if (-not $SkipAoe) { $testArgs.AoeResourceGroupName = "$AoePrefix-rg"; $testArgs.AoeWorkspaceName = "$AoePrefix-la" }
if ($rows) { & (Join-Path $PSScriptRoot 'Test-FinOpsDeployment.ps1') @testArgs }
else { Write-Skip 'no cost data yet' }
#endregion

$minutes = [int]((Get-Date) - $started).TotalMinutes
Write-Host "`n=== Done in $minutes minutes ===" -ForegroundColor Cyan
Write-Host @"
Eventhouse Query URI: $queryUri
Fabric workspace:     https://app.fabric.microsoft.com/groups/$($workspace.id)

Manual steps left:
  1. Fabric data agent: open 'FinOps Hub Data Agent', test it in the chat pane, then select Publish.
  2. Power BI (optional): download https://github.com/microsoft/finops-toolkit/releases/download/v14/PowerBI-kql.zip,
     open each .pbit, and set Cluster URI to the Query URI above. The AOE report is
     optimization-engine/views/AzureOptimizationEngine.pbix (server $AoePrefix-sql.database.windows.net).
  3. Copilot Studio agent (optional): follow copilot-studio-agent/SETUP-INSTRUCTIONS.md, using the cluster URI
     without https:// in agent-instructions.md.
  4. Give users Viewer on the '$WorkspaceName' workspace.
"@
