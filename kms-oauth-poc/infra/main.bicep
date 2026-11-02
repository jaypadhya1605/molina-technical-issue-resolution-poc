// Molina KMS - OAuth-only, private-network PoC (core infrastructure)
// Every data-plane hop is Entra ID (managed identity / OAuth). No API keys, no shared keys, no secrets.
targetScope = 'resourceGroup'

@description('Azure region. Defaults to the resource group location (South Central US).')
param location string = resourceGroup().location

@description('Object ID of the demo presenter. Gets AI Search data-plane roles for setup and inspection.')
param demoUserObjectId string

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param demoUserPrincipalType string = 'User'

@description('Admin user name for the KMS publisher VM. The VM has no public IP and is operated with Run Command only.')
param vmAdminUsername string = 'kmsadmin'

@secure()
@description('One-time random password generated in memory by the deploy script. Never stored.')
param vmAdminPassword string

@description('Publisher email for API Management.')
param apimPublisherEmail string = 'jaypadhya@microsoft.com'

@description('Embedding deployment capacity (thousands of tokens per minute).')
param embeddingCapacity int = 350

@description('Embedding deployment SKU. DataZoneStandard keeps processing inside the US data zone.')
param embeddingSkuName string = 'DataZoneStandard'

param tags object = {
  project: 'molina-kms-oauth-poc'
  owner: 'jaypadhya'
  purpose: 'customer-demo'
  'data-classification': 'synthetic-only'
}

var suffix = substring(uniqueString(resourceGroup().id), 0, 5)
var names = {
  vnet: 'vnet-kms-poc'
  law: 'log-kms-poc-${suffix}'
  storage: 'stkmspoc${suffix}'
  search: 'srch-kms-poc-${suffix}'
  aoai: 'aoai-kms-poc-${suffix}'
  apim: 'apim-kms-poc-${suffix}'
  uami: 'id-kms-agent-app'
  vm: 'vm-kms-app'
}
var containerName = 'kms-articles'
var embeddingDeploymentName = 'text-embedding-3-large'

var roleIds = {
  storageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  cognitiveServicesOpenAIUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
}

var privateDnsZoneNames = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.dfs.${environment().suffixes.storage}'
  'privatelink.search.windows.net'
  'privatelink.openai.azure.com'
  'privatelink.azure-api.net'
]

// ---------------------------------------------------------------- Monitoring
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.law
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------- Network
resource nsgPe 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-private-endpoints'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource nsgApim 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-apim-outbound'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-KeyVault-Outbound'
        properties: {
          description: 'Required dependency for API Management v2 virtual network integration'
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource nsgVm 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-kms-vm'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: names.vnet
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.60.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.60.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: {
            id: nsgPe.id
          }
        }
      }
      {
        name: 'snet-apim-outbound'
        properties: {
          addressPrefix: '10.60.2.0/24'
          networkSecurityGroup: {
            id: nsgApim.id
          }
          delegations: [
            {
              name: 'apim-standardv2-integration'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-kms-vm'
        properties: {
          addressPrefix: '10.60.3.0/24'
          networkSecurityGroup: {
            id: nsgVm.id
          }
          defaultOutboundAccess: true
        }
      }
    ]
  }
}

resource snetPe 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-private-endpoints'
}

resource snetApim 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-apim-outbound'
}

resource snetVm 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-kms-vm'
}

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zone in privateDnsZoneNames: {
    name: zone
    location: 'global'
    tags: tags
  }
]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (zone, i) in privateDnsZoneNames: {
    parent: dnsZones[i]
    name: 'link-${names.vnet}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
]

// ---------------------------------------------------------------- ADLS Gen2 (published KMS articles)
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: names.storage
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    accessTier: 'Hot'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

// Native blob soft delete drives AI Search deletion detection (blob versioning must stay off).
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------- Azure AI Search
resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: names.search
  location: location
  tags: tags
  sku: {
    name: 'standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    disableLocalAuth: true
    // Enabled only while the PoC is being configured; scripts\Set-SearchPublicAccess.ps1 -State Disabled locks it down.
    // Re-running this template re-enables it, so run that script again after any redeploy.
    publicNetworkAccess: 'enabled'
    semanticSearch: 'free'
  }
}

resource searchDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: search
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------- Azure OpenAI (embeddings)
resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: names.aoai
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: names.aoai
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: embeddingDeploymentName
  sku: {
    name: embeddingSkuName
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-large'
      version: '1'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource aoaiDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: aoai
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------- API Management (Standard v2) = the OAuth gateway
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: names.apim
  location: location
  tags: tags
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: 'Molina KMS PoC (Microsoft)'
    // Outbound VNet integration: APIM reaches AI Search and Azure OpenAI over their private endpoints.
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: snetApim.id
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource apimDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: apim
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------- Identities and the KMS publisher VM
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.uami
  location: location
  tags: tags
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${names.vm}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: snetVm.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: names.vm
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s_v2'
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: names.vm
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------- Private endpoints (inbound)
module peBlob 'modules/private-endpoint.bicep' = {
  name: 'pe-storage-blob'
  params: {
    name: 'pe-${names.storage}-blob'
    location: location
    tags: tags
    subnetId: snetPe.id
    targetResourceId: storage.id
    groupId: 'blob'
    privateDnsZoneId: dnsZones[0].id
  }
}

module peDfs 'modules/private-endpoint.bicep' = {
  name: 'pe-storage-dfs'
  params: {
    name: 'pe-${names.storage}-dfs'
    location: location
    tags: tags
    subnetId: snetPe.id
    targetResourceId: storage.id
    groupId: 'dfs'
    privateDnsZoneId: dnsZones[1].id
  }
  dependsOn: [
    peBlob
  ]
}

module peSearch 'modules/private-endpoint.bicep' = {
  name: 'pe-search'
  params: {
    name: 'pe-${names.search}'
    location: location
    tags: tags
    subnetId: snetPe.id
    targetResourceId: search.id
    groupId: 'searchService'
    privateDnsZoneId: dnsZones[2].id
  }
}

module peAoai 'modules/private-endpoint.bicep' = {
  name: 'pe-aoai'
  params: {
    name: 'pe-${names.aoai}'
    location: location
    tags: tags
    subnetId: snetPe.id
    targetResourceId: aoai.id
    groupId: 'account'
    privateDnsZoneId: dnsZones[3].id
  }
  dependsOn: [
    embedding
  ]
}

module peApim 'modules/private-endpoint.bicep' = {
  name: 'pe-apim'
  params: {
    name: 'pe-${names.apim}'
    location: location
    tags: tags
    subnetId: snetPe.id
    targetResourceId: apim.id
    groupId: 'Gateway'
    privateDnsZoneId: dnsZones[4].id
  }
}

// ---------------------------------------------------------------- AI Search shared private links (outbound, created one at a time)
resource splBlob 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'spl-adls-blob'
  properties: {
    privateLinkResourceId: storage.id
    groupId: 'blob'
    requestMessage: 'Azure AI Search indexer to ADLS Gen2 (blob) - Molina KMS PoC'
  }
  dependsOn: [
    peSearch
    peDfs
  ]
}

resource splDfs 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'spl-adls-dfs'
  properties: {
    privateLinkResourceId: storage.id
    groupId: 'dfs'
    requestMessage: 'Azure AI Search indexer to ADLS Gen2 (dfs) - Molina KMS PoC'
  }
  dependsOn: [
    splBlob
  ]
}

resource splApim 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'spl-apim-gateway'
  properties: {
    privateLinkResourceId: apim.id
    groupId: 'Gateway'
    requestMessage: 'Azure AI Search embedding skill and vectorizer to APIM AI gateway - Molina KMS PoC'
  }
  dependsOn: [
    splDfs
    peApim
  ]
}

// ---------------------------------------------------------------- RBAC (least privilege, identity-only)
resource raSearchReadsStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, search.id, roleIds.storageBlobDataReader)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataReader)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'AI Search indexer reads published KMS articles'
  }
}

resource raVmWritesContainer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, vm.id, roleIds.storageBlobDataContributor)
  scope: container
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataContributor)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'KMS publisher writes/deletes article JSON in kms-articles only'
  }
}

resource raApimCallsAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoai.id, apim.id, roleIds.cognitiveServicesOpenAIUser)
  scope: aoai
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAIUser)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Only the APIM gateway identity may call the embedding model'
  }
}

resource raApimQueriesSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, apim.id, roleIds.searchIndexDataReader)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchIndexDataReader)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'APIM gateway queries the KMS index on behalf of authorized callers'
  }
}

resource raApimRunsIndexer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, apim.id, roleIds.searchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchServiceContributor)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'APIM gateway triggers the indexer and reads its status'
  }
}

resource raUserSearchContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, demoUserObjectId, roleIds.searchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchServiceContributor)
    principalId: demoUserObjectId
    principalType: demoUserPrincipalType
    description: 'PoC presenter - manage search objects'
  }
}

resource raUserIndexContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, demoUserObjectId, roleIds.searchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchIndexDataContributor)
    principalId: demoUserObjectId
    principalType: demoUserPrincipalType
    description: 'PoC presenter - inspect index content'
  }
}

// ---------------------------------------------------------------- Outputs
output suffix string = suffix
output location string = location
output storageAccountName string = storage.name
output containerName string = containerName
output searchServiceName string = search.name
output searchPrincipalId string = search.identity.principalId
output aoaiName string = aoai.name
output embeddingDeployment string = embeddingDeploymentName
output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output agentIdentityName string = uami.name
output agentClientId string = uami.properties.clientId
output agentPrincipalId string = uami.properties.principalId
output logAnalyticsWorkspaceName string = law.name
output logAnalyticsCustomerId string = law.properties.customerId
