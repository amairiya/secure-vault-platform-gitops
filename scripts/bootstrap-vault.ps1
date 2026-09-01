<#
.SYNOPSIS
    One-time Vault initialization for the Secure Vault Production Platform.
    Runs `vault operator init` against vault-0, verifies AWS KMS
    Auto-Unseal, and confirms all 3 Raft peers join the cluster.

.DESCRIPTION
    Run this ONCE, after the vault Application has synced and vault-0/1/2
    pods are Running (but sealed/uninitialized - that's expected before
    this script runs).

    With seal "awskms" configured, Vault does NOT need manual unseal keys
    entered after this - it auto-unseals via KMS on every restart. This
    script still captures the "recovery keys" (the awskms-seal equivalent
    of unseal key shares - used only for narrow recovery operations, not
    routine unsealing) and the initial root token, because both are only
    ever shown once, at this exact moment.

.USAGE
    cd secure-vault-platform-gitops
    .\scripts\bootstrap-vault.ps1
#>

param(
    [string]$Namespace = "vault",
    [string]$OutDir = "./vault-init-local",
    [int]$RecoveryShares = 5,
    [int]$RecoveryThreshold = 3
)

$ErrorActionPreference = "Stop"

Write-Host "== Vault initialization ==" -ForegroundColor Cyan

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

# ---------------------------------------------------------------------------
# 0. Wait for pods to exist (sealed/uninitialized is the expected state)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Waiting for vault-0 pod to be present" -ForegroundColor Cyan

$attempts = 0
$maxAttempts = 30
while ($attempts -lt $maxAttempts) {
    $pod = kubectl -n $Namespace get pod vault-0 -o jsonpath="{.status.phase}" 2>$null
    if ($pod -eq "Running") { break }
    Start-Sleep -Seconds 10
    $attempts++
}

if ($attempts -eq $maxAttempts) {
    Write-Host "vault-0 did not reach Running in time. Check: kubectl -n $Namespace get pods" -ForegroundColor Red
    exit 1
}

Write-Host "vault-0 is Running." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 1. Check whether already initialized (idempotency - never re-init)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Checking initialization status" -ForegroundColor Cyan

$statusJson = kubectl -n $Namespace exec vault-0 -- vault status -format=json 2>$null | ConvertFrom-Json

if ($statusJson.initialized -eq $true) {
    Write-Host "Vault is already initialized. Skipping init - this script never re-initializes an existing cluster." -ForegroundColor Yellow
    Write-Host "If you need recovery keys again, they cannot be retrieved - only regenerated via 'vault operator generate-root'" -ForegroundColor Yellow
    Write-Host "or a documented recovery-key rotation procedure. This script will not do that automatically." -ForegroundColor Yellow
} else {
    # -----------------------------------------------------------------
    # 2. Initialize - with an awskms seal, this generates RECOVERY keys,
    #    not traditional unseal keys, and auto-unseals immediately after.
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "-- Initializing Vault (recovery-shares=$RecoveryShares, recovery-threshold=$RecoveryThreshold)" -ForegroundColor Cyan

    $initJson = kubectl -n $Namespace exec vault-0 -- vault operator init `
        -recovery-shares=$RecoveryShares `
        -recovery-threshold=$RecoveryThreshold `
        -format=json

    $initFile = "$OutDir/vault-init.json"
    $initJson | Out-File -FilePath $initFile -Encoding utf8

    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host " VAULT INITIALIZED - THIS OUTPUT IS SHOWN EXACTLY ONCE" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host " Recovery keys and the initial root token were written to:" -ForegroundColor Yellow
    Write-Host "   $initFile" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " REQUIRED NEXT STEPS (do these NOW, in this order):" -ForegroundColor Yellow
    Write-Host "  1. Move $initFile to an offline, encrypted location" -ForegroundColor Yellow
    Write-Host "     (password manager, hardware token, sealed physical envelope -" -ForegroundColor Yellow
    Write-Host "     NOT a shared drive, NOT Slack, NOT another Git repo)." -ForegroundColor Yellow
    Write-Host "  2. Split the 5 recovery key shares across separate people/locations" -ForegroundColor Yellow
    Write-Host "     if your organization has more than one trusted operator." -ForegroundColor Yellow
    Write-Host "  3. Delete $initFile from this machine once safely stored elsewhere." -ForegroundColor Yellow
    Write-Host "  4. The root token is a BOOTSTRAP credential only - CONTEXT.md section 21" -ForegroundColor Yellow
    Write-Host "     requires it be revoked after Phase 5 creates proper admin policies." -ForegroundColor Yellow
    Write-Host "     Do not use it for applications, ArgoCD, or routine operations." -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow

    # Confirm this file is actually gitignored before moving on.
    $ignoreCheck = git check-ignore $initFile 2>$null
    if (-not $ignoreCheck) {
        Write-Host ""
        Write-Host "WARNING: $initFile does NOT appear to be covered by .gitignore!" -ForegroundColor Red
        Write-Host "Do not run 'git add .' until this is confirmed ignored." -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# 3. Verify Auto-Unseal actually worked (no manual unseal should be needed)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Verifying AWS KMS Auto-Unseal on vault-0" -ForegroundColor Cyan

Start-Sleep -Seconds 5
$status0 = kubectl -n $Namespace exec vault-0 -- vault status -format=json 2>$null | ConvertFrom-Json

if ($status0.sealed -eq $false) {
    Write-Host "vault-0: unsealed automatically via AWS KMS. Auto-Unseal confirmed working." -ForegroundColor Green
} else {
    Write-Host "vault-0 is still sealed. Check the awskms seal config and the vault-kms-unseal IAM role/Pod Identity association." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Wait for vault-1 and vault-2 to join Raft and auto-unseal too
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Waiting for vault-1 and vault-2 to join and auto-unseal" -ForegroundColor Cyan

foreach ($pod in @("vault-1", "vault-2")) {
    $joined = $false
    for ($i = 0; $i -lt 18; $i++) {
        try {
            $s = kubectl -n $Namespace exec $pod -- vault status -format=json 2>$null | ConvertFrom-Json
            if ($s.sealed -eq $false) { $joined = $true; break }
        } catch {}
        Start-Sleep -Seconds 10
    }
    if ($joined) {
        Write-Host "$pod : unsealed and healthy." -ForegroundColor Green
    } else {
        Write-Host "$pod did not auto-unseal in time. Check: kubectl -n $Namespace logs $pod" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# 5. Raft peer check
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Checking Raft cluster membership" -ForegroundColor Cyan

$rootToken = if (Test-Path "$OutDir/vault-init.json") {
    (Get-Content "$OutDir/vault-init.json" | ConvertFrom-Json).root_token
} else {
    $null
}

if ($rootToken) {
    $env:VAULT_TOKEN = $rootToken
    kubectl -n $Namespace exec vault-0 -- env VAULT_TOKEN=$rootToken vault operator raft list-peers
} else {
    Write-Host "No root token available in this session (cluster was already initialized before this run)." -ForegroundColor Yellow
    Write-Host "Run manually with your stored root token: vault operator raft list-peers" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "== Vault initialization check complete ==" -ForegroundColor Green
