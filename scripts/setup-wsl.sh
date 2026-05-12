#!/bin/bash
# setup-wsl.sh — vérifie et prépare un environnement WSL2 (ou Linux) pour
# lancer Terraform/OpenTofu sur le projet kickstart-forge.
#
# Idempotent : ré-exécutable sans danger. Affiche [OK] / [INSTALL] / [SKIP]
# pour chaque étape.
#
# Usage :
#   bash scripts/setup-wsl.sh                    # vérif + install tout ce qui manque
#   bash scripts/setup-wsl.sh --check-only        # vérif sans rien installer
#   bash scripts/setup-wsl.sh --skip-binaries     # ne propose pas le rsync 2.5 GB
#   bash scripts/setup-wsl.sh --<LIBVIRT_HOST> <host>     # source rsync (défaut <LIBVIRT_HOST>:2222)

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_PATH="${PROJECT_DIR}"
KORRIG_HOST="${KORRIG_HOST:-<LIBVIRT_HOST>}"
KORRIG_PORT="${KORRIG_PORT:-2222}"
KORRIG_USER="${KORRIG_USER:-root}"
KORRIG_REMOTE_DIR="/srv/_AI/kickstart-forge"

CHECK_ONLY=0
SKIP_BINARIES=0

# ── Couleurs ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
else
    G=''; R=''; Y=''; B=''; N=''
fi

ok()    { echo -e "  ${G}[OK]${N}    $*"; }
inst()  { echo -e "  ${B}[INSTALL]${N} $*"; }
warn()  { echo -e "  ${Y}[WARN]${N}  $*"; }
err()   { echo -e "  ${R}[FAIL]${N}  $*" >&2; }
skip()  { echo -e "  ${Y}[SKIP]${N}  $*"; }
hdr()   { echo; echo -e "${B}── $* ──${N}"; }

# ── Args ────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --check-only)    CHECK_ONLY=1; shift ;;
        --skip-binaries) SKIP_BINARIES=1; shift ;;
        --<LIBVIRT_HOST>)        KORRIG_HOST="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0 ;;
        *) err "Option inconnue : $1"; exit 1 ;;
    esac
done

if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "Mode --check-only : rien ne sera installé"
fi

cd "$PROJECT_DIR"

# ── 0. Détection système ────────────────────────────────────────────────────
hdr "Détection système"
if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "WSL2 détecté ($(uname -r))"
else
    ok "Linux natif ($(uname -sr))"
fi

if [ -f /etc/debian_version ]; then
    ok "Debian/Ubuntu — installations apt OK"
else
    warn "Distro non Debian — install commands à adapter manuellement"
fi

# ── 1. Outils système de base ───────────────────────────────────────────────
hdr "Outils de base"
needs_apt=()
for tool in git ssh curl rsync python3 python3-venv jq; do
    if command -v "$tool" >/dev/null 2>&1 || dpkg -l "$tool" >/dev/null 2>&1; then
        ok "$tool présent"
    else
        warn "$tool absent"
        needs_apt+=("$tool")
    fi
done

if [ "${#needs_apt[@]}" -gt 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
    inst "apt install ${needs_apt[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${needs_apt[@]}"
fi

# ── 2. OpenTofu ─────────────────────────────────────────────────────────────
hdr "OpenTofu"
if command -v tofu >/dev/null 2>&1; then
    ok "tofu $(tofu version | head -1 | awk '{print $2}')"
else
    if [ "$CHECK_ONLY" -eq 1 ]; then
        warn "tofu absent (--check-only)"
    else
        inst "tofu via script officiel"
        curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh \
          -o /tmp/install-opentofu.sh
        chmod +x /tmp/install-opentofu.sh
        /tmp/install-opentofu.sh --install-method deb >/dev/null 2>&1 \
          || sudo /tmp/install-opentofu.sh --install-method deb
        rm /tmp/install-opentofu.sh
        command -v tofu >/dev/null && ok "tofu $(tofu version | head -1 | awk '{print $2}')" || err "install tofu KO"
    fi
fi

# ── 3. Hetzner CLI ──────────────────────────────────────────────────────────
hdr "Hetzner Cloud CLI"
if command -v hcloud >/dev/null 2>&1; then
    ok "hcloud $(hcloud version 2>&1 | head -1 | awk '{print $2}')"
else
    if [ "$CHECK_ONLY" -eq 1 ]; then
        warn "hcloud absent (--check-only)"
    else
        inst "hcloud via release GitHub"
        ARCH="$(dpkg --print-architecture)"
        case "$ARCH" in
            amd64) HC_ARCH="amd64" ;;
            arm64) HC_ARCH="arm64" ;;
            *) err "arch $ARCH non supportée"; exit 1 ;;
        esac
        URL="https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-${HC_ARCH}.tar.gz"
        curl -fsSL "$URL" | sudo tar xz -C /usr/local/bin hcloud
        sudo chmod +x /usr/local/bin/hcloud
        command -v hcloud >/dev/null && ok "hcloud $(hcloud version | head -1 | awk '{print $2}')" || err "install hcloud KO"
    fi
fi

# ── 4. sops + age ───────────────────────────────────────────────────────────
hdr "sops + age (chiffrement secrets)"
if command -v age >/dev/null 2>&1; then
    ok "age présent"
else
    if [ "$CHECK_ONLY" -eq 0 ]; then
        inst "apt install age"
        sudo apt-get install -y age
    else
        warn "age absent"
    fi
fi

if command -v sops >/dev/null 2>&1; then
    ok "sops $(sops --version 2>&1 | head -1 | awk '{print $2}')"
else
    if [ "$CHECK_ONLY" -eq 0 ]; then
        inst "sops via release GitHub"
        ARCH="$(dpkg --print-architecture)"
        SOPS_VER=3.9.1
        URL="https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.${ARCH}"
        curl -fsSLo /tmp/sops "$URL"
        sudo install -m 755 /tmp/sops /usr/local/bin/sops
        rm /tmp/sops
        ok "sops $(sops --version | head -1 | awk '{print $2}')"
    else
        warn "sops absent"
    fi
fi

# ── 5. WireGuard tools (pour générer les paires de clés) ────────────────────
hdr "WireGuard tools"
if command -v wg >/dev/null 2>&1; then
    ok "wg présent"
else
    if [ "$CHECK_ONLY" -eq 0 ]; then
        inst "apt install wireguard-tools"
        sudo apt-get install -y wireguard-tools
    else
        warn "wg absent (nécessaire pour générer les clés WG des VMs)"
    fi
fi

# ── 6. Python venv + httpx (pour module wireguard-mesh) ─────────────────────
hdr "Python venv (.venv)"
VENV_DIR="${PROJECT_DIR}/.venv"
if [ -x "${VENV_DIR}/bin/python3" ]; then
    ok "venv existant : ${VENV_DIR}"
else
    if [ "$CHECK_ONLY" -eq 0 ]; then
        inst "création venv ${VENV_DIR}"
        python3 -m venv "${VENV_DIR}"
        ok "venv créé"
    else
        warn "venv absent"
    fi
fi

if [ -x "${VENV_DIR}/bin/python3" ]; then
    if "${VENV_DIR}/bin/python3" -c "import httpx" 2>/dev/null; then
        ok "httpx installé dans le venv"
    else
        if [ "$CHECK_ONLY" -eq 0 ]; then
            inst "pip install httpx"
            "${VENV_DIR}/bin/pip" install --quiet httpx
            ok "httpx installé"
        else
            warn "httpx absent (le module wireguard-mesh en a besoin)"
        fi
    fi
fi

# ── 7. SSH GitLab ───────────────────────────────────────────────────────────
hdr "Accès SSH GitLab"
if ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@gitlab.com 2>&1 | grep -q "Welcome to GitLab"; then
    ok "SSH GitLab OK"
elif [ -f ~/.ssh/id_ed25519.pub ] || [ -f ~/.ssh/id_rsa.pub ]; then
    warn "Clé SSH locale présente mais pas autorisée sur GitLab"
    echo "       → ajouter ta pubkey à https://gitlab.com/-/user_settings/ssh_keys"
    echo "       → puis retester : ssh -T git@gitlab.com"
else
    warn "Aucune clé SSH locale"
    if [ "$CHECK_ONLY" -eq 0 ]; then
        echo "       → générer : ssh-keygen -t ed25519 -C \"\$USER@\$HOSTNAME\""
        echo "       → ajouter la pubkey à GitLab"
    fi
fi

# ── 8. Fichier .env ─────────────────────────────────────────────────────────
hdr "Fichier .env (credentials)"
ENV_FILE="${PROJECT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    ok ".env présent"
    for var in TF_HTTP_USERNAME TF_HTTP_PASSWORD HCLOUD_TOKEN; do
        if grep -q "^${var}=" "$ENV_FILE"; then
            ok "  $var défini"
        else
            warn "  $var manquant"
        fi
    done
else
    warn ".env absent"
    if [ "$CHECK_ONLY" -eq 0 ] && [ -f "${PROJECT_DIR}/.env.sops" ]; then
        echo "       Une version chiffrée .env.sops existe dans le repo."
        echo "       Décrypter avec : sops --decrypt .env.sops > .env"
    fi
fi

# ── 9. Binaires LLM + GGUF (optionnels — déjà sur GitLab Generic Packages) ──
hdr "Binaires LLM + modèles GGUF"
echo "  Stratégie par défaut : les VMs Hetzner téléchargent depuis GitLab"
echo "  Generic Packages (uploadés via scripts/upload-llm-assets.sh)."
echo "  → Pas besoin de 2.5 GB de fichiers sur ce poste."
echo
echo "  Vérifier que l'upload GitLab est OK :"
echo "    https://gitlab.com/llm_tests/kickstart-forge/-/packages"
echo
echo "  Si tu veux uploader/re-uploader les fichiers, depuis <LIBVIRT_HOST> (où ils existent) :"
echo "    GITLAB_PAT=glpat-... bash scripts/upload-llm-assets.sh"
echo
echo "  Optionnel : rsync local pour mode SCP (alternative aux URLs) :"
LLAMA_DIR="${PROJECT_DIR}/llama-bin"
GGUF_DIR="${PROJECT_DIR}/gguf"
if [ -d "$LLAMA_DIR" ] && [ -d "$GGUF_DIR" ]; then
    SIZE=$(du -sh "$LLAMA_DIR" "$GGUF_DIR" 2>/dev/null | tail -1 | awk '{print $1}')
    ok "llama-bin/ + gguf/ présents (prêt pour mode SCP local si voulu)"
else
    skip "llama-bin/gguf absents — utiliser les URLs GitLab dans tfvars"
fi

# ── 10. terraform.tfvars ────────────────────────────────────────────────────
hdr "infra/envs/hcloud/terraform.tfvars"
TFVARS="${PROJECT_DIR}/infra/envs/hcloud/terraform.tfvars"
if [ -f "$TFVARS" ]; then
    ok "tfvars présent ($(wc -l < "$TFVARS") lignes)"
else
    warn "tfvars absent"
    echo "       → cp infra/envs/hcloud/terraform.tfvars.example infra/envs/hcloud/terraform.tfvars"
    echo "       → puis éditer pour remplir les credentials"
fi

# ── Bilan final ─────────────────────────────────────────────────────────────
hdr "Prochaines étapes"
cat <<EOF

Si tout est ${G}OK${N} ci-dessus :

  cd ${PROJECT_DIR}
  set -a && . .env && set +a    # charge TF_HTTP_USERNAME/PASSWORD pour le backend
  cd infra/envs/hcloud

  tofu init
  tofu plan
  tofu apply

Outputs après apply :
  tofu output summary

Documentation :
  ${PROJECT_DIR}/README.md
EOF
