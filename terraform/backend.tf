# Remote state. If you are not me, point this at your own bucket — backend
# blocks cannot use variables, so either edit it or pass -backend-config.
terraform {
  backend "s3" {
    bucket       = "tfstate-717668026952-ml-platform"
    key          = "vllm-on-eks/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
