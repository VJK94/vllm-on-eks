output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "install_karpenter" {
  description = "Step 2 — CRDs first, then the controller"
  value       = <<-EOT
    helm install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd -n kube-system
    helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
      --namespace kube-system \
      --set settings.clusterName=${module.eks.cluster_name} \
      --set settings.interruptionQueue=${module.karpenter.interruption_queue_name} \
      --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${module.karpenter.controller_role_arn}" \
      --wait
  EOT
}

output "install_lb_controller" {
  value = <<-EOT
    helm repo add eks https://aws.github.io/eks-charts && helm repo update
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      --namespace kube-system \
      --set clusterName=${module.eks.cluster_name} \
      --set region=${var.region} \
      --set vpcId=${module.vpc.vpc_id} \
      --set serviceAccount.create=true \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${module.lb_controller_irsa.role_arn}"
  EOT
}

output "karpenter_node_role_name" {
  description = "Must match spec.role in k8s/karpenter/gpu-ec2nodeclass.yaml"
  value       = module.karpenter.node_role_name
}

output "weights_bucket" {
  value = var.create_weights_bucket ? aws_s3_bucket.weights[0].bucket : "(not created)"
}

output "weights_reader_role_arn" {
  description = "Annotate the vllm ServiceAccount with this for phase-2 S3 loading"
  value       = var.create_weights_bucket ? module.weights_reader_irsa[0].role_arn : "(not created)"
}

output "hourly_cost_estimate" {
  value = <<-EOT
    EKS control plane      $0.10/hr
    NAT gateway (single)   $0.045/hr
    2x t3.large spot       ~$0.05/hr
    1x g4dn.xlarge spot    ~$0.33/hr   (only while a GPU pod is scheduled)
    ------------------------------------
    idle (no GPU node)     ~$0.20/hr
    serving                ~$0.53/hr
  EOT
}
