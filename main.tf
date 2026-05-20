locals {
  common_tags = merge(var.tags, {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
  })
  name_prefix = "${var.project}-${var.environment}"
}

# ── Resource Group ──────────────────────────────────────────────────────────
module "resource_group" {
  source   = "./modules/resource-group"
  name     = "${local.name_prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# ── Networking ───────────────────────────────────────────────────────────────
module "networking" {
  source              = "./modules/networking"
  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = module.resource_group.name
  vnet_address_space  = var.vnet_address_space
  subnet_prefixes     = var.subnet_prefixes
  tags                = local.common_tags
}

# ── Virtual Machines ─────────────────────────────────────────────────────────
module "vm" {
  source              = "./modules/vm"
  count               = var.vm_count
  name                = "${local.name_prefix}-vm-${format("%02d", count.index + 1)}"
  location            = var.location
  resource_group_name = module.resource_group.name
  subnet_id           = module.networking.subnet_ids["default"]
  vm_size             = var.vm_size
  admin_username      = var.vm_admin_username
  ssh_public_key_path = var.ssh_public_key_path
  tags                = local.common_tags
}
