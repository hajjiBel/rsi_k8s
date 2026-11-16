#!/usr/bin/env bash
# =============================================================================
#  common.sh — préparation commune à TOUS les nœuds (master et workers)
#  Variables fournies par le Vagrantfile : K8S_VERSION, NODE_IP, CLUSTER_HOSTS
# =============================================================================
set -euo pipefail

: "${K8S_VERSION:?K8S_VERSION non défini}"
: "${NODE_IP:?NODE_IP non défini}"
: "${CLUSTER_HOSTS:?CLUSTER_HOSTS non défini}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # évite les invites de needrestart (Ubuntu 24.04)

log() { echo -e "\n==> [$(hostname)] $*"; }

# -----------------------------------------------------------------------------
log "1/8 Résolution des noms (/etc/hosts)"
# Vagrant ajoute "127.0.1.1 <hostname>" (ou 127.0.2.1) : le nom du nœud doit
# résoudre vers son IP host-only, sinon kubelet/etcd peuvent utiliser la mauvaise IP.
sed -i -E '/^127\.0\.[12]\.1[[:space:]]/d' /etc/hosts
IFS=',' read -ra HOST_ENTRIES <<< "${CLUSTER_HOSTS}"
for entry in "${HOST_ENTRIES[@]}"; do
  ip="${entry%%=*}"
  name="${entry##*=}"
  sed -i -E "/[[:space:]]${name}([[:space:]]|\$)/d" /etc/hosts
  echo "${ip} ${name}" >> /etc/hosts
done

# -----------------------------------------------------------------------------
log "2/8 Désactivation du swap (exigé par kubelet)"
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
systemctl mask swap.target >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
log "3/8 Modules noyau et paramètres sysctl"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# -----------------------------------------------------------------------------
log "4/8 Paquets de base"
apt-get update -q
apt-get install -y -q apt-transport-https ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings

# -----------------------------------------------------------------------------
log "5/8 Installation de containerd (2.x, dépôt Docker)"
# containerd 2.x : requis à partir de Kubernetes v1.36 (v1.35 est la dernière
# version à accepter containerd 1.x) — permet un futur lab "kubeadm upgrade".
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q containerd.io

# -----------------------------------------------------------------------------
log "6/8 Installation de kubelet, kubeadm, kubectl (${K8S_VERSION})"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl containerd.io >/dev/null

# -----------------------------------------------------------------------------
log "7/8 Configuration de containerd (cgroup systemd + image pause)"
# Le paquet containerd.io livre une config qui DÉSACTIVE le plugin CRI :
# on régénère la configuration par défaut complète.
CFG=/etc/containerd/config.toml
mkdir -p /etc/containerd
containerd config default > "${CFG}"

if grep -q 'SystemdCgroup' "${CFG}"; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${CFG}"
else
  # containerd 2.x : l'option peut être absente de la config par défaut
  sed -i "/\[plugins\.'io\.containerd\.cri\.v1\.runtime'\.containerd\.runtimes\.runc\.options\]/a\            SystemdCgroup = true" "${CFG}"
fi
grep -q 'SystemdCgroup = true' "${CFG}" \
  || { echo "ERREUR : SystemdCgroup non activé dans ${CFG}" >&2; exit 1; }

# Aligner l'image "pause" sur celle attendue par kubeadm (évite l'avertissement de kubeadm)
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" 2>/dev/null | grep '/pause:' || true)"
if [[ -n "${PAUSE_IMAGE}" ]]; then
  sed -i -E "s#registry\.k8s\.io/pause:[0-9.]+#${PAUSE_IMAGE}#" "${CFG}"
fi

systemctl restart containerd
systemctl enable containerd >/dev/null

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# -----------------------------------------------------------------------------
log "8/8 kubelet sur l'IP host-only (${NODE_IP})"
# Sans cela, kubelet annonce l'IP NAT 10.0.2.15, IDENTIQUE sur les 3 VM :
# kubectl logs/exec et le réseau des pods ne fonctionnent pas.
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
systemctl daemon-reload
systemctl enable kubelet >/dev/null
# Note : kubelet redémarre en boucle tant que kubeadm init/join n'a pas été lancé (normal).

# Confort pour les stagiaires : alias k + autocomplétion
BASHRC=/home/vagrant/.bashrc
if ! grep -q 'kubectl completion bash' "${BASHRC}"; then
  cat >> "${BASHRC}" <<'EOF'

# --- Kubernetes (formation) ---
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
fi

log "Préparation commune terminée"
