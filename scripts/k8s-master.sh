#!/bin/bash
# K8s v1.33 - initialisation du control-plane (VM 450, 172.16.3.10). Log : /root/k8s-master.log
set -euo pipefail
exec > /root/k8s-master.log 2>&1
echo "DEBUT $(date -Is)"
test -f /etc/kubernetes/admin.conf && { echo "Déjà initialisé"; exit 4; }
# Nom de nœud en minuscules (RFC 1123) : les hostnames cloud-init contiennent des majuscules
NODE=$(hostname -s | tr '[:upper:]' '[:lower:]')
kubeadm init \
  --apiserver-advertise-address=172.16.3.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --node-name "$NODE"
mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config
if id efi >/dev/null 2>&1; then
  mkdir -p /home/efi/.kube && cp /etc/kubernetes/admin.conf /home/efi/.kube/config && chown -R efi: /home/efi/.kube
fi
export KUBECONFIG=/etc/kubernetes/admin.conf
# CNI Flannel (VXLAN, réseau pods 10.244.0.0/16)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubeadm token create --ttl 2h --print-join-command > /root/join.sh
chmod 600 /root/join.sh
for i in $(seq 1 60); do kubectl get nodes --no-headers | grep -q ' Ready ' && break; sleep 5; done
kubectl get nodes -o wide
kubectl get pods -A
echo "MASTER_OK $(date -Is)"
