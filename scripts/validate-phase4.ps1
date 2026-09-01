<#
.SYNOPSIS
    Phase 4 validation for the Secure Vault Production Platform
    (Vault namespace, TLS, Helm/Raft/HA, KMS Auto-Unseal).

.DESCRIPTION
    Read-only checks only. Run from the gitops repo root after
    bootstrap-vault.ps1 has completed.

.USAGE
    cd secure-vault-platform-gitops
    .\scripts\validate-phase4.ps1
#>

param(
    [string]$Namespace = "vault"
)

$ErrorActionPreference = "Continue"
$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

function Write-Check { param([string]$Name) Write-Host ""; Write-Host "-- $Name" -ForegroundColor Cyan }
function Pass { param([string]$Message) Write-Host "  [PASS] $Message" -ForegroundColor Green; $script:PassCount++ }
function Fail { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red; $script:FailCount++ }
function Warn { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow; $script:WarnCount++ }

# ---------------------------------------------------------------------------
# 1. Namespace and StorageClass
# ---------------------------------------------------------------------------
Write-Check "Namespace and StorageClass"

$ns = kubectl get namespace $Namespace -o jsonpath="{.metadata.labels.pod-security\.kubernetes\.io/enforce}" 2>$null
if ($ns -eq "baseline") { Pass "Namespace '$Namespace' exists with PSS enforce=baseline" }
else { Fail "Namespace '$Namespace' missing or wrong PSS label (got: '$ns')" }

$sc = kubectl get storageclass gp3-encrypted -o jsonpath="{.parameters.encrypted}" 2>$null
if ($sc -eq "true") { Pass "StorageClass gp3-encrypted exists and encrypted=true" }
else { Fail "StorageClass gp3-encrypted missing or not encrypted" }

# ---------------------------------------------------------------------------
# 2. TLS secret
# ---------------------------------------------------------------------------
Write-Check "TLS"

$tlsSecret = kubectl -n $Namespace get secret vault-tls -o jsonpath="{.data.tls\.crt}" 2>$null
if ($tlsSecret) {
    Pass "vault-tls Secret exists"
    $certText = kubectl -n $Namespace get secret vault-tls -o jsonpath="{.data.tls\.crt}" | ForEach-Object {
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))
    }
    $certText | Out-File -FilePath "$env:TEMP\vault-cert-check.pem" -Encoding ascii
    $sanOutput = openssl x509 -in "$env:TEMP\vault-cert-check.pem" -noout -text 2>$null
    foreach ($san in @("vault-0.vault-internal", "vault-1.vault-internal", "vault-2.vault-internal")) {
        if ($sanOutput -match [regex]::Escape($san)) { Pass "Certificate SAN includes: $san" }
        else { Fail "Certificate SAN MISSING: $san" }
    }
} else {
    Fail "vault-tls Secret not found - run scripts/generate-vault-tls.ps1"
}

# ---------------------------------------------------------------------------
# 3. Pods
# ---------------------------------------------------------------------------
Write-Check "Vault pods"

$pods = kubectl -n $Namespace get pods -l app.kubernetes.io/name=vault -o json | ConvertFrom-Json
$runningCount = ($pods.items | Where-Object { $_.status.phase -eq "Running" }).Count
if ($runningCount -ge 3) { Pass "$runningCount Vault pods Running" }
else { Fail "Only $runningCount Vault pods Running - expected 3" }

foreach ($item in $pods.items) {
    $node = $item.spec.nodeName
    $nodeLabels = kubectl get node $node -o jsonpath="{.metadata.labels.workload}" 2>$null
    if ($nodeLabels -eq "vault") { Pass "$($item.metadata.name) scheduled on a vault-labeled node" }
    else { Fail "$($item.metadata.name) scheduled on node without workload=vault label ($node)" }
}

# ---------------------------------------------------------------------------
# 4. Seal / unseal status per pod
# ---------------------------------------------------------------------------
Write-Check "Auto-Unseal status"

foreach ($pod in @("vault-0", "vault-1", "vault-2")) {
    try {
        $status = kubectl -n $Namespace exec $pod -- vault status -format=json 2>$null | ConvertFrom-Json
        if ($status.initialized -eq $true -and $status.sealed -eq $false) {
            Pass "$pod : initialized and unsealed"
        } elseif ($status.sealed -eq $true) {
            Fail "$pod : SEALED - Auto-Unseal did not work, check IAM/Pod Identity/KMS key policy"
        } else {
            Warn "$pod : not yet initialized"
        }
    } catch {
        Fail "$pod : could not query status ($_)"
    }
}

# ---------------------------------------------------------------------------
# 5. Raft cluster health
# ---------------------------------------------------------------------------
Write-Check "Raft cluster"

try {
    $raftStatus = kubectl -n $Namespace exec vault-0 -- vault status -format=json 2>$null | ConvertFrom-Json
    if ($raftStatus.ha_enabled -eq $true) { Pass "HA enabled" } else { Fail "HA not enabled" }
    if ($raftStatus.leader_address) { Pass "Leader elected: $($raftStatus.leader_address)" } else { Fail "No leader elected" }
} catch {
    Warn "Could not read HA/leader status - vault may not have a valid VAULT_TOKEN in this session for raft list-peers"
}

# ---------------------------------------------------------------------------
# 6. PodDisruptionBudget
# ---------------------------------------------------------------------------
Write-Check "PodDisruptionBudget"

$pdb = kubectl -n $Namespace get pdb -o json 2>$null | ConvertFrom-Json
if ($pdb.items.Count -ge 1) { Pass "PodDisruptionBudget present ($($pdb.items[0].metadata.name))" }
else { Fail "No PodDisruptionBudget found in namespace $Namespace" }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Phase 4 Validation Summary"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Passed : $script:PassCount" -ForegroundColor Green
Write-Host "  Warned : $script:WarnCount" -ForegroundColor Yellow
Write-Host "  Failed : $script:FailCount" -ForegroundColor Red
Write-Host ""

if ($script:FailCount -eq 0) {
    Write-Host "Phase 4 looks healthy. Once you have manually confirmed the root token is stored" -ForegroundColor Green
    Write-Host "securely and revoked-after-Phase-5 plan is in place, enable automated sync on the" -ForegroundColor Green
    Write-Host "vault Application and proceed to Phase 5 (Kubernetes Auth, Policies, KV v2)." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Phase 4 has $script:FailCount failing check(s) - do not proceed to Phase 5 until resolved." -ForegroundColor Red
    exit 1
}
