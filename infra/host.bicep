param location string
param labId string
param configHash string
@minLength(3)
@maxLength(8)
param prefix string
@allowed([
  'Standard_E16ds_v5'
  'Standard_E16ds_v6'
  'Standard_D16s_v5'
])
param hostVmSize string
param adminUsername string
@secure()
@minLength(14)
param adminPassword string
param allowedSourceIp string
@minValue(256)
@maxValue(4096)
param dataDiskSizeGB int
param shutdownTime string
param shutdownTimeZone string

var vmName = '${prefix}-hv01'
var tags = {
  labId: labId
  configHash: configHash
  managedBy: 'hyperv-discovery-lab'
}
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'OperatorRdpOnly'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.240.0.0/24'] }
    subnets: [
      {
        name: 'host'
        properties: {
          addressPrefix: '10.240.0.0/27'
          networkSecurityGroup: { id: nsg.id }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${prefix}-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'host'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${vnet.id}/subnets/host' }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}
resource disk 'Microsoft.Compute/disks@2024-03-02' = {
  name: '${vmName}-data'
  location: location
  tags: tags
  sku: { name: 'Premium_LRS' }
  properties: {
    diskSizeGB: dataDiskSizeGB
    creationData: { createOption: 'Empty' }
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: hostVmSize }
    // Standard security is intentional: do not inherit Trusted Launch defaults.
    securityProfile: { securityType: 'Standard' }
    storageProfile: {
      diskControllerType: hostVmSize == 'Standard_E16ds_v6' ? 'NVMe' : 'SCSI'
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-os'
        createOption: 'FromImage'
        diskSizeGB: 128
        caching: 'ReadWrite'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Detach'
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          caching: 'None'
          managedDisk: { id: disk.id }
          deleteOption: 'Detach'
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByOS' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}
resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: shutdownTime }
    timeZoneId: shutdownTimeZone
    targetResourceId: vm.id
    notificationSettings: { status: 'Disabled' }
  }
}
output vmName string = vm.name
output publicIp string = pip.properties.ipAddress
