#!/bin/bash
# Génère le ClusterRole efi-tenant-admin : tous les droits sur tous les groupes d'API SAUF
#  - admissionregistration (lecture seule : protège la politique efi-tenant-protection)
#  - certificates (pas d'approbation de CSR : empêche de fabriquer l'identité d'un collègue)
#  - rbac (sans bind/escalate : pas d'auto-élévation), core (sans impersonate : pas de --as)
#  - Calico, flowcontrol, scheduling (lecture seule : ne pas casser le réseau / la priorité des autres)
#  - core sans lecture des Secrets hors de ses namespaces (sinon : lecture des secrets Argo CD / kube-system = contournement)
# Relancé toutes les 2 min par efi-tenant-rbac-sync.timer pour inclure les nouveaux groupes (CRD)
# et donner les droits complets (secrets compris) dans chaque namespace marqué tenant=efiadminN.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
RO='^(admissionregistration\.k8s\.io|certificates\.k8s\.io|rbac\.authorization\.k8s\.io|authentication\.k8s\.io|crd\.projectcalico\.org|projectcalico\.org|policy\.networking\.k8s\.io|flowcontrol\.apiserver\.k8s\.io|scheduling\.k8s\.io)$'
ALL=$(kubectl api-versions | grep / | cut -d/ -f1 | sort -u)
RW=$(echo "$ALL" | grep -vE "$RO")
READ=$(echo "$ALL" | grep -E "$RO" | grep -vE '^(rbac\.authorization\.k8s\.io|certificates\.k8s\.io|authentication\.k8s\.io)$' || true)
# Ressources du groupe core (avec sous-ressources), sauf secrets
CORE=$(kubectl get --raw /api/v1 | python3 -c 'import sys,json; print("\n".join(sorted(r["name"] for r in json.load(sys.stdin)["resources"] if r["name"] != "secrets")))')
F=$(mktemp)
{
cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: efi-tenant-admin
  labels: {tenant: platform}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "update", "patch", "delete"]
EOF
echo '- apiGroups: [""]'; echo '  resources:'; for r in $CORE; do echo "  - \"$r\""; done
echo '  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"]'
cat <<'EOF'
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews", "selfsubjectreviews"]
  verbs: ["create"]
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["get", "list", "watch", "create", "delete"]
- nonResourceURLs: ["*"]
  verbs: ["get"]
EOF
echo "- apiGroups:"; for g in $RW; do echo "  - \"$g\""; done
echo '  resources: ["*"]'; echo '  verbs: ["*"]'
if [ -n "$READ" ]; then
  echo "- apiGroups:"; for g in $READ; do echo "  - \"$g\""; done
  echo '  resources: ["*"]'; echo '  verbs: ["get", "list", "watch"]'
fi
} > "$F"
kubectl apply -f "$F" >/dev/null
rm -f "$F"
# Nouveaux objets système : protégés automatiquement
kubectl get clusterroles,clusterrolebindings -o name -l '!tenant' 2>/dev/null | grep '/system:' | xargs -r kubectl label --overwrite tenant=platform >/dev/null 2>&1 || true
# Droits complets (secrets compris) pour le propriétaire de chaque namespace marqué tenant=efiadminN
kubectl get ns -l tenant -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.tenant}{"\n"}{end}' |
while read -r ns owner; do
  [[ "$owner" =~ ^efiadmin[0-9]+$ ]] || continue
  kubectl -n "$ns" get rolebinding tenant-owner >/dev/null 2>&1 && continue
  kubectl -n "$ns" create rolebinding tenant-owner --clusterrole=admin --user="$owner" >/dev/null &&
  kubectl -n "$ns" label rolebinding tenant-owner tenant=platform --overwrite >/dev/null
done
