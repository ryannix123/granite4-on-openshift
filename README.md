<p align="center">
  <img src="images/logo.jpg" alt="Self-Hosted LLM on OpenShift" width="500">
</p>

# OpenShift Lightspeed with a Self-Hosted LLM on Single Node OpenShift

A homelab-scale reference architecture for running Red Hat OpenShift
Lightspeed against a self-hosted LLM on Red Hat OpenShift AI, with no
external LLM provider. Built around an SNO cluster with a consumer
NVIDIA GPU (RTX 3060 Ti / 8 GB VRAM).

The default model is **IBM Granite 4.1 3B** — a dense, instruction-tuned
language model released under Apache 2.0. The architecture supports
swapping to any vLLM-compatible model by changing the OCI model image
and a single ServingRuntime arg.

**Not officially supported by Red Hat.** This uses the OLS `openai`
provider type pointing at a self-hosted vLLM ServingRuntime. The
pattern works but is outside the supported provider matrix. For
production use with regulated customers, file a support exception
through your account team.

## What this builds

Three namespaces cooperating. The **model itself** runs in
`llm-serving`. **OpenShift AI** manages it from
`redhat-ods-applications`. The **NVIDIA driver** provides the GPU
from `nvidia-gpu-operator`. And **OpenShift Lightspeed** calls the
model over in-cluster DNS from `openshift-lightspeed`.

```
openshift-lightspeed              llm-serving
────────────────────              ───────────
lightspeed-app-server  ────HTTP──►  granite-41-3b-predictor (vLLM + Granite 4.1)
                                         │
                                         │ requests nvidia.com/gpu: 1
                                         ▼
                                   [ NVIDIA RTX 3060 Ti ]
                                         ▲
                        ┌────────────────┴────────────────┐
          reconciled by │                                 │ driver from
                        │                                 │
              redhat-ods-applications             nvidia-gpu-operator
              (KServe controller)                 (driver DaemonSet)
```

For a full walkthrough of what runs where, namespace responsibilities,
the end-to-end request path, and what changes at production scale,
see [ARCHITECTURE.md](ARCHITECTURE.md).

## Why Granite 4.1?

This project started with Google Gemma 4. During development, we
discovered that **all Gemma 4 variants use a Mixture-of-Experts (MoE)
architecture** that stores all 128 expert parameter sets in VRAM —
even the "Effective 2B" variant consumes ~9.5 GB. On an 8 GB consumer
GPU, no quantization or offloading strategy fits any Gemma 4 model
via vLLM.

IBM Granite 4.1 3B is a **dense** 3B-parameter model that fits on
8 GB VRAM. This project serves IBM's official FP8 quantization
(`ibm-granite/granite-4.1-3b-fp8`), which halves the weights from
~6.4 GB to ~3.4 GB and leaves ~3.7 GB for the KV cache — enough for
a 32k context window. In bf16 the same card affords only ~0.7 GB of
KV cache, capping context near 9.7k, which is not enough once
OpenShift Lightspeed starts injecting retrieved documentation into
the prompt. The FP8 image is also half the size to mirror into a
disconnected registry. It
benchmarks competitively with much larger models on instruction
following and tool calling (see the
[Granite 4.1 blog post](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)),
is Apache 2.0 licensed, and is supported by Red Hat.

For production deployments on larger GPUs (L4, L40S, H100), the same
architecture supports Granite 4.1 8B, 30B, or any model the customer
prefers — only the OCI model image and one `--served-model-name` arg
change.

## Hardware target

- Single Node OpenShift 4.19+ (required for RHOAI 3.x)
- 12th Gen Intel i9 (or equivalent), 64 GB+ RAM recommended
- NVIDIA RTX 3060 Ti (or any NVIDIA card with 8 GB+ VRAM)
- ~10 GB free on default storage class for model image pull (~3.9 GB image)

For a customer pilot, the target is a 3-node compact cluster with an
L4 or L40S GPU worker. The YAML in this bundle changes minimally
between the two — see "Scaling up" at the bottom.

## Two paths: manual or automated

You can apply the manifests by hand (`oc apply -f ...`) or run the
included Ansible playbook that handles everything — including GPU
auto-detection, readiness waits, and a CUDA validation step — in one
command.

- **Manual apply:** see "Apply order" below. Best when you're
  recording a video or learning the pattern step by step.
- **Ansible automation:** see [`ansible/README.md`](ansible/README.md).
  Best for repeat deployments, customer pilots, or when you just want
  the thing built without babysitting it.

Both paths apply the same YAML files. The Ansible playbook uses `oc`
under the hood — no extra Python dependencies, no SSH required.

A third playbook, `ansible/power.yml`, stops and starts the deployed
stack to reclaim RAM and the GPU between demos without destroying
configuration.

## Prerequisites (do these first, in this order)

1. **Install operators.** The Ansible playbook installs all four
   automatically if they are missing, so you can skip this step
   entirely on the automated path. For the manual path, install them
   from OperatorHub (in the web console):
   - Node Feature Discovery Operator
   - NVIDIA GPU Operator
   - Red Hat OpenShift AI — **select the `stable-3.x` channel**
   - OpenShift Lightspeed

   Wait for each to reach Succeeded before installing the next.

   > **Note:** RHOAI 3.x requires OCP 4.19 or later. If you are on an
   > older OCP version, upgrade first or use the `eus-2.y` channel
   > (which uses the older v1 DSC API — see `manifests/03-dsc.yaml`).

2. **Have a Quay account** at `quay.io` (or update the image
   references in `manifests/05-inferenceservice.yaml` and `build.sh`
   to your own namespace).

3. **Build and push the model image** using `build.sh`. The script
   downloads model weights from Hugging Face, packages them into an
   OCI ModelCar image, and pushes to Quay. See the "Building the
   model image" section below.

## Apply order (manual path)

```bash
# Phase 1: GPU plumbing
oc apply -f manifests/01-nfd.yaml
# Wait ~60s for NFD to label the node, then verify:
oc get nodes -o json | jq '.items[].metadata.labels' | grep 10de
# You should see: "feature.node.kubernetes.io/pci-10de.present": "true"

oc apply -f manifests/02-gpu-clusterpolicy.yaml
# This takes 5-10 min on first apply (driver build). Watch:
oc -n nvidia-gpu-operator get pods -w
# Wait until nvidia-driver-daemonset, nvidia-device-plugin-daemonset,
# and nvidia-operator-validator pods are all Running.

# Validate GPU is visible to pods (CRITICAL — do not skip):
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd-test
  namespace: default
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
oc -n default logs cuda-vectoradd-test
# Expected output ends with: "Test PASSED"
oc -n default delete pod cuda-vectoradd-test

# Phase 2: OpenShift AI
oc apply -f manifests/03-dsc.yaml
# Watch the RHOAI pods come up:
oc -n redhat-ods-applications get pods -w
# Wait for kserve-controller-manager and odh-model-controller to be
# Running. Should take 2-3 min.

# Phase 3: Deploy the model
oc apply -f manifests/00-namespace.yaml
oc apply -f manifests/04-servingruntime.yaml
oc apply -f manifests/05-inferenceservice.yaml
# Watch the predictor pod come up:
oc -n llm-serving get pods -w
# First start is slow: KServe pulls the OCI image (~3.9 GB), copies
# model files, vLLM loads the model. Expect 5-10 min.

# SMOKE TEST the model directly before touching OLS:
POD=$(oc get pod -n llm-serving -o jsonpath='{.items[0].metadata.name}')
oc exec -n llm-serving "$POD" -c kserve-container -- \
  curl -s http://localhost:8080/v1/models | python3 -m json.tool
# Should return a model with id "granite-41-3b"

oc exec -n llm-serving "$POD" -c kserve-container -- \
  curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "granite-41-3b",
    "messages": [{"role": "user", "content": "What is a Kubernetes Deployment in one sentence?"}],
    "max_tokens": 100
  }' | python3 -m json.tool
# Should return a coherent answer. If this fails, OLS will too —
# debug here first.

# Phase 4: Wire OLS
oc apply -f manifests/06-ols-secret.yaml
oc apply -f manifests/07-olsconfig.yaml
oc -n openshift-lightspeed get pods -w
# Wait for lightspeed-app-server to be 2/2 Running.
```

## Building the model image

The model is packaged as an OCI "ModelCar" image — a minimal
container with the model weights at `/models/`. KServe pulls this
image and mounts the weights into the vLLM serving container.

```bash
# Install huggingface_hub if not present
pip install --user huggingface_hub

# Log in to Hugging Face (needed for gated models; Granite 4.1 is
# open but login avoids rate limits)
hf auth login

# Log in to Quay
podman login quay.io

# Build and push
chmod +x build.sh
./build.sh v2-fp8
```

The script downloads ~3.4 GB of FP8 model weights from Hugging Face,
builds a ~3.9 GB OCI image on top of UBI 10 micro, and pushes to Quay.

> **Note:** `build.sh` skips the download if `model/config.json`
> already exists. After changing `MODEL_ID`, `rm -rf model/` first or
> you will repackage the previous weights under a new tag.

**Tip:** If pushing from a Mac is slow or unreliable (iCloud competing
for upload bandwidth, podman VM disk limits), push from a RHEL bastion
host instead. `podman` and `skopeo` on RHEL run natively without a VM
and push reliably over wired connections.

## Apply order (Ansible path)

```bash
cd ansible/
pip install --user ansible-core
oc login ...                                    # log in to target cluster
ansible-playbook -i inventory/hosts.ini deploy.yml
```

That's it. The playbook runs every step above — including installing
any missing operators via OLM, GPU detection via `oc debug node`,
readiness waits, and the CUDA validation pod — as a single idempotent
run. Operator channels are discovered from the cluster's own
catalog rather than hardcoded. To skip operator installation and
verify only, pass `-e install_operators=false`. See
[`ansible/README.md`](ansible/README.md) for tags, troubleshooting,
and teardown instructions.

To stop the stack between demos without tearing anything down, see
"Powering the stack down and back up" below.

## Demo: ask OLS a question

1. In the OCP web console, click the Lightspeed sparkle icon
   (top-right corner).
2. Ask: "How do I create a PersistentVolumeClaim with the LVM storage
   class?"
3. In a side terminal:
   `oc -n llm-serving logs -f deployment/granite-41-3b-predictor`
   You'll see the request hit and tokens stream back.

## Powering the stack down and back up

On a single node with 8 GB of VRAM and finite RAM, you will not want
the model resident when you are not demoing. `ansible/power.yml` stops
and starts the stack without destroying any configuration.

```bash
cd ansible/

# What's running right now, and what the node costs. Changes nothing.
ansible-playbook -i inventory/hosts.ini power.yml

# Stop OpenShift Lightspeed and model serving (default scope)
ansible-playbook -i inventory/hosts.ini power.yml -e state=down

# Stop the model only; leave OLS running
ansible-playbook -i inventory/hosts.ini power.yml -e state=down -e scope=model

# Also tear down the DataScienceCluster (KServe controllers, dashboard)
ansible-playbook -i inventory/hosts.ini power.yml -e state=down -e scope=rhoai

# Bring the whole stack back, in dependency order
ansible-playbook -i inventory/hosts.ini power.yml -e state=up
```

`scope` is a ladder — each level includes the ones below it:

| Scope | Stops | Frees |
|---|---|---|
| `model` | InferenceService | The GPU, plus the predictor's 12-16Gi request |
| `ols` *(default)* | + OLSConfig | App server, Postgres, and the Solr/RHOKP retrieval pod |
| `rhoai` | + DataScienceCluster | KServe controllers and the RHOAI dashboard |

**Why it deletes custom resources instead of scaling deployments.**
KServe and the Lightspeed operator both reconcile their workloads, so
a hand-scaled Deployment comes straight back. Deleting the
`InferenceService` and `OLSConfig` CRs is what actually tells the
controllers to stand down. Nothing is lost — both are fully defined in
`manifests/`, and `state=up` re-applies those same files.

Restarting is fast because the model image stays in the node's
container storage: `state=up` is a model load (~1-3 min), not a 3.9 GB
image pull.

**What deliberately keeps running:** the four operators, the NVIDIA
driver daemonset, and NFD. They are small, and stopping the driver
would mean rebuilding it on the next start.

> **Note:** `scope=rhoai` removes the DataScienceCluster, which stops
> the KServe controllers — but not the RHOAI operator itself. OLM
> reverts manual scaling of a CSV-owned deployment, so the operator pod
> stays. The DSC-managed workloads are where the memory actually is.

Run the status mode before and after to measure the real saving on
your node rather than trusting an estimate — it prints `oc adm top
node` alongside a pod inventory for each namespace.

## Swapping models

The architecture is model-agnostic. To swap in a different model:

1. Update `MODEL_ID` and `IMAGE_REPO` in `build.sh`.
2. Run `rm -rf model/ && ./build.sh <tag>` to download, build, and push.
3. Update `storageUri` in `manifests/05-inferenceservice.yaml`.
4. Update `--served-model-name` in `manifests/04-servingruntime.yaml`.
5. Update `models[].name` in `manifests/07-olsconfig.yaml`.
6. Adjust vLLM args (`--max-model-len`, `--gpu-memory-utilization`,
   etc.) based on the model's size and your GPU's VRAM.
7. Set `contextWindowSize` in `manifests/07-olsconfig.yaml` to the
   **same value** as `--max-model-len`. If OLS believes the window is
   larger than vLLM will accept, the first question in a conversation
   succeeds and follow-ups fail once retrieved docs fill the prompt.
8. Check whether the model's tool-call format matches the configured
   `--tool-call-parser` (see Troubleshooting).
9. `oc apply` the updated manifests.

Models tested or considered during development:

| Model | Type | Size (bf16) | Fits 8 GB? | Notes |
|---|---|---|---|---|
| **Granite 4.1 3B FP8** | Dense | 3.4 GB | ✅ Yes | **Current default.** ~3.7 GB KV cache → 32k context |
| Granite 4.1 3B (bf16) | Dense | 6.4 GB | ⚠️ Barely | Only ~0.7 GB KV cache → ~9.7k context ceiling |
| Gemma 4 E4B | MoE | ~15 GB total | ❌ No | "Effective 4B" but MoE stores all experts in VRAM |
| Gemma 4 E2B | MoE | ~9.5 GB total | ❌ No | Same MoE trap as E4B |
| Granite 4.1 8B | Dense | ~16 GB | ❌ No | Great for L4/L40S production deployments |
| Llama 3.2 3B | Dense | ~6 GB | ✅ Yes | Alternative; Meta Community License |

## Troubleshooting matrix

| Symptom | Likely cause | Fix |
|---|---|---|
| `nvidia-driver-daemonset` CrashLoop | Driver version doesn't support your GPU | Pin `driver.version` in `manifests/02-gpu-clusterpolicy.yaml` to a known-good build (e.g. `550.90.07`) and re-apply |
| `cuda-vectoradd-test` pod fails | GPU Operator not fully ready | Wait longer; check `nvidia-operator-validator` logs |
| Predictor pod stuck `Init` | OCI image pull slow or repo private | Check `oc describe pod` for image pull progress; make Quay repo public |
| vLLM CrashLoop with CUDA OOM | Model too large for GPU | Lower `--max-model-len` and `--gpu-memory-utilization`, or use a smaller model |
| vLLM CrashLoop with KV cache error | `max-model-len` exceeds available KV cache | Reduce `--max-model-len` or increase `--gpu-memory-utilization` |
| OLS "prompt exceeds maximum token limit" | Context window too small for OLS system prompt | Increase `--max-model-len` to 8192+ |
| OLS "Connection error" to predictor | Port mismatch or service name wrong | Verify OLSConfig URL includes `:8080` and matches `oc get svc -n llm-serving` |
| OLS pod can't reach predictor | Wrong service name/URL | Verify with `oc -n llm-serving get svc`; the service is `<isvc-name>-predictor` in RawDeployment mode |
| Old ReplicaSet deadlocks new deployment | Rolling update can't schedule (GPU contention) | Set `deploymentStrategy.type: Recreate` in `05-inferenceservice.yaml`. To unstick now: `oc scale replicaset -n llm-serving <old-rs> --replicas=0` |
| OLS answer shows raw `<tool_call>{...}</tool_call>` text | vLLM `--tool-call-parser` doesn't match the model's format | Granite 4.1 emits Hermes-style tags — use `--tool-call-parser=hermes`. The `granite` parser targets Granite 3.x's `<\|tool_call\|>` array format. Confirm with the model's own `chat_template.jinja` |
| OLS: "prompt exceeds available context window limit 512" | `contextWindowSize` too small for OLS's own budgeting | OLS reserves 512 tokens for the response by default and needs far more declared headroom than the raw prompt. Raise `contextWindowSize` well above the prompt size |
| First question works, follow-ups fail with token limit | `contextWindowSize` > vLLM `--max-model-len` | Make them equal. Turn 2 carries history plus turn 1's retrieved docs, which is what overflows |
| Predictor pod never appears, no Deployment created | `runtime:` in the ISVC doesn't match a ServingRuntime name | `oc -n redhat-ods-applications logs deploy/kserve-controller-manager \| grep -i "No ServingRuntimes"`. The Ansible playbook catches this in ~1s |
| vLLM: "estimated maximum model length is N" | KV cache too small for `--max-model-len` | Use FP8 weights (halves weight memory) or lower `--max-model-len` to N. `--max-num-seqs` does **not** change pool size in vLLM V1 |
| `Marlin kernel` warning on startup | GPU lacks native FP8 compute (pre-Ada) | Expected on Ampere. Weight-only FP8 compression; memory savings kept, no throughput gain |

## Scaling up: from SNO/3060 Ti to L4/L40S pilot

The OLSConfig is identical between homelab and pilot. Only three
things change:

1. **Model size**: Build a new OCI image with a larger model
   (e.g. `ibm-granite/granite-4.1-8b` or `ibm-granite/granite-4.1-30b`).
   Update `storageUri` in `manifests/05-inferenceservice.yaml`.

2. **vLLM args**: Drop `--enforce-eager`, raise `--max-model-len` to
   32768 or higher, raise `--max-num-seqs` to 16-32 for real
   concurrency. Raise memory limit to 64 Gi.

3. **Deployment mode**: For scale-to-zero, switch from
   `RawDeployment` to `Serverless`. In RHOAI 3.x this default lives in
   the `inferenceservice-config` ConfigMap in `redhat-ods-applications`,
   not in the DataScienceCluster — the v1 `kserve.defaultDeploymentMode`
   field no longer exists in the v2 DSC API. Check the current value
   with:

   ```bash
   oc get cm inferenceservice-config -n redhat-ods-applications \
     -o jsonpath='{.data.deploy}'
   ```

   Serverless costs Knative + Istio overhead but is the more
   "enterprise" pattern.

That's it. The OLSConfig (`manifests/07-olsconfig.yaml`) doesn't
change at all.

## Repository layout

```
├── manifests/
│   ├── 00-namespace.yaml ........ llm-serving namespace
│   ├── 01-nfd.yaml .............. NodeFeatureDiscovery instance
│   ├── 02-gpu-clusterpolicy.yaml  NVIDIA GPU Operator config
│   ├── 03-dsc.yaml .............. RHOAI DataScienceCluster (trimmed for SNO)
│   ├── 04-servingruntime.yaml ... vLLM ServingRuntime (Granite 4.1 compatible)
│   ├── 05-inferenceservice.yaml . Granite 4.1 3B InferenceService
│   ├── 06-ols-secret.yaml ....... Placeholder OLS credentials secret
│   ├── 07-olsconfig.yaml ........ OLSConfig pointing at the KServe predictor
│   └── 08-metrics.yaml .......... vLLM Prometheus metrics (applied manually)
├── ansible/
│   ├── deploy.yml ............... Full deployment playbook (oc-based)
│   ├── power.yml ................ Stop/start the stack to reclaim RAM + GPU
│   ├── teardown.yml ............. Remove CRs; optionally uninstall operators
│   ├── README.md ................ Ansible-specific docs
│   ├── inventory/hosts.ini ...... Localhost-only inventory
│   ├── group_vars/all.yml ....... Operators, timeouts, GPU ID table
│   ├── tasks/
│   │   ├── install-operators.yml   Subscribe one operator via OLM and wait
│   │   └── uninstall-operators.yml Remove one operator's Sub/CSV/OG/namespace
│   └── templates/
│       └── operator-subscription.yaml.j2  Namespace + OperatorGroup + Subscription
├── tests/
│   ├── README.md ................ How to run the OLS answer-quality suite
│   ├── test-ols.yml ............. Ask OLS a question set, score the answers
│   ├── test-questions.yml ....... Question bank for the above
│   ├── test-tool-calling.yml .... Tool-calling capability suite
│   ├── test-tool-calling-questions.yml  Question bank for tool calling
│   └── ols-test-report example.json ... Sample JSON report output
├── hummingbird/
│   ├── Containerfile ............ Project Hummingbird distroless variant
│   └── README.md ................ Hummingbird build notes
├── .github/workflows/
│   └── build-model-image.yml .... CI/CD: build and push model image to Quay
├── images/
│   └── logo.jpg ................. Project logo
├── Containerfile ................ OCI ModelCar image definition
├── build.sh ..................... HF download + image build + Quay push
├── ARCHITECTURE.md .............. Namespace and component architecture
├── .gitignore
└── README.md .................... This file
```

## CI/CD

The repo includes a GitHub Actions workflow at
`.github/workflows/build-model-image.yml` that rebuilds the model
OCI image and pushes it to Quay. It runs three ways:

| Trigger | Tags pushed |
|---|---|
| Manual dispatch (with a tag input) | `:<tag>` and `:hummingbird-<tag>` |
| Push to `main` touching `Containerfile`, `hummingbird/Containerfile`, or `build.sh` | `:latest`, `:hummingbird-latest` — see note |
| Weekly cron — Sundays 06:00 UTC | `:latest`, `:hummingbird-latest` |

Pin `storageUri` to an explicit tag, never `:latest`. The scheduled
rebuild re-downloads from Hugging Face and republishes `:latest` every
week, so anything pinned there can change under a running deployment.

> **Note:** the push trigger is configured for the `main` branch, but
> this repo's default branch is `master`, so push builds never fire.
> Only manual dispatch and the weekly cron currently run. Change
> `on.push.branches` to `master` if you want push builds.

> **Note:** `MODEL_ID` is defined in **two** places — the `env:` block
> of the workflow and `build.sh`. Change both together or CI and local
> builds will produce different images.

To enable it, configure three secrets in your GitHub repo
(Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `HF_TOKEN` | Hugging Face access token |
| `QUAY_USERNAME` | Quay robot account name (e.g. `ryan_nix+github_actions`) |
| `QUAY_TOKEN` | Quay robot account password |

Use a **robot account**, not your personal Quay credentials — scope
the robot to write access on just the model image repository.

## Disclaimer

The projects and opinions in this repository are Ryan's own and are
not official Red Hat positions or products.