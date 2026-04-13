import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const indexPath = join(root, "dist", "index.html");

if (!existsSync(indexPath)) {
  console.error("Missing dist/index.html — run `npm run build` first.");
  process.exit(1);
}

const html = readFileSync(indexPath, "utf8");
if (html.includes("/src/main.tsx") || html.includes('src="/src/')) {
  console.error(
    "dist/index.html still references /src/… (dev entry). " +
      "You must deploy the Vite output in dist/, not the repo-root index.html."
  );
  process.exit(1);
}
if (!html.includes("/Deploy_Contracts/")) {
  console.error(
    "dist/index.html has no /Deploy_Contracts/ asset paths. " +
      "Check vite.config.ts `base` matches the GitHub repo name."
  );
  process.exit(1);
}

console.log("dist/index.html looks like a production GitHub Pages build.");
