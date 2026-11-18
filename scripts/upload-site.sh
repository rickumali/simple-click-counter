#!/usr/bin/env bash
#
# Upload a static Next.js export to an S3 prefix, idempotently.
#
#   scripts/upload-site.sh <local-dir> s3://<bucket>/<prefix>
#
# - Hashed assets under _next/static get a one-year immutable cache.
# - Everything else (HTML, RSC .txt payloads, deploy.json, images) is
#   revalidated on every request, so a CDN in front (CloudFront) and browsers
#   pick up new deploys of latest/ immediately.
# - Assets are uploaded before HTML so a page never references files that
#   aren't there yet. --delete removes files that no longer exist locally.

set -euo pipefail

src="${1:?usage: upload-site.sh <local-dir> s3://bucket/prefix}"
dest="${2:?usage: upload-site.sh <local-dir> s3://bucket/prefix}"
dest="${dest%/}"

if [[ ! -f "$src/index.html" ]]; then
  echo "$src/index.html not found; did the build run?" >&2
  exit 1
fi

if [[ -d "$src/_next/static" ]]; then
  aws s3 sync "$src/_next/static" "$dest/_next/static" \
    --delete --only-show-errors \
    --cache-control "public, max-age=31536000, immutable"
fi

aws s3 sync "$src" "$dest" \
  --delete --only-show-errors \
  --exclude "_next/static/*" \
  --cache-control "public, max-age=0, must-revalidate"

echo "Uploaded $src -> $dest"
