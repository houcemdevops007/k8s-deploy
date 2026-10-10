#!/bin/bash
# Validation K8s : rôles worker, test nginx x3 + DNS/réseau inter-nœuds, nettoyage.
L=/root/k8s-deploy/logs/validate.txt
timeout 240 ssh -n -o BatchMode=yes efi@172.16.3.10 'K="sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf"
for n in m1 m2 m3; do $K label node kube-worker-revision-$n node-role.kubernetes.io/worker= --overwrite; done
$K -n kube-system rollout status deploy/coredns --timeout=90s
$K create namespace smoke-test
$K -n smoke-test create deployment web --image=nginx:stable --replicas=3
$K -n smoke-test expose deployment web --port=80
$K -n smoke-test rollout status deploy/web --timeout=150s
$K -n smoke-test get pods -o wide
$K -n smoke-test run t --image=busybox:stable --restart=Never --rm -i --timeout=90s -- sh -c "nslookup web.smoke-test.svc.cluster.local && for i in 1 2 3 4 5 6; do wget -qO- -T 3 http://web | grep -o \"<title>.*</title>\"; done"
echo "SMOKE_RC=$?"
$K delete namespace smoke-test --wait=false
$K get nodes
$K get pods -A | grep -vE "Running|Completed" || echo "Tous les pods système sont Running"' > "$L" 2>&1
echo FINI >> "$L"
