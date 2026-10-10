#!/bin/bash
# Correctif 2 du modèle « admin du cluster protégé » : nœuds, secrets, PV hostPath, namespaces perso.
# Exécuté en root sur le master. Log : /root/k8s-fix2.log
set -uo pipefail
exec > /root/k8s-fix2.log 2>&1
export KUBECONFIG=/etc/kubernetes/admin.conf
step() { echo "===== $* $(date +%T)"; }

step "1. Politique d'admission corrigée"
kubectl apply -f /tmp/efi-tenant-protection.yaml
kubectl get validatingadmissionpolicy efi-tenant-protection -o jsonpath='typeChecking={.status.typeChecking}{"\n"}'

step "2. RBAC : plus de lecture globale des secrets + RoleBinding auto par namespace marqué"
install -m 755 /tmp/efi-tenant-rbac-sync.sh /usr/local/sbin/efi-tenant-rbac-sync.sh
/usr/local/sbin/efi-tenant-rbac-sync.sh && echo "rbac-sync OK"

step "3. Argo CD : suppression du secret initial (mot de passe conservé dans /root/argocd-admin-password.txt)"
if [ -s /root/argocd-admin-password.txt ]; then
  kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
fi

sleep 5
step "4. Tests"
K1="kubectl --kubeconfig /root/k8s-users/efiadmin1.kubeconfig"
K2="kubectl --kubeconfig /root/k8s-users/efiadmin2.kubeconfig"
PASS=0; FAILN=0
T() { local exp="$1" desc="$2"; shift 2; local out rc got; out=$("$@" 2>&1); rc=$?
  [ $rc -eq 0 ] && got=OK || got=REFUS
  if [ "$got" = "$exp" ]; then r="OK  "; PASS=$((PASS+1)); else r="KO!!"; FAILN=$((FAILN+1)); fi
  printf '[%s] %-58s attendu=%-5s obtenu=%-5s | %s\n' "$r" "$desc" "$exp" "$got" "$(echo "$out" | tail -1 | cut -c1-110)"; }
printf 'apiVersion: v1\nkind: PersistentVolume\nmetadata: {name: hack-hostpath}\nspec:\n  capacity: {storage: 1Gi}\n  accessModes: [ReadWriteOnce]\n  hostPath: {path: /}\n' > /tmp/pv-hostpath.yaml
T OK    "efiadmin1 get ns"                                   $K1 get ns
T OK    "efiadmin1 get all -n kube-system"                   $K1 get all -n kube-system
T OK    "efiadmin1 get all -n argocd"                        $K1 get all -n argocd
T OK    "efiadmin1 get all -A"                               $K1 get all -A
T OK    "efiadmin1 get configmaps -n kube-system"            $K1 get cm -n kube-system
T OK    "efiadmin1 logs d'un pod kube-system"                $K1 -n kube-system logs ds/kube-proxy --tail=1
T OK    "efiadmin1 pose un label sur un noeud"               $K1 label node kube-worker-revision-m3 efi-test=1
T OK    "efiadmin1 retire ce label"                          $K1 label node kube-worker-revision-m3 efi-test-
T REFUS "efiadmin1 taint NoExecute un noeud"                 $K1 taint node kube-worker-revision-m3 hack=1:NoExecute --dry-run=server
T REFUS "efiadmin1 cordon un noeud"                          $K1 cordon kube-worker-revision-m3 --dry-run=server
T REFUS "efiadmin1 supprime un noeud"                        $K1 delete node kube-worker-revision-m3 --dry-run=server
T REFUS "efiadmin1 lit les secrets de kube-system"           $K1 get secrets -n kube-system
T REFUS "efiadmin1 lit les secrets d'argocd"                 $K1 -n argocd get secret argocd-secret
T REFUS "efiadmin1 lit les secrets d'efiadmin2"              $K1 -n efiadmin2-ns get secrets
T OK    "efiadmin1 cree un secret chez lui"                  $K1 -n efiadmin1-ns create secret generic s1 --from-literal=a=b
T OK    "efiadmin1 lit ses secrets"                          $K1 -n efiadmin1-ns get secret s1
T OK    "efiadmin1 supprime son secret"                      $K1 -n efiadmin1-ns delete secret s1
T REFUS "efiadmin1 PV hostPath /"                            $K1 apply -f /tmp/pv-hostpath.yaml --dry-run=server
T REFUS "efiadmin1 supprime son namespace efiadmin1-ns"      $K1 delete ns efiadmin1-ns --dry-run=server
T REFUS "efiadmin1 deprotege efiadmin1-ns"                   $K1 label ns efiadmin1-ns tenant- --dry-run=server
T REFUS "efiadmin2 supprime un pod d'efiadmin1"              $K2 -n efiadmin1-ns delete pods --all --dry-run=server
T REFUS "efiadmin1 se donne admin dans default"              $K1 -n default create rolebinding hack --clusterrole=admin --user=efiadmin1 --dry-run=server
T OK    "efiadmin1 cree un namespace lab + label"            sh -c "$K1 create ns lab-efiadmin1 && $K1 label ns lab-efiadmin1 tenant=efiadmin1"
echo "attente rolebinding auto (rbac-sync)"; /usr/local/sbin/efi-tenant-rbac-sync.sh
T OK    "efiadmin1 lit les secrets de son ns lab"            $K1 -n lab-efiadmin1 get secrets
T REFUS "efiadmin2 lit les secrets du ns lab d'efiadmin1"    $K2 -n lab-efiadmin1 get secrets
T REFUS "efiadmin2 supprime le ns lab d'efiadmin1"           $K2 delete ns lab-efiadmin1 --dry-run=server
T OK    "efiadmin1 supprime son ns lab"                      $K1 delete ns lab-efiadmin1 --wait=false
T OK    "efiadmin1 helm list (son ns)"                       sudo -u efiadmin1 -H helm list -n efiadmin1-ns
echo "BILAN : $PASS OK / $FAILN KO"

step "5. Santé"
kubectl get nodes --no-headers | awk '{print $1, $2}'
kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || echo "Tous les pods sont Running"
echo "FIX2_OK $(date -Is)"
