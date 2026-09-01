<#
.SYNOPSIS
    Generates a CA and a Vault server certificate with all required SANs
    for a 3-node Raft cluster, and creates the vault-tls Secret directly in
    the cluster. Nothing this script writes to disk or to Kubernetes is
    ever committed to Git.

.DESCRIPTION
    Requires: openssl (bundled with Git for Windows - if you have Git
    installed, run this from "Git Bash" or ensure openssl.exe is on PATH),
    kubectl already authenticated to the cluster.

    Output files are written to a local, gitignored ./vault-tls-local/
    directory. Treat the CA private key as sensitive for as long as you
    keep it (needed to re-issue certs later, e.g. rotation).

.USAGE
    cd secure-vault-platform-gitops
    .\scripts\generate-vault-tls.ps1
#>

param(
    [string]$Namespace = "vault",
    [string]$OutDir = "./vault-tls-local",
    [int]$ValidityDays = 825 # ~2.25 years - matches common browser/CA-Browser-Forum max cert lifetime norms
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Host "openssl not found on PATH." -ForegroundColor Red
    Write-Host "If you have Git for Windows installed, run this from 'Git Bash', or add" -ForegroundColor Yellow
    Write-Host "the Git installation's usr\bin folder (contains openssl.exe) to your PATH." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

Write-Host "== Generating Vault TLS material ==" -ForegroundColor Cyan
Write-Host "Output directory: $OutDir (gitignored - never commit this)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. CA
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Generating CA" -ForegroundColor Cyan

openssl genrsa -out "$OutDir/vault-ca.key" 4096
openssl req -x509 -new -nodes `
    -key "$OutDir/vault-ca.key" `
    -sha256 -days $ValidityDays `
    -out "$OutDir/vault-ca.crt" `
    -subj "/CN=secure-vault-platform-internal-ca/O=secure-vault-platform"

# ---------------------------------------------------------------------------
# 2. Server cert - single cert shared by vault-0/1/2, SANs cover every DNS
#    name any component will use to reach any Vault pod (client API AND
#    Raft peer-to-peer traffic both need to pass hostname verification).
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Generating server certificate (multi-SAN, covers all 3 Raft pods)" -ForegroundColor Cyan

$sanConfig = @"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = vault.$Namespace.svc.cluster.local

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = vault-0.vault-internal
DNS.2 = vault-1.vault-internal
DNS.3 = vault-2.vault-internal
DNS.4 = vault-0.vault-internal.$Namespace.svc.cluster.local
DNS.5 = vault-1.vault-internal.$Namespace.svc.cluster.local
DNS.6 = vault-2.vault-internal.$Namespace.svc.cluster.local
DNS.7 = vault.$Namespace.svc.cluster.local
DNS.8 = vault.$Namespace.svc
DNS.9 = vault.$Namespace
DNS.10 = vault
DNS.11 = localhost
IP.1 = 127.0.0.1
"@
$sanConfig | Out-File -FilePath "$OutDir/vault-san.cnf" -Encoding ascii

openssl genrsa -out "$OutDir/vault-server.key" 2048
openssl req -new `
    -key "$OutDir/vault-server.key" `
    -out "$OutDir/vault-server.csr" `
    -config "$OutDir/vault-san.cnf"

openssl x509 -req `
    -in "$OutDir/vault-server.csr" `
    -CA "$OutDir/vault-ca.crt" -CAkey "$OutDir/vault-ca.key" -CAcreateserial `
    -out "$OutDir/vault-server.crt" `
    -days $ValidityDays -sha256 `
    -extfile "$OutDir/vault-san.cnf" -extensions v3_req

# ---------------------------------------------------------------------------
# 3. Create the namespace (if not already applied by ArgoCD) and the Secret
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Applying namespace and creating the vault-tls Secret" -ForegroundColor Cyan

kubectl apply -f kubernetes/vault/namespace.yaml

kubectl -n $Namespace create secret generic vault-tls `
    --from-file=tls.crt="$OutDir/vault-server.crt" `
    --from-file=tls.key="$OutDir/vault-server.key" `
    --from-file=ca.crt="$OutDir/vault-ca.crt" `
    --dry-run=client -o yaml | kubectl apply -f -

Write-Host ""
Write-Host "== TLS material generated and applied ==" -ForegroundColor Green
Write-Host "IMPORTANT: back up $OutDir/vault-ca.key somewhere secure and OFF this machine" -ForegroundColor Yellow
Write-Host "if you want to re-issue certs later without regenerating the whole CA." -ForegroundColor Yellow
Write-Host "This directory is gitignored - verify it never shows up in 'git status'." -ForegroundColor Yellow
