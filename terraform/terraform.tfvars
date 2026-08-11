region          = "us-east-1"
name            = "vllm-eks"
cluster_version = "1.36"

vpc_cidr = "10.20.0.0/16" # non-overlapping with the eks-platform repo's VPCs
az_count = 2

system_instance_types = ["t3.large", "t3a.large"]
system_min_size       = 2
system_max_size       = 4

# One T4 per node regardless of size, so scale out means more NODES.
gpu_instance_types = ["g4dn.xlarge"]
gpu_capacity_type  = "spot"

# Cost guardrail AND the real ceiling: the default G-family spot quota is
# 8 vCPUs = exactly two g4dn.xlarge. Raise both together if you need more.
gpu_cpu_limit = 8

create_weights_bucket = true

# Tighten to "<your-ip>/32" — curl -s ifconfig.me
endpoint_public_access_cidrs = ["0.0.0.0/0"]
