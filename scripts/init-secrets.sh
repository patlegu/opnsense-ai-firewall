#!/bin/bash
# init-secrets.sh — génère automatiquement tous les secrets pour terraform.tfvars
# (paires WireGuard, API OPNsense, hashes mots de passe).
#
# Idempotent : remplit uniquement les valeurs vides ou placeholders, ne touche
# pas aux valeurs déjà saisies.
#
# Usage :
#   bash scripts/init-secrets.sh                 # mode interactif (demande les mots de passe)
#   bash scripts/init-secrets.sh --auto         # génère tout, mots de passe aléatoires
#   bash scripts/init-secrets.sh --dry-run      # affiche les valeurs sans modifier tfvars

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TFVARS="${PROJECT_DIR}/infra/envs/hcloud/terraform.tfvars"

AUTO=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --auto) AUTO=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Option inconnue : $1"; exit 1 ;;
    esac
done

if [ ! -f "$TFVARS" ]; then
    echo "✗ $TFVARS introuvable — copier d'abord depuis terraform.tfvars.example" >&2
    exit 1
fi

# ── Outils requis ───────────────────────────────────────────────────────────
for tool in openssl wg python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "✗ $tool requis — apt install $tool wireguard-tools" >&2
        exit 1
    fi
done

# ── Helpers ──────────────────────────────────────────────────────────────────
gen_password() {
    # ~28-32 chars alphanumériques sécurisés, basés sur openssl rand.
    # Évite le combo 'tr | head -c' qui produit un SIGPIPE sur tr et fait
    # planter le script à cause de `set -o pipefail`.
    openssl rand -base64 24 | tr -d '/+=\n'
}

gen_wg_pair() {
    local priv pub
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    echo "$priv|$pub"
}

# Remplace une ligne `key = "old"` par `key = "new"` dans tfvars (in-place).
# Cible précisément les valeurs vides ou les placeholders type ".." / "$6$..." / "ssh-ed25519 AAAA...".
sed_replace() {
    local key="$1" value="$2"
    # Échapper les caractères spéciaux pour sed
    local v
    v=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')
    # Pattern : key = "" OU key = "...placeholder..."
    sed -i -E "s|^([[:space:]]*)${key}([[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1${key}\2\"${v}\"|" "$TFVARS"
}

# Remplace UNIQUEMENT si la valeur courante est vide ou un placeholder reconnu.
# Évite d'écraser une valeur déjà remplie par l'utilisateur.
patch_if_placeholder() {
    local key="$1" value="$2"
    local current
    current=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)
    # Détection placeholder : vide OU contient "..." (les exemples de tfvars.example
    # finissent toujours par "..." — '$6$rounds=5000$...', 'ssh-ed25519 AAAA...', etc.)
    if [ -z "$current" ] || [[ "$current" == *"..."* ]]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  [DRY] $key = \"$value\""
        else
            sed_replace "$key" "$value"
            echo "  [OK]  $key (${#value} chars)"
        fi
        return 0
    fi
    echo "  [SKIP] $key (déjà rempli)"
    return 0   # skip n'est PAS une erreur (sinon set -e tue le caller)
}

# Patch les wg_privkey/wg_pubkey d'une entrée nommée dans une map (llm_vms ou debian_vms).
# Recherche la 1ère occurrence vide après la clé et la remplit.
patch_wg_pair_in_map() {
    local map_key="$1" entry_name="$2" priv="$3" pub="$4"
    # Trouver la ligne de l'entrée et patcher les wg_privkey="" / wg_pubkey="" suivants
    python3 - "$TFVARS" "$entry_name" "$priv" "$pub" <<'PYEOF'
import sys, re
path, name, priv, pub = sys.argv[1:]
src = open(path).read()
# Trouver le bloc "<name> = {"
m = re.search(rf'(?ms)\b{re.escape(name)}\b\s*=\s*\{{(.*?)(\n[ \t]*\}})', src)
if not m:
    print(f"  [SKIP] entrée {name} introuvable")
    sys.exit(0)
block = m.group(1)
new_block = re.sub(r'(wg_privkey\s*=\s*)""', f'\\1"{priv}"', block, count=1)
new_block = re.sub(r'(wg_pubkey\s*=\s*)""',  f'\\1"{pub}"',  new_block, count=1)
if new_block != block:
    src = src[:m.start(1)] + new_block + src[m.end(1):]
    open(path, 'w').write(src)
    print(f"  [OK]  {name} wg_privkey/wg_pubkey")
else:
    print(f"  [SKIP] {name} déjà rempli")
PYEOF
}

# ── Chargement .env (PAT pour download_auth_header) ─────────────────────────
if [ -f "${PROJECT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "${PROJECT_DIR}/.env"; set +a
fi
GITLAB_PAT_CLEAN="${GITLAB_PAT:-${TF_HTTP_PASSWORD:-}}"

# ── 0. SSH public keys ──────────────────────────────────────────────────────
# Var Tofu = ssh_public_keys (liste). Le script n'auto-patch PAS la liste
# (format HCL multi-lignes pénible à manipuler avec sed). On affiche juste
# la clé locale pour que l'opérateur la copie/colle dans tfvars.
echo "── SSH public keys (à copier dans var.ssh_public_keys) ──"
if [ -f ~/.ssh/id_ed25519.pub ]; then
    echo "  ⚠ Coller ceci dans tfvars (en premier dans le tableau) :"
    echo "      $(cat ~/.ssh/id_ed25519.pub)"
elif [ -f ~/.ssh/id_rsa.pub ]; then
    echo "  ⚠ Coller ceci dans tfvars (en premier dans le tableau) :"
    echo "      $(cat ~/.ssh/id_rsa.pub)"
else
    echo "  ✗ Pas de clé SSH locale (~/.ssh/id_ed25519.pub ou id_rsa.pub)" >&2
fi

# ── 1. Mots de passe (root OPNsense + user VMs) ─────────────────────────────
echo
echo "── Mots de passe (hash SHA512) ──"
if [ "$AUTO" -eq 1 ]; then
    PW_VM=$(gen_password)
    PW_OPN=$(gen_password)
    echo "  Mot de passe user VM (cloud-init) : $PW_VM"
    echo "  Mot de passe root OPNsense                : $PW_OPN"
    echo "  ⚠  À sauvegarder dans 1Password/KeePass !"
else
    read -r -s -p "  Mot de passe user VM (Enter = aléatoire) : " PW_VM; echo
    [ -z "$PW_VM" ] && { PW_VM=$(gen_password); echo "  → généré : $PW_VM"; }
    read -r -s -p "  Mot de passe root OPNsense (Enter = aléatoire) : " PW_OPN; echo
    [ -z "$PW_OPN" ] && { PW_OPN=$(gen_password); echo "  → généré : $PW_OPN"; }
fi
HASH_VM=$(openssl passwd -6 "$PW_VM")
HASH_OPN=$(openssl passwd -6 "$PW_OPN")
patch_if_placeholder vm_password_hash "$HASH_VM"
patch_if_placeholder opnsense_root_hash "$HASH_OPN"

# ── 2. API OPNsense (key clair + secret clair + secret hashé) ───────────────
echo
echo "── API OPNsense ──"
API_KEY=$(openssl rand -hex 40)
API_SECRET=$(openssl rand -hex 40)
API_SECRET_HASH=$(openssl passwd -6 "$API_SECRET")
patch_if_placeholder opnsense_api_key "$API_KEY"
patch_if_placeholder opnsense_api_secret "$API_SECRET_HASH"
patch_if_placeholder opnsense_api_secret_plain "$API_SECRET"

# ── 3. WireGuard server (OPNsense hub) ──────────────────────────────────────
echo
echo "── WireGuard hub OPNsense ──"
IFS='|' read -r WG_SRV_PRIV WG_SRV_PUB <<< "$(gen_wg_pair)"
patch_if_placeholder wg_server_privkey "$WG_SRV_PRIV"
patch_if_placeholder wg_server_pubkey "$WG_SRV_PUB"

# ── 4. WireGuard pour chaque VM (llm_vms + debian_vms) ──────────────────────
echo
echo "── WireGuard peers (VMs LLM + Debian) ──"
# Détecter les noms d'entrées dans llm_vms et debian_vms via grep
for entry in $(grep -oE '^[[:space:]]+[a-z][a-z0-9-]*[[:space:]]+=[[:space:]]+\{' "$TFVARS" | awk '{print $1}' | sort -u); do
    IFS='|' read -r WG_PRIV WG_PUB <<< "$(gen_wg_pair)"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [DRY] $entry wg_privkey=… wg_pubkey=$WG_PUB"
    else
        patch_wg_pair_in_map all "$entry" "$WG_PRIV" "$WG_PUB"
    fi
done

# ── 5. Auth header GitLab pour le download des binaires ─────────────────────
echo
echo "── Auth header GitLab Generic Packages ──"
if [ -n "$GITLAB_PAT_CLEAN" ]; then
    patch_if_placeholder llm_download_auth_header "PRIVATE-TOKEN: $GITLAB_PAT_CLEAN"
else
    echo "  ✗ GITLAB_PAT non défini dans .env — skip"
fi

# ── 6. hcloud_token : NE PAS injecter dans tfvars ─────────────────────────
# Le provider hcloud lit HCLOUD_TOKEN directement de l'environnement
# (chargé depuis .env via `set -a && . .env && set +a` avant tofu).
# Pas la peine de dupliquer le secret dans terraform.tfvars.
if [ -n "${HCLOUD_TOKEN:-}" ]; then
    echo
    echo "── Hetzner Cloud token : présent dans .env, provider hcloud le lira directement"
fi

# ── Bilan ───────────────────────────────────────────────────────────────────
echo
echo "── ✓ Init secrets terminé ────────────────────────────────────"
echo
echo "Vérifier le tfvars :"
echo "  grep -E '^[a-z_]+\s*=' ${TFVARS} | head -20"
echo
echo "Chiffrer + commit :"
echo "  sops --encrypt ${TFVARS} > ${TFVARS}.sops"
echo "  git add ${TFVARS}.sops"
echo
echo "Lancer le déploiement :"
echo "  set -a && . ${PROJECT_DIR}/.env && set +a"
echo "  cd ${PROJECT_DIR}/infra/envs/hcloud"
echo "  tofu init && tofu plan && tofu apply"
