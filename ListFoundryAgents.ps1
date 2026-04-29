<#
.SYNOPSIS
    Lists all agents (assistants) and published Agent Applications across Azure AI Foundry projects.

.DESCRIPTION
    Queries Azure Resource Graph to discover AI Foundry projects, then calls each
    project's data plane API to list unpublished agents (assistants) and uses the
    ARM API to list published Agent Applications and their deployments.

.PARAMETER ProjectId
    (Optional) The full Azure resource ID of a specific AI Foundry project.
    If omitted, the script lists agents for all discovered projects.

.EXAMPLE
    # List agents across all AI Foundry projects
    .\ListFoundryAgents.ps1

.PARAMETER ExportCsv
    (Optional) Path to a CSV file to export the results.
    If specified, all agents found will be exported to the given CSV file.

.PARAMETER ExportExcel
    (Optional) Path to an Excel (.xlsx) file to export the results with rich formatting:
    styled header, frozen header row, auto-filter, auto-sized columns, banded rows,
    conditional color-coding on the Status column, and a summary sheet.
    Requires the ImportExcel PowerShell module.

.EXAMPLE
    # List agents for a specific project
    .\ListFoundryAgents.ps1 -ProjectId "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>"

.EXAMPLE
    # Export all agents to CSV
    .\ListFoundryAgents.ps1 -ExportCsv ".\agents.csv"

.EXAMPLE
    # Export all agents to a styled Excel workbook
    .\ListFoundryAgents.ps1 -ExportExcel ".\agents.xlsx"

.NOTES
    Requires the Az.Accounts and Az.ResourceGraph PowerShell modules.
    Install them with:
        Install-Module -Name Az.Accounts, Az.ResourceGraph -Scope CurrentUser
    For -ExportExcel, also install:
        Install-Module -Name ImportExcel -Scope CurrentUser
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectId,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [string]$ExportExcel
)

# Check required modules
$requiredModules = @('Az.Accounts', 'Az.ResourceGraph')
if ($ExportExcel) { $requiredModules += 'ImportExcel' }
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
    $baseFilter = "type =~ 'Microsoft.CognitiveServices/accounts/projects' and id startswith '$ProjectId'"
    $notFoundMessage = "No projects found under: $ProjectId"
} else {
    # Get all AI Foundry projects across all subscriptions
    $baseFilter = "type =~ 'Microsoft.CognitiveServices/accounts/projects'"
    $notFoundMessage = "No projects found."
}

# First, count total projects so we can page through them in batches of 1000
# (Azure Resource Graph caps a single page at 1000 results, so we paginate via SkipToken)
$countQuery = "resources | where $baseFilter | summarize Count = count()"
try {
    $countResult = Search-AzGraph -Query $countQuery
    $totalProjects = [int]$countResult.Count
} catch {
    Write-Host "Failed to count projects: $($_.Exception.Message)" -ForegroundColor Red
    exit
}

if ($totalProjects -eq 0) {
    Write-Output $notFoundMessage
    exit
}

Write-Host "Found $totalProjects AI Foundry project(s). Retrieving in batches of 1000..." -ForegroundColor Cyan

$pageQuery = "resources | where $baseFilter | project name, id, subscriptionId, resourceGroup, properties"
$projects = @()
$skipToken = $null
$pageNumber = 0
do {
    $pageNumber++
    if ($skipToken) {
        $page = Search-AzGraph -Query $pageQuery -First 1000 -SkipToken $skipToken
    } else {
        $page = Search-AzGraph -Query $pageQuery -First 1000
    }

    if ($page) {
        $projects += $page
        Write-Host "  Retrieved page $pageNumber ($($page.Count) project(s)); total so far: $($projects.Count)/$totalProjects" -ForegroundColor DarkGray
    }

    $skipToken = $page.SkipToken
} while ($skipToken)

if (-not $projects -or $projects.Count -eq 0) {
    Write-Output $notFoundMessage
    exit
}

# Get access token for the data plane and ARM
$token = (Get-AzAccessToken -ResourceUrl "https://ai.azure.com" -AsSecureString).Token
$tokenPlain = [System.Net.NetworkCredential]::new('', $token).Password

$armToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -AsSecureString).Token
$armTokenPlain = [System.Net.NetworkCredential]::new('', $armToken).Password

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
                    SubscriptionId  = $project.subscriptionId
                    Project         = $project.name
                    ResourceGroup   = $project.resourceGroup
                    AgentName       = $agent.name
                    AgentId         = $agent.id
                    Model           = $agent.model
                    Status          = "Unpublished"
                    ApplicationName = ''
                    DeploymentName  = ''
                    DeploymentType  = ''
                    DeploymentState = ''
                    CreatedAt       = $agent.created_at
                    Instructions    = $agent.instructions
                }
            }
        } else {
            Write-Host "  No agents found." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($_.ErrorDetails.Message) {
            Write-Host "  Details: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        }
    }

    # List published Agent Applications (ARM API)
    Write-Host "  Published Agent Applications:" -ForegroundColor Green
    $armApiVersions = @('2025-10-01-preview', '2025-12-01', '2025-04-01-preview')
    $appsResponse = $null
    foreach ($armApiVer in $armApiVersions) {
        $appsUrl = "https://management.azure.com$($project.id)/applications?api-version=$armApiVer"
        try {
            $appsResponse = Invoke-RestMethod -Method GET -Uri $appsUrl -Headers @{
                Authorization = "Bearer $armTokenPlain"
            }
            break  # success — stop trying versions
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 400 -or $statusCode -eq 404) {
                continue   # API version not supported, try next
            }
            Write-Host "    Error listing applications: $($_.Exception.Message)" -ForegroundColor Yellow
            break
        }
    }

    if ($appsResponse -and $appsResponse.value) {
        foreach ($app in $appsResponse.value) {
            $appName       = $app.name
            $agentNames    = ($app.properties.agents | ForEach-Object { $_.agentName }) -join ', '
            $appCreatedAt  = if ($app.systemData.createdAt) { $app.systemData.createdAt } else { '' }
            Write-Host "    Application: $appName"
            Write-Host "    Agent(s):    $agentNames"
            Write-Host "    Created:     $appCreatedAt" -ForegroundColor Gray

            # Get deployments for this application
            $deploymentsUrl = "https://management.azure.com$($app.id)/agentdeployments?api-version=$armApiVer"
            $hasDeployments = $false
            try {
                $deploymentsResponse = Invoke-RestMethod -Method GET -Uri $deploymentsUrl -Headers @{
                    Authorization = "Bearer $armTokenPlain"
                }
                if ($deploymentsResponse.value) {
                    $hasDeployments = $true
                    foreach ($deployment in $deploymentsResponse.value) {
                        $deployName   = $deployment.name
                        $deployType   = $deployment.properties.deploymentType
                        $deployState  = $deployment.properties.state
                        $deployAgents = ($deployment.properties.agents | ForEach-Object { "$($_.agentName) v$($_.agentVersion)" }) -join ', '
                        Write-Host "      Deployment:  $deployName" -ForegroundColor White
                        Write-Host "        Type:      $deployType"
                        Write-Host "        State:     $deployState"
                        Write-Host "        Agent(s):  $deployAgents"

                        # One CSV row per deployment for granularity
                        $allAgents += [PSCustomObject]@{
                            SubscriptionId  = $project.subscriptionId
                            Project         = $project.name
                            ResourceGroup   = $project.resourceGroup
                            AgentName       = $agentNames
                            AgentId         = $app.id
                            Model           = ''
                            Status          = "Published"
                            ApplicationName = $appName
                            DeploymentName  = $deployName
                            DeploymentType  = $deployType
                            DeploymentState = $deployState
                            CreatedAt       = $appCreatedAt
                            Instructions    = ''
                        }
                    }
                }
            } catch {
                Write-Host "      Could not retrieve deployments." -ForegroundColor Yellow
            }

            # If no deployments, still record the application
            if (-not $hasDeployments) {
                $allAgents += [PSCustomObject]@{
                    SubscriptionId  = $project.subscriptionId
                    Project         = $project.name
                    ResourceGroup   = $project.resourceGroup
                    AgentName       = $agentNames
                    AgentId         = $app.id
                    Model           = ''
                    Status          = "Published (no deployments)"
                    ApplicationName = $appName
                    DeploymentName  = ''
                    DeploymentType  = ''
                    DeploymentState = ''
                    CreatedAt       = $appCreatedAt
                    Instructions    = ''
                }
            }
            Write-Host ""
        }
    } elseif (-not $appsResponse) {
        Write-Host "    Applications API not available for this project." -ForegroundColor DarkGray
    } else {
        Write-Host "    No published applications found." -ForegroundColor DarkGray
    }
}

# Export to CSV if requested
if ($ExportCsv) {
    if ($allAgents.Count -gt 0) {
        # Inject a timestamp before the extension to avoid overwriting previous exports
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $directory = [System.IO.Path]::GetDirectoryName($ExportCsv)
        $fileName  = [System.IO.Path]::GetFileNameWithoutExtension($ExportCsv)
        $extension = [System.IO.Path]::GetExtension($ExportCsv)
        if ([string]::IsNullOrEmpty($extension)) { $extension = '.csv' }
        $timestampedName = "$fileName-$timestamp$extension"
        $exportPath = if ([string]::IsNullOrEmpty($directory)) {
            $timestampedName
        } else {
            Join-Path -Path $directory -ChildPath $timestampedName
        }

        $allAgents | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
        $resolvedPath = (Resolve-Path -Path $exportPath).Path
        Write-Host "Exported $($allAgents.Count) agent(s) to $exportPath" -ForegroundColor Green
        Write-Host "CSV file path: $resolvedPath" -ForegroundColor Green
    } else {
        Write-Host "No agents found to export." -ForegroundColor Yellow
    }
}

# Export to Excel if requested
if ($ExportExcel) {
    if ($allAgents.Count -gt 0) {
        Import-Module ImportExcel -ErrorAction Stop

        # Inject a timestamp before the extension to avoid overwriting previous exports
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $directory = [System.IO.Path]::GetDirectoryName($ExportExcel)
        $fileName  = [System.IO.Path]::GetFileNameWithoutExtension($ExportExcel)
        $extension = [System.IO.Path]::GetExtension($ExportExcel)
        if ([string]::IsNullOrEmpty($extension)) { $extension = '.xlsx' }
        $timestampedName = "$fileName-$timestamp$extension"
        $excelPath = if ([string]::IsNullOrEmpty($directory)) {
            $timestampedName
        } else {
            Join-Path -Path $directory -ChildPath $timestampedName
        }

        # Remove pre-existing file (defensive — timestamp already prevents collisions)
        if (Test-Path $excelPath) { Remove-Item $excelPath -Force }

        # ---------- Summary sheet ----------
        $totalAgents       = $allAgents.Count
        $unpublishedCount  = ($allAgents | Where-Object { $_.Status -eq 'Unpublished' }).Count
        $publishedCount    = ($allAgents | Where-Object { $_.Status -like 'Published*' }).Count
        $distinctProjects  = ($allAgents | Select-Object -ExpandProperty Project -Unique).Count
        $distinctSubs      = ($allAgents | Select-Object -ExpandProperty SubscriptionId -Unique).Count

        $summary = [ordered]@{
            'Report generated'        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            'Total rows'              = $totalAgents
            'Unpublished agents'      = $unpublishedCount
            'Published deployments'   = $publishedCount
            'Distinct projects'       = $distinctProjects
            'Distinct subscriptions'  = $distinctSubs
        }
        $summaryRows = $summary.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{ Metric = $_.Key; Value = $_.Value }
        }

        $titleStyle = New-ExcelStyle -Range 'A1:B1' -BackgroundColor '#1F4E78' -FontColor White `
            -Bold -FontSize 14 -HorizontalAlignment Center -VerticalAlignment Center

        $summaryExcel = $summaryRows | Export-Excel -Path $excelPath `
            -WorksheetName 'Summary' `
            -StartRow 3 `
            -AutoSize `
            -BoldTopRow `
            -TableName 'SummaryTable' `
            -TableStyle 'Medium2' `
            -PassThru

        $summarySheet = $summaryExcel.Workbook.Worksheets['Summary']
        $summarySheet.Cells['A1:B1'].Merge = $true
        $summarySheet.Cells['A1'].Value = 'Azure AI Foundry Agents — Executive Summary'
        $summarySheet.Cells['A1'].Style.Font.Bold = $true
        $summarySheet.Cells['A1'].Style.Font.Size = 14
        $summarySheet.Cells['A1'].Style.Font.Color.SetColor([System.Drawing.Color]::White)
        $summarySheet.Cells['A1'].Style.Fill.PatternType = 'Solid'
        $summarySheet.Cells['A1'].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml('#1F4E78'))
        $summarySheet.Cells['A1'].Style.HorizontalAlignment = 'Center'
        $summarySheet.Cells['A1'].Style.VerticalAlignment = 'Center'
        $summarySheet.Row(1).Height = 24

        # Style summary header row (row 3)
        $summarySheet.Cells['A3:B3'].Style.Font.Bold = $true
        $summarySheet.Cells['A3:B3'].Style.Font.Color.SetColor([System.Drawing.Color]::White)
        $summarySheet.Cells['A3:B3'].Style.Fill.PatternType = 'Solid'
        $summarySheet.Cells['A3:B3'].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml('#1F4E78'))

        Close-ExcelPackage $summaryExcel

        # ---------- Agents sheet ----------
        $excel = $allAgents | Export-Excel -Path $excelPath `
            -WorksheetName 'Agents' `
            -AutoSize `
            -AutoFilter `
            -FreezeTopRow `
            -BoldTopRow `
            -TableName 'AgentsTable' `
            -TableStyle 'Medium2' `
            -PassThru

        $sheet = $excel.Workbook.Worksheets['Agents']

        # Style header row
        $headerRange = $sheet.Dimension.Address.Split(':')[0] + ':' + ($sheet.Cells[1, $sheet.Dimension.End.Column].Address)
        $sheet.Cells[$headerRange].Style.Font.Bold = $true
        $sheet.Cells[$headerRange].Style.Font.Color.SetColor([System.Drawing.Color]::White)
        $sheet.Cells[$headerRange].Style.Fill.PatternType = 'Solid'
        $sheet.Cells[$headerRange].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml('#1F4E78'))
        $sheet.Cells[$headerRange].Style.HorizontalAlignment = 'Center'
        $sheet.Row(1).Height = 22

        # Cap "Instructions" column width so the sheet stays readable
        $headerRow = $sheet.Cells[1, 1, 1, $sheet.Dimension.End.Column]
        foreach ($cell in $headerRow) {
            if ($cell.Value -eq 'Instructions') {
                $sheet.Column($cell.Start.Column).Width = 60
                $sheet.Column($cell.Start.Column).Style.WrapText = $true
            }
            if ($cell.Value -eq 'AgentId') {
                $sheet.Column($cell.Start.Column).Width = 50
            }
        }

        # Conditional formatting on Status column
        $statusColIndex = ($headerRow | Where-Object { $_.Value -eq 'Status' } | Select-Object -First 1).Start.Column
        if ($statusColIndex) {
            $lastRow = $sheet.Dimension.End.Row
            $statusRange = "$([OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($statusColIndex))2:$([OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($statusColIndex))$lastRow"
            Add-ConditionalFormatting -Worksheet $sheet -Range $statusRange -RuleType ContainsText -ConditionValue 'Unpublished' -BackgroundColor '#FFF2CC' -ForegroundColor '#7F6000'
            Add-ConditionalFormatting -Worksheet $sheet -Range $statusRange -RuleType ContainsText -ConditionValue 'Published (no deployments)' -BackgroundColor '#FCE4D6' -ForegroundColor '#9C5700'
            Add-ConditionalFormatting -Worksheet $sheet -Range $statusRange -RuleType ContainsText -ConditionValue 'Published' -BackgroundColor '#E2EFDA' -ForegroundColor '#375623'
        }

        # Move Summary tab first
        $excel.Workbook.Worksheets.MoveToStart('Summary')

        Close-ExcelPackage $excel

        $resolvedExcelPath = (Resolve-Path -Path $excelPath).Path
        Write-Host "Exported $($allAgents.Count) agent(s) to $excelPath" -ForegroundColor Green
        Write-Host "Excel file path: $resolvedExcelPath" -ForegroundColor Green
    } else {
        Write-Host "No agents found to export to Excel." -ForegroundColor Yellow
    }
}