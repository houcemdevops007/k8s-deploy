#!/bin/bash
# Dépose la clé SSH root d'Infra dans efi@VM (mot de passe utilisé une seule fois via SSH_ASKPASS, puis effacé).
L=/root/k8s-deploy/logs/sshsetup.txt; : > "$L"
pkill -f start_vms.sh
A=/root/k8s-deploy/.askpass
printf '#!/bin/sh\necho efi\n' > "$A"; chmod 700 "$A"
for i in 10 11 12 13; do
  echo "== 172.16.3.$i" >> "$L"
  SSH_ASKPASS="$A" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 timeout 30 setsid ssh-copy-id \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 efi@172.16.3.$i < /dev/null >> "$L" 2>&1
  echo "copy rc=$?" >> "$L"
done
shred -u "$A" 2>/dev/null || rm -f "$A"
for i in 10 11 12 13; do
  echo "== test 172.16.3.$i" >> "$L"
  timeout 20 ssh -n -o BatchMode=yes -o ConnectTimeout=5 efi@172.16.3.$i \
    'hostname; . /etc/os-release; echo "$PRETTY_NAME"; uname -r; nproc; free -m | sed -n 2p; df -h / | tail -1; echo "swap:"; swapon --show; sudo -n true && echo SUDO_OK; curl -sS -m 8 -o /dev/null -w "pkgs.k8s.io:%{http_code}\n" https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key; timedatectl show -p NTPSynchronized; which kubeadm containerd docker 2>/dev/null; ls /etc/kubernetes 2>/dev/null' >> "$L" 2>&1
done
echo FINI >> "$L"
