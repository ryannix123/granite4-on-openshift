# Granite 4.1 / 4.2 Dual-Model Setup

Run either Granite **4.1 3B** (the proven OLS backend, 95% validation pass)
or the new Granite **4.2 3B** reasoning model on the same SNO GPU, and pivot
between them without ripping anything out.

Both live in the same Quay repo, distinguished by tag:

| Model | Explicit tag | Floating tag | Build with |
|---|---|---|---|
| granite-4.1-3b | `:v1` | `:latest` | `./build-granite41.sh` |
| granite-4.2-3b | `:granite42-v1` | `:granite42-latest` | `./build-granite42.sh` |

`:latest` always stays on the proven 4.1 model — 4.2 gets its own floating
tag — so nothing auto-switches under you.

## Build the 4.2 image

```bash
./build-granite42.sh
# downloads ibm-granite/granite-4.2-3b, builds, pushes :granite42-v1 + :granite42-latest
```

The model weights download into `model-ibm-granite-granite-4.2-3b/`, kept
separate from the 4.1 weights so the two never cross-contaminate. The build
symlinks the right one to `model/` for the Containerfile.

## Switching which model runs

Only one fits on the 8 GB card at a time. Two InferenceServices exist:
`granite-41-3b` and `granite-42-3b`. Stop one, start the other.

**Try 4.2:**

```bash
oc annotate isvc granite-41-3b -n llm-serving serving.kserve.io/stop=true --overwrite
oc apply -f manifests/05-inferenceservice-granite42.yaml
oc get pod -n llm-serving -w      # wait for granite-42-3b-predictor 2/2
```

**Pivot back to 4.1:**

```bash
oc annotate isvc granite-42-3b -n llm-serving serving.kserve.io/stop=true --overwrite
oc annotate isvc granite-41-3b -n llm-serving serving.kserve.io/stop-
oc get pod -n llm-serving -w
```

## Pointing OLS at the 4.2 model

OLSConfig targets a predictor Service by DNS name. 4.1 is
`granite-41-3b-predictor`; 4.2 is `granite-42-3b-predictor`. To send OLS to
4.2, update the provider URL:

```bash
oc patch olsconfig cluster --type=json -p='[{
  "op":"replace",
  "path":"/spec/llm/providers/0/url",
  "value":"http://granite-42-3b-predictor.llm-serving.svc.cluster.local:8080/v1"
}]'
```

Change `granite-42-3b-predictor` back to `granite-41-3b-predictor` to revert.
Everything else in the OLSConfig (contextWindowSize, introspectionEnabled)
stays as-is.

## Two things to verify on the 4.2 bring-up

These are the same unknowns that took time on the 4.1 bring-up — check them
first if 4.2 misbehaves:

1. **served-model-name.** The shared `vllm-granite` ServingRuntime hardcodes
   `--served-model-name=granite-41-3b`. When 4.2 runs through it, clients
   still address the model as `granite-41-3b`. That's harmless for OLS (it
   uses whatever name the endpoint reports), but if you want the id to read
   `granite-42-3b`, either give 4.2 its own ServingRuntime with the matching
   name, or override the arg. Easiest for A/B testing: leave it, and track
   which model is live by which ISVC is running.

2. **tool-call parser.** 4.1 used `--tool-call-parser=granite`. If 4.2
   changed the tool-call format, vLLM may need a different parser name. If
   the predictor crashes on startup with an "invalid tool call parser"
   error, check the log for the valid list (as we did for 4.1) and update
   the ServingRuntime arg. Since OLS runs with `introspectionEnabled: false`
   anyway, tool calling isn't exercised in your OLS demo — but it matters if
   you test tool calling separately.

## A/B testing with the validation suite

Run the same 20-question suite against each model and compare:

```bash
# with 4.1 running:
cd ansible && ansible-playbook -i inventory/hosts.ini ../tests/test-ols.yml
cp /tmp/ols-test-report.json /tmp/report-granite41.json

# switch to 4.2 (steps above), point OLS at it, then:
ansible-playbook -i inventory/hosts.ini ../tests/test-ols.yml
cp /tmp/ols-test-report.json /tmp/report-granite42.json

python3 -c "
import json
for v in ['granite41','granite42']:
    d=json.load(open(f'/tmp/report-{v}.json'))
    print(f\"{v}: {d['summary']['passed']}/{d['summary']['total']} ({d['summary']['score_pct']}%)\")
"
```

Same questions, same scoring — a clean head-to-head on your own hardware
before you commit to either.
