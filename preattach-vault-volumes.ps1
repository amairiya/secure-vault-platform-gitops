<#
.SYNOPSIS
    Manually attaches the 6 static Vault EBS volumes to their target
    instances, using the operator's own IAM identity (confirmed reliable),
    as a workaround for the account-level bug where AttachVolume fails when
    called via the ebs-csi-driver's Pod Identity role.

.DESCRIPTION
    The AWS EBS CSI driver's ControllerPublishVolume is idempotent: if it
    finds a volume already attached to the target instance, it skips its
    own AttachVolume call and proceeds straight to the node-level mount
    step (which does not go through the broken code path). Pre-attaching
    here should let Kubernetes' subsequent attach attempt succeed as a
    no-op.

    After pre-attaching, this deletes the vault-0/1/2 pods so they are
    rescheduled fresh and the CSI driver re-evaluates attachment state
    from scratch rather than retrying its cached failure.

.USAGE
    cd secure-vault-platform-gitops
    .\scripts\preattach-vault-volumes.ps1
#>

param(
    [string]$Region = "us-east-1",
    [string]$Namespace = "vault"
)

$ErrorActionPreference = "Stop"

# volume ID -> (instance ID, device name). One data + one audit volume per
# instance, using the standard /dev/sd[f-p] range recommended by AWS for
# additional (non-root) volumes on Linux.
$attachments = @(
    @{ Volume = "vol-0733ae25b010224d7"; Instance = "i-06251ac823778577b"; Device = "/dev/sdf" }  # data-vault-0
    @{ Volume = "vol-0571188667bba0863"; Instance = "i-06251ac823778577b"; Device = "/dev/sdg" }  # audit-vault-0
    @{ Volume = "vol-031529ede1da18ba3"; Instance = "i-093a2d6006dc5e5e7"; Device = "/dev/sdf" }  # data-vault-1
    @{ Volume = "vol-04c98add98ea66dce"; Instance = "i-093a2d6006dc5e5e7"; Device = "/dev/sdg" }  # audit-vault-1
    @{ Volume = "vol-05026abec445b652e"; Instance = "i-00cfbab9c2b531570"; Device = "/dev/sdf" }  # data-vault-2
    @{ Volume = "vol-03684faefc29a8059"; Instance = "i-00cfbab9c2b531570"; Device = "/dev/sdg" }  # audit-vault-2
)

Write-Host "== Pre-attachement manuel des 6 volumes Vault ==" -ForegroundColor Cyan

foreach ($a in $attachments) {
    Write-Host ""
    Write-Host "Attache $($a.Volume) -> $($a.Instance) ($($a.Device))" -ForegroundColor Yellow

    # Verifie l'etat actuel avant de tenter l'attachement (idempotence de ce script lui-meme).
    $current = aws ec2 describe-volumes --volume-ids $a.Volume --region $Region --query "Volumes[0].State" --output text

    if ($current -eq "in-use") {
        Write-Host "  Deja attache - on passe au suivant." -ForegroundColor DarkGray
        continue
    }

    try {
        aws ec2 attach-volume --volume-id $a.Volume --instance-id $a.Instance --device $a.Device --region $Region
        Write-Host "  OK" -ForegroundColor Green
    } catch {
        Write-Host "  ECHEC: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "-- Attente de la stabilisation des attachements (30s)" -ForegroundColor Cyan
Start-Sleep -Seconds 30

Write-Host ""
Write-Host "-- Verification finale" -ForegroundColor Cyan
foreach ($a in $attachments) {
    $state = aws ec2 describe-volumes --volume-ids $a.Volume --region $Region --query "Volumes[0].Attachments[0].State" --output text
    Write-Host "  $($a.Volume) : $state" -ForegroundColor $(if ($state -eq "attached") { "Green" } else { "Yellow" })
}

Write-Host ""
Write-Host "-- Suppression des pods Vault pour forcer une re-evaluation propre par le CSI driver" -ForegroundColor Cyan
kubectl -n $Namespace delete pod vault-0 vault-1 vault-2 --ignore-not-found

Write-Host ""
Write-Host "== Termine. Surveillez : kubectl -n vault get pods -w ==" -ForegroundColor Green
