# FinOps toolkit deployment runbook (Fabric + AOE + Copilot Studio)

Deploys FinOps toolkit **v14**: a FinOps hub backed by a Microsoft Fabric eventhouse, the Azure Optimization Engine (AOE) with its workbooks, a Fabric Real-Time Dashboard and data agent, Power BI reports, and the Copilot Studio agent. Every command runs from the repo root unless a step says otherwise.

## Quick start: one command

`deploy/Deploy-FinOpsSolution.ps1` runs steps 0–5, 6b, 7b, and 8 in order. It creates the capacity, eventhouse, hub, Data Factory access, export, AOE (with first-run initialization), dashboard, and data agent, waits for the first cost data, and verifies everything. Meet the [prerequisites](#0-prerequisites) first, then:

```powershell
Connect-AzAccount -Tenant <tenant-id>
az login --tenant <tenant-id>
./deploy/Deploy-FinOpsSolution.ps1 -SubscriptionId <subscription-id> -HubRegion <hub-region> -AoeRegion <aoe-region> `
    -CapacityName <capacity-name> -AoePrefix <aoe-prefix> -GrantGlobalReader
```

| Option | Use |
|---|---|
| `-Tags @{ <tag-name> = '<tag-value>' }` | Tags every new resource group and resource, for example a policy exemption tag your tenant requires |
| `-GrantGlobalReader` | Grants Global Reader to the AOE identity (needs Privileged Role Administrator or Global Administrator). Leave it off if you don't have the role. |
| `-CapacitySku F4` (and up) | A larger Fabric capacity. The default is F2. |
| `-BackfillMonths 13` | Months of cost history to export (0–13) |
| `-UpdateExisting` | Replaces the dashboard and the data agent draft with the repo versions |
| `-Force` | Redeploys the hub template even if the hub exists |
| `-SkipAoe`, `-SkipDashboard`, `-SkipDataAgent` | Leaves out those components |
| `-DataWaitMinutes 60` | How long to wait for the first cost data before verifying (0 skips the wait) |

A full first run takes about 1.5–3 hours, mostly AOE initialization and the first export. The script is safe to re-run. Each step checks what exists and skips work that's done, so you can re-run it to finish after an interruption or to verify an existing deployment. It ends with the few steps that remain manual: publishing the data agent, Power BI reports (step 6), and the Copilot Studio agent (step 7).

The rest of this runbook describes each step individually, for manual deployment or troubleshooting.

## Values you choose

Replace these placeholders throughout the runbook and the scripts:

| Placeholder | Example | Notes |
|---|---|---|
| `<tenant-id>` | `00000000-0000-0000-0000-000000000000` | Microsoft Entra tenant ID |
| `<subscription-id>` | `00000000-0000-0000-0000-000000000000` | Subscription to deploy into and monitor |
| `<your-upn>` | `you@contoso.com` | Becomes the Fabric capacity admin |
| `<hub-region>` | `westus2` | Region for the Fabric capacity and the hub. Use the same region for both. |
| `<capacity-name>` | `finopshubcap01` | Fabric capacity name: lowercase letters and numbers, globally unique |
| `<aoe-prefix>` | `finopsaoe01` | AOE name prefix: lowercase, at most 13 characters. AOE creates `<aoe-prefix>-rg`, `<aoe-prefix>sa`, `<aoe-prefix>-auto`, `<aoe-prefix>-la`, and `<aoe-prefix>-sql`. |
| `<aoe-region>` | `westus3` | AOE region. It needs Azure SQL Database available for your subscription (see [Known limitations](#known-limitations)). |
| `<eventhouse-id>.<zone>` | `abc123xyz.z4` | From the eventhouse **Query URI**, printed in step 1 |

These names are fixed by the runbook. You can change them, but then update every command that uses them:

| Setting | Value |
|---|---|
| Hub resource group / hub name | `rg-finops-hub` / `finops-hub` |
| Fabric workspace / eventhouse / databases | `FinOps Hub` / `FinOpsHub` / `Ingestion` and `Hub` |
| Fabric SKU | F2 |

## 0. Prerequisites

- PowerShell 7 with `Az` and `FinOpsToolkit` 14.0 (`Install-Module FinOpsToolkit`), the Azure CLI, and the Bicep CLI on PATH. Az PowerShell doesn't find the copy installed by `az bicep install`, so add it first: `$env:PATH = "$HOME\.azure\bin;$env:PATH"`.
- Owner (or Contributor + Role Based Access Control Administrator) on the subscription.
- Fabric enabled in the tenant. Step 1 creates the capacity and workspace.
- To create Cost Management exports: Cost Management Contributor on the subscription. For price sheet, reservation, and savings plan data: an EA billing account or MCA billing profile role (see [Known limitations](#known-limitations)).
- Optional: a Microsoft Entra role that can assign directory roles (Privileged Role Administrator or Global Administrator), for AOE's Identities and Roles workbook.
- Connect to Azure:

  ```powershell
  Connect-AzAccount -Tenant <tenant-id>; Set-AzContext <subscription-id>
  az login --tenant <tenant-id>; az account set -s <subscription-id>
  ```

- Register the resource providers the hub needs (skip any already registered):

  ```powershell
  Register-AzResourceProvider -ProviderNamespace Microsoft.CostManagementExports
  Register-AzResourceProvider -ProviderNamespace Microsoft.EventGrid
  ```

- **Tenant security policies.** If Azure Policy in your tenant changes storage accounts automatically (for example, disables shared-key access or public network access), get an exemption for both resource groups before you start. See [ARCHITECTURE.md §7](ARCHITECTURE.md#7-networking-and-tenant-policy-constraints).

## 1. Fabric capacity and eventhouse (before the hub)

```powershell
az group create -n rg-finops-hub -l <hub-region>
az resource create -g rg-finops-hub -n <capacity-name> --resource-type Microsoft.Fabric/capacities --api-version 2023-11-01 --is-full-object `
    --properties '{"location":"<hub-region>","sku":{"name":"F2","tier":"Fabric"},"properties":{"administration":{"members":["<your-upn>"]}}}'
./deploy/New-FinOpsFabricEventhouse.ps1 -CapacityName <capacity-name>
```

The script is idempotent. It creates the `FinOps Hub` workspace on the capacity, the `FinOpsHub` eventhouse, and the `Ingestion` and `Hub` KQL databases. It then runs the official v14 setup scripts on both databases (with raw retention 0) and prints the **Query URI**. Note the URI; later steps need it.

Pause the capacity when you aren't using it to stop F2 charges. Queries and ingestion fail while it's paused.

## 2. FinOps hub

Deploy the v14 release template directly. The `Deploy-FinOpsHub` cmdlet in FinOpsToolkit 14.0 fails with "Could not find template 'main.bicep'", because the release zip has no `finops-hub-v*` folder.

```bash
curl -sL -o hub.zip https://github.com/microsoft/finops-toolkit/releases/download/v14/finops-hub-v14.zip && unzip -q hub.zip -d finops-hub-v14
az deployment group create -g rg-finops-hub -n finops-hub-v14 --template-file finops-hub-v14/main.bicep \
    --parameters hubName=finops-hub location=<hub-region> fabricQueryUri=https://<eventhouse-id>.<zone>.kusto.fabric.microsoft.com fabricCapacityUnits=2
```

If your tenant requires an exemption tag, add it with `tags='{"<tag-name>":"<tag-value>"}'`.

## 3. Give Data Factory access to Fabric

Copy the hub Data Factory's managed identity **Object (principal) ID**:

```powershell
(Get-AzDataFactoryV2 -ResourceGroupName rg-finops-hub | Select-Object -First 1).Identity.PrincipalId
```

Then run these two commands **separately** in the `Ingestion` queryset:

```kusto
.add database Ingestion admins ('aadapp=<adf-principal-id>')
```

```kusto
.add database Hub admins ('aadapp=<adf-principal-id>')
```

## 4. Cost Management exports

Subscription scope:

```powershell
$sa = Get-AzStorageAccount -ResourceGroupName rg-finops-hub | Where-Object StorageAccountName -like '*hub*' | Select-Object -First 1
New-FinOpsCostExport -Name finops-hub-costs -Scope '/subscriptions/<subscription-id>' `
    -Dataset FocusCost -StorageAccountId $sa.Id -StorageContainer msexports `
    -StoragePath 'subscriptions/<subscription-id>' -DoNotOverwrite -Backfill 13 -Execute
```

If you have an EA billing account or MCA billing profile, create the `PriceSheet` export **before** `FocusCost`, then `ReservationRecommendations`, at that billing scope. The commands are in the [hub deploy guide](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/deploy#configure-scopes-to-monitor).

Wait for ingestion to finish, then confirm in the `Hub` queryset that `Costs_v1_2() | count` returns more than 0.

## 5. Azure Optimization Engine

Edit `optimization-engine/aoe-settings.json` and set `SubscriptionId`, `NamePrefix`, and `TargetLocation`. Then run the deployment from `optimization-engine/`. The script deploys the local `azuredeploy.bicep` and `views/workbooks/*.bicep`, and imports runbooks from the pinned v14 URL. The local runbooks are byte-identical to the published v14 runbooks.

```powershell
cd optimization-engine
./Deploy-AzureOptimizationEngine.ps1 -SilentDeploymentSettingsPath ./aoe-settings.json `
    -TemplateUri https://microsoft.github.io/finops-toolkit/deploy/optimization-engine/14.0/azuredeploy.bicep `
    -ResourceTags @{ purpose = 'finops-toolkit' }
cd ..
```

The script adds a SQL firewall rule for your public IP and connects to SQL. On a corporate VPN, the egress IP can change mid-run. If the SQL step times out, run it from Azure Cloud Shell instead.

Then initialize AOE so the workbooks have data immediately. This seeds the Suppressions table, optionally grants Global Reader, and runs every job once in dependency order (about 30–90 minutes):

```powershell
./deploy/Initialize-AoeData.ps1 -NamePrefix <aoe-prefix> -GrantGlobalReader   # drop -GrantGlobalReader if you lack the Entra role
```

The script waits 20 minutes between ingesting data and generating recommendations, because new Log Analytics tables take time to become queryable.

**Workbook customizations in this repo** (an AOE upgrade overwrites them, so reapply afterwards):

- The five benefits workbooks are moved to `views/workbooks/benefits/`, so `Deploy-AzureOptimizationEngine.ps1` doesn't deploy them without EA/MCA billing access. To re-enable them, move them back to `views/workbooks/` and set `DeployBenefitsUsageDependencies` to `y`.
- `resources-inventory.json` is patched by `./deploy/Patch-AoeInventoryWorkbook.ps1`. Tabs for resource types that don't exist in the subscription (VMs, scale sets, disks, NSGs, load balancers, App Gateways, App Service plans, RBAC) show a "No … found" note instead of "Failed to resolve table". After an upgrade, run the patch script and redeploy:

```powershell
./deploy/Patch-AoeInventoryWorkbook.ps1
$la = Get-AzOperationalInsightsWorkspace -ResourceGroupName <aoe-prefix>-rg -Name <aoe-prefix>-la
New-AzResourceGroupDeployment -ResourceGroupName <aoe-prefix>-rg -TemplateFile ./optimization-engine/views/workbooks/resources-inventory.bicep `
    -workbookSourceId $la.ResourceId -resourceTags @{ purpose = 'finops-toolkit' }
```

## 6. Power BI

Use the **KQL** report templates, because Fabric is a KQL backend. Download [PowerBI-kql.zip (v14)](https://github.com/microsoft/finops-toolkit/releases/download/v14/PowerBI-kql.zip), open each `.pbit`, and set **Cluster URI** to the eventhouse Query URI. Authorize Kusto with an account that has Viewer on the workspace. Authorize the GitHub and ccmstorageprod URLs as anonymous.

The AOE report is `optimization-engine/views/AzureOptimizationEngine.pbix`. Point it at `<aoe-prefix>-sql.database.windows.net` / `azureoptimization`.

### 6b. Fabric Real-Time Dashboard

Create the FinOps hub dashboard in the `FinOps Hub` workspace. It has 12 pages organized by FinOps Framework domain (Summary, Anomaly management, Data ingestion, Rate optimization, Licensing + SaaS, Budgeting, and Invoicing + chargeback), and every tile is a live KQL query against `Hub`:

```powershell
./deploy/New-FinOpsHubDashboard.ps1 -ClusterUri https://<eventhouse-id>.<zone>.kusto.fabric.microsoft.com
```

The template in `dashboard/finops-hub-dashboard.json` is the official v14 hub dashboard with one fix: the two *Commitment discount chargeback* tiles show an empty table instead of an error when there's no commitment discount usage. You need Contributor on the workspace to run the script. Re-running it replaces the dashboard's definition. Dashboard users need Viewer on the workspace. Tiles for reservations, savings plans, and Hybrid Benefit stay empty until that data exists.

To import it by hand instead: in the workspace, select **+ New item** > **Real-Time Dashboard**, then **Manage** > **Replace with file**. Then go to **Manage** > **Data sources**, and point **Hub** at your eventhouse's `Hub` database.

## 7. Copilot Studio agent

Follow [`copilot-studio-agent/SETUP-INSTRUCTIONS.md`](copilot-studio-agent/SETUP-INSTRUCTIONS.md). Set the cluster URI in `agent-instructions.md` to the eventhouse Query URI **without** `https://`, and upload the three files from `copilot-studio-agent/knowledge/`. The setup guide also covers licensing, Dataverse, and connector policies, which commonly block a first setup.

### 7b. Optional: Fabric data agent

A Fabric data agent answers the same kinds of questions as the Copilot Studio agent, but it runs entirely in Fabric, with no Copilot Studio license, Dataverse, or connector policies. It needs a paid Fabric capacity (F2 or higher) and the tenant setting **Users can use Copilot, AI Agents and other AI experiences powered by Azure OpenAI**. If the capacity is outside the US or EU, it may also need the cross-geo processing settings.

```powershell
./deploy/New-FinOpsHubDataAgent.ps1
```

The script creates **FinOps Hub Data Agent** in the `FinOps Hub` workspace from the files in `data-agent/`:

- `agent-instructions.md`: FinOps rules (default metric, date handling, dimensions, marketplace separation, output format)
- `datasource-instructions.md`: how to use the `Hub` functions
- `example-queries.json`: 10 question-and-KQL pairs (top subscriptions, services, and resource groups; monthly and daily trends; week over week; untagged spend; savings rate; top resources; and anomaly spikes)

It selects `Costs_v1_2`, `Prices_v1_2`, `Recommendations_v1_2`, and `CommitmentDiscountUsage_v1_2` as the data source functions. Re-running the script replaces the agent's draft. Open the agent in Fabric, test it in the chat pane (for example, *"What are my top 5 services by cost in the last 30 days?"*), then select **Publish**. Users need Viewer on the workspace.

After you publish it, the data agent can also be added to the Copilot Studio agent as a tool, so Fabric holds the query logic and Copilot Studio provides the chat in Teams or on the web.

## 8. Verify (read-only)

```powershell
./deploy/Test-FinOpsDeployment.ps1 -ClusterUri https://<eventhouse-id>.<zone>.kusto.fabric.microsoft.com `
    -AoeResourceGroupName <aoe-prefix>-rg -AoeWorkspaceName <aoe-prefix>-la
```

The test runs all 24 executable Copilot catalog queries against `Hub`, checks that each AOE workbook is deployed, and checks that every Log Analytics table each workbook queries exists. Any FAIL gives the exact query or table to fix.

## Known limitations

- **Azure SQL region availability.** Some subscriptions, including many internal and trial subscriptions, can't create Azure SQL Database in popular regions such as West US 2, East US, and East US 2. If the AOE deployment fails on SQL, pick another `<aoe-region>` (West US 3, West US, and Central US often work), or open a *Service and subscription limits* support request.
- **Benefits workbooks need EA/MCA billing data.** *Benefits Simulation*, *Benefits Usage*, *Reservations Potential*, *Reservations Usage*, and *Savings Plans Usage* query the `Pricesheet`, `ReservationsPrice`, `ReservationsUsage`, and `SavingsPlansUsage` tables. AOE only populates those when `DeployBenefitsUsageDependencies` is `y`, which requires an EA billing account or MCA billing profile plus `CustomerType`, `BillingAccountId`, and `CurrencyCode` (and `BillingProfileId` for MCA) in `aoe-settings.json`. Without them, these five workbooks show "Failed to resolve table", which is why this repo holds them back (see step 5).
- **Identities and Roles workbook** needs Global Reader on the AOE identity. A Global Administrator or Privileged Role Administrator can run `./deploy/Initialize-AoeData.ps1 -NamePrefix <aoe-prefix> -GrantGlobalReader -SkipSuppressionSeed -SkipRunbooks`, or assign Global Reader to the `<aoe-prefix>-auto` managed identity under Entra ID > Roles and administrators. To keep your deployment login unaffected, run it under a separate Azure CLI profile (`AZURE_CONFIG_DIR`).
- **Reservation recommendations** in the Rate optimization report and the agent's `Recommendations()` queries return no rows until a `ReservationRecommendations` export runs at an EA or MCA billing scope.
- **Data latency.** Cost data lags 24–48 hours. AOE metric-based recommendations improve after several days of collected metrics.
- **Windows Git Bash.** When you pass resource IDs (`/subscriptions/...`) to `az` from Git Bash, prefix the command with `MSYS_NO_PATHCONV=1` and strip carriage returns (`| tr -d '\r'`). Otherwise the calls fail with `MissingSubscription` or `Bad Request`.
