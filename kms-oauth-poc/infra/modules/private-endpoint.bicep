@description('Private endpoint name')
param name string
param location string
param tags object
param subnetId string
param targetResourceId string
param groupId string
param privateDnsZoneId string

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    customNetworkInterfaceName: 'nic-${name}'
    privateLinkServiceConnections: [
      {
        name: '${name}-conn'
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'zone'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output id string = pe.id
