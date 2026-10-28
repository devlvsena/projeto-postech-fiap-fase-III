#!/usr/bin/env bash
set -euo pipefail

: "${ECR_REGISTRY:?}"
: "${IMAGE_TAG:?}"
: "${SERVICE:?}"
: "${SOURCE_SHA:?}"
: "${GITHUB_OUTPUT:?}"

manifest=k8s/overlays/production/kustomization.yaml
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for attempt in {1..10}; do
  # Explicit refspec: a bare "git fetch origin main" may only update FETCH_HEAD.
  git fetch origin +refs/heads/main:refs/remotes/origin/main
  git switch --detach refs/remotes/origin/main

  if ! git merge-base --is-ancestor "$SOURCE_SHA" HEAD; then
    echo "::error::The image source commit is not part of main."
    exit 1
  fi
  if ! git diff --quiet "$SOURCE_SHA" HEAD -- \
    "toggle-master/microsservices/${SERVICE}-main" \
    ".github/workflows/${SERVICE}-ci.yml" \
    .github/workflows/update-gitops.yml .github/scripts/update-gitops.sh; then
    echo "::error::Newer changes exist for $SERVICE. Run CI on the latest main."
    exit 1
  fi

  (
    cd k8s/overlays/production
    kustomize edit set image "$SERVICE=$ECR_REGISTRY/$SERVICE:$IMAGE_TAG"
  )
  kustomize build k8s/overlays/production > /dev/null
  git add "$manifest"

  if git diff --cached --quiet; then
    echo "Manifest already references $IMAGE_TAG."
    echo "manifest-commit=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  git commit -m "chore(gitops): update $SERVICE to $IMAGE_TAG" \
    -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
  if git push origin HEAD:refs/heads/main; then
    echo "manifest-commit=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  # Rebuild the change on the latest main so parallel service updates are preserved.
  if [ "$attempt" -lt 10 ]; then
    echo "::warning::Push rejected; retrying against the latest main ($attempt/10)."
    sleep 5
  fi
done

echo "::error::Could not push the GitOps update after 10 attempts. Check branch rules and token permissions."
exit 1
