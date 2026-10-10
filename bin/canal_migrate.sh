#!/bin/bash
# Migration CNI Flannel -> Canal (Flannel VXLAN + Calico pour les NetworkPolicy), puis tests d'isolation réseau.
# Orchestré depuis Infra (SSH efi@VM + sudo). Log : /root/k8s-deploy/logs/canal.txt
L=/root/k8s-deploy/logs/canal.txt; exec > "$L" 2>&1
set -u
M=172.16.3.10; NODES="172.16.3.10 172.16.3.11 172.16.3.12 172.16.3.13"
S() { local h=$1; shift; timeout "${T:-120}" ssh -n -o BatchMode=yes -o ConnectTimeout=5 efi@$h "$@"; }
K() { S $M "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf $*"; }
step() { echo "===== $* $(date +%T)"; }
W=/root/k8s-deploy/canal; mkdir -p $W

step "1. Téléchargement des manifestes"
curl -fsSL https://api.github.com/repos/projectcalico/calico/releases/latest -o $W/gh.json || exit 2
V=$(grep -m1 '"tag_name"' $W/gh.json | cut -d'"' -f4); echo "Calico/Canal $V"
curl -fsSL -o $W/canal.yaml "https://raw.githubusercontent.com/projectcalico/calico/$V/manifests/canal.yaml" || exit 2
curl -fsSL -o $W/kube-flannel.yml https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || exit 2
grep -q '"Network": "10.244.0.0/16"' $W/canal.yaml || { echo "ARRÊT: CIDR Canal inattendu"; grep -n '"Network"' $W/canal.yaml; exit 3; }
timeout 30 scp -q -o BatchMode=yes $W/canal.yaml $W/kube-flannel.yml efi@$M:/tmp/ || exit 2

step "2. Retrait de Flannel"
K delete -f /tmp/kube-flannel.yml --ignore-not-found --wait=true
for h in $NODES; do S $h "sudo -n rm -f /etc/cni/net.d/10-flannel.conflist; ls /etc/cni/net.d/"; done

step "3. Déploiement de Canal"
K apply -f /tmp/canal.yaml
T=330 K -n kube-system rollout status ds/canal --timeout=300s || { echo "ARRÊT: canal non prêt"; K -n kube-system get pods -o wide; exit 4; }
T=200 K -n kube-system rollout status deploy/calico-kube-controllers --timeout=180s

step "4. Redémarrage des workloads (rattachement au CNI Canal)"
S $M "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get deploy,ds,sts -A --no-headers -o custom-columns=NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name" |
while read -r ns kind name; do
  case "$name" in canal|kube-proxy|calico-kube-controllers) continue;; esac
  K -n "$ns" rollout restart "${kind,,}/$name" < /dev/null
done
sleep 20
T=330 K wait --for=condition=Ready pods --all -A --timeout=300s
K get pods -A -o wide

step "5. Tests d'isolation réseau (NetworkPolicy)"
K -n efiadmin1-ns create deployment np-web --image=nginx:stable
K -n efiadmin1-ns expose deployment np-web --port=80
K -n efiadmin1-ns create ingress np-web --rule='np.test/*=np-web:80'
K -n efiadmin1-ns run np-client --image=busybox:stable -- sleep 3600
K -n efiadmin2-ns run np-client --image=busybox:stable -- sleep 3600
T=200 K -n efiadmin1-ns rollout status deploy/np-web --timeout=180s
T=200 K wait --for=condition=Ready pod/np-client -n efiadmin1-ns --timeout=180s
T=200 K wait --for=condition=Ready pod/np-client -n efiadmin2-ns --timeout=180s
echo -n "Même namespace (efiadmin1 -> efiadmin1, attendu OK) : "
K -n efiadmin1-ns exec np-client -- wget -qO- -T 4 http://np-web.efiadmin1-ns >/dev/null 2>&1 && echo OK || echo BLOQUE
echo -n "Autre namespace (efiadmin2 -> efiadmin1, attendu BLOQUE) : "
K -n efiadmin2-ns exec np-client -- wget -qO- -T 4 http://np-web.efiadmin1-ns >/dev/null 2>&1 && echo "OK (FUITE)" || echo BLOQUE
echo -n "DNS depuis un tenant (attendu OK) : "
K -n efiadmin2-ns exec np-client -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo OK || echo KO
sleep 3
echo -n "Via Ingress Traefik (attendu OK) : "
curl -s -m 5 -o /dev/null -w '%{http_code}\n' -H 'Host: np.test' http://172.16.3.11/
K -n efiadmin1-ns delete deployment np-web; K -n efiadmin1-ns delete service np-web; K -n efiadmin1-ns delete ingress np-web
K -n efiadmin1-ns delete pod np-client --wait=false; K -n efiadmin2-ns delete pod np-client --wait=false

step "6. État final"
K get nodes -o wide
K get pods -A | grep -vE 'Running|Completed' || echo "Tous les pods sont Running"
echo "CANAL_OK $(date -Is)"
