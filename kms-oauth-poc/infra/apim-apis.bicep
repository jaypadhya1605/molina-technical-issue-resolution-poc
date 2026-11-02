// APIs, operations and policies for the KMS AI gateway (Azure API Management Standard v2).
// Deployed after main.bicep:  az deployment group create -g <rg> -n kms-poc-apim -f infra/apim-apis.bicep -p ...
targetScope = 'resourceGroup'

@description('Existing API Management instance name (from main.bicep output apimName).')
param apimName string

@description('Entra tenant ID that issues the OAuth tokens.')
param tenantId string = tenant().tenantId

@description('Application (client) ID of the "kms-ai-gateway-poc" app registration. Tokens must be issued for this audience.')
param gatewayAppId string

@description('Application (client) ID of the Azure AI Search system-assigned managed identity. Only this identity may call the embedding API.')
param searchMiAppId string

@description('Azure AI Search service name.')
param searchServiceName string

@description('Azure OpenAI account name.')
param aoaiName string

@description('The only embedding deployment exposed by the gateway.')
param embeddingDeployment string = 'text-embedding-3-large'

param indexName string = 'kms-knowledge-v2'
param indexerName string = 'kms-articles-indexer'
param searchApiVersion string = '2025-09-01'

@description('When true, every API rejects traffic that does not arrive through the APIM private endpoint.')
param requirePrivateLink bool = false

var aoaiEndpoint = 'https://${aoaiName}.openai.azure.com/'
var searchEndpoint = 'https://${searchServiceName}.search.windows.net'

var tokens = {
  __TENANT_ID__: tenantId
  __GATEWAY_APP_ID__: gatewayAppId
  __SEARCH_MI_APP_ID__: searchMiAppId
  __INDEX_NAME__: indexName
  __INDEXER_NAME__: indexerName
  __EMBEDDING_DEPLOYMENT__: embeddingDeployment
  __SEARCH_API_VERSION__: searchApiVersion
  __AOAI_ENDPOINT__: aoaiEndpoint
}

var policyOpenAi = reduce(items(tokens), loadTextContent('../apim/policies/openai-api.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyKmsApi = reduce(items(tokens), loadTextContent('../apim/policies/kms-api.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyWhoami = reduce(items(tokens), loadTextContent('../apim/policies/kms-whoami.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policySearch = reduce(items(tokens), loadTextContent('../apim/policies/kms-search.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyChunks = reduce(items(tokens), loadTextContent('../apim/policies/kms-article-chunks.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyStats = reduce(items(tokens), loadTextContent('../apim/policies/kms-stats.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyIngestRun = reduce(items(tokens), loadTextContent('../apim/policies/kms-ingest-run.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyIngestStatus = reduce(items(tokens), loadTextContent('../apim/policies/kms-ingest-status.xml'), (cur, next) => replace(string(cur), next.key, next.value))
var policyAiSearch = reduce(items(tokens), loadTextContent('../apim/policies/aisearch-api.xml'), (cur, next) => replace(string(cur), next.key, next.value))

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource nvPrivateLink 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'kms-require-private-link'
  properties: {
    displayName: 'kms-require-private-link'
    value: requirePrivateLink ? 'true' : 'false'
    secret: false
    tags: [ 'kms-poc' ]
  }
}

resource azureMonitorLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    isBuffered: true
  }
}

resource serviceDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerId: azureMonitorLogger.id
    alwaysLog: 'allErrors'
    logClientIp: true
    verbosity: 'information'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: { headers: [ 'Content-Length', 'Content-Type' ], body: { bytes: 0 } }
      response: { headers: [ 'x-kms-request-id' ], body: { bytes: 0 } }
    }
    backend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
  }
}

// ---------------------------------------------------------------------------
// API 1: /openai  - AI gateway for the AI Search embedding skill + vectorizer
// ---------------------------------------------------------------------------
resource apiOpenAi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    displayName: 'KMS AI Gateway - Azure OpenAI embeddings'
    description: 'Called only by Azure AI Search (embedding skill and vectorizer) with its managed identity. APIM calls Azure OpenAI with its own managed identity over a private endpoint.'
    path: 'openai'
    protocols: [ 'https' ]
    serviceUrl: '${aoaiEndpoint}openai'
    subscriptionRequired: false
    apiType: 'http'
  }
}

resource opEmbeddings 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiOpenAi
  name: 'embeddings'
  properties: {
    displayName: 'Create embeddings'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/embeddings'
    templateParameters: [
      { name: 'deployment-id', type: 'string', required: true }
    ]
  }
}

resource apiOpenAiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiOpenAi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyOpenAi
  }
  dependsOn: [ nvPrivateLink ]
}

// ---------------------------------------------------------------------------
// API 2: /kms  - curated KMS API (search, chunks, stats, pointer ingest)
// ---------------------------------------------------------------------------
resource apiKms 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'kms'
  properties: {
    displayName: 'KMS Knowledge API'
    description: 'OAuth-protected KMS API. Callers present Entra ID tokens for api://${gatewayAppId}; app roles KMS.Search / KMS.Ingest are enforced per operation. APIM calls AI Search with its managed identity.'
    path: 'kms'
    protocols: [ 'https' ]
    serviceUrl: searchEndpoint
    subscriptionRequired: false
    apiType: 'http'
  }
}

resource apiKmsPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiKms
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyKmsApi
  }
  dependsOn: [ nvPrivateLink ]
}

var kmsOperations = [
  { name: 'whoami', displayName: 'Who am I (token echo)', method: 'GET', urlTemplate: '/whoami', params: [], policy: policyWhoami }
  { name: 'search', displayName: 'Search knowledge (hybrid + semantic)', method: 'POST', urlTemplate: '/search', params: [], policy: policySearch }
  { name: 'article-chunks', displayName: 'List chunks for an article', method: 'GET', urlTemplate: '/articles/{articleId}/chunks', params: [ { name: 'articleId', type: 'string', required: true } ], policy: policyChunks }
  { name: 'stats', displayName: 'Index statistics', method: 'GET', urlTemplate: '/stats', params: [], policy: policyStats }
  { name: 'ingest-run', displayName: 'Ingest pointer (run indexer)', method: 'POST', urlTemplate: '/ingest/run', params: [], policy: policyIngestRun }
  { name: 'ingest-status', displayName: 'Ingest status', method: 'GET', urlTemplate: '/ingest/status', params: [], policy: policyIngestStatus }
]

resource kmsOps 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [for op in kmsOperations: {
  parent: apiKms
  name: op.name
  properties: {
    displayName: op.displayName
    method: op.method
    urlTemplate: op.urlTemplate
    templateParameters: op.params
  }
}]

resource kmsOpPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = [for (op, i) in kmsOperations: {
  parent: kmsOps[i]
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: op.policy
  }
  dependsOn: [ apiKmsPolicy ]
}]

// ---------------------------------------------------------------------------
// API 3: /aisearch  - drop-in endpoint for azure-search-documents SDK clients
// ---------------------------------------------------------------------------
resource apiAiSearch 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'aisearch'
  properties: {
    displayName: 'KMS AI Search (SDK pass-through, allow-listed)'
    description: 'Drop-in Azure AI Search endpoint for existing SDK clients. Only query/count on the KMS index and run/status on the KMS indexer are allowed.'
    path: 'aisearch'
    protocols: [ 'https' ]
    serviceUrl: searchEndpoint
    subscriptionRequired: false
    apiType: 'http'
  }
}

resource aiSearchGet 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAiSearch
  name: 'get-any'
  properties: {
    displayName: 'GET (allow-listed)'
    method: 'GET'
    urlTemplate: '/*'
  }
}

resource aiSearchPost 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAiSearch
  name: 'post-any'
  properties: {
    displayName: 'POST (allow-listed)'
    method: 'POST'
    urlTemplate: '/*'
  }
}

// Write verbs are routed to the policy (instead of an APIM 404) so callers get an explicit 403 operation_not_allowed.
resource aiSearchPut 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAiSearch
  name: 'put-any'
  properties: {
    displayName: 'PUT (denied by policy)'
    method: 'PUT'
    urlTemplate: '/*'
  }
}

resource aiSearchPatch 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAiSearch
  name: 'patch-any'
  properties: {
    displayName: 'PATCH (denied by policy)'
    method: 'PATCH'
    urlTemplate: '/*'
  }
}

resource aiSearchDelete 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAiSearch
  name: 'delete-any'
  properties: {
    displayName: 'DELETE (denied by policy)'
    method: 'DELETE'
    urlTemplate: '/*'
  }
}

resource apiAiSearchPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiAiSearch
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyAiSearch
  }
  dependsOn: [ nvPrivateLink ]
}

output gatewayUrl string = apim.properties.gatewayUrl
output kmsApiBase string = '${apim.properties.gatewayUrl}/kms'
output sdkEndpoint string = '${apim.properties.gatewayUrl}/aisearch'
output embeddingResourceUri string = apim.properties.gatewayUrl
