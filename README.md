# ListFoundryAgents

A PowerShell script that discovers all Azure AI Foundry projects across your tenant using Azure Resource Graph (KQL) and lists both **unpublished agents** (assistants) and **published Agent Applications** in each project.

## Objectives

- **Discover** all AI Foundry projects across all subscriptions without being limited to a single subscription scope.
- **List unpublished agents** (assistants) in each project, including their name, ID, and model.
- **List published Agent Applications** and their deployments, including deployment type and state.
- **Export results** to CSV for reporting, auditing, or inventory purposes.
- **Filter** by a specific AI Foundry account to scope the query to a subset of projects.

## Prerequisites

- **Azure subscription** with access to AI Foundry projects.
- **PowerShell 5.1+** (Windows PowerShell) or **PowerShell 7+** (cross-platform).
- **Azure PowerShell modules**:
  - `Az.Accounts` — for authentication (`Connect-AzAccount`, `Get-AzAccessToken`).
  - `Az.ResourceGraph` — for cross-subscription resource discovery (`Search-AzGraph`).
- **Permissions**:
  - The signed-in user must have **Reader** access to the subscriptions containing AI Foundry resources (for Resource Graph queries).
  - The signed-in user must have **Azure AI User** (or equivalent) role on the AI Foundry projects to call the data plane API.

## Environment Setup

### 1. Install required PowerShell modules

```powershell
Install-Module -Name Az.Accounts, Az.ResourceGraph -Scope CurrentUser
```

### 2. Authenticate to Azure

```powershell
Connect-AzAccount
```

> **Note:** The script automatically checks if you're already authenticated and only prompts for login if needed.

## Usage

### List agents across all AI Foundry projects

```powershell
.\ListFoundryAgents.ps1
```

### List agents for projects under a specific AI Foundry account

```powershell
.\ListFoundryAgents.ps1 -ProjectId "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account-name>"
```

### Export results to CSV

```powershell
.\ListFoundryAgents.ps1 -ExportCsv ".\agents.csv"
```

### Combine parameters

```powershell
.\ListFoundryAgents.ps1 -ProjectId "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account-name>" -ExportCsv ".\agents.csv"
```

## Parameters

| Parameter    | Required | Description |
|-------------|----------|-------------|
| `ProjectId` | No       | The full Azure resource ID of an AI Foundry account (hub). When provided, only projects under this account are queried. If omitted, all projects across all subscriptions are queried. |
| `ExportCsv` | No       | Path to a CSV file. When provided, all discovered agents are exported to this file. |

## Output

### Console output

```
Project: my-foundry-project
  Subscription: 12345678-1234-1234-1234-123456789abc
  Resource Group: my-rg

  Printing agents...
  Agent: MyAgent
  ID:    asst_abc123def456
  Model: gpt-4.1

  Published Agent Applications:
    Application: my-published-app
    Agent(s):    MyAgent
    Created:     2025-10-15T08:30:00Z
      Deployment:  prod-deployment
        Type:      Managed
        State:     Running
        Agent(s):  MyAgent v1
```

### CSV columns

| Column           | Description |
|-----------------|-------------|
| `SubscriptionId` | Azure subscription ID containing the project |
| `Project`        | Name of the AI Foundry project |
| `ResourceGroup`  | Azure resource group containing the project |
| `AgentName`      | Name of the agent |
| `AgentId`        | Unique identifier of the agent or application resource ID |
| `Model`          | Model deployment used by the agent (empty for published apps) |
| `Status`         | `Unpublished`, `Published`, or `Published (no deployments)` |
| `ApplicationName`| Name of the published Agent Application (empty for unpublished) |
| `DeploymentName` | Name of the deployment (empty for unpublished or undeployed apps) |
| `DeploymentType` | Deployment type, e.g. `Managed` (empty for unpublished) |
| `DeploymentState`| Deployment state, e.g. `Running` (empty for unpublished) |
| `CreatedAt`      | Creation timestamp (Unix for unpublished, ISO 8601 for published) |
| `Instructions`   | System instructions configured for the agent (empty for published apps) |

## How It Works

1. **Authentication** — Checks for an existing Azure context; prompts login if not authenticated.
2. **Module validation** — Verifies that `Az.Accounts` and `Az.ResourceGraph` are installed.
3. **Project discovery** — Uses `Search-AzGraph` with KQL to find all `Microsoft.CognitiveServices/accounts/projects` resources, including their data plane endpoints.
4. **Token acquisition** — Obtains bearer tokens for both the data plane (`https://ai.azure.com`) and ARM (`https://management.azure.com`).
5. **Unpublished agent enumeration** — For each project, calls `GET {endpoint}/assistants?api-version=2025-05-15-preview` on the project's data plane endpoint.
6. **Published agent enumeration** — For each project, calls the ARM API to list Agent Applications (`GET .../applications`) and their deployments (`GET .../agentdeployments`). Automatically tries multiple API versions for compatibility.
7. **Output** — Displays results in the console and optionally exports to CSV. Published apps produce one CSV row per deployment for granularity.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `No projects found` | Verify you have Reader access to subscriptions with AI Foundry resources. |
| `401 Unauthorized` | Ensure you have the **Azure AI User** role on the project. Re-authenticate with `Connect-AzAccount`. |
| `No data plane endpoint found` | The project may not have been fully provisioned. Check the project in the Azure portal. |
| Missing modules error | Run `Install-Module -Name Az.Accounts, Az.ResourceGraph -Scope CurrentUser`. |

## References & Documentation

### Azure AI Foundry

- [Microsoft Foundry documentation](https://learn.microsoft.com/azure/foundry/)
- [What is Foundry Agent Service?](https://learn.microsoft.com/azure/foundry/agents/overview)
- [Publish and share agents in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-agent)

### APIs used in this script

- **Data plane — List Assistants**: `GET {endpoint}/assistants?api-version=2025-05-15-preview` — lists unpublished agents (assistants) in a project via the data plane endpoint.
- **ARM — Agent Applications**: [`Microsoft.CognitiveServices/accounts/projects/applications`](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/projects/applications) — lists published Agent Applications and their deployments via Azure Resource Manager.
- **Azure Resource Graph**: [`Search-AzGraph`](https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph) — cross-subscription KQL queries against Azure Resource Manager.

### Azure PowerShell modules

- [`Az.Accounts`](https://learn.microsoft.com/powershell/module/az.accounts/) — authentication and token acquisition (`Connect-AzAccount`, `Get-AzAccessToken`).
- [`Az.ResourceGraph`](https://learn.microsoft.com/powershell/module/az.resourcegraph/) — Azure Resource Graph queries.

### Authentication & permissions

- [Azure RBAC built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles)
- [Azure AI services RBAC roles](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry)

## License

This project is provided as-is with no warranty. Use at your own risk.
