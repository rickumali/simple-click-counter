import type { NextConfig } from "next";

// The site is deployed as static files to S3 (and later CloudFront), where
// each deploy lives under its own path such as /deploys/<sha> or /latest.
// BASE_PATH is set by the deploy workflow at build time. Leave it unset for
// local development so the app is served from "/".
const basePath = (process.env.BASE_PATH ?? "").replace(/\/+$/, "");

if (basePath && !basePath.startsWith("/")) {
  throw new Error(`BASE_PATH must start with "/" (got "${basePath}")`);
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
};

export default nextConfig;
