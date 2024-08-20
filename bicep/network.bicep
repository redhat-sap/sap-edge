// SPDX-FileCopyrightText: 2024 SAP edge team
// SPDX-FileContributor: Kirill Satarin (@kksat)
// SPDX-FileContributor: Manjun Jiao (@mjiao)
//
// SPDX-License-Identifier: Apache-2.0

param vnetName string = '${resourceGroup().name}-vnet'
param masterSubnetName string = 'master'
param workerSubnetName string = 'worker'

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: resourceGroup().location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.1.0.0/23'
      ]
    }
  }
  resource masterSubnet 'subnets@2024-01-01' = {
    name: masterSubnetName
    properties: {
      addressPrefix: '10.1.0.0/27'
    }
  }
  resource workerSubnet 'subnets@2024-01-01' = {
    name: workerSubnetName
    properties: {
      addressPrefix: '10.1.0.128/25'
    }
  }
}
