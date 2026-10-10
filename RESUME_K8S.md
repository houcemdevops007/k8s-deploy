# Cluster Kubernetes v1.33 « Revision » — Résumé d'installation (10/10/2026)

## État final ✅

| Nœud | VM | IP | Rôle | Version | Runtime |
|---|---|---|---|---|---|
| kube-master-revision-m0 | 450 | 172.16.3.10 | control-plane | v1.33.13 | containerd 2.4.1 |
| kube-worker-revision-m1 | 451 | 172.16.3.11 | worker | v1.33.13 | containerd 2.4.1 |
| kube-worker-revision-m2 | 452 | 172.16.3.12 | worker | v1.33.13 | containerd 2.4.1 |
| kube-worker-revision-m3 | 453 | 172.16.3.13 | worker | v1.33.13 | containerd 2.4.1 |

- 4/4 nœuds `Ready`, tous les pods système `Running`, controller-manager / scheduler / etcd `Healthy`.
- API : `https://172.16.3.10:6443`. CNI : Canal (Flannel VXLAN + Calico NetworkPolicy). Réseau des pods : `10.244.0.0/16`. Services : `10.96.0.0/12`.
- Test de bout en bout réussi : nginx sur 3 réplicas (un par worker), Service, DNS CoreDNS, réseau entre nœuds (`SMOKE_RC=0`). Le namespace de test a été supprimé.

## Étapes réalisées

1. VM 450-453 (Debian 12, 2 vCPU, 6 Go, 30 Go sur local-lvm, node4) : `net0` passé de `vmbr1` (inexistant sur node4) à `newvnet`, MAC conservées, configurations sauvegardées dans `backup/`.
2. Clé SSH root d'Infra ajoutée au cloud-init (vos 2 clés conservées), puis redémarrage des VM (l'authentification SSH par mot de passe est désactivée et l'agent QEMU n'est pas installé).
3. Préparation commune (`scripts/k8s-common.sh`) : swap désactivé, modules `overlay`/`br_netfilter`, sysctl, `/etc/hosts`, containerd.io (dépôt Docker, `SystemdCgroup=true`, pause 3.10), kubelet/kubeadm/kubectl v1.33 (pkgs.k8s.io), paquets bloqués à leur version (`apt-mark hold`).
4. `kubeadm init` sur le master, Flannel, puis `kubeadm join` des 3 workers, label `worker`.

## Incidents et corrections

| Incident | Cause | Correction |
|---|---|---|
| VM impossibles à démarrer | bridge `vmbr1` inexistant sur node4 | `net0` → `newvnet` (même réseau que vos autres VM K8s, gw 172.16.1.52) |
| SSH refusé | images cloud : clés uniquement, agent QEMU absent | clé d'Infra ajoutée via cloud-init |
| `kubeadm init` : `nodes "kube-master-Revision-M0" not found` | majuscules dans le hostname (interdites dans les noms de nœud K8s) | `--node-name` en minuscules, `kubeadm reset`, relance |
| `connection refused` sur containerd.sock | redémarrage de containerd juste après `kubeadm reset` | relance après stabilisation |

## Utilisation

```bash
ssh efi@172.16.3.10
kubectl get nodes            # kubeconfig déjà en place pour efi et root
# Ajouter un worker (jeton valable 24 h) :
sudo kubeadm token create --print-join-command
# puis, sur le nouveau nœud : sudo <commande> --node-name <nom-en-minuscules>
```

Récupérer le kubeconfig sur votre poste : `scp efi@172.16.3.10:.kube/config ~/.kube/config-revision`

## Points d'attention / recommandations

1. **Mot de passe `efi`/`efi` faible et SSH par mot de passe activé** : à changer (`passwd`) sur les 4 VM.
2. **IP statiques dans la plage DHCP** de `newvnet` (172.16.1.10 → 172.16.254.200) : risque de doublon. Réduire la plage DHCP ou réserver 172.16.3.10-13.
3. **Les 4 VM sont sur node4** et sur `local-lvm` : si node4 tombe, tout le cluster tombe. Après validation de Ceph (lundi) : disques sur `ceph-vm` et répartition des workers sur plusieurs nœuds.
4. **Master unique** (pas de HA du control-plane) : sauvegarder etcd régulièrement (`etcdctl snapshot save`).
5. Clé SSH d'Infra présente dans les VM (retirable dans Cloud-Init → SSH keys).
6. Add-ons installés : voir section « Add-ons installés ».

## Fichiers

- Scripts : `/root/k8s-deploy/scripts/` (common, master), `/root/k8s-deploy/bin/` (orchestration).
- Journaux : `/root/k8s-deploy/logs/` (`join.txt`, `validate.txt`, etc.).


## Add-ons installés (10/10/2026 10:56) ✅

| Composant | Version / détail | Accès |
|---|---|---|
| Helm | v4.3.0 (checksum vérifié) | `helm` sur le master |
| Stockage persistant | local-path-provisioner v0.0.37, StorageClass **`local-path` par défaut** | PVC automatiques (données dans `/opt/local-path-provisioner` du nœud) |
| metrics-server | chart Helm, `--kubelet-insecure-tls` | `kubectl top nodes` / `top pods` |
| Ingress | **Traefik** (DaemonSet sur les 3 workers, hostPort 80/443), IngressClass `traefik` par défaut | `http://172.16.3.11` / `.12` / `.13` |
| Argo CD | chart argo/argo-cd + CLI `argocd` | `https://172.16.3.10:30443` (n'importe quel nœud), user `admin` |
| Autocomplétion | bash : `kubectl` (+ alias `k`), `helm`, `argocd` | efi et root sur le master |

Tests réussis : PVC créé et écrit (`persistant-OK`), Ingress `whoami.test` joignable via les 3 workers, interface Argo CD HTTP 200, `kubectl top nodes` OK. Le namespace de test a été supprimé.

Mot de passe admin initial d'Argo CD (à changer après la première connexion) :

```bash
ssh efi@172.16.3.10 sudo cat /root/argocd-admin-password.txt
argocd login 172.16.3.10:30443 --username admin --insecure
argocd account update-password
```

> ingress-nginx n'a pas été retenu : le projet Kubernetes ingress-nginx est arrêté depuis mars 2026. Traefik prend en charge les ressources `Ingress` standard.
> local-path : le stockage est lié au nœud (pas de réplication). Passer à Ceph RBD (CSI) après validation de Ceph (switch lundi).

## Accès SSH par mot de passe (demande utilisateur)

- `efi`/`efi` sur les 4 VM, via `/etc/ssh/sshd_config.d/01-password-auth.conf` (prioritaire sur cloud-init, conservé après redémarrage). Testé OK.
- ⚠️ Mot de passe faible + `sudo` sans mot de passe = accès root pour toute personne qui atteint 172.16.x. À changer rapidement ; pour revenir en arrière : supprimer le fichier puis `systemctl reload ssh`.


## Utilisateurs efiadmin1 → efiadmin20 (10/10/2026 11:21) ✅

| Élément | Configuration |
|---|---|
| Authentification | certificat client signé par la CA du cluster (CN=efiadminN), valable 1 an |
| Namespace | `efiadminN-ns` (contexte par défaut du kubeconfig) |
| Droits | **admin du cluster protégé** (10/10 11:51) : ClusterRole `efi-tenant-admin` (tout voir / tout créer) + ValidatingAdmissionPolicy `efi-tenant-protection` (lecture seule sur le travail des collègues et la plateforme). Voir tutoriel section 3 |
| Visibilité | tout le cluster (`get ns`, `nodes`, `kube-system`, `argocd`…) ; secrets lisibles uniquement dans ses namespaces |
| Pod Security | `enforce=baseline` (pas de pod privilégié, hostPath, hostNetwork) ; `warn=restricted` |
| Quota | 1 CPU / 1 Gi demandés, 2 CPU / 2 Gi limites, 15 pods, 5 PVC / 10 Gi, 0 NodePort, 0 LoadBalancer |
| Valeurs par défaut | conteneur : limite 500m / 512Mi, demande 50m / 64Mi |
| NetworkPolicy | `isolate-namespace` : trafic entrant autorisé seulement depuis son namespace et Traefik |

Tests réussis (modèle protégé, 2 passages de tests) : efiadmin1 voit `get ns`, `kube-system`, `argocd` sans erreur ; efiadmin2 ne peut ni supprimer ni modifier le travail d'efiadmin1 ; secrets des autres / système illisibles ; suppression/taint de nœud, PV hostPath, pod privilégié refusés. Convention : `kubectl label ns <ns> tenant=efiadminN` pour protéger un namespace créé (sans label = partagé).

Fichiers kubeconfig : `/root/k8s-deploy/users/efiadminN.kubeconfig` sur Infra (chmod 600) et `/root/k8s-users/` sur le master (root uniquement). Ils contiennent la clé privée de chaque utilisateur : à transmettre par un canal sûr.

```bash
kubectl --kubeconfig efiadmin3.kubeconfig get pods      # namespace efiadmin3-ns par défaut
```

Limites connues :

- **Isolation réseau active** : CNI migré vers Canal (Flannel + Calico) le 10/10 à 11:33 ; trafic entre namespaces bloqué (testé). Voir TUTORIEL_KUBERNETES_REVISION.md.
- Révocation : un certificat ne peut pas être révoqué ; pour retirer un utilisateur, le retirer du ClusterRoleBinding `efi-tenants-cluster` et supprimer `efiadminN-admin` (tutoriel 5.3).
- Argo CD : secret `argocd-initial-admin-secret` supprimé ; mot de passe admin uniquement dans `/root/argocd-admin-password.txt` (master). Ne pas le donner aux candidats (Argo CD = cluster-admin).
- Ingress : deux utilisateurs peuvent déclarer le même nom d'hôte ; à encadrer si besoin.

## Tutoriel complet

Voir `TUTORIEL_KUBERNETES_REVISION.md` / `.html` (installation, modèle multi-utilisateurs, guide utilisateur, guide administrateur, dépannage). CPU des VM : x86-64-v3. Comptes SSH efiadmin1-20 sur le master (mot de passe initial = nom du compte, ex. efiadmin1/efiadmin1, changement obligatoire à la 1re connexion).
