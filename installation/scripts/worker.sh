#!/usr/bin/env bash
# =============================================================================
#  worker.sh — jonction du worker au cluster (kubeadm join)
#  Variable fournie par le Vagrantfile : MASTER_IP
# =============================================================================
set -euo pipefail

: "${MASTER_IP:?MASTER_IP non défini}"
log() { echo -e "\n==> [$(hostname)] $*"; }

JOIN_FILE=/vagrant/join.sh

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  log "Nœud déjà membre du cluster : kubeadm join ignoré"
  exit 0
fi

if [[ ! -s "${JOIN_FILE}" ]]; then
  echo "ERREUR : ${JOIN_FILE} introuvable ou vide." >&2
  echo "Provisionnez d'abord le master : vagrant up k8s-master" >&2
  exit 1
fi

log "Vérification de l'accès à l'API server ${MASTER_IP}:6443"
for _ in $(seq 1 30); do
  if curl -sk --max-time 3 "https://${MASTER_IP}:6443/livez" >/dev/null; then
    break
  fi
  sleep 5
done

log "kubeadm join"
# tr -d '\r' : protège contre un join.sh ouvert/enregistré sous Windows (CRLF)
bash <(tr -d '\r' < "${JOIN_FILE}")

log "Worker joint au cluster — vérifier depuis le master : kubectl get nodes"
