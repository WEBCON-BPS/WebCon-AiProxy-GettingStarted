// ---------------------------------------------------------------------------
// AI Proxy - Getting Started sandbox
// Phase 2: Azure Container Instance running the AI Proxy in SelfHosted + KeyVault mode.
// Deploy AFTER infra.bicep + image push + KV secret seeding.
// Scope: resource group.
// ---------------------------------------------------------------------------

@description('Region')
param parLocation string = resourceGroup().location

@description('Container group name')
param parAciName string

@description('Full image reference in ACR, e.g. craipxgs1234.azurecr.io/webcon/aiproxy:gs')
param parImage string

@description('ACR login server, e.g. craipxgs1234.azurecr.io')
param parAcrLoginServer string

@description('Resource id of the user-assigned Managed Identity')
param parMiId string

@description('Client id of the user-assigned Managed Identity (for AZURE_CLIENT_ID)')
param parMiClientId string

@description('Key Vault URI, e.g. https://kvaipxgs1234.vault.azure.net/')
param parKvUri string

@description('Name of the KV secret holding the combined cert+key PEM. Since 2026.2.260.63 the app reads it from KV for all three roles: HTTPS server cert, mTLS trust, JWT signing key.')
param parSigningSecretName string = 'aiproxy-certificate-pem'

@description('DNS name label -> <label>.<region>.azurecontainer.io')
param parDnsNameLabel string

@description('Optional Application Insights connection string')
param parAppInsightsConnectionString string = ''

@description('Access key for the config UI (/config-ui) login')
@secure()
param parConfigAdminAccessKey string

@description('Resource tags')
param parTags object = {
  purpose: 'aiproxy-getting-started'
  disposable: 'true'
}

var varEnv = concat([
  {
    name: 'ASPNETCORE_ENVIRONMENT'
    value: 'Production'
  }
  {
    name: 'AppConfiguration__SelfHosted__Enabled'
    value: 'true'
  }
  {
    name: 'AppConfiguration__SelfHosted__UseAzureKeyVault'
    value: 'true'
  }
  {
    name: 'AppConfiguration__AzureKeyVault__Url'
    value: parKvUri
  }
  {
    // Was AppConfiguration__AzureKeyVault__SecretName (removed in 2026.2.260.63).
    name: 'AppConfiguration__SelfHosted__Certificate__SecretName'
    value: parSigningSecretName
  }
  {
    name: 'AZURE_CLIENT_ID'
    value: parMiClientId
  }
  {
    name: 'ConfigAdmin__AccessKey'
    value: parConfigAdminAccessKey
  }
  {
    // Force HTTP/1.1 on HTTPS so mTLS client-cert renegotiation works (h2 forbids it)
    name: 'Kestrel__Endpoints__Https__Protocols'
    value: 'Http1'
  }
  {
    name: 'Logging__LogLevel__Default'
    value: 'Information'
  }
  {
    name: 'Logging__LogLevel__Microsoft'
    value: 'Warning'
  }
], empty(parAppInsightsConnectionString) ? [] : [
  {
    name: 'AppConfiguration__ApplicationInsightsConnectionString'
    value: parAppInsightsConnectionString
  }
])

resource resAci 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: parAciName
  location: parLocation
  tags: parTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${parMiId}': {}
    }
  }
  properties: {
    osType: 'Linux'
    sku: 'Standard'
    restartPolicy: 'Always'
    imageRegistryCredentials: [
      {
        server: parAcrLoginServer
        identity: parMiId
      }
    ]
    containers: [
      {
        name: 'aiproxy'
        properties: {
          image: parImage
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 2
            }
          }
          ports: [
            {
              protocol: 'TCP'
              port: 8081
            }
            {
              protocol: 'TCP'
              port: 8080
            }
          ]
          environmentVariables: varEnv
        }
      }
    ]
    ipAddress: {
      type: 'Public'
      dnsNameLabel: parDnsNameLabel
      // Expose ONLY 8081 (HTTPS/mTLS) publicly. 8080 (plain HTTP, no mTLS) stays a container-internal
      // port so the Config UI / health are never reachable over unencrypted, cert-less HTTP from the internet.
      ports: [
        {
          protocol: 'TCP'
          port: 8081
        }
      ]
    }
  }
}

output outFqdn string = resAci.properties.ipAddress.fqdn
output outIp string = resAci.properties.ipAddress.ip
output outEndpoint string = 'https://${resAci.properties.ipAddress.fqdn}:8081'
