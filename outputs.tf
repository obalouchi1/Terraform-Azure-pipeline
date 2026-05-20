output "resource_group_name" {
  description = "Name of the resource group"
  value       = module.resource_group.name
}

output "vnet_id" {
  description = "ID of the virtual network"
  value       = module.networking.vnet_id
}

output "subnet_ids" {
  description = "Map of subnet names to IDs"
  value       = module.networking.subnet_ids
}

output "vm_private_ips" {
  description = "Private IP addresses of deployed VMs"
  value       = [for vm in module.vm : vm.private_ip]
}
