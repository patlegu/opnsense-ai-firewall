#!/usr/bin/env bash
#
# sync-github.sh — synchronise le `main` GitLab privé vers le mirror
# public GitHub, en retirant CLAUDE.md de TOUT l'historique git (git
# filter-repo).
#
# Pourquoi : CLAUDE.md contient des instructions internes (conventions
# de commit, override "no AI mentions", etc.) qu'on garde sur le repo
# privé GitLab mais qu'on n'expose pas publiquement.
#
# Pour les humains :
#   - Travailler normalement sur `main` (CLAUDE.md inclus).
#   - `git push` pousse sur GitLab (origin) comme d'habitude.
#   - Quand tu veux sync GitHub, lance ce script.
#
# Le script crée un clone temporaire, applique filter-repo dessus,
# force-push GitHub, puis nettoie. Le repo principal n'est jamais
# affecté (CLAUDE.md reste tracké sur main local + GitLab).

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

echo "[sync] filter-repo : retire CLAUDE.md de tout l'historique ..."
${FILTER} --path CLAUDE.md --invert-paths --force 2>&1 | tail -3

echo "[sync] vérification : CLAUDE.md ne doit apparaître nulle part"
if git log --all --follow -- CLAUDE.md 2>&1 | grep -q .; then
    echo "ERREUR : CLAUDE.md encore présent dans l'historique" >&2
    exit 1
fi

echo "[sync] force-push vers ${GH_URL} ..."
git remote add github "${GH_URL}"
git push -f github main 2>&1 | tail -3

echo
echo "✓ Mirror GitHub à jour (filter-repo a réécrit l'historique sans CLAUDE.md)."
echo "  Local main + GitLab origin restent inchangés (CLAUDE.md tracké)."
