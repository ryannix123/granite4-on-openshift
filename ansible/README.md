# Ansible playbook for OLS + Self-Hosted LLM on SNO

Automates operator installation, GPU detection, and manifest application
for the OpenShift Lightspeed + self-hosted LLM reference architecture.

**No SSH required. No Python Kubernetes libraries. Just `oc` and
`ansible-core`.**

## What it does

1. **Installs the four required operators** if they aren't already
   present — Node Feature Discovery, NVIDIA GPU Operator, Red Hat
   OpenShift AI, and OpenShift Lightspeed — by creating the Namespace,
   OperatorGroup and Subscription for each, then blocking until the CSV
   reports `Succeeded` and the CRD is `Established`.
2. **Detects the NVIDIA GPU** on the SNO node via `oc debug node` +
   `lspci` in a privileged debug pod. Fails loudly if no NVIDIA GPU
   is present. Identifies the specific model and warns about known
   consumer-GPU driver issues.
3. Applies the NFD and GPU Operator manifests via `oc apply`, waits
   for the driver daemonset to finish building (5-10 min on first run)
   using `oc wait`.
4. Runs a CUDA vector-add validation pod to prove the GPU is usable
   from a container.
5. Applies the trimmed RHOAI DataScienceCluster.
6. Deploys the InferenceService and smoke-tests it by `oc exec`-ing
   a curl into the predictor pod.
7. Wires up OpenShift Lightspeed via OLSConfig.
8. Prints a summary with the console URL and next steps.

## Prerequisites

### On the machine running the playbook (your laptop)

```bash
# Just ansible-core. No collections, no Python K8s libraries.
pip install --user ansible-core

# And of course `oc` on your PATH, already logged in:
oc whoami
```

### In the cluster

Nothing. Bare SNO cluster with a GPU is enough — the playbook installs
what it needs.

If you'd rather install the operators yourself (see
[Opting out](#opting-out-of-operator-installation) below), these are the
four:

| Operator | Package | Namespace |
|---|---|---|
| Node Feature Discovery | `nfd` | `openshift-nfd` |
| NVIDIA GPU Operator | `gpu-operator-certified` | `nvidia-gpu-operator` |
| Red Hat OpenShift AI | `rhods-operator` | `redhat-ods-operator` |
| OpenShift Lightspeed | `lightspeed-operator` | `openshift-lightspeed` |

### Environment

- `oc` in PATH
- Already logged in to the target cluster (`oc login ...`)
- Current user has cluster-admin privileges (required to create
  Subscriptions — the playbook checks this up front with
  `oc auth can-i`)
- The OCI model image already built and pushed to Quay (see
  `../build.sh`)
- The cluster can reach `redhat-operators` and `certified-operators`,
  or a mirror carrying those four packages

## Usage

Full run:

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml
```

Install the operators and stop there:

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --tags operators
```

Just detect the GPU (no cluster changes made — the `detect` tag
deliberately does *not* pull in the operator install):

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --tags detect
```

Re-apply just the OLS config (after tweaking `manifests/07-olsconfig.yaml`):

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --tags ols
```

Dry run to see what would change:

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --check --diff
```

Target a different cluster — just log in somewhere else first:

```bash
oc login https://api.customer-cluster.example.com:6443
ansible-playbook -i inventory/hosts.ini deploy.yml
```

## How operator installation works

The playbook checks for each operator's CRD (`clusterpolicies.nvidia.com`,
`olsconfigs.ols.openshift.io`, and so on). Anything missing gets
installed; anything already there is left completely alone, including
its channel and version. Installing on top of an existing operator is
never attempted.

**Channels are discovered, not hardcoded.** For each package the
playbook reads `.status.defaultChannel` and `.status.catalogSource`
straight off the cluster's own `packagemanifest`:

```bash
oc get packagemanifest gpu-operator-certified -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}'
```

That way the playbook doesn't rot every time NVIDIA cuts a new `v25.x`
stream or Red Hat renames an RHOAI channel. If you need determinism for
a customer demo, pin it in `group_vars/all.yml`:

```yaml
  - name: "NVIDIA GPU Operator"
    package: "gpu-operator-certified"
    namespace: "nvidia-gpu-operator"
    crd: "clusterpolicies.nvidia.com"
    catalog_source: "certified-operators"
    fallback_channel: "stable"
    channel: "v25.3"                              # pin the channel
    starting_csv: "gpu-operator-certified.v25.3.0" # or the exact version
```

Precedence is: `channel` in `group_vars` → the catalog's
`defaultChannel` → `fallback_channel`.

**Order matters and is preserved.** `required_operators` is a list, not
a dict, and it's walked top to bottom: NFD before the GPU Operator
(which needs NFD's `feature.node.kubernetes.io/pci-10de.present` label
before it does anything), then RHOAI, then Lightspeed.

**Existing OperatorGroups are reused.** A namespace may only contain one
OperatorGroup; a second one wedges OLM for everything in that namespace.
If the playbook finds one already there, it subscribes into it rather
than creating its own.

### Opting out of operator installation

Set `install_operators: false` to restore the original behavior — verify
only, and fail with instructions naming exactly what's missing:

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml -e install_operators=false
```

Worth doing when you want the OperatorHub click-through visible in a
demo, or when the customer's cluster is governed by GitOps and
Subscriptions aren't allowed to originate from a laptop.

## Available tags

| Tag | What it runs |
|---|---|
| `detect` | GPU detection only (oc debug node + lspci) — never changes the cluster |
| `operators` | Install/verify the four operators |
| `gpu` | Operators + detection + NFD + GPU Operator + CUDA validation |
| `rhoai` | Operators + DataScienceCluster |
| `model` | Operators + Namespace + ServingRuntime + InferenceService + smoke test |
| `ols` | Operators + OLS secret + OLSConfig |
| `validate` | Summary output with console URL |

Every tag except `detect` pulls in the operator phase, because every
other phase applies a CR that one of the four operators owns.

## Teardown

```bash
ansible-playbook -i inventory/hosts.ini teardown.yml
```

Removes all CRs deployed by `deploy.yml` and leaves the operators
installed — which is what you want between demo runs.

To also remove the operators (Subscriptions, CSVs, OperatorGroups,
namespaces):

```bash
ansible-playbook -i inventory/hosts.ini teardown.yml -e uninstall_operators=true
```

CRDs are deliberately left behind. Deleting a CRD deletes every CR of
that type cluster-wide, which is too blunt to do implicitly; the
teardown prints the exact `oc delete crd` command if you want it.

## How GPU detection works without SSH

The playbook uses `oc debug node/<n>` — a built-in OCP mechanism that
spawns a privileged debug pod on the target node with the host
filesystem mounted at `/host`. Then it chroots into `/host` and runs
`lspci -nn`, which sees the real PCI devices on the node, including
any NVIDIA GPU.

This is the canonical "run a command on an OCP node" pattern and works
identically on RHCOS, SNO, and any other OCP node type. No SSH keys,
no firewall rules, no user account management.

## Re-running

The playbook is idempotent — every `oc apply` naturally is, and all
`oc delete` operations use `--ignore-not-found`. Re-running after a
partial failure picks up where it left off. Re-running after a
successful run is a no-op (modulo the smoke test, which always runs).

Operator installation is idempotent the same way: on a second run all
four CRDs are found, `missing_operators` is empty, and the whole phase
is skipped.

## Troubleshooting

**`oc whoami` fails at preflight.** You're not logged in, or your
token expired. Run `oc login ...` and retry.

**"cannot create Subscriptions cluster-wide."** You're logged in as a
user without cluster-admin. Either log in as cluster-admin or run with
`-e install_operators=false` and have the operators pre-installed.

**"Package X was not found in any CatalogSource."** Either the catalog
is still starting, or it isn't carrying that package (common on
disconnected clusters with a mirrored catalog):

```bash
oc get catalogsource -n openshift-marketplace
oc get pods -n openshift-marketplace
oc get operatorhub cluster -o yaml     # are sources disabled?
oc get packagemanifest -n openshift-marketplace | grep -Ei 'nfd|gpu|rhods|lightspeed'
```

**CSV never reaches Succeeded.** Look at the InstallPlan and the CSV's
own status message:

```bash
oc get sub,ip,csv -A | grep -Ev 'Succeeded|Complete'
oc describe csv -n redhat-ods-operator | sed -n '/Conditions/,$p'
```

The usual cause is a channel that doesn't exist on this cluster's
catalog. List what's actually there and pin it:

```bash
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
```

**Operator install is slow.** RHOAI is the slowest of the four. Raise
`operator_install_timeout` in `group_vars/all.yml` (default 600s).

**NFD wait times out.** NFD operator pod may not be running. Check
`oc get pods -n openshift-nfd`. The NodeFeatureDiscovery CR requires
the operator to be installed first.

**Driver daemonset wait times out.** On a 3060 Ti (or other consumer
GPU), the NVIDIA driver build can fail. Check pod logs:
`oc -n nvidia-gpu-operator logs -l app.kubernetes.io/component=nvidia-driver`.
If you see driver version issues, pin `driver.version` in
`manifests/02-gpu-clusterpolicy.yaml` to a known-good build (e.g.
`550.90.07`) and re-run with `--tags gpu`.

**DSCInitialization never goes Ready in Phase 2.** RHOAI creates
`default-dsci` itself shortly after the operator installs. If it's
still absent after five minutes, check the operator logs:
`oc -n redhat-ods-operator logs -l name=rhods-operator`.

**KServe wait times out in Phase 2.** The label selector
`control-plane=kserve-controller-manager` may not match what RHOAI
actually uses in your version. Check:

```bash
oc -n redhat-ods-applications get pods --show-labels | grep kserve
```

Update the selector in `deploy.yml` Phase 2 accordingly.

**Smoke test curl fails.** The model name mismatch is the most common
cause. Check what vLLM is actually advertising:

```bash
oc exec -n llm-serving <predictor-pod> -c kserve-container -- \
  curl -s http://localhost:8080/v1/models
```

The `id` field in that response must match `--served-model-name` in
`manifests/04-servingruntime.yaml` and `models[].name` in
`manifests/07-olsconfig.yaml`.
