#!/bin/bash
# Attend MASTER_OK, joint les 3 workers, attend Ready, collecte l'état final.
L=/root/k8s-deploy/logs/join.txt; : > "$L"
S() { local h=$1; shift; timeout ${T:-20} ssh -n -o BatchMode=yes -o ConnectTimeout=5 efi@$h "$@"; }
for t in $(seq 1 40); do
  S 172.16.3.10 "sudo -n grep -qE 'MASTER_OK|ERREUR|error execution' /root/k8s-master.log" && break; sleep 6
done
S 172.16.3.10 "sudo -n tail -25 /root/k8s-master.log" >> "$L" 2>&1
S 172.16.3.10 "sudo -n grep -q MASTER_OK /root/k8s-master.log" || { echo "ARRÊT: master non OK" >> "$L"; exit 3; }
J=$(S 172.16.3.10 "sudo -n cat /root/join.sh")
echo "join: ${J%%--token*}--token ***" >> "$L"
for h in 172.16.3.11 172.16.3.12 172.16.3.13; do
  echo "== join $h $(date +%T)" >> "$L"
  T=180 S $h "sudo -n test -f /etc/kubernetes/kubelet.conf && echo DEJA_JOINT || sudo -n $J --node-name \$(hostname -s | tr A-Z a-z)" >> "$L" 2>&1
  echo "rc=$?" >> "$L"
done
K="sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf"
for t in $(seq 1 40); do
  n=$(S 172.16.3.10 "$K get nodes --no-headers" | grep -c ' Ready ')
  echo "Ready $n/4 $(date +%T)" >> "$L"; [ "$n" = 4 ] && break; sleep 6
done
{ echo "===== ETAT FINAL"; S 172.16.3.10 "$K get nodes -o wide; $K get pods -A -o wide; $K version; $K get cs 2>/dev/null; $K cluster-info"; } >> "$L" 2>&1
echo FINI >> "$L"
