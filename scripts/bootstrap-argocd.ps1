<#
.SYNOPSIS
    Phase 3 bootstrap for the Secure Vault Production Platform - installs
    ArgoCD via Helm, forces an immediate admin password rotation, and
    applies the AppProject + root Application.

.DESCRIPTION
    Requires: helm, kubectl, aws cli already authenticated to the cluster
    (run `aws eks update-kubeconfig` first if you have not already).

    Run this script FROM WITHIN this gitops repo's checkout - it reads
    helm/argocd/values-production.yaml, argocd/projects/platform-project.yaml,
    and argocd/bootstrap/root-app.yaml relative to the current directory.

.USAGE
    cd secure-vault-platform-gitops
    .\scripts\bootstrap-argocd.ps1 -GitRepoUrl "https://github.com/you/secure-vault-platform-gitops.git"

    Note: -GitRepoUrl must point at THIS gitops repo, not the infra repo -
    it's what ArgoCD itself will clone and continuously watch.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$GitRepoUrl,

    [string]$ChartVersion = "10.4.3",
    [string]$Namespace = "argocd"
)

$ErrorActionPreference = "Stop"

Write-Host "== Phase 3 - ArgoCD bootstrap ==" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
foreach ($tool in @("helm", "kubectl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "Missing required tool: $tool" -ForegroundColor Red
        exit 1
    }
}

try {
    kubectl get nodes | Out-Null
} catch {
    Write-Host "kubectl cannot reach the cluster. Run 'aws eks update-kubeconfig' first." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Namespace
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Applying namespace" -ForegroundColor Cyan
kubectl apply -f kubernetes/namespaces/argocd-namespace.yaml

# ---------------------------------------------------------------------------
# 2. Helm repo + install (pinned chart version - never 'latest')
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Installing ArgoCD (chart version $ChartVersion)" -ForegroundColor Cyan

helm repo add argo https://argoproj.github.io/argo-helm | Out-Null
helm repo update | Out-Null

Write-Host "Checking chart version $ChartVersion is still available..." -ForegroundColor DarkGray
$available = helm search repo argo/argo-cd --versions | Select-String $ChartVersion
if (-not $available) {
    Write-Host "WARNING: chart version $ChartVersion not found in the repo index." -ForegroundColor Yellow
    Write-Host "Run 'helm search repo argo/argo-cd --versions' and pick a current version," -ForegroundColor Yellow
    Write-Host "then re-run this script with -ChartVersion <version>." -ForegroundColor Yellow
    exit 1
}

helm upgrade --install argocd argo/argo-cd `
    --namespace $Namespace `
    --version $ChartVersion `
    --values helm/argocd/values-production.yaml `
    --wait --timeout 10m

# ---------------------------------------------------------------------------
# 3. Rotate the initial admin password immediately
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Rotating initial admin password" -ForegroundColor Cyan

$initialPassword = kubectl -n $Namespace get secret argocd-initial-admin-secret `
    -o jsonpath="{.data.password}" | ForEach-Object {
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))
    }

if (-not $initialPassword) {
    Write-Host "Could not read the initial admin secret. Check the argocd-server pods are Running." -ForegroundColor Red
    exit 1
}

Write-Host "Initial admin password retrieved. Generating a new one..." -ForegroundColor DarkGray

# Generate a strong random password rather than asking the operator to
# invent one on the spot.
Add-Type -AssemblyName System.Web
$newPassword = [System.Web.Security.Membership]::GeneratePassword(24, 6)

# Port-forward briefly to reach the ClusterIP service for the CLI login.
$portForward = Start-Process -PassThru -WindowStyle Hidden kubectl `
    -ArgumentList "-n", $Namespace, "port-forward", "svc/argocd-server", "8080:443"
Start-Sleep -Seconds 5

try {
    # argocd CLI must be installed separately - https://argo-cd.readthedocs.io/en/stable/cli_installation/
    if (Get-Command argocd -ErrorAction SilentlyContinue) {
        argocd login localhost:8080 --username admin --password $initialPassword --insecure
        argocd account update-password --current-password $initialPassword --new-password $newPassword
        Write-Host "Admin password rotated successfully." -ForegroundColor Green
        Write-Host ""
        Write-Host "NEW ADMIN PASSWORD (save this somewhere secure - it is shown ONLY once):" -ForegroundColor Yellow
        Write-Host "  $newPassword" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Delete the now-stale initial secret:" -ForegroundColor DarkGray
        kubectl -n $Namespace delete secret argocd-initial-admin-secret
    } else {
        Write-Host "argocd CLI not found - password NOT rotated automatically." -ForegroundColor Yellow
        Write-Host "Initial admin password (rotate this manually as soon as possible):" -ForegroundColor Yellow
        Write-Host "  $initialPassword" -ForegroundColor Yellow
    }
} finally {
    Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 4. AppProject + root Application
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Applying AppProject and root Application" -ForegroundColor Cyan

$projectContent = Get-Content argocd/projects/platform-project.yaml -Raw
$projectContent = $projectContent -replace '<GITOPS_REPO_URL>', $GitRepoUrl
$projectContent | kubectl apply -f -

$rootAppContent = Get-Content argocd/bootstrap/root-app.yaml -Raw
$rootAppContent = $rootAppContent -replace '<GITOPS_REPO_URL>', $GitRepoUrl
$rootAppContent | kubectl apply -f -

Write-Host ""
Write-Host "== Phase 3 bootstrap complete ==" -ForegroundColor Green
Write-Host "Access the UI with: kubectl -n $Namespace port-forward svc/argocd-server 8080:443" -ForegroundColor DarkGray
Write-Host "Then browse to https://localhost:8080 (self-signed cert - expected until a proper CA is wired up)." -ForegroundColor DarkGray
