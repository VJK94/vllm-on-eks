# vLLM on EKS — LLM inference on autoscaling spot GPUs

Serves a quantized 7B model behind an OpenAI-compatible API on Amazon EKS,
with GPU nodes provisioned on demand by Karpenter and observability that
covers both the serving layer and the silicon.

Built as a learning project, so the interesting parts are the **measurements
and the tradeoffs**, not the YAML.

```
                          internet
                              │
                     ┌────────▼────────┐
                     │   ALB / kubectl │
                     │   port-forward  │
                     └────────┬────────┘
   ┌──────────────────────────▼──────────────────────────┐
   │  EKS cluster                                        │
   │                                                     │
   │  ┌─ system nodes (t3.large spot) ─────────────────┐  │
   │  │  Karpenter · LB controller · Prometheus/Grafana│  │
   │  └───────────────────┬───────────────────────────┘  │
   │                      │ sees a Pending GPU pod       │
   │  ┌───────────────────▼───────────────────────────┐  │
   │  │ GPU node (g4dn.xlarge spot, 1x T4)            │  │
   │  │  taint: nvidia.com/gpu=true:NoSchedule        │  │
   │  │                                               │  │
   │  │  nvidia device plugin ─► nvidia.com/gpu: 1    │  │
   │  │  vLLM pod (claims the whole GPU)              │  │
   │  │  DCGM exporter ─► SM / tensor / bandwidth     │  │
   │  └───────────────────────────────────────────────┘  │
   └─────────────────────────────────────────────────────┘
```

## What it demonstrates

- **GPU scheduling in Kubernetes** — the device plugin advertising
  `nvidia.com/gpu` as an extended resource, and why GPUs are indivisible
- **Cost protection through taints** — a GPU node costs ~8x a general node,
  so nothing lands there without explicitly tolerating the taint
- **Karpenter provisioning GPU capacity on demand**, with a hard vCPU limit
  that matches the AWS quota
- **Probes that survive multi-minute model loads** — the single most common
  reason LLM pods CrashLoopBackOff on Kubernetes
- **Observability that joins two layers**: vLLM's queue depth and KV cache
  alongside DCGM's SM and tensor-core activity
- **Terraform modules consumed cross-repo at a pinned tag**, rather than
  copy-pasted

## Measured results

Benchmarked on a single spot g4dn.xlarge (1x NVIDIA T4, 16 GiB) serving
`Mistral-7B-Instruct-v0.2-AWQ` (INT4):

| concurrency | TTFT p50 | per-stream | aggregate | cost / 1M output tokens |
|---|---|---|---|---|
| 1 | 27 ms | 50.9 tok/s | 50.8 tok/s | $1.80 |
| 4 | 53 ms | 47.9 | 189.2 | — |
| 16 | 139 ms | 34.4 | 535.6 | — |
| **32** | **226 ms** | **25.9** | **800.8** | **$0.11** |
| 71 | 325 ms | 12.2 | 842.6 | $0.11 |

**Continuous batching gave 16.6x throughput on identical hardware**, because
decode is memory-bandwidth-bound: producing one token requires reading the
entire model out of VRAM, and that read is a fixed cost per step no matter
how many sequences share it.

**The saturation knee is ~32.** Going from 32 to 71 concurrent bought +5%
throughput while halving per-user speed. The proof it is compute-bound:
batch grew 2.22x and step time grew 2.13x — almost exactly proportional, so
tokens/sec flattens. `--max-num-seqs=32` enforces the knee so excess requests
queue instead of degrading everyone already being served; past it, you scale
horizontally.

### Does Kubernetes cost you throughput? No.

The same model and GPU, benchmarked first on a bare EC2 instance and then on
this cluster:

| conc | TPOT (EC2 → EKS) | per-stream | aggregate tok/s |
|---|---|---|---|
| 1 | 19.6 → 19.4 ms | 50.9 → 51.4 | 50.8 → 49.8 |
| 4 | 20.9 → 20.8 | 47.9 → 48.2 | 189.2 → 186.4 |
| 16 | 29.0 → 28.8 | 34.4 → 34.7 | 535.6 → 531.9 |
| 32 | 38.6 → 38.2 | 25.9 → 26.2 | 800.8 → 790.4 |

Identical within 1.3%. Containerisation, the device plugin, Karpenter and the
CNI cost **nothing** in GPU throughput.

TTFT did rise ~70 ms (27 → 96 ms at concurrency 1), but that is a measurement
artifact: this run was driven from a laptop through `kubectl port-forward`, so
every request crosses the internet and the API server before reaching the pod.
TTFT includes that round trip; TPOT does not, which is exactly why TPOT is
unchanged. **Benchmark from inside the cluster if you want the server's real
latency.**

### What Kubernetes does cost: fixed overhead

| | |
|---|---|
| GPU node (on-demand g4dn.xlarge) | $0.526/hr |
| EKS control plane | $0.100 |
| NAT gateway | $0.045 |
| 2x t3.large spot (system) | $0.050 |
| **total** | **$0.721/hr → $0.25 per 1M output tokens** |

The same workload on one spot EC2 box costs **$0.11 per 1M**. So the platform
roughly doubles cost per token — *at one GPU*. That inverts quickly:

| GPUs | fixed overhead as % of spend |
|---|---|
| 1 | 27% |
| 4 | 8.5% |
| 10 | 3.6% |

Kubernetes is a poor deal for a single GPU and an obvious one at ten. Worth
being honest about rather than assuming orchestration is free.

### Capacity: predicted, then confirmed twice

Capacity was predicted before deploying and matched what vLLM computed:

| | predicted | vLLM on EC2 | vLLM on EKS |
|---|---|---|---|
| KV cache pool | 8.9 GiB | 8.9 GiB | 9.04 GiB |
| Token capacity | ~73,000 | 72,928 | 74,048 |
| Max concurrency @ 2048 | ~35 | 35.61x | 36.16x |

The arithmetic is just usable VRAM, minus weights, minus overhead, divided by
`2 × layers × kv_heads × head_dim × 2 bytes` per token. EKS came out marginally
ahead — slightly less host-side overhead in the container.

## Deploy

Requires Terraform >= 1.10, AWS CLI v2, kubectl, helm, and a
**G-family spot vCPU quota of at least 8** (`L-3819A6DF`) — the default is 0.

```bash
cd terraform
terraform init && terraform apply          # ~15 min
aws eks update-kubeconfig --region us-east-1 --name vllm-eks

# controllers
terraform output install_karpenter         # run the printed commands
terraform output install_lb_controller     # optional, only for Ingress

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin && helm repo update
helm install nvdp nvdp/nvidia-device-plugin -n kube-system --version 0.17.4 \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'

# StorageClass FIRST — Prometheus asks for `gp3` and the operator silently
# refuses to create its StatefulSet without it (no pod, no PVC, empty graphs).
kubectl apply -f ../k8s/storage/

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f ../helm/monitoring-values.yaml

# nodeSelector matters: without it the DaemonSet lands on CPU nodes too and
# CrashLoopBackOffs there, since there is no GPU to talk to.
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm install dcgm-exporter gpu-helm-charts/dcgm-exporter -n gpu-operator --create-namespace \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]' \
  --set-json 'nodeSelector={"workload":"inference"}'

# GPU capacity + the workload
kubectl apply -f ../k8s/karpenter/
kubectl apply -f ../k8s/vllm/
kubectl apply -f ../k8s/monitoring/
```

Watch the whole chain — Pending pod, Karpenter launching a node, the device
plugin advertising the GPU, then a long model load:

```bash
kubectl get pods -n inference -w
kubectl get nodes -w
kubectl logs -n inference deploy/vllm -f
```

Ready in **5–10 minutes**. Then:

```bash
kubectl -n inference port-forward svc/vllm 8000:8000
curl -s localhost:8000/v1/models

python3 scripts/bench-vllm.py --concurrency 1,4,16,32
```

## Cost

| | |
|---|---|
| EKS control plane | $0.10/hr |
| NAT gateway (single) | $0.045/hr |
| 2x t3.large spot | ~$0.05/hr |
| 1x g4dn.xlarge spot | ~$0.33/hr, **only while a GPU pod is scheduled** |
| **idle / serving** | **~$0.20 / ~$0.53 per hour** |

Karpenter removes the GPU node ~5 minutes after the last GPU pod goes away,
so idling costs nothing beyond the cluster itself.

## Teardown

```bash
kubectl delete -f k8s/vllm/ -f k8s/karpenter/
kubectl get nodeclaims                # must be empty before continuing
helm uninstall dcgm-exporter -n gpu-operator
helm uninstall monitoring -n monitoring && kubectl delete pvc -n monitoring --all
helm uninstall nvdp karpenter karpenter-crd aws-load-balancer-controller -n kube-system
cd terraform && terraform destroy
```

Delete the NodePool **first** — Karpenter drains and terminates the nodes it
owns, and those EC2 instances are in neither Terraform state nor a managed
node group. Skipping this orphans running GPUs.

## Design notes

Longer write-ups of the decisions that were not obvious:

- [docs/cold-start.md](docs/cold-start.md) — why a pod takes minutes to
  become Ready, what each phase costs, and the four ways to fix it
- [docs/lessons.md](docs/lessons.md) — what broke, and what it taught

## A note on the modules

The VPC, EKS, Karpenter and IRSA modules are consumed from
[VJK94/AI-ML-ops](https://github.com/VJK94/AI-ML-ops) at a pinned tag rather
than vendored here:

```hcl
source = "git::https://github.com/VJK94/AI-ML-ops.git//eks-platform/modules/vpc?ref=week-06"
```

That is deliberate — it is how multi-repo Terraform works in a team. Modules
are versioned artifacts and consumers pin a ref, so upstream changes never
arrive unannounced.
