variable "admin_password" {
  type        = string
  description = "The administrator password for all Linux Virtual Machines."
  sensitive   = true
}