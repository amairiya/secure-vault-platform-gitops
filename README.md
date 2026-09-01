# Secure Vault Platform - GitOps

Everything ArgoCD watches and continuously reconciles for the Secure Vault
Production Platform: ArgoCD's own Helm values, Kubernetes manifests, and
every Application it deploys from here on.

## This is one of two repositories

| Repo | Contains | Applied by |
|---|---|---|
| [`secure-vault-platform-infra`](<INFRA_REPO_URL>) | Terraform: VPC, EKS, KMS, IAM, S3 | `terraform apply`, run by a human/CI with AWS credentials |
| **This repo (gitops)** | Helm values, Kubernetes manifests, ArgoCD Applications | ArgoCD, continuously, from inside the cluster |

**This repo never needs AWS credentials.** Only cluster-scoped Kubernetes
RBAC. See the infra repo's README for the full rationale on why these are
split.

## Structure

```
helm/argocd/            - ArgoCD's own Helm values (chart-managed by the infra bootstrap)
kubernetes/namespaces/   - Namespace manifests with Pod Security Standards
argocd/projects/         - AppProject definitions (scoped, least-privilege)
argocd/bootstrap/         - The root "app-of-apps" Application (applied once, manually)
argocd/applications/     - Every Application ArgoCD manages from here on (populated starting Phase 4)
vault/                    - Vault policies, auth config, KV structure (Phase 4+)
monitoring/               - Prometheus, Grafana, alert rules (Phase 7+)
scripts/                  - Bootstrap script (Helm install, password rotation)
```

## Getting started

1. Provision infrastructure first, from the
   [infra repo](<INFRA_REPO_URL>) (Phases 1-2).
2. From this repo:
   ```powershell
   aws eks update-kubeconfig --name secure-vault-production --region us-east-1
   .\scripts\bootstrap-argocd.ps1 -GitRepoUrl "<URL_OF_THIS_REPO>"
   ```
3. Every future phase adds its own `Application` manifest under
   `argocd/applications/` - commit and push, ArgoCD picks it up
   automatically (`selfHeal: true`, `prune: true`).

## Phases covered here

- Phase 3: ArgoCD itself (this repo's own bootstrap)
- Phase 4 onward: Vault, monitoring, and everything else - added here as
  each phase lands.
