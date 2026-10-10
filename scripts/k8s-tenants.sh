#!/bin/bash
# 20 tenants efiadmin1..20 : namespace dédié, admin du namespace uniquement, certificat client + kubeconfig.
# Exécuté en root sur le master. Log : /root/k8s-tenants.log ; kubeconfigs : /root/k8s-users/ (root uniquement)
set -euo pipefail
exec > /root/k8s-tenants.log 2>&1
export KUBECONFIG=/etc/kubernetes/admin.conf
command -v openssl >/dev/null || apt-get install -y -q openssl
OUT=/root/k8s-users; mkdir -p -m 700 "$OUT"; umask 077
SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')

for i in $(seq 1 20); do
  U=efiadmin$i; NS=$U-ns
  echo "===== $U"
  # 1. Namespace + Pod Security (baseline : pas de pod privilégié / hostPath / hostNetwork)
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NS" --overwrite tenant="$U" \
    pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest
  # 2. RBAC : ClusterRole "admin" limitée au namespace (aucun droit cluster)
  kubectl -n "$NS" create rolebinding "$U-admin" --clusterrole=admin --user="$U" --dry-run=client -o yaml | kubectl apply -f -
  # 3. Isolation réseau
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: isolate-namespace, namespace: $NS}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: traefik}}
EOF
  # 4. Certificat client (CSR API, 1 an) + kubeconfig dédié
  if [ ! -s "$OUT/$U.kubeconfig" ]; then
    openssl genrsa -out "$OUT/$U.key" 3072 2>/dev/null
    openssl req -new -key "$OUT/$U.key" -subj "/CN=$U/O=efi-tenants" -out "$OUT/$U.csr"
    kubectl delete csr "$U" --ignore-not-found
    cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata: {name: $U}
spec:
  request: $(base64 -w0 "$OUT/$U.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages: [client auth]
EOF
    kubectl certificate approve "$U"
    C=""
    for t in $(seq 1 30); do C=$(kubectl get csr "$U" -o jsonpath='{.status.certificate}'); [ -n "$C" ] && break; sleep 1; done
    [ -n "$C" ] || { echo "ERREUR certificat $U"; exit 3; }
    echo "$C" | base64 -d > "$OUT/$U.crt"
    K="$OUT/$U.kubeconfig"
    kubectl config --kubeconfig="$K" set-cluster revision --server="$SERVER" --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true
    kubectl config --kubeconfig="$K" set-credentials "$U" --client-certificate="$OUT/$U.crt" --client-key="$OUT/$U.key" --embed-certs=true
    kubectl config --kubeconfig="$K" set-context "$U@revision" --cluster=revision --user="$U" --namespace="$NS"
    kubectl config --kubeconfig="$K" use-context "$U@revision"
    rm -f "$OUT/$U.csr"
    kubectl delete csr "$U"
  fi
done

echo "===== TESTS D'ISOLATION"
set +e
K1="kubectl --kubeconfig $OUT/efiadmin1.kubeconfig"
K2="kubectl --kubeconfig $OUT/efiadmin2.kubeconfig"
echo -n "efiadmin1 peut créer un deployment dans son ns : "; $K1 auth can-i create deployments
echo -n "efiadmin1 peut créer des rolebindings dans son ns : "; $K1 auth can-i create rolebindings
echo -n "efiadmin1 peut lire les pods de efiadmin2-ns : "; $K1 auth can-i get pods -n efiadmin2-ns
echo -n "efiadmin1 peut supprimer dans efiadmin2-ns : "; $K1 auth can-i delete deployments -n efiadmin2-ns
echo -n "efiadmin1 peut lister les namespaces : "; $K1 auth can-i list namespaces
echo -n "efiadmin1 peut lister les nodes : "; $K1 auth can-i list nodes
echo -n "efiadmin1 peut lire les secrets kube-system : "; $K1 auth can-i get secrets -n kube-system
$K1 create deployment demo --image=nginx:stable && $K1 rollout status deploy/demo --timeout=120s
echo "--- efiadmin2 tente de voir/supprimer le deployment de efiadmin1 :"
$K2 get deploy -n efiadmin1-ns 2>&1 | tail -1
$K2 delete deploy demo -n efiadmin1-ns 2>&1 | tail -1
$K2 get namespaces 2>&1 | tail -1
echo "--- efiadmin1 tente un pod privilégié :"
$K1 run priv --image=busybox:stable --privileged --restart=Never -- sleep 1 2>&1 | tail -1
$K1 get pods
$K1 delete deployment demo
echo "--- quota efiadmin1-ns :"; kubectl -n efiadmin1-ns describe quota tenant-quota | tail -12
ls -l "$OUT"/*.kubeconfig | wc -l
echo "TENANTS_OK $(date -Is)"
