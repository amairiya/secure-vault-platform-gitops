# AWS Support Ticket — Volumes created via assumed-role (STS) credentials never become visible via DescribeVolumes

## Résumé

Les volumes EBS créés via un rôle IAM assumé (identifiants temporaires STS, obtenus via EKS Pod Identity) ne deviennent **jamais** visibles via `DescribeVolumes` — ni depuis la session qui les a créés, ni depuis aucune autre identité du compte — alors que l'appel `CreateVolume` retourne un ID de volume valide. Les volumes créés par un utilisateur IAM classique (identifiants long-terme) dans le même compte, la même région, et la même zone de disponibilité sont, eux, visibles **instantanément**, sans exception, sur plus de 10 tests répétés.

## Informations sur l'environnement

| Champ | Valeur |
|---|---|
| Compte AWS | `264284392625` |
| Région | `us-east-1` |
| Zones de disponibilité testées | `us-east-1a`, `us-east-1b` |
| Service concerné | EC2 (EBS), en lien avec EKS / IAM (Pod Identity) |
| Rôle IAM affecté | `arn:aws:iam::264284392625:role/secure-vault-production-ebs-csi-driver` |
| Mécanisme d'assomption du rôle | EKS Pod Identity (principal de service `pods.eks.amazonaws.com`) |
| Cluster EKS | `secure-vault-production` (Kubernetes v1.36) |
| Driver concerné | `aws-ebs-csi-driver` (testé en v1.65.0-eksbuild.1 **et** v1.63.1-eksbuild.1 — comportement identique) |

## Description détaillée du problème

Le driver `aws-ebs-csi-driver`, exécuté dans le cluster EKS ci-dessus et authentifié via un rôle IAM assumé (EKS Pod Identity), échoue systématiquement à provisionner des volumes EBS dynamiques. Le cycle observé est constant :

1. `CreateVolume` est appelé avec succès (chiffré, clé KMS gérée par le client, tags requis inclus) → un ID de volume valide est retourné par l'API.
2. `DescribeVolumes` sur ce même ID, appelé immédiatement après (moins d'une seconde à quelques dizaines de secondes plus tard), échoue systématiquement avec :
   ```
   InvalidVolume.NotFound: The volume 'vol-xxxxxxxxxxxxxxxxx' does not exist.
   ```
3. Le volume ne devient **jamais** visible, même après plusieurs minutes, même interrogé depuis une **identité IAM complètement différente** (utilisateur IAM classique du même compte).

## Preuve décisive (test isolé, contrôlé)

Un volume test a été créé explicitement pour isoler le problème, avec toutes les variables confondantes éliminées (tags requis inclus, chemin réseau identique à celui du driver, même rôle IAM) :

```
Volume créé : vol-06afd2678a98ae4e2
Créé via    : assumed-role/secure-vault-production-ebs-csi-driver (session Pod Identity, depuis l'intérieur du VPC)
AZ          : us-east-1b
Chiffrement : activé, clé KMS arn:aws:kms:us-east-1:264284392625:key/cf960639-fa99-40f0-8b95-e5793b45f793
Tags requis : ebs.csi.aws.com/cluster=true, CSIVolumeName=manual-test-vol (per AmazonEBSCSIDriverPolicy)
```

Résultat de `CreateVolume` : succès, ID retourné.

Résultat de `DescribeVolumes vol-06afd2678a98ae4e2` :
- Depuis la **même session** (rôle assumé, intérieur du cluster) : `InvalidVolume.NotFound`
- Depuis une **identité totalement différente** (utilisateur IAM `terraform-deployer-lab`, poste local, quelques minutes plus tard) : `InvalidVolume.NotFound`

Le volume est donc invisible pour absolument tout le compte, bien que l'API ait confirmé sa création.

## Contre-test : comportement normal avec un utilisateur IAM classique

Pour confirmer que ce n'est pas un problème général de propagation dans la région/le compte, les mêmes opérations ont été répétées avec l'utilisateur IAM `terraform-deployer-lab` (identifiants long-terme, pas de session assumée) :

| Test | AZ | Chiffré | Résultat `DescribeVolumes` immédiat |
|---|---|---|---|
| `vol-04ca8b3483f05f98e` | us-east-1a | Non | `available` (immédiat) |
| `vol-027092d5c23ee01c0` | us-east-1a | Oui (même clé KMS) | `available` (immédiat) |
| Volume test #2 | us-east-1b | Oui (même clé KMS) | `available` (immédiat) |

Tous ces tests, faits en dehors de toute session de rôle assumé, ont réussi instantanément, sans exception.

## Étapes de dépannage déjà réalisées (causes exclues)

- [x] Politique IAM du rôle vérifiée et confirmée correcte et complète (`AmazonEBSCSIDriverPolicy`, aucune permission boundary)
- [x] Politique de la clé KMS vérifiée — statements explicites pour les rôles liés au service concernés
- [x] Redémarrage complet du contrôleur `ebs-csi-controller` — comportement identique après redémarrage
- [x] Vérification qu'aucune ressource orpheline (`VolumeAttachment`, `PersistentVolume`) ne pollue les appels groupés du driver — aucune trouvée
- [x] Test avec deux versions différentes du driver (`v1.65.0-eksbuild.1` et `v1.63.1-eksbuild.1`) — comportement identique
- [x] Test dans deux zones de disponibilité différentes (`us-east-1a`, `us-east-1b`) — comportement identique
- [x] Test avec et sans chiffrement KMS — comportement identique (le chiffrement n'est pas en cause)
- [x] Test depuis le réseau interne du VPC (même chemin réseau que le driver, via un pod utilisant le même ServiceAccount/Pod Identity) — reproduit le problème à l'identique
- [x] Analyse CloudTrail des appels `DescribeVolumes` — confirme que les appels proviennent bien du rôle attendu (`assumed-role/secure-vault-production-ebs-csi-driver/...`), sans erreur de région ou de compte

## Impact

Impossible de provisionner du stockage persistant chiffré via EKS/Pod Identity dans ce compte — bloque le déploiement de tout workload nécessitant des PVC dynamiques (dans notre cas, un cluster HashiCorp Vault en haute disponibilité avec stockage Raft persistant).

## Demande

Merci de bien vouloir investiguer pourquoi les ressources EBS créées via des identifiants de session temporaires (rôle assumé via EKS Pod Identity/STS) dans ce compte (`264284392625`, région `us-east-1`) ne deviennent jamais visibles via `DescribeVolumes`, alors que les mêmes opérations réussissent instantanément avec un utilisateur IAM à identifiants long-terme.

Merci de confirmer si :
1. Il s'agit d'un incident de service connu affectant ce compte ou cette région.
2. Une garde-fou/restriction spécifique à ce compte (SCP, quota, ou limitation d'environnement) explique ce comportement.
3. Une action corrective peut être appliquée côté AWS, ou si un contournement (provisioning statique, ou changement de mécanisme d'authentification) est recommandé de notre côté en attendant.

## Références pour investigation (Request IDs)

- `754a8dfa-197d-426c-8858-5921bc2c862f`
- `16ccf300-03a5-49a1-8b4e-5b3340325bf6`
- `2fad1cda-6661-4991-a5a4-7cf8e4fb2bc1`
- `81ce0958-be4c-465a-b3f4-382e86ca105b`
- `93df3c6f-1085-4a8d-b5a5-daec0c0ecd79`
- `6854e3b0-7f05-40f7-9635-3c2033630141`
- `3b262a5f-e2c9-411b-be75-446b19c47759`

## Volume IDs affectés (créés, jamais devenus visibles)

```
vol-0b6f45c436b5630bb
vol-0e2a0645b59971461
vol-0a775574c4531f2fb
vol-054f88ffc9f42f627
vol-038d1799989f02045
vol-025a58004c17074aa
vol-0544f166d73244c27
vol-0bf65c37afe79b713
vol-0fc879538fdb77eac
vol-06afd2678a98ae4e2
```
