// SPDX-FileCopyrightText: 2024 SAP edge team
// SPDX-FileContributor: Kirill Satarin (@kksat)
// SPDX-FileContributor: Manjun Jiao (@mjiao)
//
// SPDX-License-Identifier: Apache-2.0

param clusterName string
@description('The pull secret for the ARO cluster.')
@secure()
param pullSecret string
@description('The domain for the ARO cluster.')
param domain string
@description('OpenShift version for the ARO cluster (validated by Azure at deployment time)')
param version string

param servicePrincipalClientId string

@secure()
param servicePrincipalClientSecret string

param aroResourceGroup string = '${resourceGroup().name}-resources'

param vnetName string = '${resourceGroup().name}-vnet'
param masterSubnetName string = 'master'
param workerSubnetName string = 'worker'

@description('VM size for master nodes')
@allowed(['Standard_D8s_v3', 'Standard_D16s_v3'])
param masterVmSize string = 'Standard_D8s_v3'

@description('VM size for worker nodes (optimized for testing)')
@allowed(['Standard_D4s_v3', 'Standard_D8s_v3'])
param workerVmSize string = 'Standard_D4s_v3'

@description('Disk size for worker nodes in GB')
@minValue(128)
@maxValue(1024)
param workerDiskSizeGB int = 128

@description('Number of worker nodes (limited for testing)')
@minValue(3)
@maxValue(10)
param workerCount int = 3

param location string = resourceGroup().location

// Cost optimization parameters for testing
@description('Enable auto-shutdown for cost savings (testing only)')
param enableAutoShutdown bool = true

@description('Auto-shutdown time in 24-hour format (testing only)')
param shutdownTime string = '19:00'

@description('Testing-specific tags for resource management')
param testingTags object = {
  purpose: 'testing'
  team: 'sap-edge'
  autoCleanup: 'enabled'
  maxLifetime: '7days'
  costOptimized: 'true'
}

// Deploy minimal VNet with only master and worker subnets
module network 'network-minimal.bicep' = {
  name: 'network-deployment'
  params: {
    location: location
    vnetName: vnetName
    masterSubnetName: masterSubnetName
    workerSubnetName: workerSubnetName
  }
}

// Reference the deployed VNet and subnets
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
  dependsOn: [
    network
  ]
}

resource masterSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  name: masterSubnetName
  parent: vnet
}

resource workerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  name: workerSubnetName
  parent: vnet
}

resource aroCluster 'Microsoft.RedHatOpenShift/openShiftClusters@2023-11-22' = {
  name: clusterName
  location: location
  tags: union(testingTags, {
    clusterName: clusterName
    deployment: 'bicep'
  })
  properties: {
    clusterProfile: {
      domain: domain
      pullSecret: base64ToString(pullSecret)
      resourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${aroResourceGroup}'
      version: version
      fipsValidatedModules: 'Disabled'
    }
    networkProfile: {
      podCidr: '10.128.0.0/14'
      serviceCidr: '172.30.0.0/16'
    }
    servicePrincipalProfile: {
      clientId: servicePrincipalClientId
      clientSecret: servicePrincipalClientSecret
    }
    masterProfile: {
      vmSize: masterVmSize
      subnetId: masterSubnet.id
      encryptionAtHost: 'Disabled'
    }
    workerProfiles: [
      {
        name: 'worker'
        vmSize: workerVmSize
        diskSizeGB: workerDiskSizeGB
        subnetId: workerSubnet.id
        count: workerCount
        encryptionAtHost: 'Disabled'
      }
    ]
    apiserverProfile: {
      visibility: 'Public'
    }
    ingressProfiles: [
      {
        name: 'default'
        visibility: 'Public'
      }
    ]
  }
}

// Enhanced testing-focused outputs
@description('Quick connection info for testing and debugging')
output quickConnectionInfo object = {
  cluster: {
    name: clusterName
    apiServerUrl: aroCluster.properties.apiserverProfile.url
    consoleUrl: aroCluster.properties.consoleProfile.url
    version: version
    workerCount: workerCount
    domain: domain
  }
  commands: {
    getKubeconfig: 'az aro get-admin-kubeconfig --name ${clusterName} --resource-group ${resourceGroup().name} --file kubeconfig'
    getCredentials: 'az aro list-credentials --name ${clusterName} --resource-group ${resourceGroup().name}'
    ocLogin: 'oc login ${aroCluster.properties.apiserverProfile.url}'
  }
  testing: {
    tags: testingTags
    autoShutdown: enableAutoShutdown
    shutdownTime: shutdownTime
    estimatedMonthlyCost: 'Check Azure Cost Management for current costs'
    cleanupCommand: 'az group delete --name ${resourceGroup().name} --yes --no-wait'
  }
}

@description('ARO cluster resource ID for additional operations')
output aroClusterId string = aroCluster.id

@description('ARO cluster API server URL')
output apiServerUrl string = aroCluster.properties.apiserverProfile.url

@description('ARO cluster console URL')
output consoleUrl string = aroCluster.properties.consoleProfile.url





