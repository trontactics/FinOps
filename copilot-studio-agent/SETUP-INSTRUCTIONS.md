# FinOps Hub Copilot Studio Agent Setup Instructions

## Prerequisites

Before setting up the Copilot Studio agent, ensure you have:

1. **FinOps hub v12+ backed by Microsoft Fabric Real-Time Intelligence** (or Azure Data Explorer). The agent queries the `Hub` KQL database; a storage-only hub isn't supported. Follow `../DEPLOYMENT-RUNBOOK.md` to deploy the hub with a Fabric eventhouse.

2. **Copilot Studio License** - Either:
   - Microsoft 365 Copilot user license, OR
   - Standalone Copilot Studio license, OR
   - For a demo: the free [Copilot Studio trial](https://go.microsoft.com/fwlink/?LinkId=2107702) (test pane only; it can't publish). Without one of these, saving the agent fails with "User license not found".

3. **A Power Platform environment with Dataverse** - Copilot Studio stores the agent and knowledge files in Dataverse. A tenant's default environment often has no Dataverse database. For a demo, sign up for the free [Power Apps Developer Plan](https://powerapps.microsoft.com/developerplan), which creates a Developer environment with Dataverse. If Copilot Studio's environment picker doesn't list it, open it directly with `https://copilotstudio.microsoft.com/environments/<environment-id>/home`; the ID is in the Power Apps URL.

4. **Azure Data Explorer allowed by connector policy** - The Kusto Query MCP Server is an action of the **Azure Data Explorer** connector (`shared_kusto`). New Developer environments join a Microsoft-managed **Default Environment Group** with an advanced connector policy (ACP) allowlist that doesn't include it. To allow it, move the environment into your own environment group. Under **Rules** > **Advanced connector policies**, allow Azure Data Explorer, Content Conversion, Microsoft Dataverse, Microsoft Copilot Studio, and Microsoft Learn Docs MCP, then select **Apply changes**. This needs Global Administrator or Power Platform Administrator, and you might need to activate the role in PIM.

5. **Data access for every agent user** - the Kusto tool runs with end-user credentials, so each user needs **Viewer** (or greater) on the Fabric workspace, or viewer on the `Hub` KQL database.

6. **Cost data ingested** - `Costs_v1_2() | count` must return rows in the `Hub` database before you test the agent.

## Step 1: Get the eventhouse Query URI

1. In Microsoft Fabric, open the workspace and the FinOps hub eventhouse.
2. Select **System overview** and copy the **Query URI** (for example `https://abc123xyz.z4.kusto.fabric.microsoft.com`).
3. Remove the `https://` prefix; you'll use the remainder in Step 3.
4. Run `../deploy/Test-FinOpsDeployment.ps1 -ClusterUri <query-uri>` and confirm every Copilot catalog query passes.

## Step 2: Create the Copilot Studio Agent

1. Go to [https://copilotstudio.microsoft.com](https://copilotstudio.microsoft.com)
2. Select **Other ways to build** (or **…** > **Open classic experience** > **Create**) and start a blank agent. This creates a *standard harness* agent. The default **Create** > **New agent** path creates a GitHub Copilot harness agent, which is billed in Copilot Credits; with a trial license it couldn't add the Kusto tool.
3. Name: `FinOps Hub Agent`
4. Description:
   ```
   FinOps Hub Agent provides governed, real-time insights from your FinOps Toolkit Hub database. It translates natural language questions into validated KQL queries and delivers structured analysis on cloud spend, commitments, savings plans, anomalies, and optimization opportunities.
   ```

## Step 3: Configure Agent Instructions

1. Open `agent-instructions.md` from this folder
2. Update the **Environment** section with your eventhouse Query URI:

   ```
   Cluster URI: abc123xyz.z4.kusto.fabric.microsoft.com
   Database: Hub
   ```

   > **Important:** Do NOT include `https://` in the cluster URI

3. Copy the entire contents of `agent-instructions.md` from a text editor, not a rendered Markdown preview. The pasted text must start with `# FinOps Hub Agent` and must not be wrapped in ```` ``` ````.
4. Paste into the agent's **Instructions** field in Copilot Studio
5. Save the agent

## Step 4: Add Required Tools

### Kusto Query MCP Server (Required)

1. Create the connection first. In Power Apps (make.powerapps.com, same environment), go to **Connections** > **+ New connection** > **Azure Data Explorer** and sign in. Without a connection, the tool shows a red X in Copilot Studio.
2. Make sure **Settings** > **Generative AI** > **Orchestration** is set to **Yes**.
3. In Copilot Studio, go to **Tools** > **Add a tool**, search `Kusto`, and select **Kusto Query MCP Server** (an action of the Azure Data Explorer connector). Pick the connection.
4. Configure:
   - **Ask end user before running:** No
   - **Credentials:** End user credentials
5. Verify connection shows **Connected**

### Microsoft Learn Docs MCP Server (Optional)

1. Add **Microsoft Learn Docs MCP Server** for FinOps concept lookups
2. This enables the agent to reference documentation when answering questions

## Step 5: Upload Knowledge Files

Upload each file from the `knowledge/` folder:

| File | Description (paste into Copilot Studio) |
|------|----------------------------------------|
| `schema-reference.md` | Column reference for Costs_v1_2() including names, data types, usage notes, and edge cases. Use to look up correct column names before writing queries. |
| `query-catalog.md` | Ready-to-use KQL query templates for cost breakdowns, monthly trends, anomaly detection, forecasting, savings summary, and commitment utilization. |
| `weekly-report-guide.md` | Step-by-step workflow for producing structured weekly cost anomaly reports with seven KQL queries, post-processing rules, and the final report structure. |

Wait for all files to show **Ready** status.

## Step 6: Test the Agent

Use these sample prompts to verify setup:

```
What are my top 5 subscriptions by cost?
```

```
Show me the week-over-week cost summary
```

```
Are there any unusual spikes in cost over the last 3 months?
```

```
What was my savings rate last month?
```

### Verification Checklist

- [ ] Agent executes KQL queries (not just quoting from knowledge files)
- [ ] Results displayed as formatted tables
- [ ] KQL query shown in code block
- [ ] Confidence level, time range, and scope included in response

## Step 7: Publish the Agent

1. Click **Publish** in Copilot Studio
2. Configure channels:
   - Microsoft Teams (recommended)
   - Web chat
   - Custom channels

## Troubleshooting

### "Schema error" or "Column not found"

The agent may be using incorrect column names. Verify it's checking `schema-reference.md` before writing queries.

### "Timeout" errors

Add tighter time filters to queries. The default lookback may be too long for large datasets.

### "Empty results"

1. Verify data has been ingested into Data Explorer
2. Check that filters aren't too restrictive
3. Verify the scope filter matches available data

### Connection shows "Not Connected"

1. Verify the Fabric capacity is running (paused capacities reject queries)
2. Re-authenticate in Copilot Studio
3. Check the user has Viewer access to the Fabric workspace or Hub database

### "1 connector is blocked by data policy" or HTTP 442 "blocked due to ... advanced connector policies (ACP)"

1. Allow **Azure Data Explorer** in the environment's advanced connector policy (see Prerequisites 4), then select **Apply changes** once. Each retry of a failed apply can leave behind a duplicate "Default Policy Name" policy.
2. If the 442 error's **Last refresh** time is earlier than your policy change, the old policy is still cached against the existing connection. Remove the tool, delete the **Azure Data Explorer** connection in Power Apps, create a new connection, and add the tool again. This fixed the error on 2026-10-26, when waiting more than an hour didn't.

### Agent says it "can't access the Kusto Query MCP Server" and asks you to run the queries

The tool call failed and the agent fell back to the knowledge files. Open the tool step in the test pane's activity map to see the real error.

## Files in This Package

```
copilot-studio-agent/
├── agent-instructions.md      # Full agent instructions (paste into Copilot Studio)
├── knowledge-descriptions.md  # Descriptions for each knowledge file
├── SETUP-INSTRUCTIONS.md      # This file
└── knowledge/
    ├── schema-reference.md    # Column reference for Costs_v1_2()
    ├── query-catalog.md       # KQL query templates
    └── weekly-report-guide.md # Weekly report workflow
```

## Next Steps After Setup

1. **Test with real users** - Have finance/IT team members test the agent
2. **Customize queries** - Add organization-specific query templates
3. **Configure alerts** - Set up anomaly notifications
4. **Train users** - Share sample prompts and best practices

## Support Resources

- [FinOps Toolkit Documentation](https://aka.ms/ftk/docs)
- [Copilot Studio Documentation](https://learn.microsoft.com/microsoft-copilot-studio/)
- [Configure FinOps Hub Agent](https://learn.microsoft.com/en-us/cloud-computing/finops/toolkit/hubs/configure-ai-copilot-studio)
- [GitHub Issues](https://github.com/microsoft/finops-toolkit/issues)

---

*Generated: September 2026*
*FinOps Toolkit Version: v14*
