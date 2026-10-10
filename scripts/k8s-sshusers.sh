#!/bin/bash
# Comptes SSH efiadmin1..20 sur le master : sans sudo, home 700, kubeconfig personnel, autocomplétion,
# mot de passe aléatoire à changer à la 1re connexion. Exécuté en root sur le master. Log : /root/k8s-sshusers.log
set -euo pipefail
exec > /root/k8s-sshusers.log 2>&1
umask 077
P=/root/k8s-users/ssh-passwords.txt; : > "$P"
for i in $(seq 1 20); do
  U=efiadmin$i
  id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash -c "Tenant Kubernetes $U" "$U"
  chmod 700 "/home/$U"
  install -d -m 700 -o "$U" -g "$U" "/home/$U/.kube"
  install -m 600 -o "$U" -g "$U" "/root/k8s-users/$U.kubeconfig" "/home/$U/.kube/config"
  grep -q 'k8s-completion' "/home/$U/.bashrc" || cat >> "/home/$U/.bashrc" <<'EOF'
# k8s-completion
[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
[ -f /etc/profile.d/k8s-aliases.sh ] && . /etc/profile.d/k8s-aliases.sh
EOF
  PW=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 14)
  echo "$U:$PW" | chpasswd
  echo "$U $PW" >> "$P"
done
echo "== test efiadmin7"
runuser -l efiadmin7 -c 'kubectl config view --minify -o jsonpath="{.contexts[0].context.namespace}"; echo; kubectl get pods; kubectl auth can-i list namespaces; kubectl auth can-i create deployments' || true
echo "== test isolation des homes"
runuser -l efiadmin7 -c 'cat /home/efiadmin8/.kube/config >/dev/null 2>&1 && echo "FUITE" || echo "home efiadmin8 inaccessible (OK)"'
runuser -l efiadmin7 -c 'sudo -n true 2>/dev/null && echo "SUDO PRESENT" || echo "pas de sudo (OK)"'
# Changement de mot de passe obligatoire à la première connexion
for i in $(seq 1 20); do chage -d 0 "efiadmin$i"; done
echo "SSHUSERS_OK $(date -Is)"
