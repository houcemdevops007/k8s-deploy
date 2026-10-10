#!/bin/bash
# Add-ons K8s : Helm, local-path (StorageClass par défaut), metrics-server, Traefik (Ingress), Argo CD + tests.
# Exécuté en root sur le master (172.16.3.10). Log : /root/k8s-addons.log
set -euo pipefail
exec > /root/k8s-addons.log 2>&1
export KUBECONFIG=/etc/kubernetes/admin.conf
step() { echo "===== $* $(date +%T)"; }
gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" -o /tmp/gh.json && grep -m1 '"tag_name"' /tmp/gh.json | cut -d'"' -f4; }

step "1. Helm"
if ! command -v helm >/dev/null; then
  V=$(gh_latest helm/helm); echo "Helm $V"
  cd /tmp
  curl -fsSLO "https://get.helm.sh/helm-$V-linux-amd64.tar.gz"
  curl -fsSLO "https://get.helm.sh/helm-$V-linux-amd64.tar.gz.sha256sum"
  sha256sum -c "helm-$V-linux-amd64.tar.gz.sha256sum"
  tar xzf "helm-$V-linux-amd64.tar.gz" && install -m 755 linux-amd64/helm /usr/local/bin/helm
fi
helm version
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

step "2. Stockage persistant local-path"
LP=$(gh_latest rancher/local-path-provisioner); echo "local-path $LP"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/$LP/deploy/local-path-storage.yaml"
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s

step "3. metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m

step "4. Traefik (Ingress, DaemonSet hostPort 80/443 sur les workers)"
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  --set deployment.kind=DaemonSet \
  --set ports.web.hostPort=80 --set ports.websecure.hostPort=443 \
  --set service.type=ClusterIP \
  --set ingressClass.enabled=true --set ingressClass.isDefaultClass=true \
  --wait --timeout 10m

step "5. Argo CD (NodePort 30880/30443)"
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30880 --set server.service.nodePortHttps=30443 \
  --wait --timeout 15m
umask 077
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d > /root/argocd-admin-password.txt
curl -fsSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && chmod 755 /usr/local/bin/argocd
argocd version --client --short || true

step "6. Tests"
set +e
for i in $(seq 1 12); do kubectl top nodes && break; sleep 10; done
kubectl create namespace addons-test
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-test, namespace: addons-test}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: pvc-test, namespace: addons-test}
spec:
  restartPolicy: Never
  containers:
  - {name: t, image: busybox:stable, command: [sh, -c, "echo persistant-OK > /data/f && cat /data/f"], volumeMounts: [{name: d, mountPath: /data}]}
  volumes: [{name: d, persistentVolumeClaim: {claimName: pvc-test}}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: whoami, namespace: addons-test}
spec:
  replicas: 2
  selector: {matchLabels: {app: whoami}}
  template:
    metadata: {labels: {app: whoami}}
    spec: {containers: [{name: w, image: traefik/whoami, ports: [{containerPort: 80}]}]}
---
apiVersion: v1
kind: Service
metadata: {name: whoami, namespace: addons-test}
spec: {selector: {app: whoami}, ports: [{port: 80}]}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: whoami, namespace: addons-test}
spec:
  rules:
  - host: whoami.test
    http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: whoami, port: {number: 80}}}}]}
EOF
kubectl -n addons-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvc-test --timeout=180s && kubectl -n addons-test logs pvc-test
kubectl -n addons-test get pvc
kubectl -n addons-test rollout status deploy/whoami --timeout=120s
sleep 5
for w in 172.16.3.11 172.16.3.12 172.16.3.13; do
  echo -n "Ingress via $w : "; curl -s -m 5 -H 'Host: whoami.test' http://$w/ | grep -m1 Hostname || echo KO
done
echo -n "Argo CD UI : "; curl -sk -m 5 -o /dev/null -w '%{http_code}\n' https://172.16.3.11:30443/
kubectl delete namespace addons-test --wait=false

step "7. État"
helm list -A
kubectl get storageclass
kubectl get ingressclass
kubectl get pods -A -o wide
kubectl top nodes
echo "ADDONS_OK $(date -Is)"
