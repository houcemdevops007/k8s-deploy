#!/bin/bash
# K8s - vérifications préalables (lecture seule) des VM 450-453 via l'agent QEMU, exécuté depuis Infra.
D=/root/k8s-deploy/logs; mkdir -p "$D"; OUT="$D/precheck.txt"; : > "$OUT"
for id in 450 451 452 453; do
  echo "===== VM $id" >> "$OUT"
  timeout 60 ssh -n -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.6 "qm status $id; qm guest exec $id --timeout 40 -- bash -c 'hostname; . /etc/os-release; echo \$PRETTY_NAME; uname -r; nproc; free -m | sed -n 2,3p; df -h / | tail -1; swapon --show; ip -br a | grep -v lo; timedatectl show -p NTPSynchronized; curl -sS -m 8 -o /dev/null -w \"pkgs.k8s.io:%{http_code}\\n\" https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key; which kubeadm containerd docker 2>/dev/null; ls /etc/kubernetes 2>/dev/null'" >> "$OUT" 2>&1
done
echo FINI >> "$OUT"
