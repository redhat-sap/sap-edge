// SPDX-FileCopyrightText: 2024 SAP edge team
// SPDX-FileContributor: Kirill Satarin (@kksat)
// SPDX-FileContributor: Manjun Jiao (@mjiao)
//
// SPDX-License-Identifier: Apache-2.0

param clusterName string
param domain string
@secure()
param pullSecret string

@allowed([
  '4.14.16'
  '4.13.40'
  '4.12.25'
])
param version string
param servicePrincipalClientId string
@secure()
param servicePrincipalClientSecret string

param vnetName string = 'aro-sapeic-vnet'
param masterSubnetName string = 'master'
param workerSubnetName string = 'worker'
param masterVmSize string = 'Standard_D8s_v3'
param workerVmSize string = 'Standard_D4s_v3'
param workerDiskSizeGB int = 128
@minValue(3)
param workerCount int = 3

param location string = resourceGroup().location

resource aroCluster 'Microsoft.RedHatOpenShift/openShiftClusters@2023-11-22' = {
  name: clusterName
  location: location
  properties: {
    clusterProfile: {
      pullSecret: pullSecret
      domain: domain
      version: version
      // resourceGroupId: resourceGroup().id
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
    }
    workerProfiles: [
      {
        name: 'worker'
        vmSize: workerVmSize
        diskSizeGB: workerDiskSizeGB
        subnetId: workerSubnet.id
        count: workerCount
      }
    ]
    apiserverProfile: {
      visibility: 'Public'
    }
    ingressProfiles: [
      {
        visibility: 'Public'
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
}

resource masterSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  name: masterSubnetName
  parent: vnet
}

resource workerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  name: workerSubnetName
  parent: vnet
}
