# FinOps Toolkit Customer Demonstration Guide

A comprehensive step-by-step guide for presenting and demonstrating the Microsoft FinOps Toolkit to customers.

---

## Table of Contents

1. [Pre-Demo Preparation](#pre-demo-preparation)
2. [Executive Overview (5 min)](#executive-overview)
3. [Demo Flow](#demo-flow)
   - [FinOps Hubs](#demo-1-finops-hubs)
   - [Azure Optimization Engine](#demo-2-azure-optimization-engine)
   - [Power BI Reports](#demo-3-power-bi-reports)
   - [Copilot Studio Agent](#demo-4-copilot-studio-agent)
   - [Azure Workbooks](#demo-5-azure-workbooks)
4. [Customer Q&A Preparation](#customer-qa-preparation)
5. [Post-Demo Actions](#post-demo-actions)

---

## Pre-Demo Preparation

### Environment Requirements

| Component | Requirement | Status Check |
|-----------|-------------|--------------|
| Azure Subscription | Owner or Contributor access | `az account show` |
| FinOps Hub | v12+ with Fabric eventhouse | Check `rg-finops-hub` |
| Azure Optimization Engine | Deployed and running | Check `<aoe-prefix>-rg` |
| Power BI Desktop | Latest version | Open KQL .pbit templates |
| Copilot Studio | Licensed user | copilotstudio.microsoft.com |
| Cost data | 30+ days ingested | `Costs_v1_2() \| count` in the Fabric Hub database |

### Pre-Demo Checklist

- [ ] Verify all Azure resources are running (no failed deployments)
- [ ] Confirm cost data has been ingested (check last 7 days)
- [ ] Test Power BI reports load correctly
- [ ] Prepare sample questions for Copilot Studio demo
- [ ] Clear browser cache/cookies for clean demo experience
- [ ] Have backup screenshots ready in case of connectivity issues

### Demo Environment URLs

```
Azure Portal:        https://portal.azure.com
Copilot Studio:      https://copilotstudio.microsoft.com
Power BI Service:    https://app.powerbi.com
FinOps Hub Storage:  <hub-storage-account>.blob.core.windows.net
AOE Log Analytics:   <aoe-prefix>-la
```

---

## Executive Overview

**Duration:** 5 minutes

### Opening Statement

> "The Microsoft FinOps Toolkit is a comprehensive, open-source solution that helps organizations understand, optimize, and govern their cloud spending. It provides centralized cost visibility, AI-powered insights, and actionable recommendations to help you maximize the value of every cloud dollar."

### Key Value Propositions

1. **Unified Cost Visibility** - Single source of truth for all Azure cost data
2. **AI-Powered Insights** - Natural language queries through Copilot Studio
3. **Automated Recommendations** - Continuous optimization suggestions
4. **Executive Reporting** - Power BI dashboards for stakeholder communication
5. **Open Source** - No licensing costs, community-driven improvements

### ROI Talking Points

| Metric | Typical Customer Outcome |
|--------|-------------------------|
| Cost Reduction | 15-30% within first 6 months |
| Time Savings | 80% reduction in manual reporting |
| Visibility | 100% coverage across all subscriptions |
| Compliance | Automated tagging and governance checks |

---

## Demo Flow

### Demo 1: FinOps Hubs

**Duration:** 10-15 minutes

#### Story: "Your Single Source of Cloud Cost Truth"

**Step 1: Navigate to FinOps Hub Resources**

```bash
# Show resource group in portal
Azure Portal > Resource Groups > rg-finops-hub
```

**Talking Points:**
- "FinOps Hub automatically ingests cost data from Azure Cost Management"
- "Data is stored in Azure Storage with configurable retention"
- "Supports multi-cloud through FOCUS schema standardization"

**Step 2: Show Data Flow Architecture**

Navigate to Data Factory and show:
- Pipeline runs (successful ingestion)
- Data flow from Cost Management exports
- Storage account structure

**Demo Script:**
> "Here we can see the automated pipelines that ingest your cost data daily. Notice how the data is organized by billing period - this ensures you always have accurate, complete cost information for any reporting period."

**Step 3: Show Cost Data in Storage**

```
Storage Account > Containers > ingestion > [date folders]
```

**Key Points to Highlight:**
- FOCUS-compliant schema
- Parquet format for efficient queries
- Automatic data lifecycle management

---

### Demo 2: Azure Optimization Engine

**Duration:** 15-20 minutes

#### Story: "Automated Recommendations That Drive Action"

**Step 1: Navigate to AOE Resources**

```bash
Azure Portal > Resource Groups > <aoe-prefix>-rg
```

**Components to Show:**
- Automation Account (runbooks)
- Log Analytics Workspace (recommendations)
- SQL Database (historical data)
- Storage Account (exports)

**Step 2: Show Azure Workbooks**

Navigate to Log Analytics > Workbooks and demonstrate:

**Workbook: Recommendations Overview**
- Show recommendation categories (Cost, Performance, Security)
- Filter by subscription/resource group
- Highlight potential savings amounts

**Demo Script:**
> "The Azure Optimization Engine continuously analyzes your environment and generates actionable recommendations. Unlike Azure Advisor, AOE provides custom recommendations tailored to your organization's policies and thresholds."

**Step 3: Show Recommendation Details**

Select a high-impact recommendation and show:
- Resource details
- Current vs. recommended configuration
- Estimated savings
- Implementation steps

**Sample Recommendations to Highlight:**

| Category | Example | Impact |
|----------|---------|--------|
| Right-sizing | VM downsizing opportunity | $500/month |
| Unused Resources | Orphaned disks | $200/month |
| Reservations | RI purchase recommendation | $2,000/year |
| Hybrid Benefit | Windows Server AHUB | $800/month |

**Step 4: Show Automation Runbooks**

```
Automation Account > Runbooks
```

**Key Runbooks to Demonstrate:**
- `Export-ARGVirtualMachinesPropertiesToBlobStorage`
- `Recommend-VMOptimizationsToBlobStorage`
- `Ingest-RecommendationsToSQLServer`

**Demo Script:**
> "These runbooks run on a schedule - daily, weekly, or custom - and automatically export resource data, generate recommendations, and store them for reporting. This eliminates the manual effort of collecting optimization data."

---

### Demo 3: Power BI Reports

**Duration:** 10-15 minutes

#### Story: "Executive Dashboards That Tell Your Cost Story"

**Pre-Demo:** Open Power BI Desktop with the FinOps Toolkit reports loaded

**Step 1: Cost Overview Dashboard**

**Pages to Show:**
- Monthly cost trends
- Top 10 subscriptions by spend
- Cost by service category
- Month-over-month variance

**Demo Script:**
> "This executive dashboard provides an at-a-glance view of your cloud spending. Finance teams love this because they can see trends, identify anomalies, and prepare budget forecasts - all without writing a single query."

**Step 2: Commitment Discounts Page**

Show:
- Reservation utilization rates
- Savings Plan coverage
- Unused commitment costs
- Recommendations for optimization

**Key Metrics to Highlight:**
- Current utilization %
- Potential savings from unused commitments
- Expiring commitments

**Step 3: Cost Allocation Page**

Demonstrate:
- Cost breakdown by tag (team, environment, application)
- Showback/chargeback reports
- Untagged resource identification

**Demo Script:**
> "Cost allocation is critical for organizations with multiple teams or business units. This report shows exactly who is spending what, and highlights resources that aren't properly tagged - making accountability transparent."

**Step 4: Anomaly Detection Page**

Show:
- Automated spike detection
- Historical comparisons
- Drill-down capabilities

---

### Demo 4: Copilot Studio Agent

**Duration:** 10-15 minutes

#### Story: "Ask Questions, Get Answers - In Plain English"

**Prerequisites:**
- FinOps Hub v12+ with a Fabric eventhouse (Hub database)
- Copilot Studio agent configured
- Sample cost data ingested

**Step 1: Open Copilot Studio**

Navigate to: `https://copilotstudio.microsoft.com`

**Step 2: Demonstrate Natural Language Queries**

**Query Set 1: Basic Cost Questions**

```
"What are my top 5 subscriptions by cost this month?"
```

**Expected Response:**
- Formatted table with subscription names and costs
- KQL query shown for transparency
- Confidence level indicated

**Query Set 2: Trend Analysis**

```
"Show me the week-over-week cost trend for the last 3 months"
```

**Demo Script:**
> "Notice how the agent automatically generates the correct KQL query, executes it against your FinOps Hub data, and returns a formatted response. This democratizes cost data - anyone can get insights without knowing query languages."

**Query Set 3: Anomaly Investigation**

```
"Why did my Virtual Machines cost increase last week?"
```

**Demo Script:**
> "The agent doesn't just return data - it provides analysis. Here it's identifying the specific resources, comparing usage patterns, and suggesting potential causes for the cost change."

**Query Set 4: Savings Analysis**

```
"What was my effective savings rate last month?"
```

**Query Set 5: Weekly Report**

```
"Generate a weekly cost anomaly report"
```

**Key Points to Highlight:**
- No technical knowledge required
- Real-time data access
- Audit trail of queries
- Customizable for organization needs

---

### Demo 5: Azure Workbooks

**Duration:** 5-10 minutes

#### Story: "Interactive Analysis Within Azure Portal"

**Step 1: Navigate to Workbooks**

```
Azure Portal > Log Analytics workspace > Workbooks
```

**Step 2: Show Interactive Filters**

Demonstrate:
- Subscription picker
- Date range selector
- Resource type filters

**Step 3: Show Drill-Down Capabilities**

Click on a recommendation to show:
- Detailed resource information
- Historical trends
- Related recommendations

---

## Customer Q&A Preparation

### Common Questions and Answers

**Q: How does this compare to Azure Advisor?**
> "Azure Advisor provides generic recommendations, while AOE gives you customizable recommendations based on your organization's specific policies. You can set custom thresholds, exclude certain resources, and integrate with your existing processes."

**Q: What's the cost to run this?**
> "The toolkit itself is free and open-source. You'll pay for the Azure resources it uses - typically $200-500/month depending on data volume. The ROI usually exceeds 10x within the first quarter."

**Q: How long does implementation take?**
> "Core deployment takes 2-4 hours. Full configuration with custom policies typically takes 1-2 weeks. Data starts flowing immediately after deployment."

**Q: Does it support multi-cloud?**
> "FinOps Hubs use the FOCUS schema, which is cloud-agnostic. You can ingest AWS and GCP cost data for unified reporting, though native recommendations are Azure-focused."

**Q: What permissions are required?**
> "Deployment requires Owner access on the subscription. Ongoing operation needs Reader access to monitored subscriptions and Contributor to the toolkit resource groups."

**Q: How does data security work?**
> "All data stays in your Azure tenant. The toolkit uses managed identities for authentication - no secrets stored. You can enable private endpoints for full network isolation."

---

## Post-Demo Actions

### Immediate Follow-Up

1. **Send Demo Recording** (if recorded)
2. **Share Documentation Links:**
   - [FinOps Toolkit Documentation](https://aka.ms/ftk/docs)
   - [Azure Optimization Engine](https://aka.ms/AzureOptimizationEngine)
   - [Copilot Studio Setup](https://learn.microsoft.com/en-us/cloud-computing/finops/toolkit/hubs/configure-ai-copilot-studio)

### Implementation Resources

| Resource | Link |
|----------|------|
| GitHub Repository | https://github.com/microsoft/finops-toolkit |
| Deployment Guide | https://aka.ms/ftk/deploy |
| Community Forum | https://github.com/microsoft/finops-toolkit/discussions |
| Issue Reporting | https://github.com/microsoft/finops-toolkit/issues |

### Success Metrics to Track

After customer deployment, schedule a follow-up to review:

- [ ] Cost reduction achieved (target: 15-30%)
- [ ] Recommendation adoption rate
- [ ] Report usage frequency
- [ ] User feedback and additional requirements

---

## Appendix: Quick Reference Commands

### Verify Deployment Status

```bash
# Check FinOps Hub
az resource list --resource-group rg-finops-hub -o table

# Check AOE
az resource list --resource-group <aoe-prefix>-rg -o table

# Check recent cost data
az storage blob list --account-name <hub-storage-account> \
  --container-name ingestion --query "[?properties.createdOn > '<yyyy-mm-dd>']" -o table
```

### Useful KQL Queries for Live Demo

```kusto
// Top 10 subscriptions by cost (last 30 days)
Costs_v1_2()
| where ChargePeriodStart >= ago(30d)
| summarize Cost = sum(EffectiveCost) by SubAccountName
| top 10 by Cost desc

// Month-over-month cost change
Costs_v1_2()
| where ChargePeriodStart >= startofmonth(ago(60d))
| summarize Cost = sum(EffectiveCost) by Month = startofmonth(ChargePeriodStart)
| order by Month asc

// Savings summary
Costs_v1_2()
| where ChargePeriodStart >= startofmonth(ago(30d))
| summarize
    ListCost = sum(ListCost),
    EffectiveCost = sum(EffectiveCost),
    Savings = sum(ListCost - EffectiveCost)
| extend SavingsRate = 100.0 * Savings / ListCost
```

---

*Last Updated: September 2026*
*Version: 1.0*
*FinOps Toolkit Version: v14*
