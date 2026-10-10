# Guide Formateur — Cluster Kubernetes & Argo CD Multi-Tenants

> Document de référence à destination des formateurs expliquant l'architecture des clusters, les accès formateurs et candidats, ainsi que la manipulation complète d'Argo CD (Web & CLI).

---

## 1. Cartographie de l'Infrastructure & IP

### Cluster Principal « Revision » (Kubernetes v1.33.13)

| Nœud | Nom d'hôte | Adresse IP | Rôle | Ressources |
|---|---|---|---|---|
| **Master** | `kube-master-revision-m0` | `172.16.3.10` | Control-Plane (API, etcd, Argo CD, Traefik) | 2 vCPU / 6 Go RAM / 30 Go SSD |
| **Worker 1** | `kube-worker-revision-m1` | `172.16.3.11` | Exécution Pods & Ingress Traefik | 2 vCPU / 6 Go RAM / 30 Go SSD |
| **Worker 2** | `kube-worker-revision-m2` | `172.16.3.12` | Exécution Pods & Ingress Traefik | 2 vCPU / 6 Go RAM / 30 Go SSD |
| **Worker 3** | `kube-worker-revision-m3` | `172.16.3.13` | Exécution Pods & Ingress Traefik | 2 vCPU / 6 Go RAM / 30 Go SSD |

### Cluster Secondaire (Kubernetes v1.28.15)

| Nœud | Nom d'hôte | Adresse IP | Rôle | Nom sous Argo CD |
|---|---|---|---|---|
| **Master 2** | `kube-master-g33-m0` | `172.16.33.70` | Control-Plane Externe | `cluster-172-16-33-70` |
| **Worker 2** | `kube-worker-g33-m0` | `172.16.33.80` | Worker Externe | Rattaché au cluster 33 |

---

## 2. Accès Formateurs (Administrateur Total)

### Accès SSH & Kubernetes

```bash
ssh efi@172.16.3.10
# Mot de passe : efi
sudo -i # Accès root total sans mot de passe
```
Le fichier `/etc/kubernetes/admin.conf` donne les privilèges cluster-admin sans restriction.

### Accès Argo CD Web (Admin)

- **URL Web :** `https://172.16.3.10:30443`
- **Nom d'utilisateur :** `admin`
- **Mot de passe :** `AdminEfi2026!` (stocké dans `/root/argocd-admin-password.txt` sur le master)

---

## 3. Accès & Environnement Candidats (efiadmin1 → efiadmin20)

| Utilisateur | Mot de passe initial | Namespace Dédié | Projet Argo CD | Accès & Restrictions |
|---|---|---|---|---|
| `efiadmin1` | `efiadmin1` | `efiadmin1-ns` | `efiadmin1` | Admin de son espace, SSH avec changement de mot de passe obligatoire |
| `efiadmin2` | `efiadmin2` | `efiadmin2-ns` | `efiadmin2` | Admin de son espace, SSH avec changement de mot de passe obligatoire |
| ... | ... | ... | ... | ... |
| `efiadmin20` | `efiadmin20` | `efiadmin20-ns` | `efiadmin20` | Admin de son espace, SSH avec changement de mot de passe obligatoire |

### Règles applicables aux candidats :
1. **Connexion SSH :** `ssh efiadminN@172.16.3.10`. À la 1re connexion, la modification du mot de passe est **obligatoire**.
2. **Ressources autorisées :** Deployments, Services (ClusterIP, NodePort, LoadBalancer), PVC, Ingress, Pods, Namespaces personnels (ex: `lab-efiadmin1`).
3. **Protection inter-candidats :** Règle ValidatingAdmissionPolicy `efi-tenant-protection` active.
4. **Accès Argo CD :** `efiadminN` / `efiadminN`. Chaque candidat ne voit et ne gère que ses propres applications.

---

## 4. Guide Pratique Argo CD (CLI & Web)

### 1. Se connecter à Argo CD via CLI

```bash
# Connexion Admin Formateur
argocd login 172.16.3.10:30443 --username admin --password AdminEfi2026! --insecure --grpc-web

# Connexion Candidat (ex. efiadmin1)
argocd login 172.16.3.10:30443 --username efiadmin1 --password efiadmin1 --insecure --grpc-web
```

### 2. Lister les Clusters et les Projets

```bash
argocd cluster list
argocd proj list
```

### 3. Créer une Application Argo CD (CLI)

#### Sur Cluster Local (in-cluster) :
```bash
argocd app create demo-guestbook \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace efiadmin1-ns \
  --project efiadmin1
```

#### Sur Cluster Secondaire (172.16.33.70) :
```bash
argocd app create demo-cluster33 \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path helm-guestbook \
  --dest-server https://172.16.33.70:6443 \
  --dest-namespace efiadmin1-ns \
  --project efiadmin1
```

### 4. Vérifier l'état d'une Application

```bash
argocd app list
argocd app get demo-guestbook
```

### 5. Synchronisation Manuelle et Automatique (Auto-Sync)

```bash
# Synchronisation manuelle
argocd app sync demo-guestbook

# Activer l'Auto-Sync, Auto-Prune et Self-Heal
argocd app set demo-guestbook --sync-policy automated
argocd app set demo-guestbook --auto-prune --self-heal
```

### 6. Consulter les Logs et l'Historique

```bash
argocd app logs demo-guestbook
argocd app history demo-guestbook
```

### 7. Rollback et Suppression

```bash
# Rollback vers révision 1
argocd app rollback demo-guestbook 1

# Supprimer l'application
argocd app delete demo-guestbook
```

---

## 5. Workflow Exemple pour une Séance de Travail

1. **Le formateur attribue le compte :** `efiadminN` / `efiadminN`.
2. **Connexion SSH candidat :** `ssh efiadmin1@172.16.3.10` ➔ changement de mot de passe SSH.
3. **Connexion Argo CD Web :** `https://172.16.3.10:30443` avec `efiadmin1`.
4. **Création d'une application Web sur Argo CD :**
   - **+ NEW APP** ➔ `Name`: `mon-app`, `Project`: `efiadmin1`, `Repo`: `https://github.com/argoproj/argocd-example-apps.git`, `Path`: `guestbook`, `Cluster`: `https://kubernetes.default.svc`, `Namespace`: `efiadmin1-ns`.
5. **Validation :** Cliquer sur **CREATE** puis **SYNC**. Statut final : **Synced / Healthy**.

---

## 6. Dépannage & Commandes de Secours (Formateurs)

```bash
# 1. Vérifier l'état global du cluster K8s
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running

# 2. Réinitialiser le mot de passe SSH d'un candidat (ex. efiadmin3)
passwd efiadmin3 && chage -d 0 efiadmin3

# 3. Réinitialiser la configuration Argo CD Multi-Tenants
/root/k8s-deploy/scripts/k8s-argocd-tenants.sh

# 4. Désactiver temporairement la politique de protection K8s en cas de blocage
kubectl delete validatingadmissionpolicybinding efi-tenant-protection

# 5. Réactiver la politique de protection K8s
kubectl apply -f /root/efi-tenant-protection.yaml
```
