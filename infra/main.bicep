targetScope = 'subscription'

param resourceGroupName string
param location string
param labId string
param configHash string
param prefix string
param hostVmSize string
param adminUsername string
@secure()
param adminPassword string
param allowedSourceIp string
param dataDiskSizeGB int
param shutdownTime string
param shutdownTimeZone string

resource lab 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    labId: labId
    configHash: configHash
    managedBy: 'hyperv-discovery-lab'
  }
}

module host 'host.bicep' = {
  name: '${prefix}-host'
  scope: lab
  params: {
    location: location
    labId: labId
    configHash: configHash
    prefix: prefix
    hostVmSize: hostVmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    allowedSourceIp: allowedSourceIp
    dataDiskSizeGB: dataDiskSizeGB
    shutdownTime: shutdownTime
    shutdownTimeZone: shutdownTimeZone
  }
}
output vmName string = host.outputs.vmName
output publicIp string = host.outputs.publicIp
