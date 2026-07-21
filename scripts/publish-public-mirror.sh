#!/usr/bin/env bash
# Publie l'etat courant du repo prive (tracked files only) vers le mirroir
# public Paul-Colin/ironmonstats-tracker : historique orphelin (aucun lien
# avec le repo prive), branche main ecrasee a chaque publication + release
# GitHub taguee sur la version courante (TrackerUpdater.lua verifie la
# version via l'API releases/latest, mais telecharge toujours l'archive de
# la branche main).
#
# A lancer depuis un clone authentifie aupres de GitHub (le clone WSL
# ~/nds-ironmon-tracker-fr), jamais depuis la copie de travail Windows. Les
# modifs sont faites sur la copie Windows : ce script commence donc par en
# recuperer les commits (fast-forward uniquement) avant de publier.
set -euo pipefail

PUBLIC_REPO="Paul-Colin/ironmonstats-tracker"
PUBLIC_REMOTE_URL="https://github.com/${PUBLIC_REPO}.git"
WINDOWS_COPY="/mnt/c/Users/User/Desktop/Kaizo IronMon HG FR (galino)/6-Tracker-FR"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Arbre de travail non propre (git status). Commit ou stash avant de publier." >&2
    exit 1
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "main" ]]; then
    echo "Sur la branche '${current_branch}', attendu 'main'. Checkout main avant de publier." >&2
    exit 1
fi

if [[ -d "$WINDOWS_COPY/.git" ]]; then
    echo "Synchronisation depuis la copie Windows (${WINDOWS_COPY})..."
    git fetch "$WINDOWS_COPY" main:refs/remotes/windows-copy/main
    if ! git merge-base --is-ancestor HEAD refs/remotes/windows-copy/main; then
        echo "La copie WSL a des commits absents de la copie Windows (ou inversement) : impossible de fast-forward. Reconcilie main a la main (git log / git diff) avant de publier." >&2
        exit 1
    fi
    git merge --ff-only refs/remotes/windows-copy/main
else
    echo "Copie Windows introuvable a '${WINDOWS_COPY}' — publication a partir du HEAD local tel quel." >&2
fi

version=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' ironmon_tracker/constants/MiscConstants.lua | head -1 | tr -d '"')
if [[ -z "$version" ]]; then
    echo "Impossible de lire MiscConstants.TRACKER_VERSION." >&2
    exit 1
fi
tag="v${version}"

echo "Publication de la version ${version} vers ${PUBLIC_REPO}..."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

git archive HEAD | tar -x -C "$tmpdir"

(
    cd "$tmpdir"
    git init -q
    git add -A
    git commit -q -m "Release ${tag}"
    git branch -M main
    git remote add public "$PUBLIC_REMOTE_URL"
    git push --force public main
)

if command -v gh >/dev/null 2>&1; then
    if gh release view "$tag" --repo "$PUBLIC_REPO" >/dev/null 2>&1; then
        echo "La release ${tag} existe deja sur ${PUBLIC_REPO}, rien a creer."
    else
        gh release create "$tag" \
            --repo "$PUBLIC_REPO" \
            --target main \
            --title "$tag" \
            --notes "Release ${tag}."
    fi
else
    echo "gh non trouve : creer la release ${tag} manuellement sur https://github.com/${PUBLIC_REPO}/releases/new" >&2
fi

echo "Publication terminee : ${tag} -> ${PUBLIC_REPO}"
