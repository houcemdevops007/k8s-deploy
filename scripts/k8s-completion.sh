#!/bin/bash
# Autocomplétion bash pour kubectl (+ alias k), helm et argocd sur le master. Log : /root/k8s-completion.log
set -euo pipefail
exec > /root/k8s-completion.log 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q bash-completion
mkdir -p /etc/bash_completion.d
kubectl completion bash > /etc/bash_completion.d/kubectl
helm completion bash > /etc/bash_completion.d/helm
argocd completion bash > /etc/bash_completion.d/argocd
chmod 644 /etc/bash_completion.d/{kubectl,helm,argocd}
cat > /etc/profile.d/k8s-aliases.sh <<'EOF'
# Alias kubectl + autocomplétion de l'alias
alias k=kubectl
if [ -n "$BASH_VERSION" ] && type __start_kubectl >/dev/null 2>&1; then complete -o default -F __start_kubectl k; fi
EOF
# Charge bash-completion pour tous les shells interactifs (root et efi)
for f in /root/.bashrc /home/efi/.bashrc; do
  [ -f "$f" ] || continue
  grep -q 'k8s-completion' "$f" || cat >> "$f" <<'EOF'
# k8s-completion
[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
[ -f /etc/profile.d/k8s-aliases.sh ] && . /etc/profile.d/k8s-aliases.sh
EOF
done
# Vérification dans un shell interactif de efi
su - efi -c 'bash -ic "complete -p kubectl k helm argocd" 2>/dev/null'
echo COMPLETION_OK
