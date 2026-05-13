#!/usr/bin/env bash
#
# sync-github.sh — synchronise le `main` GitLab privé vers le mirror
# public GitHub, en retirant de TOUT l'historique git (git filter-repo) :
#
#   - CLAUDE.md                                (conventions internes)
#   - .sops.yaml                               (config sops, clé age)
#   - .env.sops                                (env chiffré)
#   - infra/envs/hcloud/terraform.tfvars.sops  (tfvars chiffré)
#   - scripts/upload-llm-assets.sh             (workflow GitLab interne)
#   - scripts/generate-tools-catalog.py        (dépend du repo training privé)
#
# Pourquoi : ces fichiers ne sont **pas** des secrets en clair (.sops*
# est chiffré age, .sops.yaml ne contient que des clés publiques), mais
# on préfère ne pas les exposer sur le mirror public — c'est de la
# configuration interne au repo privé.
#
# Pour les humains :
#   - Travailler normalement sur `main` (tout inclus).
#   - `git push` pousse sur GitLab (origin) comme d'habitude.
#   - Quand tu veux sync GitHub, lance ce script.
#
# Le script crée un clone temporaire, applique filter-repo dessus,
# force-push GitHub, puis nettoie. Le repo principal n'est jamais
# affecté (les fichiers restent trackés sur main local + GitLab).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GH_URL="${OAF_GITHUB_REMOTE:-git@github.com:patlegu/opnsense-ai-firewall.git}"
TMP_DIR="$(mktemp -d -t oaf-public-XXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Repérer git-filter-repo, sinon le télécharger en standalone.
if command -v git-filter-repo >/dev/null 2>&1; then
    FILTER="git filter-repo"
else
    echo "[sync] git-filter-repo absent → téléchargement temporaire..."
    curl -sL https://raw.githubusercontent.com/newren/git-filter-repo/main/git-filter-repo \
        -o "${TMP_DIR}/git-filter-repo"
    chmod +x "${TMP_DIR}/git-filter-repo"
    FILTER="python3 ${TMP_DIR}/git-filter-repo"
fi

echo "[sync] clone propre dans ${TMP_DIR}/repo ..."
git clone --no-local "${REPO_ROOT}" "${TMP_DIR}/repo" 2>&1 | tail -2

cd "${TMP_DIR}/repo"

# Liste des paths à retirer de tout l'historique. Garder synchronisée
# avec le bloc d'en-tête de ce script.
EXCLUDE_PATHS=(
    CLAUDE.md
    .sops.yaml
    .env.sops
    infra/envs/hcloud/terraform.tfvars.sops
    # Scripts qui dépendent d'infra/repos privés — inutilisables côté
    # public, donc on ne les expose pas.
    scripts/upload-llm-assets.sh           # GitLab Generic Packages
    scripts/generate-tools-catalog.py      # repo training privé
    # Artefacts générés par accident à la racine (tofu hors-place)
    terraform.tfstate
    terraform.tfstate.backup
)

echo "[sync] filter-repo : retire les ${#EXCLUDE_PATHS[@]} fichiers internes de tout l'historique ..."
FILTER_ARGS=()
for p in "${EXCLUDE_PATHS[@]}"; do
    FILTER_ARGS+=(--path "$p")
done
${FILTER} "${FILTER_ARGS[@]}" --invert-paths --force 2>&1 | tail -3

echo "[sync] vérification : aucun des fichiers exclus ne doit apparaître"
for p in "${EXCLUDE_PATHS[@]}"; do
    if git log --all --follow -- "$p" 2>&1 | grep -q .; then
        echo "ERREUR : $p encore présent dans l'historique" >&2
        exit 1
    fi
done

echo "[sync] force-push vers ${GH_URL} ..."
git remote add github "${GH_URL}"
git push -f github main 2>&1 | tail -3

echo
echo "✓ Mirror GitHub à jour (filter-repo a réécrit l'historique sans CLAUDE.md)."
echo "  Local main + GitLab origin restent inchangés (CLAUDE.md tracké)."
