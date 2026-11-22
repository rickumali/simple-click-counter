# Simple Click Counter

A small [Next.js](https://nextjs.org) app (a counter with an incrementing
timer and a reset button). It builds to plain static files and is deployed to
a public AWS S3 website by GitHub Actions.

- [Local development](#local-development)
- [How deployment works](#how-deployment-works)
- [One-time setup: AWS](#one-time-setup-aws)
- [One-time setup: GitHub](#one-time-setup-github)
- [Deploying](#deploying)
- [Cleaning up old deploys](#cleaning-up-old-deploys)
- [Optional one-time setup: CloudFront](#optional-one-time-setup-cloudfront)
- [Troubleshooting](#troubleshooting)

## Local development

```bash
bun install
bun dev          # http://localhost:3000
```

To check the static build the way S3 will serve it:

```bash
bun run build    # writes ./out
bun run start    # serves ./out on http://localhost:3000
```

`next start` isn't used: the app is built with `output: "export"` (see
`next.config.ts`), which produces static files and no Node.js server.

## How deployment works

Every push to `main` runs `.github/workflows/deploy.yml`, which:

1. Installs dependencies, lints, and builds the site **twice**: once with
   `BASE_PATH=/deploys/<commit-sha>` and once with `BASE_PATH=/latest`
   (Next.js writes the base path into every asset URL, so each location needs
   its own build).
2. Signs in to AWS with GitHub's OIDC token. There are no AWS keys stored in
   GitHub.
3. Uploads the builds into one bucket:

   ```text
   s3://<bucket>/
   ├── deploys/
   │   ├── 4a2ca9e.../      one immutable copy per commit
   │   └── 8343543.../
   └── latest/              always the most recent deploy
   ```

Each folder includes a `deploy.json` saying which commit, branch and workflow
run produced it, and when it was built (`built_at`).

Every HTML page also carries the build time (UTC) and commit in a comment
right after the doctype, so "View page source" shows which build you're
getting:

```html
<!DOCTYPE html><!--20261122T194418Z_4a2ca9e-->
```

That comment is the Next.js build ID, set in `next.config.ts`. Next.js keeps
only its first 24 characters and turns `-` into `_`, hence the compact
format.

The workflow is **idempotent**: re-running it for the same commit syncs into
the same `deploys/<sha>/` folder with `--delete`, so you get the same result
rather than a duplicate. Deploy and cleanup share a concurrency group, so they
never run at the same time.

Caching is already set up for a CDN: hashed files under `_next/static/` get a
one-year immutable `Cache-Control`; HTML and everything else get
`max-age=0, must-revalidate`.

`.github/workflows/cleanup.yml` deletes old `deploys/<sha>/` folders (see
[below](#cleaning-up-old-deploys)). It never touches `latest/`.

| File | Purpose |
|---|---|
| `next.config.ts` | Static export, trailing slashes, `BASE_PATH` support |
| `.github/workflows/deploy.yml` | Build and upload on push to `main` |
| `.github/workflows/cleanup.yml` | Remove old deploys (manual or weekly) |
| `scripts/upload-site.sh` | `aws s3 sync` with the right cache headers |
| `scripts/cleanup-deploys.sh` | Chooses and deletes old deploys (has a dry-run mode) |
| `infra/aws/*.json` | IAM and S3 policy documents used in the setup below |

## One-time setup: AWS

You need an AWS account and the [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
signed in as a user or role that can administer IAM and S3 (check with
`aws sts get-caller-identity`). Each step below also says where to find it in
the AWS Console.

Run all commands from the repository root. Start by setting these shell
variables. Bucket names are global across AWS, so choose one nobody else has.
Use lowercase letters, digits and hyphens only; avoid dots.

```bash
export AWS_REGION=us-east-1
export BUCKET_NAME=simple-click-counter-<something-unique>
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ROLE_NAME=gha-simple-click-counter-deploy
```

### 1. Check account-level Block Public Access

S3 has a **Block Public Access** setting for the whole account. If it blocks
public bucket policies, no bucket in the account can be public, whatever its
own settings say.

```bash
aws s3control get-public-access-block --account-id "$ACCOUNT_ID"
```

If `BlockPublicPolicy` or `RestrictPublicBuckets` is `true` (or you're shown
the full set of four `true` values), turn those two off. **This applies to
every bucket in the account**, so check that nothing else relies on it:

```bash
aws s3control put-public-access-block --account-id "$ACCOUNT_ID" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
```

Console: **S3 → Block Public Access settings for this account**.

An error saying no configuration exists means nothing is blocked at the
account level, and you can move on.

### 2. Create the bucket

```bash
if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
else
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi
```

New buckets have ACLs disabled ("Bucket owner enforced"). Keep it that way:
public read access comes from the bucket policy in step 4, not from ACLs.

### 3. Allow a public bucket policy on this bucket

Keep ACLs blocked, and allow a public *policy*:

```bash
aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
```

Console: **bucket → Permissions → Block public access (bucket settings) →
Edit**. Untick the two "…bucket policies" boxes.

### 4. Add the public-read bucket policy

`infra/aws/public-read-bucket-policy.json` lets anyone read (and only read)
objects in the bucket:

```bash
sed "s/BUCKET_NAME/$BUCKET_NAME/g" infra/aws/public-read-bucket-policy.json > /tmp/bucket-policy.json
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy file:///tmp/bucket-policy.json
```

Console: **bucket → Permissions → Bucket policy**.

### 5. Turn on static website hosting

`infra/aws/website-config.json` serves `index.html` for folder URLs such as
`/latest/` and uses `latest/404.html` as the error page:

```bash
aws s3api put-bucket-website --bucket "$BUCKET_NAME" \
  --website-configuration file://infra/aws/website-config.json
```

Optional: make the bare site root `/` redirect to `/latest/`. This is a
one-time manual object; the workflows never touch the bucket root.

```bash
aws s3api put-object --bucket "$BUCKET_NAME" --key index.html \
  --website-redirect-location /latest/ --content-length 0
```

Console: **bucket → Properties → Static website hosting → Edit**.

Write down the **bucket website endpoint** shown at the bottom of that
Properties section. Depending on the region it looks like
`http://BUCKET.s3-website-REGION.amazonaws.com` or
`http://BUCKET.s3-website.REGION.amazonaws.com`. You'll need it for the
`PUBLIC_BASE_URL` variable.

### 6. Let GitHub Actions sign in to AWS (OIDC identity provider)

This only needs doing once per AWS account. First check whether it already
exists:

```bash
aws iam list-open-id-connect-providers
```

If no ARN ending in `token.actions.githubusercontent.com` is listed, create
it:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

Console: **IAM → Identity providers → Add provider → OpenID Connect**, with
provider URL `https://token.actions.githubusercontent.com` and audience
`sts.amazonaws.com`.

### 7. Create the deploy role

`infra/aws/trust-policy.json` lets **only** workflow jobs in this repository
that run in the GitHub environment named `production` assume the role. It
does this by matching the `sub` (subject) claim of GitHub's OIDC token, which
looks like `SUB_PREFIX:environment:production`.

**Get `SUB_PREFIX` from GitHub; don't type it by hand.** Its format depends on
the repository:

- Repositories with **immutable subject claims** (the default for repositories
  created after mid-2026, and an opt-in for older ones) include the owner and
  repository IDs: `repo:rickumali@40336/simple-click-counter@1463260482`.
- Other repositories use names only: `repo:rickumali/simple-click-counter`.

If the prefix doesn't match exactly, sign-in fails with `Not authorized to
perform sts:AssumeRoleWithWebIdentity`. Ask GitHub which prefix this
repository uses (needs the [GitHub CLI](https://cli.github.com), signed in with
admin access to the repo):

```bash
export GITHUB_REPO=rickumali/simple-click-counter   # <owner>/<repo>
export SUB_PREFIX=$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix)
echo "$SUB_PREFIX"
```

If that prints nothing or `null`, build the immutable form from the IDs
yourself and check which format the repo uses under **Settings → Actions →
General → OpenID Connect**:

```bash
gh api "repos/$GITHUB_REPO" --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
```

If you fork, rename or transfer the repository, fetch the value again and
update the role's trust policy (`aws iam update-assume-role-policy`).

```bash
sed -e "s/ACCOUNT_ID/$ACCOUNT_ID/g" -e "s|SUB_PREFIX|$SUB_PREFIX|g" \
  infra/aws/trust-policy.json > /tmp/trust-policy.json
grep '"token.actions.githubusercontent.com:sub"' /tmp/trust-policy.json   # check it
```

```bash
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "GitHub Actions deploy for simple-click-counter"
```

`infra/aws/deploy-permissions-policy.json` lets the role list the bucket and
read, write and delete objects under `deploys/` and `latest/`, and nothing
else:

```bash
sed "s/BUCKET_NAME/$BUCKET_NAME/g" infra/aws/deploy-permissions-policy.json > /tmp/deploy-policy.json
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name s3-deploy --policy-document file:///tmp/deploy-policy.json
```

Print the role ARN; GitHub needs it in the next section:

```bash
aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text
```

Console: **IAM → Roles → Create role → Web identity**. Choose the
`token.actions.githubusercontent.com` provider, then replace the generated
trust policy and add an inline policy using the files above.

## One-time setup: GitHub

All of this is under the repository's **Settings** tab.

### 1. Allow the actions the workflows use

**Settings → Actions → General → Actions permissions.** "Allow all actions"
works. If you restrict actions, allow these:

- `actions/checkout@*`
- `oven-sh/setup-bun@*`
- `aws-actions/configure-aws-credentials@*`

You don't need to change "Workflow permissions" here: each workflow asks for
`id-token: write` and `contents: read` itself.

### 2. Create the `production` environment

**Settings → Environments → New environment** named exactly `production`. The
IAM trust policy only accepts jobs that run in this environment.

- **Deployment branches and tags:** choose "Selected branches and tags" and
  add `main`. Otherwise someone could start a manual run from another branch
  and deploy it.
- **Required reviewers** (optional): makes every deploy, including the weekly
  scheduled cleanup, wait for approval.

### 3. Add environment variables

In the `production` environment, under **Environment variables**, add the
following. These are *variables*, not secrets; nothing in them is sensitive.

| Variable | Required | Example |
|---|---|---|
| `AWS_REGION` | yes | `us-east-1` |
| `AWS_ROLE_ARN` | yes | `arn:aws:iam::123456789012:role/gha-simple-click-counter-deploy` |
| `S3_BUCKET` | yes | `simple-click-counter-abc123` |
| `PUBLIC_BASE_URL` | recommended | the website endpoint from AWS step 5, e.g. `http://simple-click-counter-abc123.s3-website-us-east-1.amazonaws.com` |
| `CLOUDFRONT_DISTRIBUTION_ID` | no | leave unset until [CloudFront](#optional-one-time-setup-cloudfront) exists |

`PUBLIC_BASE_URL` is only used to print links in the job summary. If you leave
it unset, the workflow guesses the dash-style website URL, which is wrong in
some newer regions.

## Deploying

- **Automatically:** merge or push to `main`.
- **Manually:** **Actions → Deploy to S3 → Run workflow** (on `main`).

The run summary lists two links:

- `…/deploys/<sha>/`: this exact commit, which stays available until cleanup
  removes it
- `…/latest/`: the newest deploy

To check by hand:

```bash
aws s3 ls "s3://$BUCKET_NAME/deploys/"
curl -s "$PUBLIC_BASE_URL/latest/deploy.json"
```

## Cleaning up old deploys

**Actions → Clean up old S3 deploys → Run workflow** has these inputs:

| Input | Default | Meaning |
|---|---|---|
| `keep` | `5` | Always keep this many of the newest deploys |
| `older_than_days` | `0` | Beyond `keep`, only delete deploys older than this (0 = no age limit) |
| `dry_run` | `true` | Only list what would be deleted |

A manual run is a **dry run unless you untick `dry_run`**. Run it once as a dry
run and read the log before deleting anything.

The workflow also runs every Monday at 07:17 UTC and *does* delete, using
`keep=10` and `older_than_days=30`. To turn the schedule off, remove the
`schedule:` block in `.github/workflows/cleanup.yml`, or disable the workflow
in the Actions tab.

A deploy's age is the newest modification time of any file in its folder.
Cleanup never deletes `latest/`, and never deletes the `deploys/<sha>/` that
`latest/deploy.json` points to.

You can run the same script locally with your own AWS credentials:

```bash
S3_BUCKET="$BUCKET_NAME" KEEP=5 DRY_RUN=true ./scripts/cleanup-deploys.sh
```

## Optional one-time setup: CloudFront

**Optional.** Skip this section if the plain S3 website URL (HTTP only) is
enough, for example
`http://simple-click-counter-rumali.s3-website-us-east-1.amazonaws.com/latest/`.
Add CloudFront when you want HTTPS, a CDN cache in front of the bucket, or a
custom domain. Like the AWS and GitHub setup above, you do this **once**;
after that every deploy just works.

It assumes you've finished [One-time setup: AWS](#one-time-setup-aws) and
[One-time setup: GitHub](#one-time-setup-github) and that `/latest/` loads
from the S3 website endpoint.

The rest of the repository is already ready for a CDN:

- **Paths:** `/deploys/<sha>/` and `/latest/` work unchanged behind CloudFront.
- **Caching:** `Cache-Control` headers are already set by
  `scripts/upload-site.sh`, and CloudFront honours them.
- **Invalidation:** if `CLOUDFRONT_DISTRIBUTION_ID` is set, the deploy
  workflow invalidates `/latest/*` after uploading. Per-commit folders never
  change, so they never need invalidating.
- **Links:** `PUBLIC_BASE_URL` controls the URLs printed in the job summary.

The steps below use the **S3 website endpoint as a custom origin**. It's the
simplest choice: the bucket stays public as it is now, `/latest/` keeps
mapping to `/latest/index.html`, the existing `latest/404.html` error page
keeps working, and CloudFront adds HTTPS for viewers. (For a private bucket
instead, see [the alternative](#alternative-private-bucket-with-oac) at the
end of this section.)

### 1. Create the distribution

Console: **CloudFront → Distributions → Create distribution**. The console
layout changes from time to time; these are the settings that matter.

1. **Origin domain:** don't pick the bucket from the drop-down list (that's
   the S3 REST endpoint). Paste the **bucket website endpoint** from AWS
   step 5, without `http://` and without a path, e.g.
   `simple-click-counter-rumali.s3-website-us-east-1.amazonaws.com`.
   If the console offers **Use website endpoint**, choose it.
2. **Origin path:** leave empty, so both `/latest/` and `/deploys/<sha>/` are
   reachable.
3. **Protocol (origin):** **HTTP only**. S3 website endpoints don't support
   HTTPS; CloudFront still serves viewers over HTTPS.
4. **Viewer protocol policy:** **Redirect HTTP to HTTPS**.
5. **Allowed HTTP methods:** **GET, HEAD**.
6. **Cache policy:** **CachingOptimized** (managed policy). It respects the
   `Cache-Control` headers the deploy sets: hashed `_next/static/` files are
   cached for a year, HTML is revalidated. It also turns on compression.
   Leave **Origin request policy** and **Response headers policy** empty.
7. **Web Application Firewall (WAF):** not needed for this site; choose not
   to enable security protections (WAF is billed separately).
8. **Price class:** your choice. "Use only North America and Europe" is the
   cheapest.
9. **Alternate domain name (CNAME)** and **Custom SSL certificate:** leave
   empty unless you're adding a custom domain (see step 5).
10. **Default root object:** leave empty. The S3 website endpoint already
    handles `/` (including the optional root redirect from AWS step 5).

Choose **Create distribution**. On the distribution's page, note:

- the **Distribution ID**, e.g. `E1ABCDEFGHIJKL`
- the **Distribution domain name**, e.g. `d1234abcd.cloudfront.net`

Wait until **Last modified** changes from "Deploying" to a date (usually a few
minutes), then check it. The first request may say `Miss`, a repeat `Hit`:

```bash
export DISTRIBUTION_ID=E1ABCDEFGHIJKL           # yours
export CF_DOMAIN=d1234abcd.cloudfront.net       # yours
curl -sI "https://$CF_DOMAIN/latest/" | grep -iE '^(HTTP|x-cache|cache-control)'
curl -s "https://$CF_DOMAIN/latest/deploy.json"
curl -s "https://$CF_DOMAIN/latest/" | head -c 48; echo   # build time + commit
```

No custom error pages are needed: the S3 website endpoint already returns
`latest/404.html` with a 404 status, and CloudFront passes it through.

### 2. Let the deploy role create invalidations

`infra/aws/cloudfront-invalidation-policy.json` allows
`cloudfront:CreateInvalidation` on this one distribution only. With the
shell variables from AWS setup (`ACCOUNT_ID`, `ROLE_NAME`) still set:

```bash
sed -e "s/ACCOUNT_ID/$ACCOUNT_ID/g" -e "s/DISTRIBUTION_ID/$DISTRIBUTION_ID/g" \
  infra/aws/cloudfront-invalidation-policy.json > /tmp/cf-policy.json
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name cloudfront-invalidate --policy-document file:///tmp/cf-policy.json
```

Console: **IAM → Roles → `gha-simple-click-counter-deploy` → Permissions →
Add permissions → Create inline policy → JSON**, paste the file with
`ACCOUNT_ID` and `DISTRIBUTION_ID` filled in, and name it
`cloudfront-invalidate`.

### 3. Update the GitHub `production` environment

**Settings → Environments → production → Environment variables:**

| Variable | Value |
|---|---|
| `CLOUDFRONT_DISTRIBUTION_ID` | the Distribution ID from step 1 |
| `PUBLIC_BASE_URL` | `https://<distribution domain name>` (or your custom domain), no trailing slash |

### 4. Check a deploy

Run **Actions → Deploy to S3 → Run workflow** on `main`. The
**Invalidate CloudFront (optional)** step should now run instead of being
skipped, and the summary links should point at CloudFront. If that step fails
with `AccessDenied`, the inline policy from step 2 is missing or names the
wrong distribution ID.

The old S3 website URL keeps working too, since the bucket is still public.

### 5. Custom domain (optional)

1. Console: **AWS Certificate Manager**, in region **us-east-1** (CloudFront
   only uses certificates from there) → **Request a public certificate** for
   your domain, validated by DNS. Add the CNAME record it shows at your DNS
   provider and wait for "Issued".
2. **CloudFront → your distribution → General → Edit:** add the domain under
   **Alternate domain names (CNAME)** and pick the certificate.
3. At your DNS provider, point the domain at the distribution domain name
   (a CNAME, or a Route 53 alias record for an apex domain).
4. Change `PUBLIC_BASE_URL` to `https://<your-domain>`.

### Alternative: private bucket with OAC

Instead of the website endpoint you can use the **S3 REST endpoint with
Origin Access Control (OAC)**, which lets the bucket become private: replace
the public-read bucket policy with the OAC policy CloudFront gives you, and
turn bucket Block Public Access back on. The REST endpoint doesn't map
`/latest/` to `/latest/index.html`, so add a small CloudFront Function on
viewer requests that appends `index.html` to URIs ending in `/`. (The
`trailingSlash: true` setting in `next.config.ts` makes every route end in
`/`.) Set the custom error response for 403 and 404 to `/latest/404.html`.
The old S3 website URL stops working in this setup. Steps 2–4 above are the
same.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The trust policy's `sub` doesn't match. Compare it with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix` (immutable subjects include `@<id>` after the owner and repo names; see AWS step 7). Also check that the job runs in the `production` environment. |
| `Variable … is not set` in the first step | The variables are missing, or were added to a different environment. |
| `AccessDenied` on `s3 sync` | The role's inline policy has the wrong bucket name, or `S3_BUCKET` is wrong. |
| `403 Forbidden` in the browser | Block Public Access (account or bucket level) is still on, or the bucket policy is missing. |
| Page loads without styling, or assets 404 | The build ran without the matching `BASE_PATH`. Check the build steps in `deploy.yml`. |
| `404` at the site root `/` | Expected unless you added the optional root redirect in AWS step 5. Use `/latest/`. |
