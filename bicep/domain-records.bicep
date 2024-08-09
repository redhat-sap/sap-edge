@description('The name of the DNS zone where A records will be created, must already exist')
param domainZoneName string

@description('The name of the DNS A record to be created. The name is relative to the zone, not the FQDN.')
param recordName string

@description('ipv4 address to be associated with the A record')
param ipv4Address string

@description('A record time to live (TTL)')
param TTL int = 3600

resource domainZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: domainZoneName
}

resource record 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: domainZone
  name: recordName
  properties: {
    TTL: TTL
    ARecords: [
      {
        ipv4Address: ipv4Address
      }
    ]
  }
}
