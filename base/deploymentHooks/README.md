# Deployment hooks

`beforeArgo/*.sh` is the only executable phase. Tooling in the **devenv**
repository runs these trusted Bash-compatible scripts before Argo deployment
publication and cluster bootstrap mutations, never during rendering.
`beforeTalos/*.sh` is reserved and not wired.

Base and overlay use exact-path replacement; overlay wins. Scripts run in
lexical filename order, stop at first failure, and are copied verbatim by the
renderer. `EXCLUDED_BASE=("deploymentHooks")` disables the whole component;
`EXCLUDED_BASE=("deploymentHooks/beforeArgo/20-gateway-api-migration.sh")`
excludes that exact file **from both sources**. A phase path is not a recursive
exclusion. Discovery uses current sources, not leftover `_rendered` artifacts.
Applications may require a hook through the
`bootstrapper.talos.dev/required-before-argo-hook` annotation. An excluded/missing
required hook blocks publication of its dependent Application (rendering still
honors the exclusion). Exclude the dependent Application as well when deliberately
omitting its hook. Overlay replacement remains supported, but trusted replacement
authors must preserve equivalent safety postconditions; arbitrary script
equivalence is not statically enforceable.

The runner supplies a fresh isolated `HOOK_RENDERED_DIR` and a validated
`HOOK_KUBE_CONTEXT`; use that explicit context for kubectl calls. Rendering
does not perform migrations. Neither normal nor temporary bootstrap publication
includes this component. Dry runs skip execution.

Do not disable a safety hook just to bypass its failure. Fix the reported
condition first. If intentionally omitting a component, exclude its Application
and resources as well and review the resulting ownership/prune behavior.

Authoring workflow: `.github/skills/create-deployment-hook/SKILL.md`.
Current migration/operator recovery: `../gatewayApi/README.md`.
