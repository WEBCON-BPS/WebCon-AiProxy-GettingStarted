// ---------------------------------------------------------------------------
// AI Proxy - Getting Started sandbox (Azure Container Instance + mTLS + KeyVault)
// Phase 1: ACR + user-assigned Managed Identity + Key Vault + role assignments.
// Deploy this FIRST, then build/push the image and seed KV secrets, then aci.bicep.
// Scope: resource group.
// ---------------------------------------------------------------------------

@description('Region for all resources')
param parLocation string = resourceGroup().location

@description('Container Registry name (globally unique, 5-50 alphanumeric)')
param parAcrName string

@description('User-assigned Managed Identity name')
param parMiName string

@description('Key Vault name (globally unique, 3-24 chars)')
param parKvName string

@description('Object id (principalId) of the user/SP running the deploy - granted Key Vault Secrets Officer so it can seed secrets')
param parDeployerObjectId string

@description('Resource tags')
param parTags object = {
  purpose: 'aiproxy-getting-started'
  disposable: 'true'
}

// Built-in role definition ids
var varRoleAcrPull = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var varRoleKvSecretsUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var varRoleKvSecretsOfficer = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

resource resMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: parMiName
  location: parLocation
  tags: parTags
}

resource resAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: parAcrName
  location: parLocation
  tags: parTags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource resKv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: parKvName
  location: parLocation
  tags: parTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Sandbox: public access on so you can seed secrets and the MI can read over the internet.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// MI can pull the image from ACR
resource resRoleAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resAcr.id, resMi.id, 'AcrPull')
  scope: resAcr
  properties: {
    roleDefinitionId: varRoleAcrPull
    principalId: resMi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// MI can read secrets (signing key + provider api keys) from KV at runtime
resource resRoleKvUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resKv.id, resMi.id, 'Key Vault Secrets User')
  scope: resKv
  properties: {
    roleDefinitionId: varRoleKvSecretsUser
    principalId: resMi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Deployer can write secrets into KV (RBAC data-plane is NOT granted by Owner)
resource resRoleKvOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resKv.id, parDeployerObjectId, 'Key Vault Secrets Officer')
  scope: resKv
  properties: {
    roleDefinitionId: varRoleKvSecretsOfficer
    principalId: parDeployerObjectId
    principalType: 'User'
  }
}

output outAcrLoginServer string = resAcr.properties.loginServer
output outAcrName string = resAcr.name
output outMiId string = resMi.id
output outMiClientId string = resMi.properties.clientId
output outMiPrincipalId string = resMi.properties.principalId
output outKvName string = resKv.name
output outKvUri string = resKv.properties.vaultUri
