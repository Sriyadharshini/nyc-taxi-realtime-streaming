// ============================================================
// NYC Taxi Real-Time Streaming Pipeline — Infrastructure as Code
// Author  : Sri (Sriyadharshini Ravi)
// Purpose : Spin up / tear down full streaming pipeline infra
// Usage   : az deployment group create \
//             --resource-group rg-nyc-taxi-streaming \
//             --template-file main.bicep \
//             --parameters @parameters.json
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────
@description('Environment tag')
@allowed(['dev', 'staging', 'prod'])
param env string = 'dev'

@description('Azure region — must match your resource group region')
param location string = resourceGroup().location

@description('Short unique suffix to avoid global name collisions (3-5 chars, lowercase)')
@maxLength(5)
param suffix string = 'sri02'

@description('Your GitHub account name')
param githubAccountName string = 'Sriyadharshini'

@description('GitHub repo name')
param githubRepoName string = 'nyc-taxi-realtime-streaming'

@description('GitHub collaboration branch')
param githubBranch string = 'main'

@description('Azure SQL admin username')
param sqlAdminUsername string = 'sqladmin'

@description('Azure SQL admin password — pass via parameters.json, never hardcode')
@secure()
param sqlAdminPassword string

@description('Event Hubs partition count — 2 for dev, 8+ for prod')
param eventHubPartitionCount int = 2

@description('Event Hubs message retention in days')
param eventHubRetentionDays int = 1

// ── Variables ─────────────────────────────────────────────────
var projectName           = 'taxistream'
var storageAccountName    = 'st${projectName}${suffix}'
var adfName               = 'adf-${projectName}-${env}-${suffix}'
var sqlServerName         = 'sql-${projectName}-${env}-${suffix}'
var sqlDbName             = 'sqldb-watermark-${env}'
var databricksName        = 'dbw-${projectName}-${env}-${suffix}'
var eventHubsNamespace    = 'evhns-${projectName}-${env}-${suffix}'
var eventHubName          = 'taxi-trips-raw'
var eventHubDlqName       = 'taxi-trips-dlq'
var consumerGroupName     = 'databricks-cg'
var keyVaultName          = 'kv-${projectName}-${suffix}'

var commonTags = {
  project     : 'nyc-taxi-realtime-streaming'
  environment : env
  owner       : 'sri'
  managedBy   : 'bicep'
  costCenter  : 'free-trial'
}

// ── 1. Storage Account (ADLS Gen2) ───────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name     : storageAccountName
  location : location
  tags     : commonTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled            : true
    accessTier              : 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion       : 'TLS1_2'
    allowBlobPublicAccess   : false
  }
}

// ── 1a. Bronze Container (raw streaming events) ───────────────
resource bronzeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name      : '${storageAccount.name}/default/bronze'
  properties: {
    publicAccess: 'None'
  }
}

// ── 1b. Silver Container (cleaned events) ─────────────────────
resource silverContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name      : '${storageAccount.name}/default/silver'
  properties: {
    publicAccess: 'None'
  }
}

// ── 1c. Gold Container (real-time aggregations) ───────────────
resource goldContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name      : '${storageAccount.name}/default/gold'
  properties: {
    publicAccess: 'None'
  }
}

// ── 1d. Checkpoints Container (Spark streaming checkpoints) ───
resource checkpointsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name      : '${storageAccount.name}/default/checkpoints'
  properties: {
    publicAccess: 'None'
  }
}

// ── 1e. Config Container ──────────────────────────────────────
resource configContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name      : '${storageAccount.name}/default/config'
  properties: {
    publicAccess: 'None'
  }
}

// ── 2. Key Vault (store secrets securely) ────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name    : keyVaultName
  location: location
  tags    : commonTags
  properties: {
    sku: {
      family: 'A'
      name  : 'standard'
    }
    tenantId                : subscription().tenantId
    enableRbacAuthorization : true    // Use RBAC not access policies — modern approach
    enableSoftDelete        : true
    softDeleteRetentionInDays: 7      // Minimum retention — saves cost on free trial
    enabledForDeployment    : false
    enabledForTemplateDeployment: true
    publicNetworkAccess     : 'Enabled'
  }
}

// ── 3. Azure SQL Server ───────────────────────────────────────
resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name     : sqlServerName
  location : location
  tags     : commonTags
  properties: {
    administratorLogin        : sqlAdminUsername
    administratorLoginPassword: sqlAdminPassword
    version                   : '12.0'
    publicNetworkAccess       : 'Enabled'
  }
}

// ── 3a. Allow Azure services to access SQL ────────────────────
resource sqlFirewallAzureServices 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = {
  parent: sqlServer
  name  : 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress  : '0.0.0.0'
  }
}

// ── 3b. Azure SQL Database (serverless) ──────────────────────
resource sqlDatabase 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent  : sqlServer
  name    : sqlDbName
  location: location
  tags    : commonTags
  sku: {
    name    : 'GP_S_Gen5_1'
    tier    : 'GeneralPurpose'
    family  : 'Gen5'
    capacity: 1
  }
  properties: {
    autoPauseDelay                  : 60
    minCapacity                     : 1
    requestedBackupStorageRedundancy: 'Local'
  }
}

// ── 4. Event Hubs Namespace ───────────────────────────────────
resource eventHubsNamespaceRes 'Microsoft.EventHub/namespaces@2022-10-01-preview' = {
  name    : eventHubsNamespace
  location: location
  tags    : commonTags
  sku: {
    name    : 'Standard'   // Standard required for Kafka endpoint + consumer groups
    tier    : 'Standard'
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled  : false
    kafkaEnabled          : true    // Enables Kafka-compatible endpoint
    minimumTlsVersion     : '1.2'
    publicNetworkAccess   : 'Enabled'
    disableLocalAuth      : false
  }
}

// ── 4a. Event Hub — taxi-trips-raw ───────────────────────────
resource eventHubRaw 'Microsoft.EventHub/namespaces/eventhubs@2022-10-01-preview' = {
  parent    : eventHubsNamespaceRes
  name      : eventHubName
  properties: {
    partitionCount      : eventHubPartitionCount
    messageRetentionInDays: eventHubRetentionDays
  }
}

// ── 4b. Event Hub — taxi-trips-dlq (dead letter queue) ───────
resource eventHubDlq 'Microsoft.EventHub/namespaces/eventhubs@2022-10-01-preview' = {
  parent    : eventHubsNamespaceRes
  name      : eventHubDlqName
  properties: {
    partitionCount        : 2
    messageRetentionInDays: eventHubRetentionDays
  }
}

// ── 4c. Consumer Group for Databricks ────────────────────────
resource databricksConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2022-10-01-preview' = {
  parent: eventHubRaw
  name  : consumerGroupName
}

// ── 4d. Authorization Rule — Send (for producer) ─────────────
resource eventHubSendRule 'Microsoft.EventHub/namespaces/authorizationRules@2022-10-01-preview' = {
  parent    : eventHubsNamespaceRes
  name      : 'send-policy'
  properties: {
    rights: ['Send']
  }
}

// ── 4e. Authorization Rule — Listen (for Databricks) ─────────
resource eventHubListenRule 'Microsoft.EventHub/namespaces/authorizationRules@2022-10-01-preview' = {
  parent    : eventHubsNamespaceRes
  name      : 'listen-policy'
  properties: {
    rights: ['Listen']
  }
}

// ── 5. Azure Data Factory ─────────────────────────────────────
resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name    : adfName
  location: location
  tags    : commonTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    repoConfiguration: {
      type               : 'FactoryGitHubConfiguration'
      accountName        : githubAccountName
      repositoryName     : githubRepoName
      collaborationBranch: githubBranch
      rootFolder         : '/adf'
      lastCommitId       : ''
    }
    globalParameters: {
      environment: {
        type : 'String'
        value: env
      }
      storageAccountName: {
        type : 'String'
        value: storageAccountName
      }
      eventHubsNamespace: {
        type : 'String'
        value: eventHubsNamespace
      }
    }
  }
}

// ── 6. Azure Databricks Workspace ────────────────────────────
resource databricksWorkspace 'Microsoft.Databricks/workspaces@2023-02-01' = {
  name    : databricksName
  location: location
  tags    : commonTags
  sku: {
    name: 'trial'
  }
  properties: {
    managedResourceGroupId: '${subscription().id}/resourceGroups/rg-dbw-managed-${suffix}'
  }
}

// ── 7. Role Assignments ───────────────────────────────────────
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var keyVaultSecretsOfficerRoleId     = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

// ADF → ADLS Gen2
resource adfStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name : guid(storageAccount.id, dataFactory.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId     : dataFactory.identity.principalId
    principalType   : 'ServicePrincipal'
  }
}

// ADF → Key Vault (to read secrets for linked services)
resource adfKeyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name : guid(keyVault.id, dataFactory.id, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    principalId     : dataFactory.identity.principalId
    principalType   : 'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────
output storageAccountName      string = storageAccount.name
output storageAccountId        string = storageAccount.id
output keyVaultName            string = keyVault.name
output keyVaultUri             string = keyVault.properties.vaultUri
output adfName                 string = dataFactory.name
output adfPrincipalId          string = dataFactory.identity.principalId
output sqlServerFqdn           string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName         string = sqlDatabase.name
output databricksWorkspaceUrl  string = databricksWorkspace.properties.workspaceUrl
output databricksWorkspaceId   string = databricksWorkspace.id
output eventHubsNamespace      string = eventHubsNamespaceRes.name
output eventHubsKafkaEndpoint  string = '${eventHubsNamespaceRes.name}.servicebus.windows.net:9093'
output eventHubRawName         string = eventHubRaw.name
output eventHubDlqName         string = eventHubDlq.name
output consumerGroupName       string = databricksConsumerGroup.name
