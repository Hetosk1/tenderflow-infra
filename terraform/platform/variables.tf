variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "kubernetes_version" {
  description = "Must be in EKS STANDARD support - extended support costs 6x for the control plane"
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "docdb_instance_class" {
  description = "Smallest DocumentDB class available for engine 8.0 in ap-south-1"
  type        = string
  default     = "db.t4g.medium"
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}
