#!/usr/bin/env bash
#
# Delete old per-commit deploys from the S3 bucket.
#
# Layout in the bucket (written by .github/workflows/deploy.yml):
#   deploys/<sha>/...   one immutable copy of the site per commit
#   latest/...          copy of the most recent deploy (never touched here)
#
# A deploy's age is the newest LastModified of any object under its prefix.
# The KEEP newest deploys are always kept, as is the deploy that latest/
# currently points to. Of the rest, only those older than OLDER_THAN_DAYS are
# deleted.
#
# Usage:
#   S3_BUCKET=my-bucket KEEP=5 OLDER_THAN_DAYS=0 DRY_RUN=true scripts/cleanup-deploys.sh
#
# Requires: aws CLI v2 (with credentials), jq, GNU date.

set -euo pipefail

: "${S3_BUCKET:?S3_BUCKET must be set}"
KEEP="${KEEP:-5}"
OLDER_THAN_DAYS="${OLDER_THAN_DAYS:-0}"
DRY_RUN="${DRY_RUN:-true}"
PREFIX="deploys/"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( KEEP < 1 )); then
  echo "KEEP must be an integer >= 1 (got '$KEEP')" >&2
  exit 1
fi
if ! [[ "$OLDER_THAN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "OLDER_THAN_DAYS must be a non-negative integer (got '$OLDER_THAN_DAYS')" >&2
  exit 1
fi

cutoff_epoch=$(( $(date -u +%s) - OLDER_THAN_DAYS * 86400 ))

# Which deploy does latest/ point at? (Missing file is fine.)
latest_sha=$(aws s3 cp "s3://${S3_BUCKET}/latest/deploy.json" - 2>/dev/null | jq -r '.sha // empty' || true)
echo "Bucket:           ${S3_BUCKET}"
echo "Keep newest:      ${KEEP}"
echo "Older than days:  ${OLDER_THAN_DAYS}"
echo "Dry run:          ${DRY_RUN}"
echo "latest/ -> sha:   ${latest_sha:-<none>}"
echo

prefixes=$(aws s3api list-objects-v2 \
  --bucket "$S3_BUCKET" --prefix "$PREFIX" --delimiter / \
  --query 'CommonPrefixes[].Prefix' --output json | jq -r '.[]? // empty')

if [[ -z "$prefixes" ]]; then
  echo "No deploys found under s3://${S3_BUCKET}/${PREFIX}"
  exit 0
fi

# Build "<last-modified-iso> <prefix>" lines, newest first.
listing=""
while IFS= read -r p; do
  # Only ever consider direct children of deploys/ with a sane name.
  if ! [[ "$p" =~ ^deploys/[A-Za-z0-9._-]+/$ ]]; then
    echo "Skipping unexpected prefix: $p" >&2
    continue
  fi
  last_modified=$(aws s3api list-objects-v2 \
    --bucket "$S3_BUCKET" --prefix "$p" \
    --query 'max_by(Contents, &LastModified).LastModified' --output text)
  listing+="${last_modified} ${p}"$'\n'
done <<< "$prefixes"

sorted=$(printf '%s' "$listing" | sort -r)

total=0
deleted=0
while IFS=' ' read -r last_modified p; do
  [[ -z "${p:-}" ]] && continue
  total=$((total + 1))
  sha="${p#deploys/}"; sha="${sha%/}"
  lm_epoch=$(date -u -d "$last_modified" +%s)

  if (( total <= KEEP )); then
    echo "KEEP    $p  ($last_modified)  within newest ${KEEP}"
  elif [[ -n "$latest_sha" && "$sha" == "$latest_sha" ]]; then
    echo "KEEP    $p  ($last_modified)  served by latest/"
  elif (( lm_epoch > cutoff_epoch )); then
    echo "KEEP    $p  ($last_modified)  newer than ${OLDER_THAN_DAYS} days"
  else
    deleted=$((deleted + 1))
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DELETE  $p  ($last_modified)  [dry run]"
    else
      echo "DELETE  $p  ($last_modified)"
      aws s3 rm "s3://${S3_BUCKET}/${p}" --recursive --only-show-errors
    fi
  fi
done <<< "$sorted"

echo
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run: ${deleted} of ${total} deploys would be deleted."
else
  echo "Deleted ${deleted} of ${total} deploys."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### S3 deploy cleanup"
    echo
    echo "- Bucket: \`${S3_BUCKET}\`"
    echo "- Deploys found: ${total}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "- Would delete: ${deleted} (dry run, nothing removed)"
    else
      echo "- Deleted: ${deleted}"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
