#!/bin/bash
# Configuration de la multi-tenancy Argo CD pour efiadmin1..20
# Exécuté sur le master ou via scp/ssh depuis Infra. Log: /root/k8s-argocd-tenants.log
set -euo pipefail
exec > >(tee -a /root/k8s-argocd-tenants.log) 2>&1
export KUBECONFIG=/etc/kubernetes/admin.conf

step() { echo "===== $* $(date +%T)"; }

step "1. Ajout des 20 comptes utilisateurs dans argocd-cm"
python3 - <<'EOF'
import sys, yaml, subprocess

cm_raw = subprocess.check_output(["kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf", "-n", "argocd", "get", "cm", "argocd-cm", "-o", "yaml"])
cm = yaml.safe_load(cm_raw)
if 'data' not in cm or cm['data'] is None:
    cm['data'] = {}

for i in range(1, 21):
    u = f"efiadmin{i}"
    cm['data'][f"accounts.{u}"] = "login"

if "url" in cm['data']:
    del cm['data']['url']

with open("/tmp/argocd-cm-updated.yaml", "w") as f:
    yaml.safe_dump(cm, f)
EOF

kubectl apply -f /tmp/argocd-cm-updated.yaml
echo "argocd-cm mis à jour avec 20 comptes"

step "2. Création des 20 AppProjects (efiadmin1..20)"
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

step "3. Configuration de la politique RBAC dans argocd-rbac-cm"
python3 - <<'EOF'
import sys, yaml, subprocess

rbac_raw = subprocess.check_output(["kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf", "-n", "argocd", "get", "cm", "argocd-rbac-cm", "-o", "yaml"])
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
    lines.append(f"p, role:tenant-{u}, projects, get, *, allow")
    lines.append(f"p, role:tenant-{u}, repositories, *, *, allow")
    lines.append(f"p, role:tenant-{u}, clusters, get, *, allow")
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

step "4. Initialisation des mots de passe des utilisateurs (efiadmin1..20)"
ADMIN_PASS=$(cat /root/argocd-admin-password.txt)
argocd login 172.16.3.10:30443 --username admin --password "$ADMIN_PASS" --insecure --grpc-web >/dev/null

for i in $(seq 1 20); do
  u="efiadmin$i"
  argocd account update-password --account "$u" --current-password "$ADMIN_PASS" --new-password "$u" >/dev/null 2>&1 || true
done
echo "Mots de passe initialisés (efiadminN/efiadminN)"

step "5. Tests de validation des accès"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d '{"username":"efiadmin1","password":"efiadmin1"}' https://172.16.3.10:30443/api/v1/session)

argocd login 172.16.3.10:30443 --username efiadmin1 --password efiadmin1 --insecure --grpc-web >/dev/null
CAN_OWN=$(argocd account can-i create applications "efiadmin1/*")
CAN_OTHER=$(argocd account can-i create applications "efiadmin2/*")
CAN_CLUSTER=$(argocd account can-i get clusters "*")

echo "Login API efiadmin1: HTTP $HTTP_CODE"
echo "efiadmin1 peut créer app dans efiadmin1/* : $CAN_OWN"
echo "efiadmin1 peut créer app dans efiadmin2/* : $CAN_OTHER"
echo "efiadmin1 peut lister les clusters : $CAN_CLUSTER"

if [ "$HTTP_CODE" = "200" ] && [ "$CAN_OWN" = "yes" ] && [ "$CAN_OTHER" = "no" ] && [ "$CAN_CLUSTER" = "yes" ]; then
  echo "ARGOCD_TENANTS_OK $(date -Is)"
else
  echo "ARGOCD_TENANTS_WARN : vérification nécessaire"
fi
