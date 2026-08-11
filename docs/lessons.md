# Lessons learned

Things that were not obvious, mostly discovered by breaking them.

## GPUs are not like CPU and memory

Kubernetes natively understands two resources. It has never heard of a GPU —
the NVIDIA **device plugin** DaemonSet teaches kubelet about them, advertising
`nvidia.com/gpu` as an *extended resource*.

Extended resources behave differently in ways that shape the whole design:

- **Indivisible.** There is no `500m` of a GPU. One pod claims the whole card.
- **Non-overcommittable.** They may only be set in `limits`; `requests` is
  mirrored automatically.
- **One GPU per node means one pod per node** on g4dn.xlarge. Bin-packing does
  not apply, so replicas scale cost linearly.

A related trap: `g4dn.4xlarge`, `8xlarge` and `16xlarge` all have exactly
**one** T4, the same as `xlarge`. You pay 8x for CPU and RAM, not silicon.
Only `12xlarge` (4 GPUs) and `metal` (8) give you more.

## The taint does the protecting; the resource does the attracting

A toleration only *permits* a pod to land on a tainted node — it never pulls
it there. What actually attracts the vLLM pod to a GPU node is requesting
`nvidia.com/gpu: 1`, because only GPU nodes advertise that resource.

So the pattern is: taint GPU nodes so cheap workloads stay off, tolerate the
taint on GPU workloads, and let the resource request do the scheduling. You
rarely need explicit node affinity.

The device plugin DaemonSet must itself tolerate the taint, or it cannot run
on the nodes it exists to advertise.

## Sharing a GPU: three mechanisms, very different guarantees

| | isolation | hardware |
|---|---|---|
| **Time-slicing** | none — every pod sees full VRAM and can OOM the others | any GPU |
| **MPS** | better concurrency, still no memory isolation | most GPUs |
| **MIG** | true hardware partitioning of SMs and memory | A100/H100 only |

Time-slicing is a one-line device-plugin config that makes one GPU advertise
as N. It is oversubscription with no enforcement — good for dev density and
notebooks, dangerous for production multi-tenancy. MIG is the real answer and
it is a purchasing decision, not a config one.

## Consolidation policy has to change for GPU nodes

The general-purpose NodePool uses `WhenEmptyOrUnderutilized`, because
repacking a stateless web pod costs seconds.

GPU nodes use **`WhenEmpty`**. An inference pod is *supposed* to look
underutilized much of the time, and evicting one costs 5–10 minutes to come
back somewhere else. Empty is the only safe signal.

## Probes decide whether this works at all

The most common reason LLM pods CrashLoopBackOff on Kubernetes is a liveness
probe firing during model load. `startupProbe` with a long
`failureThreshold` holds liveness off until the server is genuinely up. See
[cold-start.md](cold-start.md).

## nvidia-smi cannot tell you if a GPU is busy

`GPU-Util` is the percentage of sampled time during which *at least one*
kernel was running — not how much of the GPU was used. A kernel touching 2%
of the SMs reads as 100%.

DCGM exporter gives the metrics that actually diagnose:

- high `DRAM_ACTIVE`, low `PIPE_TENSOR_ACTIVE` → **memory-bound**, which is
  normal and expected during decode
- low on both → **starved**: batch too small, or a CPU-side bottleneck

Measured directly: at concurrency 1 the GPU consumed ~67% of memory
bandwidth; at concurrency 32 it consumed ~33% while producing 15.8x the
tokens. The bottleneck moved from memory to compute, and that is visible in
DCGM but invisible in `nvidia-smi`.

## Scale on queue depth, not CPU

A vLLM pod keeps CPU low while the GPU does the work, so a CPU-based HPA is
blind. `vllm:num_requests_waiting` is a direct measure of "arriving faster
than we serve", and it needs KEDA or the Prometheus Adapter to reach an HPA.

Even then, help takes 5–10 minutes to arrive, so the honest strategy is
leading indicators plus warm headroom — not reactive scaling.

## Spot GPUs: the cost is recovery, not compute

A spot g4dn was reclaimed 30 minutes into a session
(`Server.SpotInstanceTermination`) in an availability zone that had scored
1/10 on `aws ec2 get-spot-placement-scores` that morning. Losing the compute
was irrelevant; rebuilding the state took ~10 minutes.

Two things follow: placement scores are a genuine leading indicator worth
checking before a session, and every cold-start fix is really an
interruption-recovery fix.

Also worth knowing: **spot and on-demand are separate vCPU quotas**
(`L-3819A6DF` vs `L-DB2E81BA`). Having spot approved tells you nothing about
on-demand — switching to on-demand as a fallback failed instantly with
`VcpuLimitExceeded ... limit of 0`.
