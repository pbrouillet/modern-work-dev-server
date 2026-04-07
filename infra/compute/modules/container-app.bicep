// ---------------------------------------------------------------------------
// Module: container-app.bicep
// Provisions the rdp-bridge Container App and its RBAC role assignments.
// ACR, LAW, App Insights, and CAE are created by the networking layer.
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string

@description('Environment name used for naming convention.')
param environmentName string

@description('ACR login server (e.g. acrspseXXX.azurecr.io).')
param acrLoginServer string

@description('ACR resource name.')
param acrName string

@description('Container Apps Environment resource ID.')
param caeId string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Private IP address of the target VM for RDP proxying. Optional when RDP_BRIDGE_IN_AZURE is enabled.')
param rdpTargetHost string = ''

@description('RDP port on the target VM.')
param rdpTargetPort int = 3389

@secure()
@description('Username for gateway PAA cookie validation.')
param bridgeAuthUsername string

@secure()
@description('Password for gateway PAA cookie validation (reserved for future NTLM support).')
param bridgeAuthPassword string

@description('Tags to apply to all resources.')
param tags object = {}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var caName = 'ca-rdpbridge-${environmentName}'

// ---------------------------------------------------------------------------
// ACR reference (created by networking layer)
// ---------------------------------------------------------------------------

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// ---------------------------------------------------------------------------
// Container App — rdp-bridge
// ---------------------------------------------------------------------------

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: caName
  location: location
  tags: union(tags, {
    'azd-service-name': 'rdp-bridge'
  })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: acrLoginServer
          identity: 'system'
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      maxInactiveRevisions: 1
      secrets: [
        {
          name: 'auth-username'
          value: bridgeAuthUsername
        }
        {
          name: 'auth-password'
          value: bridgeAuthPassword
        }
        {
          name: 'appinsights-connection-string'
          value: appInsightsConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'rdp-bridge'
          // Placeholder for initial provision; postprovision hook builds the
          // real image via ACR Tasks then updates the container app.
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'RDP_BRIDGE_IN_AZURE'
              value: 'true'
            }
            {
              name: 'AZURE_SUBSCRIPTION_ID'
              value: subscription().subscriptionId
            }
            {
              name: 'AZURE_RESOURCE_GROUP'
              value: resourceGroup().name
            }
            {
              name: 'RDP_TARGET_HOST'
              value: rdpTargetHost
            }
            {
              name: 'RDP_TARGET_PORT'
              value: string(rdpTargetPort)
            }
            {
              name: 'AUTH_USERNAME'
              secretRef: 'auth-username'
            }
            {
              name: 'AUTH_PASSWORD'
              secretRef: 'auth-password'
            }
            {
              name: 'RUST_LOG'
              value: 'rdp_bridge=info'
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              secretRef: 'appinsights-connection-string'
            }
            {
              name: 'OTEL_SERVICE_NAME'
              value: 'rdp-bridge'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 2
        rules: [
          {
            name: 'http-requests'
            http: {
              metadata: {
                concurrentRequests: '1'
              }
            }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: AcrPull for the Container App's managed identity
// ---------------------------------------------------------------------------

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, containerApp.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// RBAC: VM management for the Container App's managed identity
// ---------------------------------------------------------------------------

// Virtual Machine Contributor — start/stop/read VMs
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

resource vmContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, containerApp.id, vmContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmContributorRoleId)
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reader — read NICs and other resource metadata for IP resolution
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, containerApp.id, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('FQDN of the Container App (RD Gateway bridge endpoint).')
output bridgeFqdn string = containerApp.properties.configuration.ingress.fqdn

@description('Container App resource name.')
output containerAppName string = containerApp.name
