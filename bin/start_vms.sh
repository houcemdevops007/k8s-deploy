#!/bin/bash
# Rattache net0 des VM 450-453 à newvnet (vmbr1 inexistant sur node4), démarre, attend l'agent, précheck.
L=/root/k8s-deploy/logs/start.txt; : > "$L"
B=/root/k8s-deploy/backup; mkdir -p "$B"
declare -A MAC=([450]=BC:24:11:C1:49:B9 [451]=BC:24:11:3B:CA:83 [452]=BC:24:11:3D:A0:0C [453]=BC:24:11:47:2F:87)
for id in 450 451 452 453; do
  cp /etc/pve/nodes/node4/qemu-server/$id.conf "$B/$id.conf.$(date +%Y%m%d-%H%M%S)"
  echo "== $id net0 -> newvnet, start $(date +%T)" >> "$L"
  timeout 60 ssh -n -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.6 "qm set $id --net0 virtio=${MAC[$id]},bridge=newvnet && qm start $id" >> "$L" 2>&1
  echo "rc=$?" >> "$L"
  sleep 5
done
for t in $(seq 1 30); do
  sleep 5; ok=0
  for id in 450 451 452 453; do
    timeout 10 ssh -n -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.6 "qm agent $id ping" >/dev/null 2>&1 && ok=$((ok+1))
  done
  echo "agent OK: $ok/4 à $(date +%T)" >> "$L"
  [ $ok -eq 4 ] && break
done
/root/k8s-deploy/bin/precheck.sh
echo FINI >> "$L"
