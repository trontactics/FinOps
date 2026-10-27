<#
.SYNOPSIS
    Post-deployment initialization for the Azure Optimization Engine (AOE) so every workbook has data
    right away instead of after its first scheduled run (up to a week for recommendations).

.DESCRIPTION
    1. Optionally grants the Microsoft Entra Global Reader role to the AOE Automation managed identity.
       Deploy-AzureOptimizationEngine.ps1 skips this in silent mode; without it the AAD objects export
       fails and the "Identities and Roles" workbook has no data.
    2. Seeds two inert rows in the AOE SQL Filters table. The Recommendations workbook queries
       AzureOptimizationSuppressionsV1_CL (and its InstanceId_g / InstanceName_s columns) directly, and
       that table only exists after at least one suppression is ingested. The seed rows use the all-zero
       recommendation sub-type ID, so they never match a real recommendation.
    3. Starts every scheduled AOE job once, in dependency order (exports -> ingests -> recommendations
       -> recommendation/suppression ingests), with the same parameters as its schedule, waiting for
       each wave to finish.

.EXAMPLE
    ./Initialize-AoeData.ps1 -NamePrefix finopsaoe01 -GrantGlobalReader
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $NamePrefix,
    [string] $ResourceGroupName = "$NamePrefix-rg",
    [string] $AutomationAccountName = "$NamePrefix-auto",
    [string] $SqlServerName = "$NamePrefix-sql",
    [string] $SqlDatabaseName = 'azureoptimization',
    [switch] $GrantGlobalReader,
    [switch] $SkipSuppressionSeed,
    [switch] $SkipRunbooks,
    [int] $WaveTimeoutMinutes = 90,
    [int] $IngestionSettleMinutes = 20
)

$ErrorActionPreference = 'Stop'
if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first.' }

$automation = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
$principalId = $automation.Identity.PrincipalId

#region Global Reader
if ($GrantGlobalReader)
{
    $globalReaderRoleId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
    $existing = Invoke-AzRestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$principalId' and roleDefinitionId eq '$globalReaderRoleId'"
    if (($existing.Content | ConvertFrom-Json).value.Count -gt 0)
    {
        Write-Host 'Global Reader already assigned.' -ForegroundColor Green
    }
    else
    {
        $body = @{ principalId = $principalId; roleDefinitionId = $globalReaderRoleId; directoryScopeId = '/' } | ConvertTo-Json
        $res = Invoke-AzRestMethod -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' -Payload $body
        if ($res.StatusCode -ge 300) { throw "Global Reader assignment failed ($($res.StatusCode)): $($res.Content)" }
        Write-Host 'Granted Global Reader to the AOE managed identity.' -ForegroundColor Green
    }
}
#endregion

#region Suppressions schema seed
if (-not $SkipSuppressionSeed)
{
    $sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName
    # Temporarily allow this machine's public IP, as Deploy-AzureOptimizationEngine.ps1 does
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
    $ruleName = 'Initialize-AoeData-temp'
    New-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName -FirewallRuleName $ruleName -StartIpAddress $myIp -EndIpAddress $myIp | Out-Null
    $token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/' -AsSecureString).Token | ConvertFrom-SecureString -AsPlainText
    $conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$($sqlServer.FullyQualifiedDomainName),1433;Database=$SqlDatabaseName;Encrypt=True;Connection Timeout=60;")
    $conn.AccessToken = $token
    try
    {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM [dbo].[Filters] WHERE Author = 'aoe-schema-seed')
BEGIN
    INSERT INTO [dbo].[Filters] (RecommendationSubTypeId, FilterType, InstanceId, FilterStartDate, FilterEndDate, Author, Notes, IsEnabled)
    VALUES
    ('00000000-0000-0000-0000-000000000000', 'Dismiss', '00000000-0000-0000-0000-000000000000', '2019-01-01', NULL, 'aoe-schema-seed', 'Creates the Suppressions table schema for workbooks; matches no recommendation.', 1),
    ('00000000-0000-0000-0000-000000000000', 'Dismiss', 'aoe-schema-seed', '2019-01-01', NULL, 'aoe-schema-seed', 'Creates the Suppressions table schema for workbooks; matches no recommendation.', 1)
END
"@
        $inserted = $cmd.ExecuteNonQuery()
        Write-Host $(if ($inserted -gt 0) { 'Seeded suppression schema rows.' } else { 'Suppression schema rows already present.' }) -ForegroundColor Green
    }
    finally
    {
        $conn.Close()
        Remove-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName -FirewallRuleName $ruleName -Force | Out-Null
    }
}
#endregion

#region Run every scheduled job once, in dependency order
if (-not $SkipRunbooks)
{
    $jobSchedules = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName |
        ForEach-Object { Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -JobScheduleId $_.JobScheduleId }

    $waves = [ordered]@{
        'Exports'                    = '^AzureOptimization_Export'
        'Ingests'                    = '^AzureOptimization_Ingest(?!Recommendations|Suppressions|RemediationLogs)'
        'Recommendations'            = '^AzureOptimization_RecommendationsWeekly$'
        'Recommendation ingests'     = '^AzureOptimization_Ingest(Recommendations|Suppressions)Weekly$'
    }

    $failures = @()
    foreach ($wave in $waves.GetEnumerator())
    {
        if ($wave.Key -eq 'Recommendations')
        {
            # Newly created Log Analytics custom tables take several minutes to become queryable.
            # Recommendation queries that run too early fail or return 0 results.
            Write-Host "Waiting $IngestionSettleMinutes minutes for Log Analytics ingestion to settle..." -ForegroundColor Cyan
            Start-Sleep -Seconds ($IngestionSettleMinutes * 60)
        }
        $items = @($jobSchedules | Where-Object ScheduleName -match $wave.Value)
        Write-Host "Starting wave '$($wave.Key)' ($($items.Count) jobs)..." -ForegroundColor Cyan
        $jobs = foreach ($item in $items)
        {
            $params = @{}
            if ($item.Parameters) { foreach ($key in $item.Parameters.Keys) { $params[$key] = $item.Parameters[$key] } }
            Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $item.RunbookName -Parameters $params
        }

        $deadline = (Get-Date).AddMinutes($WaveTimeoutMinutes)
        do
        {
            Start-Sleep -Seconds 30
            $states = $jobs | ForEach-Object { Get-AzAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Id $_.JobId }
            $pending = @($states | Where-Object Status -notin 'Completed', 'Failed', 'Stopped', 'Suspended')
            Write-Host "  $($states.Count - $pending.Count)/$($states.Count) finished"
        } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)

        $bad = @($states | Where-Object Status -ne 'Completed')
        foreach ($job in $bad) { $failures += "$($job.RunbookName): $($job.Status)" }
    }

    if ($failures)
    {
        Write-Host "Jobs that did not complete (check the job output in the Automation account):" -ForegroundColor Yellow
        $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host 'Price, reservation and savings plan exports fail without EA/MCA billing access; that is expected if DeployBenefitsUsageDependencies is n.' -ForegroundColor Yellow
    }
    else
    {
        Write-Host 'All AOE jobs completed.' -ForegroundColor Green
    }
}
#endregion
