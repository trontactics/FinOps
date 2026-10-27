# FinOps toolkit on Microsoft Fabric with a Copilot Studio agent

A deployable, end-to-end setup of the [Microsoft FinOps toolkit](https://github.com/microsoft/finops-toolkit) **v14**:

- **FinOps hub on Microsoft Fabric.** Cost Management exports are normalized to FOCUS 1.2 and served from a Fabric eventhouse, with a 12-page Fabric Real-Time Dashboard on top.
- **Azure Optimization Engine (AOE).** Inventory, metrics, and Advisor data become optimization recommendations and Azure Workbooks.
- **Copilot Studio agent.** Ask cost questions in plain English, and the agent runs KQL against the hub with the signed-in user's permissions.
- **Helper scripts** that fill gaps in the official tooling: eventhouse creation, AOE first-run initialization, workbook fixes, and an end-to-end verification test.

## Get started

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) for what gets deployed and how data flows.
2. Follow [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md) step by step. It starts with a table of the values you choose (tenant, subscription, regions, names).
3. Set up the agent with [copilot-studio-agent/SETUP-INSTRUCTIONS.md](copilot-studio-agent/SETUP-INSTRUCTIONS.md).

## Repository layout

| Path | Contents |
|---|---|
| `deploy/` | Helper scripts: `New-FinOpsFabricEventhouse.ps1`, `New-FinOpsHubDashboard.ps1`, `Initialize-AoeData.ps1`, `Patch-AoeInventoryWorkbook.ps1`, and `Test-FinOpsDeployment.ps1` |
| `dashboard/` | Fabric Real-Time Dashboard template (FinOps toolkit v14 hub dashboard, 12 pages). Deploy it with `deploy/New-FinOpsHubDashboard.ps1`. |
| `optimization-engine/` | Azure Optimization Engine v14 from the FinOps toolkit, with the workbook customizations described in the runbook. Edit `aoe-settings.json` before deploying. |
| `copilot-studio-agent/` | Agent instructions, knowledge files, and setup guide |

Placeholders such as `<subscription-id>`, `<tenant-id>`, `<aoe-prefix>`, `<capacity-name>`, and `<eventhouse-id>.<zone>` appear throughout. Replace them with your own values. No tenant-specific values are stored in this repo.

## Requirements at a glance

- An Azure subscription where you're Owner (or Contributor + Role Based Access Control Administrator), and Cost Management Contributor for exports
- Microsoft Fabric enabled in the tenant. An F2 capacity costs about $263/month if it's always on; pause it when you aren't using it.
- For the agent: a Copilot Studio license or trial, a Power Platform environment with Dataverse, and connector policies that allow **Azure Data Explorer**
- PowerShell 7 with `Az` and `FinOpsToolkit` 14.0, the Azure CLI, and the Bicep CLI

## Credits and license

The Azure Optimization Engine, the FinOps hub templates, and the Power BI reports are part of the [Microsoft FinOps toolkit](https://github.com/microsoft/finops-toolkit), © Microsoft Corporation, under the MIT License (see [optimization-engine/LICENSE](optimization-engine/LICENSE)). The hub templates and Power BI reports are downloaded from the official v14 release during deployment, not stored here. This repository isn't an official Microsoft project.
