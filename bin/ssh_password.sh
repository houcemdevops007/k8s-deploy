#!/bin/bash
# Active l'authentification SSH par mot de passe pour efi sur les 4 VM K8s, puis teste une vraie connexion par mot de passe.
L=/root/k8s-deploy/logs/ssh_password.txt; : > "$L"
for i in 10 11 12 13; do
  echo "== 172.16.3.$i" >> "$L"
  timeout 30 ssh -n -o BatchMode=yes -o ConnectTimeout=5 efi@172.16.3.$i '
    echo "efi:efi" | sudo -n chpasswd &&
    printf "# Active par demande utilisateur le 10/10/2026 (prioritaire sur 50-cloud-init.conf)\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n" | sudo -n tee /etc/ssh/sshd_config.d/01-password-auth.conf >/dev/null &&
    sudo -n sshd -t && sudo -n systemctl reload ssh && echo "sshd: $(sudo -n sshd -T | grep -E "^passwordauthentication")"' >> "$L" 2>&1
  echo "rc=$?" >> "$L"
done
A=/root/k8s-deploy/.askpass; printf '#!/bin/sh\necho efi\n' > "$A"; chmod 700 "$A"
for i in 10 11 12 13; do
  echo -n "test login mot de passe 172.16.3.$i : " >> "$L"
  SSH_ASKPASS="$A" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 timeout 20 setsid ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive -o ConnectTimeout=5 efi@172.16.3.$i 'echo OK $(hostname)' < /dev/null >> "$L" 2>&1 || echo "ECHEC" >> "$L"
done
shred -u "$A" 2>/dev/null || rm -f "$A"
echo FINI >> "$L"
