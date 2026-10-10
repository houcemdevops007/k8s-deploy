#!/bin/bash
# K8s v1.33 - préparation commune (master + workers). Exécuté en root dans la VM. Log : /root/k8s-common.log
set -euo pipefail
exec > /root/k8s-common.log 2>&1
export DEBIAN_FRONTEND=noninteractive
echo "DEBUT $(date -Is)"

# 1. Swap désactivé (requis par kubelet)
swapoff -a
sed -ri '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab

# 2. Modules noyau et sysctl réseau
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-k8s.conf
sysctl --system >/dev/null

# 3. Résolution des noms du cluster
sed -i '/# k8s-cluster$/d' /etc/hosts
cat /root/k8s-hosts >> /etc/hosts

# 4. containerd (dépôt officiel Docker, cgroup systemd, image pause 3.10)
apt-get update -q
apt-get install -y -q apt-transport-https ca-certificates curl gpg
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q containerd.io
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -ri 's#(sandbox_image|sandbox) = .*pause:[0-9.]+"#\1 = "registry.k8s.io/pause:3.10"#' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || { echo "ERREUR: SystemdCgroup non activé"; exit 3; }
systemctl restart containerd
systemctl enable containerd

# 5. Dépôt officiel Kubernetes v1.33 + kubelet/kubeadm/kubectl figés
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# 6. Pré-téléchargement des images (master uniquement, détecté par l'IP)
if ip -4 a | grep -q '172.16.3.10/'; then kubeadm config images pull; fi

kubeadm version -o short
containerd --version
echo "COMMON_OK $(date -Is)"
