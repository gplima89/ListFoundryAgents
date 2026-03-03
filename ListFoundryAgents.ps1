<#
.SYNOPSIS
    Lists all agents (assistants) across Azure AI Foundry projects.

.DESCRIPTION
    Queries Azure Resource Graph to discover AI Foundry projects, then calls each
    project's data plane API to list agents. Supports querying all projects across
    all subscriptions or filtering by a specific project resource ID.

.PARAMETER ProjectId
    (Optional) The full Azure resource ID of a specific AI Foundry project.
    If omitted, the script lists agents for all discovered projects.

.EXAMPLE
    # List agents across all AI Foundry projects
    .\ListFoundryAgents.ps1

.PARAMETER ExportCsv
    (Optional) Path to a CSV file to export the results.
    If specified, all agents found will be exported to the given CSV file.

.EXAMPLE
    # List agents for a specific project
    .\ListFoundryAgents.ps1 -ProjectId "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>"

.EXAMPLE
    # Export all agents to CSV
    .\ListFoundryAgents.ps1 -ExportCsv ".\agents.csv"

.NOTES
    Requires the Az.Accounts and Az.ResourceGraph PowerShell modules.
    Install them with:
        Install-Module -Name Az.Accounts, Az.ResourceGraph -Scope CurrentUser
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectId,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsv
)

# Check required modules
$requiredModules = @('Az.Accounts', 'Az.ResourceGraph')
$missingModules = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missingModules) {
    Write-Host "The following required PowerShell modules are not installed:" -ForegroundColor Red
    $missingModules | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Install them by running:" -ForegroundColor Yellow
    Write-Host "  Install-Module -Name $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Yellow
    exit
}

# Login only if not already connected
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount
    }
} catch {
    Connect-AzAccount
}

# Get AI Foundry projects
if ($ProjectId) {
    # Filter projects under a specific AI Foundry account (hub)
    $query = "resources | where type =~ 'Microsoft.CognitiveServices/accounts/projects' and id startswith '$ProjectId' | project name, id, subscriptionId, resourceGroup, properties"
    $projects = Search-AzGraph -Query $query -First 1000
    if (-not $projects) {
        Write-Output "No projects found under: $ProjectId"
        exit
    }
} else {
    # Get all AI Foundry projects across all subscriptions
    $query = "resources | where type =~ 'Microsoft.CognitiveServices/accounts/projects' | project name, id, subscriptionId, resourceGroup, properties"
    $projects = Search-AzGraph -Query $query -First 1000
    if (-not $projects) {
        Write-Output "No projects found."
        exit
    }
}

# Get access token for the Cognitive Services data plane
$token = (Get-AzAccessToken -ResourceUrl "https://ai.azure.com" -AsSecureString).Token
$tokenPlain = [System.Net.NetworkCredential]::new('', $token).Password

# Collect results for CSV export
$allAgents = @()

foreach ($project in $projects) {
    Write-Host "Project: $($project.name)" -ForegroundColor Cyan
    Write-Host "  Subscription: $($project.subscriptionId)" -ForegroundColor Gray
    Write-Host "  Resource Group: $($project.resourceGroup)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Printing agents..." -ForegroundColor Green

    # Get the data plane endpoint from the project properties
    $endpoint = $project.properties.endpoints.'AI Foundry API'
    if (-not $endpoint) {
        Write-Host "  No data plane endpoint found, skipping." -ForegroundColor Yellow
        continue
    }

    # Build Foundry Agents data plane URL
    $url = "$endpoint/assistants?api-version=2025-05-15-preview"

    # Call Foundry Agents API (data plane)
    try {
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers @{
            Authorization = "Bearer $tokenPlain"
        }

        # Print agents
        if ($response.data) {
            foreach ($agent in $response.data) {
                Write-Host "  Agent: $($agent.name)"
                Write-Host "  ID:    $($agent.id)"
                Write-Host "  Model: $($agent.model)"
                Write-Host ""

                $allAgents += [PSCustomObject]@{
                    SubscriptionId = $project.subscriptionId
                    Project        = $project.name
                    ResourceGroup  = $project.resourceGroup
                    AgentName      = $agent.name
                    AgentId        = $agent.id
                    Model          = $agent.model
                    CreatedAt      = $agent.created_at
                    Instructions   = $agent.instructions
                }
            }
        } else {
            Write-Host "  No agents found."
        }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($_.ErrorDetails.Message) {
            Write-Host "  Details: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        }
    }
}

# Export to CSV if requested
if ($ExportCsv) {
    if ($allAgents.Count -gt 0) {
        $allAgents | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($allAgents.Count) agent(s) to $ExportCsv" -ForegroundColor Green
    } else {
        Write-Host "No agents found to export." -ForegroundColor Yellow
    }
}