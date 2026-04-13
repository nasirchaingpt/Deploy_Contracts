import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const outDir = join(root, "src/generated");

mkdirSync(outDir, { recursive: true });

// SimpleERC20: full artifact (UI deploys with bundled bytecode)
{
  const p = join(root, "artifacts/contracts/SimpleERC20.sol/SimpleERC20.json");
  const { abi, bytecode } = JSON.parse(readFileSync(p, "utf8"));
  if (!bytecode || bytecode === "0x") {
    throw new Error("Missing SimpleERC20 bytecode; run `npm run compile` first.");
  }
  writeFileSync(join(outDir, "SimpleERC20.json"), JSON.stringify({ abi, bytecode }, null, 2));
  console.log("Wrote", join(outDir, "SimpleERC20.json"));
}

// LinearPool: ABI only (creation bytecode is `src/defaultLinearPoolBytecode.ts`)
{
  const p = join(root, "artifacts/contracts/contracts/LinearPool.sol/LinearPool.json");
  const { abi } = JSON.parse(readFileSync(p, "utf8"));
  writeFileSync(join(outDir, "LinearPool.json"), JSON.stringify({ abi }, null, 2));
  console.log("Wrote", join(outDir, "LinearPool.json"));
}

// ERC1967Proxy: deploy proxy with initializer calldata (OpenZeppelin)
{
  const p = join(
    root,
    "artifacts/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol/ERC1967Proxy.json"
  );
  const { abi, bytecode } = JSON.parse(readFileSync(p, "utf8"));
  if (!bytecode || bytecode === "0x") {
    throw new Error("Missing ERC1967Proxy bytecode; run `npm run compile` first.");
  }
  writeFileSync(join(outDir, "ERC1967Proxy.json"), JSON.stringify({ abi, bytecode }, null, 2));
  console.log("Wrote", join(outDir, "ERC1967Proxy.json"));
}
