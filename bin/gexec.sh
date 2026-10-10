#!/bin/bash
# gexec.sh - pilote des VM via l'agent QEMU (sur node4), depuis Infra.
#   gexec.sh push  <vmid> <fichier_local> <chemin_vm>
#   gexec.sh bg    <vmid> <script_vm>          (lance en arrière-plan dans la VM)
#   gexec.sh run   <vmid> <commande courte>     (sortie affichée, timeout 50 s)
set -u
N=root@192.168.1.6
SSH="timeout 70 ssh -n -o BatchMode=yes -o ConnectTimeout=5 $N"
out() { python3 -c 'import sys,json
d=json.load(sys.stdin); print(d.get("out-data",""),end=""); e=d.get("err-data","")
e and print(e,end="",file=sys.stderr); sys.exit(d.get("exitcode",0))' < /dev/stdin; }
case "$1" in
push) B=$(base64 -w0 "$3"); $SSH "qm guest exec $2 --timeout 30 -- bash -c 'echo $B | base64 -d > $4 && chmod 700 $4'" | out ;;
bg)   $SSH "qm guest exec $2 --timeout 10 -- bash -c 'nohup setsid bash $3 >/dev/null 2>&1 </dev/null &'" | out ;;
run)  id=$2; shift 2; C=$(printf '%s' "$*" | base64 -w0); $SSH "qm guest exec $id --timeout 50 -- bash -c 'echo $C | base64 -d | bash'" | out ;;
*) echo "usage"; exit 2 ;;
esac
