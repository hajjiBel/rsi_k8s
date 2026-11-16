#!/usr/bin/env bash
# =============================================================================
#  master.sh — initialisation du control plane (kubeadm init) + Calico
#  Variables fournies par le Vagrantfile :
#    MASTER_IP, NODE_NAME, POD_CIDR, NODE_CIDR, CALICO_VERSION
# =============================================================================
set -euo pipefail

: "${MASTER_IP:?MASTER_IP non défini}"
: "${NODE_NAME:?NODE_NAME non défini}"
: "${POD_CIDR:?POD_CIDR non défini}"
: "${NODE_CIDR:?NODE_CIDR non défini}"
: "${CALICO_VERSION:?CALICO_VERSION non défini}"

export KUBECONFIG=/etc/kubernetes/admin.conf
log() { echo -e "\n==> [$(hostname)] $*"; }

# -----------------------------------------------------------------------------
if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "Cluster déjà initialisé : kubeadm init ignoré (re-provisionnement)"
else
  rm -f /vagrant/join.sh      # supprime un join.sh d'un ancien cluster

  log "1/4 Téléchargement des images du control plane"
  kubeadm config images pull

  log "2/4 kubeadm init"
  kubeadm init \
    --apiserver-advertise-address="${MASTER_IP}" \
    --apiserver-cert-extra-sans="${MASTER_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="${NODE_NAME}"
fi

# -----------------------------------------------------------------------------
log "3/4 kubeconfig pour root et vagrant (+ copie dans le dossier partagé)"
for dir in /root/.kube /home/vagrant/.kube; do
  mkdir -p "${dir}"
  cp -f /etc/kubernetes/admin.conf "${dir}/config"
done
chown -R vagrant:vagrant /home/vagrant/.kube
# Permet d'utiliser kubectl depuis la machine hôte : kubectl --kubeconfig kubeconfig get nodes
cp -f /etc/kubernetes/admin.conf /vagrant/kubeconfig

# -----------------------------------------------------------------------------
log "4/4 Installation de Calico ${CALICO_VERSION}"
if kubectl -n kube-system get daemonset calico-node >/dev/null 2>&1; then
  echo "Calico déjà installé"
else
  curl -fsSL -o /tmp/calico.yaml \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  # --server-side : évite l'erreur "metadata.annotations: Too long" sur les gros CRD
  kubectl apply --server-side --force-conflicts -f /tmp/calico.yaml
  # Les VM ont 2 interfaces (NAT 10.0.2.15 identique partout + host-only) :
  # on force Calico à utiliser l'interface du réseau 192.168.56.0/24.
  kubectl -n kube-system set env daemonset/calico-node \
    IP_AUTODETECTION_METHOD="cidr=${NODE_CIDR}" \
    CALICO_IPV4POOL_CIDR="${POD_CIDR}"
fi

# -----------------------------------------------------------------------------
log "Génération de la commande de jonction pour les workers"
# --ttl 0 : jeton sans expiration (lab) — un worker créé le lendemain pourra encore rejoindre
kubeadm token create --ttl 0 --print-join-command > /vagrant/join.sh

log "Attente du nœud ${NODE_NAME} (Ready)…"
kubectl wait --for=condition=Ready "node/${NODE_NAME}" --timeout=300s \
  || echo "AVERTISSEMENT : ${NODE_NAME} pas encore Ready (téléchargement des images Calico en cours ?) — vérifier avec : kubectl get pods -A"

kubectl get nodes -o wide
log "Master prêt"
