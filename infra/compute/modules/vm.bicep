// ---------------------------------------------------------------------------
// Module: vm.bicep
// Provisions a Windows Server 2025 Datacenter VM for SharePoint SE dev box
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string

@description('Name of the virtual machine.')
param vmName string = 'vm-spse-dev'

@description('Size of the virtual machine.')
param vmSize string = 'Standard_D8ds_v5'

@description('Administrator username for the VM.')
param adminUsername string

@secure()
@description('Administrator password for the VM.')
param adminPassword string

@description('Resource ID of the subnet to attach the NIC to.')
param subnetId string

@description('Resource ID of the public IP to associate with the NIC.')
param publicIpId string

@description('Name of the network interface.')
param nicName string = 'nic-spse-dev'

@description('Size of the OS disk in GB.')
param osDiskSizeGB int = 256

@description('Size of the data disk in GB.')
param dataDiskSizeGB int = 256

@description('Tags to apply to all resources.')
param tags object = {}

// ---------------------------------------------------------------------------
// Network Interface
// ---------------------------------------------------------------------------

@description('Network interface for the SharePoint SE dev VM.')
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    enableIPForwarding: false
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIpId
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Machine
// ---------------------------------------------------------------------------

@description('Windows Server 2025 Datacenter VM for SharePoint SE all-in-one dev box.')
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        timeZone: 'Eastern Standard Time'
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        caching: 'ReadWrite'
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGB
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          caching: 'None'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the virtual machine.')
output vmId string = vm.id

@description('Name of the virtual machine.')
output vmName string = vm.name

@description('Principal ID of the system-assigned managed identity.')
output principalId string = vm.identity.principalId

@description('Resource ID of the network interface.')
output nicId string = nic.id

@description('Private IP address assigned to the NIC.')
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

@description('Administrator username for the VM.')
output adminUsername string = adminUsername
