# Cold start: why a vLLM pod takes minutes to become Ready

The single hardest operational property of LLM inference on Kubernetes. A
stateless web pod is Ready in seconds; this one takes 5–10 minutes, and that
changes how you autoscale, how you write probes, and how much idle capacity
you are forced to pay for.

## Where the time goes

Scaling from 1 replica to 2, with no GPU node available:

| phase | time | notes |
|---|---|---|
| Karpenter sees the Pending pod | ~5 s | it watches the scheduler |
| EC2 launches g4dn.xlarge spot | ~60 s | longer if capacity is tight |
| node joins, kubelet registers | ~30 s | driver already in the GPU AMI |
| device plugin advertises `nvidia.com/gpu` | ~15 s | DaemonSet must schedule first |
| **container image pull (~10 GB)** | **3–5 min** | the biggest slice on a cold node |
| **model weights download (~4 GB)** | **1–2 min** | from huggingface.co, variable |
| load into VRAM | ~45 s | measured 42.9 s for Mistral-7B-AWQ |
| torch.compile + CUDA graphs | ~30 s | measured 25.8 s |
| **total** | **5–10 min** | |

Two phases dominate, and both are just *moving bytes*. Neither is compute.

## Why this matters more than it looks

- **Autoscaling is nearly useless as a burst response.** By the time a
  replica is Ready, the traffic spike is over. You scale on leading
  indicators (queue depth) and keep warm headroom, or you accept the lag.
- **Spot reclaim is expensive.** Losing a node does not cost you compute, it
  costs you the 5–10 minutes to rebuild that state somewhere else. During a
  real session a spot GPU was reclaimed after 30 minutes and the entire cost
  was re-pulling the image and re-downloading the weights.
- **Liveness probes will kill you.** A probe with default timings kills the
  pod long before the model finishes loading, forever. Hence the
  `startupProbe` with `failureThreshold: 90`.

## What this repo does now (phase 1)

vLLM downloads weights from Hugging Face at startup, into a **hostPath cache
at `/opt/hf-cache`**. Consequences, stated honestly:

- a pod rescheduled onto the **same** node skips the download
- a **new** node pays the full cost again
- nothing is shared between nodes

That is deliberate. The point of phase 1 is to make the problem *measurable*
before optimizing it.

## The four ways to fix it

| approach | startup | cost | catch |
|---|---|---|---|
| **Bake weights into the image** | fastest; node image cache serves every replica | large image (~15 GB) and a build pipeline | rebuild for every model change |
| **Init container pulls from S3** | fast — S3 to EC2 sustains 200+ MB/s | cheap | still per-pod; needs IRSA |
| **EFS PVC (ReadWriteMany)** | download once, every pod mounts it | pricier and slower than EBS | shared-filesystem latency |
| **Mountpoint for S3 CSI** | mount the bucket directly, no copy | cheapest | read-only, streaming semantics |

**The trap worth naming:** the obvious move is a PVC on the `gp3`
StorageClass. It does not work. EBS is **ReadWriteOnce** — one volume, one
node — and replicas are on different nodes by definition. This fails at
exactly two replicas, which is also exactly when you first need it.

## Phase 2, wired but not enabled

Terraform already creates an S3 bucket and an IRSA role scoped to the `vllm`
service account in the `inference` namespace. To switch:

1. Seed the bucket once (a Job that downloads from HF and syncs up, so no
   bandwidth from a laptop).
2. Annotate the ServiceAccount in `k8s/vllm/05-serviceaccount.yaml`:
   `eks.amazonaws.com/role-arn: <terraform output weights_reader_role_arn>`
3. Add an init container that runs `aws s3 sync` into the shared volume.

Expected gain: the 1–2 minute Hugging Face download becomes ~20 seconds, and
more importantly, **pod startup stops depending on a third party being up**.

## Numbers to record

```
cold node, phase 1  : image pull ___ | weights ___ | VRAM load ___ | total ___
warm node (cached)  : total ___
phase 2 (S3)        : weights ___ | total ___
```
