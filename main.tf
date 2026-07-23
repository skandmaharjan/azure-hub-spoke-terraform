# 1. The Resource Group (Physical Rack)
resource "azurerm_resource_group" "rg" {
  name     = "rg-hybrid-cloud-lab"
  location = "westus"
}

# 2. The Hub Virtual Network (Core Switch)
resource "azurerm_virtual_network" "hub_vnet" {
  name                = "vnet-hub"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# 3. Subnet for the Network Virtual Appliance (NVA)
resource "azurerm_subnet" "nva_subnet" {
  name                 = "snet-nva"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 4. Subnet for Azure Bastion 
resource "azurerm_subnet" "bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = ["10.0.2.0/26"] 
}

# 5. Subnet for the VPN Gateway 
resource "azurerm_subnet" "gateway_subnet" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}
# ==========================================
# SPOKE 1: PRODUCTION NETWORK
# ==========================================

resource "azurerm_virtual_network" "prod_vnet" {
  name                = "vnet-prod"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "prod_workload_subnet" {
  name                 = "snet-prod-workload"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.prod_vnet.name
  address_prefixes     = ["10.1.1.0/24"]
}

# ==========================================
# SPOKE 2: DEVELOPMENT NETWORK
# ==========================================

resource "azurerm_virtual_network" "dev_vnet" {
  name                = "vnet-dev"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.2.0.0/16"]
}

resource "azurerm_subnet" "dev_workload_subnet" {
  name                 = "snet-dev-workload"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.dev_vnet.name
  address_prefixes     = ["10.2.1.0/24"]
}

# ==========================================
# VNET PEERING (The Trunk Links)
# ==========================================

# Hub to Prod
resource "azurerm_virtual_network_peering" "hub_to_prod" {
  name                      = "peer-hub-to-prod"
  resource_group_name       = azurerm_resource_group.rg.name
  virtual_network_name      = azurerm_virtual_network.hub_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.prod_vnet.id
  allow_forwarded_traffic   = true
}

# Prod to Hub
resource "azurerm_virtual_network_peering" "prod_to_hub" {
  name                      = "peer-prod-to-hub"
  resource_group_name       = azurerm_resource_group.rg.name
  virtual_network_name      = azurerm_virtual_network.prod_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.hub_vnet.id
  allow_forwarded_traffic   = true
}

# Hub to Dev
resource "azurerm_virtual_network_peering" "hub_to_dev" {
  name                      = "peer-hub-to-dev"
  resource_group_name       = azurerm_resource_group.rg.name
  virtual_network_name      = azurerm_virtual_network.hub_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.dev_vnet.id
  allow_forwarded_traffic   = true
}

# Dev to Hub
resource "azurerm_virtual_network_peering" "dev_to_hub" {
  name                      = "peer-dev-to-hub"
  resource_group_name       = azurerm_resource_group.rg.name
  virtual_network_name      = azurerm_virtual_network.dev_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.hub_vnet.id
  allow_forwarded_traffic   = true
}
# ==========================================
# PHASE 3: NETWORK VIRTUAL APPLIANCE (NVA)
# ==========================================

# 1. Network Interface for the NVA
resource "azurerm_network_interface" "nva_nic" {
  name                 = "nic-nva"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  
  # THIS IS THE MAGIC ROUTER BUTTON
  ip_forwarding_enabled = true 

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.nva_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10" 
  }
}

# 2. The Linux VM (Acting as our Core Router)
resource "azurerm_linux_virtual_machine" "nva_vm" {
  name                            = "vm-nva-router"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = "Standard_D2_v3" 
  admin_username                  = "azureadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.nva_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}
# ==========================================
# PHASE 3 (PART B): USER DEFINED ROUTES (UDRs)
# ==========================================

# 1. Route Table for Production
resource "azurerm_route_table" "prod_rt" {
  name                          = "rt-prod"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  bgp_route_propagation_enabled = true

  route {
    name                   = "route-to-hub-nva"
    address_prefix         = "10.0.0.0/8" # Catch-all for our entire corporate network
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.0.1.10"  # The static IP of our Linux VM
  }
}

# Bind Prod Route Table to Prod Subnet
resource "azurerm_subnet_route_table_association" "prod_rt_assoc" {
  subnet_id      = azurerm_subnet.prod_workload_subnet.id
  route_table_id = azurerm_route_table.prod_rt.id
}

# 2. Route Table for Development
resource "azurerm_route_table" "dev_rt" {
  name                          = "rt-dev"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  bgp_route_propagation_enabled = true

  route {
    name                   = "route-to-hub-nva"
    address_prefix         = "10.0.0.0/8" 
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.0.1.10"
  }
}

# Bind Dev Route Table to Dev Subnet
resource "azurerm_subnet_route_table_association" "dev_rt_assoc" {
  subnet_id      = azurerm_subnet.dev_workload_subnet.id
  route_table_id = azurerm_route_table.dev_rt.id
}
# ==========================================
# PHASE 4: NETWORK SECURITY GROUPS (NSGs)
# ==========================================

# 1. NSG for Production
resource "azurerm_network_security_group" "prod_nsg" {
  name                = "nsg-prod"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Rule 1: Allow SSH (Port 22) strictly from the Hub network
  security_rule {
    name                       = "Allow-SSH-From-Hub"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.0/16" # The Hub VNet
    destination_address_prefix = "*"
  }

  # Rule 2: Deny all other inbound traffic
  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Bind the NSG to the Prod Subnet
resource "azurerm_subnet_network_security_group_association" "prod_nsg_assoc" {
  subnet_id                 = azurerm_subnet.prod_workload_subnet.id
  network_security_group_id = azurerm_network_security_group.prod_nsg.id
}
# ==========================================
# PHASE 4 (PART B): AZURE BASTION (SECURE ACCESS)
# ==========================================

# 1. Public IP for the Bastion Host
resource "azurerm_public_ip" "bastion_pip" {
  name                = "pip-bastion"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 2. Azure Bastion Service
resource "azurerm_bastion_host" "bastion" {
  name                = "bastion-hub"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.bastion_pip.id
  }
}
# ==========================================
# PHASE 5: WORKLOAD VMs (THE TEST SUBJECTS)
# ==========================================

# 1. Dev Workload VM
resource "azurerm_network_interface" "dev_vm_nic" {
  name                = "nic-dev-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dev_workload_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "dev_vm" {
  name                            = "vm-dev-workload"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = "Standard_D2s_v3"
  admin_username                  = "azureadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.dev_vm_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# 2. Prod Workload VM
resource "azurerm_network_interface" "prod_vm_nic" {
  name                = "nic-prod-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.prod_workload_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "prod_vm" {
  name                            = "vm-prod-workload"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = "Standard_D2s_v3"
  admin_username                  = "azureadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.prod_vm_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}