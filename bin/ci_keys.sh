#!/bin/bash
# Ajoute la clé SSH root d'Infra aux clés cloud-init des VM 450-453 (clés existantes conservées), puis redémarre les VM.
L=/root/k8s-deploy/logs/cikeys.txt; : > "$L"
PUB=$(ls /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub 2>/dev/null | head -1)
echo "clé Infra: $PUB" >> "$L"
for id in 450 451 452 453; do
  C=/etc/pve/nodes/node4/qemu-server/$id.conf
  K=/root/k8s-deploy/backup/keys-$id.pub
  python3 -c 'import sys,urllib.parse
l=[x for x in open(sys.argv[1]) if x.startswith("sshkeys:")]
print(urllib.parse.unquote(l[0].split(" ",1)[1].strip()).strip() if l else "")' "$C" > "$K" < /dev/null
  grep -qF "$(cut -d' ' -f2 "$PUB")" "$K" || cat "$PUB" >> "$K"
  sed -i '/^$/d' "$K"
  echo "== $id : $(wc -l < "$K") clés" >> "$L"
  timeout 20 scp -q -o BatchMode=yes "$K" root@192.168.1.6:/tmp/keys-$id.pub >> "$L" 2>&1
  timeout 60 ssh -n -o BatchMode=yes root@192.168.1.6 "qm set $id --sshkeys /tmp/keys-$id.pub && rm -f /tmp/keys-$id.pub && qm reboot $id --timeout 90" >> "$L" 2>&1
  echo "rc=$?" >> "$L"
done
for t in $(seq 1 24); do
  sleep 5; ok=0
  for i in 10 11 12 13; do timeout 8 ssh -n -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null efi@172.16.3.$i true 2>/dev/null && ok=$((ok+1)); done
  echo "ssh OK $ok/4 $(date +%T)" >> "$L"; [ $ok -eq 4 ] && break
done
for i in 10 11 12 13; do ssh-keygen -R 172.16.3.$i >/dev/null 2>&1; done
for i in 10 11 12 13; do
  echo "== test 172.16.3.$i" >> "$L"
  timeout 25 ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new efi@172.16.3.$i \
    'hostname; . /etc/os-release; echo "$PRETTY_NAME"; uname -r; nproc; free -m | sed -n 2p; df -h / | tail -1; echo swap:; swapon --show; sudo -n true && echo SUDO_OK; curl -sS -m 8 -o /dev/null -w "pkgs.k8s.io:%{http_code}\n" https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key; which kubeadm containerd docker 2>/dev/null' >> "$L" 2>&1
done
echo FINI >> "$L"
