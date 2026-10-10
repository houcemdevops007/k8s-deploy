#!/bin/bash
# Migration CNI Flannel -> Canal (Flannel VXLAN + Calico pour les NetworkPolicy), puis tests d'isolation réseau.
# Orchestré depuis Infra (SSH efi@VM + sudo). Log : /root/k8s-deploy/logs/canal_tests.txt
L=/root/k8s-deploy/logs/canal_tests.txt; exec > "$L" 2>&1
set -u
M=172.16.3.10; NODES="172.16.3.10 172.16.3.11 172.16.3.12 172.16.3.13"
S() { local h=$1; shift; timeout "${T:-120}" ssh -n -o BatchMode=yes -o ConnectTimeout=5 efi@$h "$@"; }
K() { S $M "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf $*"; }
step() { echo "===== $* $(date +%T)"; }
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
