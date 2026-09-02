<#
.SYNOPSIS
    Creates the missing KMS Decrypt grants for the 6 static Vault EBS
    volumes, mapped to the instance each will attach to (per AZ). Works
    around the account-level bug where AWS does not auto-create these
    grants for non-root-volume AttachVolume operations - see
    docs/aws-support-ticket-ebs-csi-visibility.md.

.USAGE
    cd secure-vault-platform-gitops
    .\scripts\create-vault-volume-grants.ps1
#>

param(
    [string]$Region = "us-east-1",
    [string]$KeyId = "arn:aws:kms:us-east-1:264284392625:key/cf960639-fa99-40f0-8b95-e5793b45f793"
)

$ErrorActionPreference = "Stop"

# volume ID -> target instance ID, from the confirmed AZ mapping:
#   us-east-1b (i-06251ac823778577b) -> ordinal 0
#   us-east-1a (i-093a2d6006dc5e5e7) -> ordinal 1
#   us-east-1c (i-00cfbab9c2b531570) -> ordinal 2
$volumeToInstance = @{
    "vol-0733ae25b010224d7" = "i-06251ac823778577b"  # data-vault-0
    "vol-0571188667bba0863" = "i-06251ac823778577b"  # audit-vault-0
    "vol-031529ede1da18ba3" = "i-093a2d6006dc5e5e7"  # data-vault-1
    "vol-04c98add98ea66dce" = "i-093a2d6006dc5e5e7"  # audit-vault-1
    "vol-05026abec445b652e" = "i-00cfbab9c2b531570"  # data-vault-2
    "vol-03684faefc29a8059" = "i-00cfbab9c2b531570"  # audit-vault-2
}

Write-Host "== Creation des grants KMS manquants ==" -ForegroundColor Cyan

foreach ($volId in $volumeToInstance.Keys) {
    $instanceId = $volumeToInstance[$volId]
    $granteePrincipal = "arn:aws:sts::264284392625:assumed-role/aws:ec2-infrastructure/$instanceId"
    $constraintsJson = "EncryptionContextSubset={aws:ebs:id=$volId}"

    Write-Host ""
    Write-Host "Volume $volId -> instance $instanceId" -ForegroundColor Yellow

    try {
        $result = aws kms create-grant `
            --key-id $KeyId `
            --grantee-principal $granteePrincipal `
            --operations Decrypt `
            --constraints $constraintsJson `
            --region $Region `
            --output json

        if ($LASTEXITCODE -eq 0) {
            $parsed = $result | ConvertFrom-Json
            Write-Host "  OK - GrantId: $($parsed.GrantId)" -ForegroundColor Green
        } else {
            Write-Host "  ECHEC (exit code $LASTEXITCODE) - sortie:" -ForegroundColor Red
            Write-Host "  $result" -ForegroundColor Red
        }
    } catch {
        Write-Host "  ERREUR: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "== Verification ==" -ForegroundColor Cyan
$grants = aws kms list-grants --key-id $KeyId --region $Region | ConvertFrom-Json
$found = $grants.Grants | Where-Object { $volumeToInstance.Keys -contains $_.Constraints.EncryptionContextSubset.'aws:ebs:id' }
Write-Host "Grants trouves pour nos 6 volumes : $($found.Count) / 6" -ForegroundColor $(if ($found.Count -eq 6) { "Green" } else { "Yellow" })
$found | Select-Object GrantId, GranteePrincipal, @{N='Volume';E={$_.Constraints.EncryptionContextSubset.'aws:ebs:id'}} | Format-Table -AutoSize
