# Coder workspace template — Kubernetes Pod + persistent home for the
# talos-bootstrapper dev image.
#
# NOTE ON RENDERING: this file is processed by render-overlay.sh with an
# envsubst *whitelist*, so only ${CODER_*} placeholders defined in the env file
# are substituted. Terraform's own ${...} interpolations (e.g.
# ${data.coder_workspace.me.name}) are NOT in the whitelist and are preserved
# verbatim.

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

# Coder runs in-cluster; use the mounted ServiceAccount for the Kubernetes API.
provider "kubernetes" {}

provider "coder" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Gitea external auth: exposes a "Login with Gitea" button in the workspace UI and
# lets the agent fetch OAuth tokens for git. optional=true so workspaces still
# start before the user has authorized (the git helper is only wired up once a
# token is available). Server side is configured via CODER_EXTERNAL_AUTH_0_* .
data "coder_external_auth" "gitea" {
  id       = "gitea"
  optional = true
}

locals {
  namespace     = "${CODER_WORKSPACES_NAMESPACE}"
  workspace_name = lower("coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}")
}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<-EOT
    set -e
    # Pre-authenticate git to the cluster's Gitea via Coder external auth. The
    # helper fetches a fresh token per git operation and is scoped to the Gitea
    # host so credentials are never sent elsewhere. Only wired up once a token is
    # available, so workspaces still start before the user authorizes Gitea.
    if command -v coder >/dev/null 2>&1 && coder external-auth access-token gitea >/dev/null 2>&1; then
      git config --global credential."https://${GITEA_DOMAIN_NAME}".helper \
        '!f() { echo username=oauth2; echo "password=$(coder external-auth access-token gitea)"; }; f'
    fi
    # The dev image ships the toolchain; land the user in their persistent home.
    cd "$HOME"
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM Usage"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# Per-PVC LUKS key for the pvckey-* Longhorn storage class, which resolves its
# encryption secret from ${pvc.name}. Terraform owns the key so it lives and dies
# with the workspace (not with start/stop) — no `count`, matching the PVC below.
resource "random_password" "home_luks" {
  length  = 43
  special = false
}

resource "kubernetes_secret_v1" "home_luks" {
  metadata {
    # MUST equal the PVC name: the pvckey-* class looks up ${pvc.name} in ${pvc.namespace}.
    name      = "${local.workspace_name}-home"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "coder"
      "com.coder.workspace.name"     = data.coder_workspace.me.name
      "com.coder.user.username"      = data.coder_workspace_owner.me.name
    }
  }
  data = {
    CRYPTO_KEY_VALUE = random_password.home_luks.result
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  # Key must exist before Longhorn provisions the encrypted volume; on destroy
  # Terraform tears the PVC down first (volume cleaned up while the key still exists).
  depends_on = [kubernetes_secret_v1.home_luks]
  metadata {
    name      = "${local.workspace_name}-home"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "coder"
      "com.coder.workspace.name"     = data.coder_workspace.me.name
      "com.coder.user.username"      = data.coder_workspace_owner.me.name
    }
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "pvckey-2replica-notretained-backedup-ssd-wn"
    resources {
      requests = {
        storage = "${CODER_WORKSPACE_STORAGE_SIZE}"
      }
    }
  }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = local.workspace_name
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "coder"
      "com.coder.workspace.name"     = data.coder_workspace.me.name
      "com.coder.user.username"      = data.coder_workspace_owner.me.name
    }
  }
  spec {
    # NOTE: We want `hostUsers = false` here for user-namespace isolation, but the
    # hashicorp/kubernetes provider's kubernetes_pod_v1 does not yet expose that field.
    # Tracked in coderDeferredWork.md. See:
    #   https://github.com/hashicorp/terraform-provider-kubernetes/issues/2818
    #   https://github.com/hashicorp/terraform-provider-kubernetes/pull/2828
    security_context {
      run_as_non_root = true
      run_as_user     = 1000
      fs_group        = 1000
      seccomp_profile {
        type = "RuntimeDefault"
      }
    }
    automount_service_account_token = false

    # Build a combined CA bundle (image's system roots + private cluster CA) into
    # an emptyDir. Needed because the agent-bootstrap curl reads the bundle FILE
    # (not the /etc/ssl/certs dir), so a bare file-drop that the Go agent would
    # trust is not enough for the initial download — see coder/coder#9863. Non-root;
    # assumes a Debian/Alpine bundle at /etc/ssl/certs/ca-certificates.crt.
    init_container {
      name              = "ca-trust"
      image             = "${CODER_WORKSPACE_IMAGE}"
      image_pull_policy = "IfNotPresent"
      command = [
        "sh", "-c",
        "set -e; cp /etc/ssl/certs/ca-certificates.crt /trust/ca-certificates.crt; cat /cluster-ca/ca.crt >> /trust/ca-certificates.crt",
      ]
      security_context {
        run_as_non_root            = true
        run_as_user                = 1000
        allow_privilege_escalation = false
        read_only_root_filesystem  = true
        capabilities {
          drop = ["ALL"]
        }
      }
      volume_mount {
        name       = "cluster-ca"
        mount_path = "/cluster-ca"
        read_only  = true
      }
      volume_mount {
        name       = "ca-trust"
        mount_path = "/trust"
      }
    }

    container {
      name              = "dev"
      image             = "${CODER_WORKSPACE_IMAGE}"
      image_pull_policy = "IfNotPresent"
      command           = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        run_as_non_root            = true
        run_as_user                = 1000
        allow_privilege_escalation = false
        capabilities {
          drop = ["ALL"]
        }
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu    = "500m"
          memory = "1Gi"
        }
        limits = {
          cpu    = "4"
          memory = "8Gi"
        }
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/vscode"
      }

      # Combined CA bundle from the initContainer so curl/git/apt and the Go agent
      # all trust the private cluster CA (Traefik ${TALOS_CLUSTER_NAME}-ca-issuer).
      volume_mount {
        name       = "ca-trust"
        mount_path = "/etc/ssl/certs/ca-certificates.crt"
        sub_path   = "ca-certificates.crt"
        read_only  = true
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata.0.name
        read_only  = false
      }
    }

    # Private cluster CA published into every namespace by trust-manager.
    volume {
      name = "cluster-ca"
      config_map {
        name         = "cluster-ca-bundle"
        default_mode = "0444"
      }
    }

    # Scratch space for the combined CA bundle assembled by the initContainer.
    volume {
      name = "ca-trust"
      empty_dir {}
    }
  }
}
