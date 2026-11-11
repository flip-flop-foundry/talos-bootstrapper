#!/usr/bin/env bash
# Protect legacy Gateway API CRDs before publishing the Traefik chart upgrade.
# No delete, no ownership rewrite, no CRD spec changes. Python is stdlib-only.
set -euo pipefail
: "${HOOK_RENDERED_DIR:?run through run-deployment-hooks.sh}"
: "${HOOK_KUBE_CONTEXT:?validated Kubernetes context required}"
python3 - <<'PY'
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

SYNC = "argocd.argoproj.io/sync-options"
TRACK = "argocd.argoproj.io/tracking-id"
SKIP = "argocd.argoproj.io/skip-reconcile"
GROUP = "gateway.networking.k8s.io"
PIN = (1, 6, 3)
LEGACY_OWNERS = {"traefik", "traefik_traefik"}  # Argo apps-in-any-namespace InstanceName.
CRD_NAMES = {f"{name}.{GROUP}" for name in (
    "backendtlspolicies", "gatewayclasses", "gateways", "grpcroutes", "httproutes",
    "listenersets", "referencegrants", "tcproutes", "tlsroutes", "udproutes")}
UPSTREAM_HASHES = {
    "backendtlspolicies": "d9824b82db284bdea67d2eb0297952be51e0e7a394f02daef0d6f3fefa5d01c0",
    "gatewayclasses": "d32070cb6930273a07c5ca183135712b1918cc140c6d9b6cef441cdf0e562345",
    "gateways": "905c89d8fefaab9088bf9d0a8d47ebd7ec4e653a914d4bfaa575a7716f07a828",
    "grpcroutes": "a96b307008290c194ad346f9bb9346dd560c12e4d4e7dfbdbe7d2fb5e812d62e",
    "httproutes": "a89d17ff5ed060fa0eac015524f9252bb291f616412c13ac8cb952ed9c25c5ad",
    "listenersets": "b81f1771dcd96dfb3bb500e07dafef79a2aa58c4a9b4b366d54ca29e8ecccb5e",
    "referencegrants": "ff8db85aaacc91fb4096975afb5782540572bf2f04842a258094cd7f50c7f38a",
    "tcproutes": "5d2891484c870865e9ae61402b412a8b81eea381fbb71fdc56406e533c9643f1",
    "tlsroutes": "b9277b755ee0f33dd245d3497ba842922ff2e2efe5070b0911e58d072d55ed9c",
    "udproutes": "a552a9aa3726367c392000a45d13e6ba07985117a5e6826364640bedfeb5e922",
    "vap_safeupgrades": "66b1d7b2c392c0e4dd4b2950e2af62811f8288a65e50708e2b3d26d4433af84c",
}


def fail(message):
    raise RuntimeError(message)


def command(argv, input_text=None):
    result = subprocess.run(argv, text=True, capture_output=True, input=input_text)
    if result.returncode:
        fail(f"Command failed ({result.returncode}): {' '.join(argv[:7])}\n{result.stderr.strip()}")
    return result.stdout


def kube(*args):
    return command(["kubectl", "--context", os.environ["HOOK_KUBE_CONTEXT"],
                    "--request-timeout=20s", *args])


def get(*args):
    text = kube("get", *args, "-o", "json")
    return json.loads(text) if text.strip() else None


def owner(crd):
    metadata = crd["metadata"]
    tracking = metadata.get("annotations", {}).get(TRACK)
    if tracking:
        app, separator, identity = tracking.partition(":")
        if separator and identity == f"apiextensions.k8s.io/CustomResourceDefinition:/{metadata['name']}":
            return app
        return None  # Non-self-referencing tracking annotations aren't ownership.
    return metadata.get("labels", {}).get("app.kubernetes.io/instance")


def options(resource):
    return [x.strip() for x in resource.get("metadata", {}).get("annotations", {}).get(SYNC, "").split(",") if x.strip()]


def protected(resource):
    values = options(resource)
    return ("Prune=false" in values and "Delete=false" in values
            and not any(x.startswith(("Prune=", "Delete=")) and x not in ("Prune=false", "Delete=false") for x in values))


def annotate(resource_type, resource, additions, namespace=None):
    metadata = resource["metadata"]
    annotations = dict(metadata.get("annotations", {}))
    annotations.update(additions)
    patch = [
        {"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
        {"op": "add", "path": "/metadata/annotations", "value": annotations},
    ]
    args = ["patch", resource_type, metadata["name"], "--type=json", "-p", json.dumps(patch)]
    if namespace:
        args.extend(["-n", namespace])
    kube(*args)  # CAS failure is visible and blocks publication; safe to re-run.


def active(app):
    return bool(app.get("operation")) or app.get("status", {}).get("operationState", {}).get("phase") in ("Running", "Terminating")


def app_from_render(component, filename, name):
    file = Path(os.environ["HOOK_RENDERED_DIR"]) / component / filename
    if not file.exists():
        return None
    text = command(["yq", "-o=json", "-I=0",
                    f'select(.kind == "Application" and .metadata.name == "{name}")', str(file)])
    documents = [json.loads(line) for line in text.splitlines() if line.strip()]
    if len(documents) != 1:
        fail(f"Expected exactly one {name} Application in {file}")
    return documents[0]


def chart_version(app):
    if not app:
        return None
    spec = app["spec"]
    sources = spec.get("sources", [spec.get("source", {})])
    charts = [x for x in sources if x.get("chart") == "traefik"]
    if len(charts) != 1 or charts[0].get("repoURL") != "https://traefik.github.io/charts":
        fail("Cannot prove target Traefik chart identity")
    return str(charts[0]["targetRevision"])


def compatibility(crds):
    # Includes non-Traefik-owned CRDs: an independent experimental installation
    # must never silently become standard just because no migration is needed.
    directory = Path(os.environ["HOOK_RENDERED_DIR"]) / "gatewayApi" / "templates"
    for suffix, digest in UPSTREAM_HASHES.items():
        file = directory / f"{GROUP}_{suffix}.yaml"
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
            fail(f"{file.name}: pinned upstream file missing/modified/excluded; refusing unreviewed bundle")
    desired = {}
    for file in sorted(directory.glob("*.yaml")):
        text = command(["yq", "-o=json", "-I=0", 'select(.kind == "CustomResourceDefinition")', str(file)])
        for line in text.splitlines():
            if line.strip():
                crd = json.loads(line)
                annotations = crd["metadata"].get("annotations", {})
                if (annotations.get("gateway.networking.k8s.io/channel") != "standard"
                        or annotations.get("gateway.networking.k8s.io/bundle-version") != "v1.6.3"):
                    fail("Desired Gateway API CRDs are not the pinned standard v1.6.3 bundle")
                desired[crd["metadata"]["name"]] = crd
    if set(desired) != CRD_NAMES:
        fail("Gateway API Application included but its complete pinned CRD set is missing/excluded")
    kustomization = json.loads(command(["yq", "-o=json", "-I=0", ".", str(directory / "kustomization.yaml")]))
    if not protected({"metadata": {"annotations": kustomization.get("commonAnnotations", {})}}):
        fail("Gateway API Kustomization must protect desired resources with Prune=false,Delete=false")
    resource_names = set(kustomization.get("resources", []))
    if (not resource_names or any("/" in name or not (directory / name).is_file() for name in resource_names)
            or any(file.name not in resource_names for file in directory.glob("gateway.networking.k8s.io_*.yaml"))):
        fail("Gateway API Kustomization must include all pinned local resources, with no remote sources")
    if "gateway.networking.k8s.io_vap_safeupgrades.yaml" not in resource_names:
        fail("Gateway API standard bundle must include its safe-upgrades admission policy")
    # Validate the actual Kustomize result too; an overlay patch must not undo
    # protection or change upstream schemas while retaining their version labels.
    built = command(["kubectl", "kustomize", str(directory)])
    rendered = command(["yq", "-o=json", "-I=0", 'select(.kind == "CustomResourceDefinition")'], built)
    transformed = [json.loads(line) for line in rendered.splitlines() if line.strip()]
    if {x["metadata"]["name"] for x in transformed} != CRD_NAMES:
        fail("Kustomize result does not contain exactly the pinned Gateway CRDs")
    for crd in transformed:
        if not protected(crd) or crd["spec"] != desired[crd["metadata"]["name"]]["spec"]:
            fail("Kustomize overlays must preserve CRD protection and pinned upstream schemas")
    for crd in crds:
        name = crd["metadata"]["name"]
        annotations = crd["metadata"].get("annotations", {})
        if annotations.get("gateway.networking.k8s.io/channel") != "standard":
            fail(f"{name}: experimental/unknown channel; select and review an appropriate bundle manually, no auto-downgrade")
        version = annotations.get("gateway.networking.k8s.io/bundle-version", "")
        match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", version)
        if not match or tuple(map(int, match.groups())) > PIN:
            fail(f"{name}: unknown/newer bundle {version!r}; refusing downgrade to v1.6.3")
        if name not in desired:
            fail(f"{name}: not in the standard v1.6.3 bundle; refusing automatic handover")
        target = desired[name]
        versions = {x["name"] for x in target["spec"]["versions"]}
        stored = set(crd.get("status", {}).get("storedVersions", []))
        served = {x["name"] for x in crd["spec"]["versions"] if x.get("served")}
        if not (stored | served) <= versions:
            fail(f"{name}: live stored/served versions {sorted(stored | served)} incompatible with target {sorted(versions)}; migrate storage/clients first")


def quiesce(app, legacy):
    # A live annotation plus a sleep cannot prove that the old controller's
    # informer has observed it, or that a queued self-heal is not still running.
    # Hard gate: administrators stop ALL application controllers and wait for
    # their pods to disappear. We never scale anything automatically.
    namespace = os.environ.get("ARGOCD_NAMESPACE", "argocd")
    config = get("configmap", "argocd-cm", "-n", namespace)
    data = config.get("data", {})
    if (data.get("application.resourceTrackingMethod") not in ("annotation", "annotation+label")
            or data.get("application.instanceLabelKey", "app.kubernetes.io/instance") != "app.kubernetes.io/instance"):
        fail("Migration requires standard annotation or annotation+label Argo tracking; review custom tracking manually")
    installation = data.get("installationID", "")
    if any(crd["metadata"].get("annotations", {}).get("argocd.argoproj.io/installation-id", "") != installation for crd in legacy):
        fail("Gateway CRD Argo installation ID does not match this controller; review ownership manually")
    selector = "app.kubernetes.io/name=argocd-application-controller"
    controllers = get("deployments,statefulsets", "-n", namespace, "-l", selector)["items"]
    if not controllers:
        fail("No standard Argo application-controller workloads found; cannot prove quiescence")
    for controller in controllers:
        if controller["spec"].get("replicas", 1) != 0:
            fail("Legacy migration requires Argo application controllers scaled to 0 and ALL their pods gone before retry. No publication occurred.")
        images = [x["image"] for x in controller["spec"]["template"]["spec"]["containers"]]
        releases = [re.search(r"(?:^|/)argocd:v?(\d+)\.(\d+)\.(\d+)(?:@sha256:[a-f0-9]+)?$", image) for image in images]
        if not any(m and tuple(map(int, m.groups())) >= (2, 7, 0) for m in releases):
            fail("Cannot verify Argo >=2.7 skip-reconcile support from controller image; review manually")
    pods = get("pods", "-n", namespace, "-l", selector)["items"]
    if pods:
        fail("Argo application-controller pods still exist (including terminating pods); wait for removal")
    if active(app):
        fail("Traefik has an active/pending sync. Finish/terminate it before stopping controllers, then retry")
    metadata = app["metadata"]
    if metadata.get("ownerReferences") or metadata.get("annotations", {}).get(TRACK):
        fail("Traefik Application has a parent manager; quiesce/review parent ownership before handover")
    if metadata.get("annotations", {}).get(SKIP) != "true":
        annotate("applications.argoproj.io", app, {SKIP: "true"}, metadata["namespace"])
    live = get("applications.argoproj.io", metadata["name"], "-n", metadata["namespace"])
    if live["metadata"].get("annotations", {}).get(SKIP) != "true" or active(live):
        fail("Traefik pause could not be verified")


def main():
    # Relevance FIRST: no Helm network calls, CRD writes, or quiescence before
    # live status + live ownership. A successful readiness query is mandatory:
    # --ignore-not-found handles only absence, never Forbidden/TLS/network errors.
    kube("get", "--raw", "/readyz")
    api = get("crd", "applications.argoproj.io", "--ignore-not-found")
    app = get("applications.argoproj.io", "traefik", "-n", "traefik", "--ignore-not-found") if api else None
    crds = [x for x in get("crds")["items"] if x["spec"].get("group") == GROUP]
    resources = (app or {}).get("status", {}).get("resources", [])
    status_names = {x["name"] for x in resources
                    if x.get("group") == "apiextensions.k8s.io" and x.get("kind") == "CustomResourceDefinition"
                    and x.get("name", "").endswith("." + GROUP)}
    legacy = [x for x in crds if owner(x) in LEGACY_OWNERS]
    # An empty recognized-owner set is not enough to prove no legacy resources:
    # custom label tracking may own status-listed CRDs under another label key.
    status_live = [x for x in crds if x["metadata"]["name"] in status_names]
    if status_live:
        data = get("configmap", "argocd-cm", "-n", os.environ.get("ARGOCD_NAMESPACE", "argocd")).get("data", {})
        if (data.get("application.resourceTrackingMethod") not in ("annotation", "annotation+label")
                or data.get("application.instanceLabelKey", "app.kubernetes.io/instance") != "app.kubernetes.io/instance"):
            fail("Status lists live Gateway CRDs but Argo tracking is unsupported/custom; cannot safely skip legacy migration")
        if any(owner(x) is None for x in status_live):
            fail("Status lists live Gateway CRDs with unrecognized/non-self-referencing tracking; cannot establish ownership for a safe skip")
    if legacy and not app:
        fail("Traefik-owned Gateway CRDs exist without the Traefik Application; cannot establish safe handover")
    if any(x["metadata"]["name"] not in status_names for x in legacy):
        fail("Gateway CRD ownership and live Traefik Application status disagree; refresh/review before publication")
    gateway = app_from_render("gatewayApi", "gatewayApiArgoApp.yaml", "gateway-api")
    target_app = app_from_render("traefik", "traefikArgoApp.yaml", "traefik")
    target_version = chart_version(target_app)
    # Exact audited upstream chart only. New versions require renewed CRD audit.
    unbundled = target_version == "42.3.1"
    if not gateway:
        if legacy and unbundled:
            fail("New Traefik chart drops Gateway CRDs but gatewayApi Application is excluded/missing; include it before upgrading")
        print("[gateway-api] SKIP: gatewayApi Application not included; no handover requested")
        return
    spec = gateway["spec"]
    if (spec.get("source", {}).get("path") != "_rendered/gatewayApi/templates"
            or spec.get("source", {}).get("repoURL") != os.environ.get("GITEA_CLUSTER_SERVICES_REPO_URL")
            or spec.get("source", {}).get("targetRevision") != os.environ.get("GITEA_CLUSTER_SERVICES_REPO_BRANCH")
            or gateway["metadata"].get("namespace") != os.environ.get("ARGOCD_NAMESPACE", "argocd")
            or spec.get("destination", {}).get("server") != "https://kubernetes.default.svc"
            or "ServerSideApply=true" not in spec.get("syncPolicy", {}).get("syncOptions", [])
            or "FailOnSharedResource=true" in spec.get("syncPolicy", {}).get("syncOptions", [])):
        fail("Gateway API Application must use this environment's repository/branch, local cluster, pinned bundle, SSA, and allow shared-resource adoption")
    if target_app and not unbundled:
        fail(f"Target Traefik chart {target_version!r} is bundled or unaudited. Use audited 42.3.1 before including gatewayApi")
    if legacy and not target_app:
        fail("Legacy Traefik ownership exists but target Traefik Application is absent; refusing removal without reviewed handover")
    compatibility(crds)
    if not legacy:
        print("[gateway-api] SKIP: no legacy Traefik-owned Gateway CRDs" +
              (" (reachable fresh bootstrap; Argo Application API absent)" if not api else ""))
        return
    quiesce(app, legacy)
    for crd in sorted(legacy, key=lambda x: x["metadata"]["name"]):
        values = options(crd)
        if any(x.startswith(("Prune=", "Delete=")) and x not in ("Prune=false", "Delete=false") for x in values):
            fail(f"{crd['metadata']['name']}: conflicting Prune/Delete sync options; resolve explicitly")
        for required in ("Prune=false", "Delete=false"):
            if required not in values:
                values.append(required)
        if not protected(crd):
            annotate("crd", crd, {SYNC: ",".join(values)})
    # Verify every live CRD AFTER writes and BEFORE the entrypoint may publish.
    for original in legacy:
        live = get("crd", original["metadata"]["name"])
        if not protected(live) or owner(live) != owner(original):
            fail(f"{original['metadata']['name']}: live protection/ownership verification failed")
    print("[gateway-api] PROTECTED: legacy CRDs verified. Controllers remain stopped; Traefik remains skip-reconcile=true.")
    print("[gateway-api] Next: publish/apply new Applications, resume controllers, sync gateway-api and verify tracking adoption BEFORE unpausing Traefik. See base/gatewayApi/README.md.")


try:
    main()
except (RuntimeError, ValueError, KeyError, OSError) as error:
    print(f"[gateway-api] BLOCKED: {error}", file=sys.stderr)
    sys.exit(1)
PY
