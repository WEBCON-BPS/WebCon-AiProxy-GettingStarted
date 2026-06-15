// ---------------------------------------------------------------------------
// AI Proxy - Getting Started sandbox (optional, -DeployFoundry)
// Creates a dedicated Azure AI Foundry (AIServices) account + project + a couple of
// model deployments, and wires the proxy's AiAzureEndpoint / AiAzureApiKey into Key Vault.
//
// Network model: Deny-by-default. The AI Proxy container's public IP is added as the ONLY
// allowed ipRule *after* deploy (see deploy.ps1) - so only the container reaches Foundry; the
// Portal and everyone else are blocked. This works because an ACI's outbound (egress) IP equals
// its inbound public IP (ipAddress.ip) and is stable across restarts.
//   IMPORTANT: Cognitive Services firewall changes are eventually-consistent and can take
//   ~10-30 minutes to fully propagate. Right after deploy the first AI calls may return
//   403 "Access denied due to Virtual Network/Firewall rules" until the rule settles.
//   (A private endpoint isn't used because it would require the container in a VNet, which
//    removes the public FQDN the Portal needs - an ACI is either public or VNet-joined.)
// Scope: resource group.
// ---------------------------------------------------------------------------

@description('Region for the AI Foundry account (must offer the chosen models)')
param parLocation string = 'swedencentral'

@description('AIServices (AI Foundry) account name; also the custom subdomain (globally unique, lowercase)')
param parAccountName string

@description('Default project name')
param parProjectName string

@description('Key Vault name to store AiAzureEndpoint / AiAzureApiKey')
param parKvName string

@description('Managed Identity principalId (granted Cognitive Services OpenAI User for optional Entra auth)')
param parMiPrincipalId string

@description('Capacity (x1000 TPM) per model deployment')
param parModelCapacity int = 10

@description('Resource tags')
param parTags object = {
  purpose: 'aiproxy-getting-started'
  disposable: 'true'
}

resource resFoundry 'Microsoft.CognitiveServices/accounts@2025-09-01' = {
  name: parAccountName
  location: parLocation
  tags: parTags
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    defaultProject: parProjectName
    customSubDomainName: parAccountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    // Deny by default. The container's public IP is added post-deploy as the only allowed caller.
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource resProject 'Microsoft.CognitiveServices/accounts/projects@2025-09-01' = {
  name: parProjectName
  parent: resFoundry
  location: parLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'AI Proxy getting-started project'
    displayName: parProjectName
  }
}

var varModels = [
  {
    name: 'gpt-4o-mini'
    format: 'OpenAI'
    model: 'gpt-4o-mini'
    version: '2024-07-18'
  }
  {
    name: 'text-embedding-3-small'
    format: 'OpenAI'
    model: 'text-embedding-3-small'
    version: '1'
  }
]

// Serial (batchSize 1) - Cognitive Services rejects parallel deployment creation on one account.
@batchSize(1)
resource resDeployments 'Microsoft.CognitiveServices/accounts/deployments@2026-03-01' = [for m in varModels: {
  parent: resFoundry
  name: m.name
  tags: parTags
  sku: {
    name: 'GlobalStandard'
    capacity: parModelCapacity
  }
  properties: {
    model: {
      format: m.format
      name: m.model
      version: m.version
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}]

// Optional: lets the MI call Foundry via Entra (UseDefaultAzureCredentials=true). Not needed for API-key auth.
resource resRoleOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resFoundry.id, parMiPrincipalId, 'Cognitive Services OpenAI User')
  scope: resFoundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: parMiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource resKv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: parKvName
}

resource resSecretEndpoint 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: resKv
  name: 'AiAzureEndpoint'
  properties: {
    value: 'https://${parAccountName}.openai.azure.com/openai/v1/'
  }
}

resource resSecretApiKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: resKv
  name: 'AiAzureApiKey'
  properties: {
    value: resFoundry.listKeys().key1
  }
}

output outFoundryName string = resFoundry.name
output outEndpoint string = 'https://${parAccountName}.openai.azure.com/openai/v1/'
output outDeployments array = [for m in varModels: m.name]
