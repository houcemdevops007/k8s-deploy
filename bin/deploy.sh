#!/bin/bash
# Orchestrateur K8s v1.33 depuis Infra (SSH efi@VM + sudo).
#   deploy.sh common   -> prépa commune sur les 4 VM en parallèle
#   deploy.sh master   -> kubeadm init sur 172.16.3.10
#   deploy.sh join     -> jonction des 3 workers
#   deploy.sh status   -> état du cluster
set -u
D=/root/k8s-deploy; L=$D/logs; mkdir -p $L
M=172.16.3.10; W="172.16.3.11 172.16.3.12 172.16.3.13"; ALL="$M $W"
S() { local h=$1; shift; timeout "${T:-60}" ssh -n -o BatchMode=yes -o ConnectTimeout=5 efi@$h "$@"; }
case "$1" in
common)
  : > $D/scripts/k8s-hosts
  for h in $ALL; do echo "$h $(S $h hostname) # k8s-cluster" >> $D/scripts/k8s-hosts; done
  cat $D/scripts/k8s-hosts
  for h in $ALL; do
    timeout 30 scp -q -o BatchMode=yes $D/scripts/k8s-common.sh $D/scripts/k8s-hosts efi@$h:/tmp/ &&
    S $h "sudo cp /tmp/k8s-hosts /root/k8s-hosts && sudo nohup setsid bash /tmp/k8s-common.sh >/dev/null 2>&1 </dev/null &" && echo "$h lancé"
  done ;;
master)
  timeout 30 scp -q -o BatchMode=yes $D/scripts/k8s-master.sh efi@$M:/tmp/ &&
  S $M "sudo nohup setsid bash /tmp/k8s-master.sh >/dev/null 2>&1 </dev/null &" && echo "master lancé" ;;
join)
  J=$(S $M "sudo cat /root/join.sh")
  [ -n "$J" ] || { echo "join.sh absent"; exit 3; }
  for h in $W; do
    S $h "sudo test -f /etc/kubernetes/kubelet.conf && echo DEJA_JOINT || sudo nohup setsid bash -c '$J > /root/k8s-join.log 2>&1; echo JOIN_RC=\$? >> /root/k8s-join.log' >/dev/null 2>&1 </dev/null &"
    echo "$h join lancé"
  done ;;
log)
  S $2 "sudo tail -${3:-5} $4" ;;
status)
  S $M "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide; sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A -o wide" ;;
esac
