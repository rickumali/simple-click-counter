import type { NextConfig } from "next";

// The site is deployed as static files to S3 (and later CloudFront), where
// each deploy lives under its own path such as /deploys/<sha> or /latest.
// BASE_PATH is set by the deploy workflow at build time. Leave it unset for
// local development so the app is served from "/".
const basePath = (process.env.BASE_PATH ?? "").replace(/\/+$/, "");

if (basePath && !basePath.startsWith("/")) {
  throw new Error(`BASE_PATH must start with "/" (got "${basePath}")`);
}

// The build ID is the build time plus the commit, e.g.
// "20261122T194418Z_4a2ca9e". Next.js writes it into a comment right after
// <!DOCTYPE html> on every page, so viewing the page source shows which build
// CloudFront or S3 is serving: <!DOCTYPE html><!--20261122T194418Z_4a2ca9e-->
//
// Next.js keeps only the first 24 characters in that comment and turns "-"
// into "_", so the time uses compact ISO 8601 (UTC) and "_" as the separator.
// The deploy workflow sets BUILD_TIME so its two builds share one ID, and
// GitHub Actions sets GITHUB_SHA. Locally they default to now and no commit.
function buildId(): string {
  const raw = process.env.BUILD_TIME;
  const time = raw ? new Date(raw) : new Date();
  if (Number.isNaN(time.getTime())) {
    throw new Error(`BUILD_TIME is not a valid date (got "${raw}")`);
  }
  const stamp = time.toISOString().replace(/\.\d+Z$/, "Z").replace(/[-:]/g, "");
  const sha = (process.env.GITHUB_SHA ?? "").slice(0, 7);
  return sha ? `${stamp}_${sha}` : stamp;
}

const nextConfig: NextConfig = {
  // Emit a fully static site into ./out (no Node.js server needed).
  output: "export",
  // Emit /route/index.html instead of /route.html so S3 website hosting (and
  // a future CloudFront directory-index function) can resolve "/route/".
  trailingSlash: true,
  basePath: basePath || undefined,
  // The Next.js image optimizer needs a server; static hosting can't run it.
  images: { unoptimized: true },
  generateBuildId: async () => buildId(),
};

export default nextConfig;
