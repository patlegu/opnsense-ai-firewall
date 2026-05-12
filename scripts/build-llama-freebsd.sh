#!/usr/bin/env bash
#
# build-llama-freebsd.sh — compile llama.cpp natif FreeBSD amd64 et
# rapatrie les artefacts dans llama-bin/freebsd-amd64/.
#
# Prérequis : une VM FreeBSD 14.x déjà up + accessible en SSH avec ta
# clé. Voir docs/build-llama-freebsd.md pour la procédure de spawn
# (mfsBSD / Hetzner / libvirt).
#
# Usage :
#   bash scripts/build-llama-freebsd.sh root@<IP_VM>
#
# Variables d'environnement override :
#   LLAMA_TAG=b3813               # tag llama.cpp à compiler (défaut)
#   BUILD_DIR=/usr/home/llama-build  # dossier de build sur la VM
#   JOBS=$(sysctl -n hw.ncpu)     # parallélisme make
#
# Cible llama.cpp = b3813 par défaut (corrige le bug
# --lora-init-without-apply des builds antérieurs, cf. mémoire
# opérateur project_lora_wireguard_bug).

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 user@host" >&2
    echo "Exemple : $0 root@95.216.X.Y" >&2
    exit 1
fi

REMOTE="$1"
LLAMA_TAG="${LLAMA_TAG:-b3813}"
BUILD_DIR="${BUILD_DIR:-/usr/home/llama-build}"

# Résolution du chemin local du repo (le script peut être appelé depuis
# n'importe où — on remonte au parent du dossier scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/llama-bin/freebsd-amd64"
mkdir -p "${OUT_DIR}/lib"

echo "[build-llama-freebsd] remote=${REMOTE} tag=${LLAMA_TAG}"
echo "[build-llama-freebsd] sortie locale : ${OUT_DIR}"

# ── Étape 1 : install des build deps sur la VM (idempotent) ─────────
ssh -o StrictHostKeyChecking=accept-new "${REMOTE}" bash -s <<'REMOTE_SETUP'
set -euo pipefail
echo "[remote] pkg install build deps…"
pkg update -q
pkg install -y -q git cmake gmake llvm openblas
which clang cmake git || { echo "deps manquantes" >&2; exit 1; }
REMOTE_SETUP

# ── Étape 2 : clone + build llama.cpp ───────────────────────────────
# On utilise `ssh -t` pour propager les signaux Ctrl-C proprement.
ssh "${REMOTE}" bash -s "${LLAMA_TAG}" "${BUILD_DIR}" <<'REMOTE_BUILD'
set -euo pipefail
LLAMA_TAG="$1"
BUILD_DIR="$2"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -d llama.cpp/.git ]]; then
    git clone https://github.com/ggml-org/llama.cpp.git
fi

cd llama.cpp
git fetch --tags --quiet
git checkout "${LLAMA_TAG}"
git clean -xfd

echo "[remote] cmake configure…"
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF

echo "[remote] cmake build (jobs=${JOBS})…"
cmake --build build -j "${JOBS}" --config Release --target llama-server

echo "[remote] strip + tarball…"
strip build/bin/llama-server build/bin/lib*.so* || true

# Tar du binaire + libs nécessaires (.so) — pas de symlinks SO résolus
# côté FreeBSD donc on garde toute la chaîne libfoo.so → libfoo.so.0 → libfoo.so.0.X.Y.
mkdir -p /tmp/llama-out
cp build/bin/llama-server /tmp/llama-out/
mkdir -p /tmp/llama-out/lib
cp -a build/bin/lib*.so* /tmp/llama-out/lib/
tar -C /tmp/llama-out -czf /tmp/llama-freebsd-amd64.tar.gz .

ls -lh /tmp/llama-freebsd-amd64.tar.gz
file /tmp/llama-out/llama-server
REMOTE_BUILD

# ── Étape 3 : rapatrier le tarball + extraire ───────────────────────
echo "[build-llama-freebsd] scp du tarball vers ${OUT_DIR}/…"
scp -q "${REMOTE}:/tmp/llama-freebsd-amd64.tar.gz" "${OUT_DIR}/"

echo "[build-llama-freebsd] extraction…"
tar -C "${OUT_DIR}" -xzf "${OUT_DIR}/llama-freebsd-amd64.tar.gz"
rm "${OUT_DIR}/llama-freebsd-amd64.tar.gz"

echo
echo "✓ Build terminé. Artefacts :"
ls -lh "${OUT_DIR}/llama-server" "${OUT_DIR}/lib/" 2>/dev/null || true
echo
echo "Vérifier avec : file ${OUT_DIR}/llama-server"
echo "Suite : palier C (tofu apply pousse ces fichiers sur OPNsense)."
