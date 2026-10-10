#!/bin/bash
# Passage des efiadminN en « admin du cluster protégé ». Exécuté en root sur le master. Log : /root/k8s-clusteradmin.log
set -uo pipefail
exec > /root/k8s-clusteradmin.log 2>&1
export KUBECONFIG=/etc/kubernetes/admin.conf
step() { echo "===== $* $(date +%T)"; }
TS=$(date +%Y%m%d-%H%M%S)

step "1. Pod Security par défaut = baseline pour TOUS les namespaces (sauf plateforme)"
mkdir -p /etc/kubernetes/psa
cat > /etc/kubernetes/psa/admission.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1
    kind: PodSecurityConfiguration
    defaults:
      enforce: "baseline"
      enforce-version: "latest"
      audit: "restricted"
      audit-version: "latest"
      warn: "restricted"
      warn-version: "latest"
    exemptions:
      usernames: []
      runtimeClasses: []
      namespaces: ["kube-system", "traefik", "local-path-storage"]
EOF
M=/etc/kubernetes/manifests/kube-apiserver.yaml
cp "$M" /root/kube-apiserver.yaml.bak.$TS
if ! grep -q admission-control-config-file "$M"; then
  python3 - "$M" <<'EOF'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); c = d['spec']['containers'][0]
c['command'].append('--admission-control-config-file=/etc/kubernetes/psa/admission.yaml')
c.setdefault('volumeMounts', []).append({'name': 'psa-config', 'mountPath': '/etc/kubernetes/psa', 'readOnly': True})
d['spec'].setdefault('volumes', []).append({'name': 'psa-config', 'hostPath': {'path': '/etc/kubernetes/psa', 'type': 'DirectoryOrCreate'}})
open(p, 'w').write(yaml.safe_dump(d, default_flow_style=False))
EOF
  sleep 20
  ok=0
  for i in $(seq 1 36); do kubectl get --raw /readyz >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
  if [ $ok -ne 1 ]; then
    echo "ROLLBACK : API non revenue, restauration du manifeste"; cp /root/kube-apiserver.yaml.bak.$TS "$M"
    for i in $(seq 1 36); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 5; done
    exit 5
  fi
  ps -ef | grep -c '[a]dmission-control-config-file' | sed 's/^/kube-apiserver avec config PSA : /'
fi
kubectl get --raw /readyz && echo

step "2. Marquage plateforme (lecture seule pour les utilisateurs)"
for ns in kube-system kube-public kube-node-lease traefik argocd local-path-storage; do kubectl label ns "$ns" tenant=platform --overwrite; done
for r in clusterroles clusterrolebindings customresourcedefinitions storageclasses ingressclasses priorityclasses apiservices.apiregistration.k8s.io csidrivers runtimeclasses; do
  kubectl label "$r" --all tenant=platform --overwrite >/dev/null 2>&1 && echo "$r marqués"
done
for i in $(seq 1 20); do
  kubectl -n efiadmin$i-ns label resourcequota/tenant-quota limitrange/tenant-defaults networkpolicy/isolate-namespace rolebinding/efiadmin$i-admin tenant=platform --overwrite >/dev/null
done
echo "objets de contrôle des 20 namespaces marqués"

step "3. Politique d'admission efi-tenant-protection"
kubectl apply -f /tmp/efi-tenant-protection.yaml
sleep 5

step "4. Rôle efi-tenant-admin + binding groupe efi-tenants + resynchronisation automatique"
install -m 755 /tmp/efi-tenant-rbac-sync.sh /usr/local/sbin/efi-tenant-rbac-sync.sh
/usr/local/sbin/efi-tenant-rbac-sync.sh
{ cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: efi-tenants-cluster, labels: {tenant: platform}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: efi-tenant-admin}
subjects:
EOF
for i in $(seq 1 20); do echo "- {apiGroup: rbac.authorization.k8s.io, kind: User, name: efiadmin$i}"; done; } | kubectl apply -f -
cat > /etc/systemd/system/efi-tenant-rbac-sync.service <<'EOF'
[Unit]
Description=Synchronise le ClusterRole efi-tenant-admin avec les groupes d'API
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/efi-tenant-rbac-sync.sh
EOF
cat > /etc/systemd/system/efi-tenant-rbac-sync.timer <<'EOF'
[Unit]
Description=Resynchronisation efi-tenant-admin toutes les 2 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now efi-tenant-rbac-sync.timer

step "5. Argo CD : rotation du mot de passe admin (le secret initial serait lisible par les utilisateurs)"
OLD=$(cat /root/argocd-admin-password.txt)
NEW=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 18)
if argocd login 172.16.3.10:30443 --username admin --password "$OLD" --insecure >/dev/null 2>&1 &&
   argocd account update-password --current-password "$OLD" --new-password "$NEW" >/dev/null 2>&1; then
  (umask 077; echo "$NEW" > /root/argocd-admin-password.txt)
  kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
  argocd logout 172.16.3.10:30443 >/dev/null 2>&1
  echo "mot de passe Argo CD changé, secret initial supprimé"
else
  echo "ATTENTION : rotation Argo CD non effectuée"
fi

step "6. Tests"
K1="kubectl --kubeconfig /root/k8s-users/efiadmin1.kubeconfig"
K2="kubectl --kubeconfig /root/k8s-users/efiadmin2.kubeconfig"
PASS=0; FAILN=0
T() { local exp="$1" desc="$2"; shift 2; local out rc got; out=$("$@" 2>&1); rc=$?
  [ $rc -eq 0 ] && got=OK || got=REFUS
  if [ "$got" = "$exp" ]; then r="OK  "; PASS=$((PASS+1)); else r="KO!!"; FAILN=$((FAILN+1)); fi
  printf '[%s] %-62s attendu=%-5s obtenu=%-5s | %s\n' "$r" "$desc" "$exp" "$got" "$(echo "$out" | tail -1 | cut -c1-120)"; }
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: hack-priv\n  labels: {pod-security.kubernetes.io/enforce: privileged}\n' > /tmp/ns-priv.yaml
T OK    "efiadmin1 liste les namespaces"                     $K1 get ns
T OK    "efiadmin1 liste les noeuds"                         $K1 get nodes
T OK    "efiadmin1 voit kube-system"                         $K1 get all -n kube-system
T OK    "efiadmin1 voit argocd"                              $K1 get all -n argocd
T OK    "efiadmin1 voit les pods de tout le cluster"         $K1 get pods -A
T OK    "efiadmin1 cree un deployment dans son namespace"    $K1 -n efiadmin1-ns create deployment demo --image=nginx:stable
T REFUS "efiadmin2 supprime le deployment d'efiadmin1"       $K2 -n efiadmin1-ns delete deployment demo
T REFUS "efiadmin2 scale le deployment d'efiadmin1"          $K2 -n efiadmin1-ns scale deployment demo --replicas=3
T REFUS "efiadmin2 cree un objet dans efiadmin1-ns"          $K2 -n efiadmin1-ns create configmap intrus --from-literal=a=b
T REFUS "efiadmin2 supprime le namespace efiadmin1-ns"       $K2 delete ns efiadmin1-ns --dry-run=server
T REFUS "efiadmin2 retire le label tenant d'efiadmin1-ns"    $K2 label ns efiadmin1-ns tenant-
T REFUS "efiadmin1 supprime coredns (kube-system)"           $K1 -n kube-system delete deployment coredns --dry-run=server
T REFUS "efiadmin1 exec dans un pod kube-system"             $K1 -n kube-system exec ds/kube-proxy -- true
T REFUS "efiadmin1 supprime son quota"                       $K1 -n efiadmin1-ns delete resourcequota tenant-quota --dry-run=server
T REFUS "efiadmin1 supprime la politique de protection"      $K1 delete validatingadmissionpolicy efi-tenant-protection --dry-run=server
T REFUS "efiadmin1 se donne cluster-admin"                   $K1 create clusterrolebinding hack --clusterrole=cluster-admin --user=efiadmin1 --dry-run=server
T REFUS "efiadmin1 se fait passer pour efiadmin2 (--as)"     $K1 get pods --as=efiadmin2
T REFUS "efiadmin1 supprime un noeud"                        $K1 delete node kube-worker-revision-m3 --dry-run=server
T REFUS "efiadmin1 acces kubelet via nodes/proxy"            $K1 get --raw /api/v1/nodes/kube-worker-revision-m1/proxy/pods
T OK    "efiadmin1 pose un label sur un noeud"               $K1 label node kube-worker-revision-m3 efi-test=1
T OK    "efiadmin1 retire ce label"                          $K1 label node kube-worker-revision-m3 efi-test-
T OK    "efiadmin1 cree un namespace"                        $K1 create ns lab-efiadmin1
T OK    "efiadmin1 s'approprie ce namespace (tenant=)"       $K1 label ns lab-efiadmin1 tenant=efiadmin1
T REFUS "efiadmin2 supprime le namespace lab d'efiadmin1"    $K2 delete ns lab-efiadmin1 --dry-run=server
T REFUS "efiadmin1 pod privilegie dans un nouveau namespace" $K1 -n lab-efiadmin1 run priv --image=busybox:stable --privileged --restart=Never -- sleep 1
T REFUS "efiadmin1 cree un namespace 'privileged'"           $K1 apply -f /tmp/ns-priv.yaml
T OK    "efiadmin1 cree un ClusterRole"                      $K1 create clusterrole efiadmin1-lecture --verb=get,list --resource=pods
T OK    "efiadmin1 supprime son ClusterRole"                 $K1 delete clusterrole efiadmin1-lecture
T OK    "efiadmin1 supprime son namespace lab"               $K1 delete ns lab-efiadmin1 --wait=false
T OK    "efiadmin1 supprime son deployment"                  $K1 -n efiadmin1-ns delete deployment demo
echo "BILAN : $PASS OK / $FAILN KO"

step "7. Santé de la plateforme après changement"
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed' || echo "Tous les pods sont Running"
kubectl -n default create deployment admin-check --image=nginx:stable --dry-run=server -o name && echo "Création par l'admin : OK"
echo "CLUSTERADMIN_OK $(date -Is)"
