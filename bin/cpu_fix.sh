#!/bin/bash
# VM 450-453 : CPU kvm64 (défaut) -> x86-64-v3, redémarrage complet, attente Ready, puis relance de la migration Canal.
L=/root/k8s-deploy/logs/cpu_fix.txt; exec > "$L" 2>&1
pkill -f canal_migrate.sh
for id in 450 451 452 453; do
  cp /etc/pve/nodes/node4/qemu-server/$id.conf /root/k8s-deploy/backup/$id.conf.cpu.$(date +%Y%m%d-%H%M%S)
done
for id in 451 452 453 450; do
  echo "== VM $id $(date +%T)"
  timeout 200 ssh -n -o BatchMode=yes root@192.168.1.6 "qm set $id --cpu x86-64-v3 && qm reboot $id --timeout 150 2>&1 | grep -v 'guest-ping'"
  echo "rc=$?"
done
S() { timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=4 efi@$1 "${@:2}"; }
for t in $(seq 1 40); do
  ok=0; for i in 10 11 12 13; do S 172.16.3.$i true 2>/dev/null && ok=$((ok+1)); done
  echo "ssh $ok/4 $(date +%T)"; [ $ok -eq 4 ] && break; sleep 6
done
for i in 10 11 12 13; do echo -n "172.16.3.$i : "; S 172.16.3.$i "grep -m1 -o -w -E 'avx2' /proc/cpuinfo; /lib64/ld-linux-x86-64.so.2 --help | grep -E 'x86-64-v3 \(supported'"; done
for t in $(seq 1 30); do
  n=$(S 172.16.3.10 "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes --no-headers" | grep -c ' Ready')
  echo "nodes Ready (avant CNI) : $n/4"; [ "$n" -ge 1 ] && break; sleep 6
done
echo "Relance migration Canal $(date +%T)"
/root/k8s-deploy/bin/canal_migrate.sh
echo FINI
