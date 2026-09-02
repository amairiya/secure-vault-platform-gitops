<#
.SYNOPSIS
    Deletes unattached ("available") EBS volumes in this account/region,
    EXCEPT the volumes explicitly protected (the Phase 4 static-provisioning
    workaround volumes for Vault).

.DESCRIPTION
    SAFETY: only ever considers volumes in state "available" (unattached).
    Attached volumes (including EKS node root volumes) are never touched -
    AWS would refuse to delete them without a force-detach anyway, but this
    script does not even attempt it, by design.

    Shows the full list of what would be deleted and asks for explicit
    confirmation before deleting anything.

.USAGE
    cd secure-vault-platform-infra
    .\scripts\cleanup-orphaned-volumes.ps1
#>

param(
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

# The 6 volumes created by terraform/vault-static-volumes.tf - never delete these.
$Protected = @(
    "vol-0733ae25b010224d7",
    "vol-031529ede1da18ba3",
    "vol-05026abec445b652e",
    "vol-0571188667bba0863",
    "vol-04c98add98ea66dce",
    "vol-03684faefc29a8059"
)

Write-Host "== Recherche des volumes disponibles (non attaches) ==" -ForegroundColor Cyan

$allAvailable = aws ec2 describe-volumes --region $Region `
    --filters "Name=status,Values=available" `
    --query "Volumes[].{ID:VolumeId,Size:Size,AZ:AvailabilityZone,Created:CreateTime,Encrypted:Encrypted}" `
    --output json | ConvertFrom-Json

$toDelete = $allAvailable | Where-Object { $Protected -notcontains $_.ID }
$kept = $allAvailable | Where-Object { $Protected -contains $_.ID }

Write-Host ""
Write-Host "-- Volumes proteges (JAMAIS touches) trouves dans le compte:" -ForegroundColor Green
if ($kept.Count -eq 0) {
    Write-Host "  Aucun des 6 volumes proteges n'existe encore dans le compte." -ForegroundColor Yellow
} else {
    $kept | Format-Table -AutoSize
}

Write-Host ""
Write-Host "-- Volumes qui seront SUPPRIMES ($($toDelete.Count)):" -ForegroundColor Red
if ($toDelete.Count -eq 0) {
    Write-Host "  Aucun volume orphelin trouve. Rien a faire." -ForegroundColor Green
    exit 0
}
$toDelete | Format-Table -AutoSize

$totalGb = ($toDelete | Measure-Object -Property Size -Sum).Sum
Write-Host ""
Write-Host "Total: $($toDelete.Count) volume(s), $totalGb Gio" -ForegroundColor Yellow

Write-Host ""
$confirm = Read-Host "Confirmer la suppression de ces $($toDelete.Count) volume(s) ? Tapez 'oui' pour continuer"

if ($confirm -ne "oui") {
    Write-Host "Annule - aucun volume supprime." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "== Suppression en cours ==" -ForegroundColor Cyan
$successCount = 0
$failCount = 0

foreach ($vol in $toDelete) {
    try {
        aws ec2 delete-volume --volume-id $vol.ID --region $Region
        Write-Host "  [OK] $($vol.ID) supprime" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host "  [ECHEC] $($vol.ID) : $_" -ForegroundColor Red
        $failCount++
    }
}

Write-Host ""
Write-Host "== Termine: $successCount supprime(s), $failCount echec(s) ==" -ForegroundColor Cyan
