#!/bin/bash
# Configuration de la multi-tenancy Argo CD pour efiadmin1..20
# Exécuté sur le master ou via scp/ssh depuis Infra. Log: /root/k8s-argocd-tenants.log
set -euo pipefail
exec > >(tee -a /root/k8s-argocd-tenants.log) 2>&1
export KUBECONFIG=/etc/kubernetes/admin.conf

step() { echo "===== $* $(date +%T)"; }

step "1. Ajout des 20 comptes utilisateurs dans argocd-cm"
# Préparation des entrées accounts.efiadminN: login
python3 - <<'EOF'
import sys, yaml, subprocess

cm_raw = subprocess.check_output(["kubectl", "-n", "argocd", "get", "cm", "argocd-cm", "-o", "yaml"])
cm = yaml.safe_load(cm_raw)
if 'data' not in cm or cm['data'] is None:
    cm['data'] = {}

for i in range(1, 21):
    u = f"efiadmin{i}"
    cm['data'][f"accounts.{u}"] = "login"

with open("/tmp/argocd-cm-updated.yaml", "w") as f:
    yaml.safe_dump(cm, f)
EOF

kubectl apply -f /tmp/argocd-cm-updated.yaml
echo "argocd-cm mis à jour avec 20 comptes"

step "2. Génération des mots de passe initiaux dans argocd-secret"
# Génération des hashes bcrypt pour efiadmin1..20 avec mot de passe = nom du compte
python3 - <<'EOF'
import subprocess, yaml, datetime

secret_raw = subprocess.check_output(["kubectl", "-n", "argocd", "get", "secret", "argocd-secret", "-o", "yaml"])
secret = yaml.safe_load(secret_raw)
if 'stringData' not in secret or secret['stringData'] is None:
    secret['stringData'] = {}

now = datetime.datetime.now(datetime.timezone.utc).isoformat()

for i in range(1, 21):
    u = f"efiadmin{i}"
    # argocd account bcrypt génère le hash standard
    hash_out = subprocess.check_output(["argocd", "account", "bcrypt", "--password", u]).decode().strip()
    secret['stringData'][f"account.{u}.password"] = hash_out
    secret['stringData'][f"account.{u}.passwordMtime"] = now

with open("/tmp/argocd-secret-updated.yaml", "w") as f:
    yaml.safe_dump(secret, f)
EOF

kubectl apply -f /tmp/argocd-secret-updated.yaml
echo "argocd-secret mis à jour avec les hashes bcrypt"

step "3. Création des 20 AppProjects (efiadmin1..20)"
for i in $(seq 1 20); do
  u="efiadmin$i"
  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $u
  namespace: argocd
  labels:
    tenant: platform
spec:
  description: "Espace Argo CD reserve a $u"
  sourceRepos:
  - '*'
  destinations:
  - namespace: '$u-ns'
    server: 'https://kubernetes.default.svc'
  - namespace: '$u-*'
    server: 'https://kubernetes.default.svc'
  - namespace: '*-$u'
    server: 'https://kubernetes.default.svc'
  - namespace: 'lab-$u'
    server: 'https://kubernetes.default.svc'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
EOF
done
echo "20 AppProjects créés"

step "4. Configuration de la politique RBAC dans argocd-rbac-cm"
python3 - <<'EOF'
import sys, yaml, subprocess

rbac_raw = subprocess.check_output(["kubectl", "-n", "argocd", "get", "cm", "argocd-rbac-cm", "-o", "yaml"])
rbac = yaml.safe_load(rbac_raw)
if 'data' not in rbac or rbac['data'] is None:
    rbac['data'] = {}

lines = [
    "g, admin, role:admin"
]

for i in range(1, 21):
    u = f"efiadmin{i}"
    lines.append(f"p, role:tenant-{u}, applications, *, {u}/*, allow")
    lines.append(f"p, role:tenant-{u}, applicationsets, *, {u}/*, allow")
    lines.append(f"p, role:tenant-{u}, projects, get, {u}, allow")
    lines.append(f"p, role:tenant-{u}, repositories, *, *, allow")
    lines.append(f"p, role:tenant-{u}, logs, get, {u}/*, allow")
    lines.append(f"p, role:tenant-{u}, exec, create, {u}/*, allow")
    lines.append(f"g, {u}, role:tenant-{u}")

rbac['data']['policy.csv'] = "\n".join(lines) + "\n"
rbac['data']['policy.default'] = ""
rbac['data']['policy.matchMode'] = "glob"

with open("/tmp/argocd-rbac-cm-updated.yaml", "w") as f:
    yaml.safe_dump(rbac, f)
EOF

kubectl apply -f /tmp/argocd-rbac-cm-updated.yaml
echo "argocd-rbac-cm mis à jour"

step "5. Tests de validation des accès"
sleep 3
# Test API de login pour efiadmin1
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d '{"username":"efiadmin1","password":"efiadmin1"}' https://172.16.3.10:30443/api/v1/session)
if [ "$HTTP_CODE" = "200" ]; then
  echo "[OK  ] Login Argo CD efiadmin1/efiadmin1 via API"
else
  echo "[KO!!] Login Argo CD efiadmin1/efiadmin1 échec (code HTTP $HTTP_CODE)"
fi

# Test RBAC avec argocd account can-i
CAN_CREATE_OWN=$(argocd account can-i create applications 'efiadmin1/*' --user efiadmin1 2>&1 || true)
CAN_CREATE_OTHER=$(argocd account can-i create applications 'efiadmin2/*' --user efiadmin1 2>&1 || true)
CAN_GET_PROJ_OWN=$(argocd account can-i get projects 'efiadmin1' --user efiadmin1 2>&1 || true)
CAN_GET_PROJ_OTHER=$(argocd account can-i get projects 'efiadmin2' --user efiadmin1 2>&1 || true)

echo "efiadmin1 peut créer app dans efiadmin1/* : $CAN_CREATE_OWN"
echo "efiadmin1 peut créer app dans efiadmin2/* : $CAN_CREATE_OTHER"
echo "efiadmin1 peut voir projet efiadmin1      : $CAN_GET_PROJ_OWN"
echo "efiadmin1 peut voir projet efiadmin2      : $CAN_GET_PROJ_OTHER"

if [ "$CAN_CREATE_OWN" = "yes" ] && [ "$CAN_CREATE_OTHER" = "no" ] && [ "$CAN_GET_PROJ_OWN" = "yes" ] && [ "$CAN_GET_PROJ_OTHER" = "no" ]; then
  echo "ARGOCD_TENANTS_OK $(date -Is)"
else
  echo "ARGOCD_TENANTS_WARN : vérification nécessaire"
fi
