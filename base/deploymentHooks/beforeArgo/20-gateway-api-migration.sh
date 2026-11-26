#!/usr/bin/env bash
# Protect legacy Gateway API CRDs before publishing the Traefik chart upgrade.
# No delete, no ownership rewrite, no CRD spec changes. Python is stdlib-only.
set -euo pipefail
: "${HOOK_RENDERED_DIR:?run through run-deployment-hooks.sh}"
: "${HOOK_KUBE_CONTEXT:?validated Kubernetes context required}"
python3 - <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

SYNC = "argocd.argoproj.io/sync-options"
TRACK = "argocd.argoproj.io/tracking-id"
REFRESH = "argocd.argoproj.io/refresh"
# Recorded on the Traefik Application when the administrator approves, so
# reruns of the same migration (e.g. Apply Overlay's push gate) don't re-ask.
APPROVAL = "bootstrapper.talos.dev/gateway-api-migration-approved"
POLL_SECONDS = float(os.environ.get("GATEWAY_API_MIGRATION_POLL_SECONDS", "2"))
GROUP = "gateway.networking.k8s.io"
LEGACY_OWNERS = {"traefik", "traefik_traefik"}  # Argo apps-in-any-namespace InstanceName.
UPSTREAM_REPO = "https://github.com/kubernetes-sigs/gateway-api.git"
UPSTREAM_PATH = "config/crd"  # Upstream standard-channel Kustomization.

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


AMBIGUOUS = object()
_argocd_cm = None


def argocd_cm():
    # Absent argocd-cm (fresh bootstrap) means Argo defaults; query errors still fail.
    global _argocd_cm
    if _argocd_cm is None:
        cm = get("configmap", "argocd-cm", "-n", os.environ.get("ARGOCD_NAMESPACE", "argocd"), "--ignore-not-found")
        _argocd_cm = (cm or {}).get("data") or {}
    return _argocd_cm


def owner(crd):
    # Returns the owning Argo app, None when Argo does not track the CRD, or
    # AMBIGUOUS. Argo only prunes live objects carrying its tracking metadata;
    # untracked objects (e.g. Helm crds/ applied by Argo) are never pruned.
    data = argocd_cm()
    method = data.get("application.resourceTrackingMethod") or "annotation"  # Argo 3.x default.
    metadata = crd["metadata"]
    if method in ("annotation", "annotation+label"):
        tracking = metadata.get("annotations", {}).get(TRACK)
        if not tracking:
            return None
        app, separator, identity = tracking.partition(":")
        if separator and identity == f"apiextensions.k8s.io/CustomResourceDefinition:/{metadata['name']}":
            return app
        return AMBIGUOUS
    if method == "label":
        return metadata.get("labels", {}).get(data.get("application.instanceLabelKey") or "app.kubernetes.io/instance")
    fail(f"Unsupported Argo resourceTrackingMethod {method!r}; review ownership manually")


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


def semver(value):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", value or "")
    return tuple(map(int, match.groups())) if match else None


def desired_bundle(gateway):
    # The gateway-api Application must render upstream's standard bundle at the
    # env's GATEWAY_API_VERSION, protected against prune/delete by Argo.
    source = gateway["spec"].get("source") or {}
    revision = str(source.get("targetRevision", ""))
    if source.get("repoURL") != UPSTREAM_REPO or source.get("path") != UPSTREAM_PATH:
        fail(f"Gateway API Application must use {UPSTREAM_REPO} path {UPSTREAM_PATH} (standard channel)")
    if not (semver(revision) or re.fullmatch(r"[0-9a-f]{40}", revision)):
        fail(f"GATEWAY_API_VERSION must be a release tag like v1.6.3 or a full commit SHA, got {revision!r}")
    if not protected({"metadata": {"annotations": (source.get("kustomize") or {}).get("commonAnnotations", {})}}):
        fail("Gateway API Application must set kustomize.commonAnnotations sync-options Prune=false,Delete=false")
    # Build exactly what Argo will render, so compatibility is checked against the real target.
    url = f"{UPSTREAM_REPO.removesuffix('.git')}/{UPSTREAM_PATH}?ref={revision}"
    built = command(["kubectl", "kustomize", url])
    text = command(["yq", "-o=json", "-I=0", 'select(.kind == "CustomResourceDefinition")'], built)
    desired = {}
    for line in text.splitlines():
        if line.strip():
            crd = json.loads(line)
            desired[crd["metadata"]["name"]] = crd
    if not desired:
        fail(f"Upstream Gateway API bundle at {revision!r} contains no CRDs")
    versions = set()
    for crd in desired.values():
        annotations = crd["metadata"].get("annotations", {})
        if annotations.get("gateway.networking.k8s.io/channel") != "standard":
            fail(f"Upstream bundle at {revision!r} is not the standard channel")
        versions.add(annotations.get("gateway.networking.k8s.io/bundle-version"))
    if len(versions) != 1 or not semver(next(iter(versions))):
        fail(f"Upstream bundle at {revision!r} has inconsistent/unknown bundle versions {sorted(map(str, versions))}")
    version = next(iter(versions))
    if semver(revision) and semver(revision) != semver(version):
        fail(f"GATEWAY_API_VERSION {revision} does not match the bundle's own version {version}")
    return version, desired


def compatibility(gateway, crds):
    # Includes non-Traefik-owned CRDs: an independent experimental installation
    # must never silently become standard just because no migration is needed.
    target, desired = desired_bundle(gateway)
    for crd in crds:
        name = crd["metadata"]["name"]
        annotations = crd["metadata"].get("annotations", {})
        if annotations.get("gateway.networking.k8s.io/channel") != "standard":
            fail(f"{name}: experimental/unknown channel; select and review an appropriate bundle manually, no auto-downgrade")
        version = annotations.get("gateway.networking.k8s.io/bundle-version", "")
        if not semver(version) or semver(version) > semver(target):
            fail(f"{name}: unknown/newer bundle {version!r}; refusing downgrade to {target}")
        if name not in desired:
            fail(f"{name}: not in the standard {target} bundle; refusing automatic handover")
        versions = {x["name"] for x in desired[name]["spec"]["versions"]}
        stored = set(crd.get("status", {}).get("storedVersions", []))
        served = {x["name"] for x in crd["spec"]["versions"] if x.get("served")}
        if not (stored | served) <= versions:
            fail(f"{name}: live stored/served versions {sorted(stored | served)} incompatible with target {sorted(versions)}; migrate storage/clients first")
    print(f"[gateway-api] Target bundle: standard {target}")


def check_tracking(legacy):
    installation = argocd_cm().get("installationID", "")
    if any(crd["metadata"].get("annotations", {}).get("argocd.argoproj.io/installation-id", "") != installation for crd in legacy):
        fail("Gateway CRD Argo installation ID does not match this controller; review ownership manually")


def confirm(legacy, pause):
    if os.environ.get("GATEWAY_API_MIGRATION_APPROVED") == "true":
        print("[gateway-api] Approved via GATEWAY_API_MIGRATION_APPROVED=true")
        return
    try:
        tty = open("/dev/tty", "r+")
    except OSError:
        fail("Administrator approval required but no terminal is available; rerun interactively "
             "or set GATEWAY_API_MIGRATION_APPROVED=true. Nothing was changed.")
    with tty:
        tty.write(f"\n[gateway-api] {len(legacy)} Gateway API CRD(s) are managed by the Traefik Application.\n"
                  "This migration will:\n" +
                  ("  - Disable auto-sync for the Traefik Application only (other apps keep syncing).\n"
                   "  - Wait for ArgoCD to acknowledge that and for any Traefik sync to finish.\n" if pause else "") +
                  "  - Protect those CRDs against prune/delete (Prune=false,Delete=false).\n" +
                  ("Traefik auto-sync is re-enabled when Apply Overlay applies the new Traefik Application.\n"
                   if pause else "") +
                  "Continue? [y/N] ")
        tty.flush()
        if tty.readline().strip().lower() not in ("y", "yes"):
            fail("Declined by administrator. Nothing was changed.")


def wait_for(app, timeout):
    # The refresh annotation is removed only by a controller refresh that read
    # this exact object (spec with auto-sync disabled). The controller's work
    # queue never processes one Application concurrently, so any older refresh
    # that may still have started an auto-sync has completed by then; such a
    # sync is visible as .operation, which we wait out next.
    metadata = app["metadata"]
    deadline = time.monotonic() + timeout
    while True:
        live = get("applications.argoproj.io", metadata["name"], "-n", metadata["namespace"])
        automated = (live["spec"].get("syncPolicy") or {}).get("automated")
        if automated is not None and automated.get("enabled") is not False:
            fail("Traefik auto-sync was re-enabled by someone else during the handover; review and rerun")
        acknowledged = REFRESH not in live["metadata"].get("annotations", {})
        if acknowledged and not active(live):
            return
        if time.monotonic() >= deadline:
            fail("Timed out: " + ("ArgoCD did not process the Traefik refresh (is the application controller running?)"
                                  if not acknowledged else
                                  "a Traefik sync is still running. Let it finish, or terminate it with "
                                  "'argocd app terminate-op traefik -N traefik', then rerun"))
        time.sleep(POLL_SECONDS)


def check_pausable(app, api):
    metadata = app["metadata"]
    if metadata.get("ownerReferences") or metadata.get("annotations", {}).get(TRACK):
        fail("Traefik Application has a parent manager that would revert disabling auto-sync; review before handover")
    automated_schema = next(
        (v for v in api["spec"]["versions"] if v["name"] == "v1alpha1"), {}).get("schema", {}).get(
        "openAPIV3Schema", {}).get("properties", {}).get("spec", {}).get("properties", {}).get(
        "syncPolicy", {}).get("properties", {}).get("automated", {}).get("properties", {})
    if "enabled" not in automated_schema:
        fail("Installed ArgoCD does not support spec.syncPolicy.automated.enabled (requires ArgoCD 3.x); upgrade ArgoCD first")


def pause_autosync(app):
    metadata = app["metadata"]
    annotations = dict(metadata.get("annotations", {}))
    annotations[REFRESH] = "normal"
    annotations[APPROVAL] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    patch = [{"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
             {"op": "add", "path": "/metadata/annotations", "value": annotations}]
    if (app["spec"].get("syncPolicy") or {}).get("automated") is not None:
        patch.append({"op": "add", "path": "/spec/syncPolicy/automated/enabled", "value": False})
    kube("patch", "applications.argoproj.io", metadata["name"], "-n", metadata["namespace"],
         "--type=json", "-p", json.dumps(patch))
    print("[gateway-api] Traefik auto-sync disabled; waiting for ArgoCD to acknowledge and for any sync to finish...")
    wait_for(app, int(os.environ.get("GATEWAY_API_MIGRATION_TIMEOUT_SECONDS", "900")))


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
    status_live = [x for x in crds if x["metadata"]["name"] in status_names]
    if any(owner(x) is AMBIGUOUS for x in status_live):
        fail("Status lists live Gateway CRDs with unrecognized/non-self-referencing tracking; cannot establish ownership for a safe skip")
    untracked = sorted(x["metadata"]["name"] for x in status_live if owner(x) is None)
    if untracked:
        print(f"[gateway-api] {len(untracked)} Gateway CRD(s) rendered by Traefik carry no Argo tracking metadata; "
              "Argo will not prune them when the chart drops them: " + ", ".join(untracked))
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
    if (gateway["metadata"].get("namespace") != os.environ.get("ARGOCD_NAMESPACE", "argocd")
            or spec.get("destination", {}).get("server") != "https://kubernetes.default.svc"
            or "ServerSideApply=true" not in spec.get("syncPolicy", {}).get("syncOptions", [])
            or "FailOnSharedResource=true" in spec.get("syncPolicy", {}).get("syncOptions", [])):
        fail("Gateway API Application must target the local cluster, use SSA, and allow shared-resource adoption")
    if target_app and not unbundled:
        fail(f"Target Traefik chart {target_version!r} is bundled or unaudited. Use audited 42.3.1 before including gatewayApi")
    if legacy and not target_app:
        fail("Legacy Traefik ownership exists but target Traefik Application is absent; refusing removal without reviewed handover")
    compatibility(gateway, crds)
    if not legacy:
        print("[gateway-api] SKIP: no legacy Traefik-owned Gateway CRDs" +
              (" (reachable fresh bootstrap; Argo Application API absent)" if not api else ""))
        return
    check_tracking(legacy)
    for crd in legacy:
        if any(x.startswith(("Prune=", "Delete=")) and x not in ("Prune=false", "Delete=false") for x in options(crd)):
            fail(f"{crd['metadata']['name']}: conflicting Prune/Delete sync options; resolve explicitly")
    if all(protected(x) for x in legacy) and chart_version(app) == target_version:
        print("[gateway-api] Handover in progress: CRDs protected and live Traefik already uses the target chart; "
              "waiting for gateway-api to adopt them. No changes.")
        return
    # The live (old) chart still declares these CRDs; its self-heal could
    # revert or prune them, so Traefik must stop syncing first.
    pause = chart_version(app) != target_version
    if pause:
        if ((target_app["spec"].get("syncPolicy") or {}).get("automated") or {}).get("enabled") is not True:
            fail("Rendered Traefik Application must set spec.syncPolicy.automated.enabled: true so Apply Overlay "
                 "re-enables the auto-sync this migration disables")
        check_pausable(app, api)
    # Every check is done; nothing has been written yet. Ask before the first write.
    if APPROVAL in app["metadata"].get("annotations", {}):
        print(f"[gateway-api] Continuing migration approved at {app['metadata']['annotations'][APPROVAL]}")
    else:
        confirm(legacy, pause)
    if pause:
        pause_autosync(app)
    for name in sorted(x["metadata"]["name"] for x in legacy):
        crd = get("crd", name)  # Re-read: the wait above may have taken a while.
        values = options(crd)
        if any(x.startswith(("Prune=", "Delete=")) and x not in ("Prune=false", "Delete=false") for x in values):
            fail(f"{name}: conflicting Prune/Delete sync options; resolve explicitly")
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
    print("[gateway-api] PROTECTED: legacy Gateway API CRDs verified (Prune=false,Delete=false).")
    if chart_version(app) != target_version:
        print("[gateway-api] Traefik auto-sync stays DISABLED until 'Apply Overlay' applies the new Traefik "
              "Application, which re-enables it together with the chart upgrade. 'Render and Push' alone does not.")


try:
    main()
except (RuntimeError, ValueError, KeyError, OSError) as error:
    print(f"[gateway-api] BLOCKED: {error}", file=sys.stderr)
    sys.exit(1)
PY
