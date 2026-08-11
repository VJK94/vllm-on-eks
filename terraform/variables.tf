variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Name prefix for every resource"
  type        = string
  default     = "vllm-eks"
}

variable "cluster_version" {
  type    = string
  default = "1.36"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  description = "2 keeps NAT and control-plane ENI costs down for a demo; 3 for production."
  type        = number
  default     = 2
}

# --- system (CPU) node group: runs Karpenter, Prometheus, controllers -------

variable "system_instance_types" {
  type    = list(string)
  default = ["t3.large", "t3a.large"]
}

variable "system_min_size" {
  type    = number
  default = 2
}

variable "system_max_size" {
  type    = number
  default = 4
}

# --- GPU capacity ----------------------------------------------------------

variable "gpu_instance_types" {
  description = <<-EOT
    Instance types the GPU NodePool may launch. g4dn.xlarge = 1x T4 (16 GiB
    VRAM, 4 vCPU) — the cheapest GPU on AWS. NOTE 4xlarge/8xlarge/16xlarge
    all still have exactly ONE GPU; you pay for CPU and RAM, not silicon.
    Only 12xlarge (4 GPUs) and metal (8) give you more.
  EOT
  type        = list(string)
  default     = ["g4dn.xlarge"]
}

variable "gpu_capacity_type" {
  description = "spot is ~40% cheaper but reclaimed more often, and a GPU node takes 5-10 min to replace"
  type        = string
  default     = "spot"
}

variable "gpu_cpu_limit" {
  description = "Hard cost guardrail: max total vCPUs the GPU NodePool may provision. 8 = two g4dn.xlarge, which is also the default G-family spot quota."
  type        = number
  default     = 8
}

variable "endpoint_public_access_cidrs" {
  description = "Tighten to <your-ip>/32 when you can"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- model weights (phase 2: S3-backed loading) ----------------------------

variable "create_weights_bucket" {
  description = "Create an S3 bucket for model weights so pods stop depending on huggingface.co at startup. See docs/cold-start.md."
  type        = bool
  default     = true
}
