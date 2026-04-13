import { useCallback, useEffect, useMemo, useState } from "react";
import { BrowserProvider, ContractFactory, getAddress, Interface, type InterfaceAbi } from "ethers";
import "./App.css";

import erc20Artifact from "./generated/SimpleERC20.json";
import linearPoolArtifact from "./constant/LinearPool.json";

type Artifact = { abi: InterfaceAbi; bytecode: string };

const ERC20_ARTIFACT = erc20Artifact as Artifact;
const LINEAR_ARTIFACT = linearPoolArtifact as Artifact;
const LINEAR_IFACE = new Interface(LINEAR_ARTIFACT.abi);

if (!ERC20_ARTIFACT.bytecode || ERC20_ARTIFACT.bytecode === "0x") {
  throw new Error("generated/SimpleERC20.json must include bytecode (run npm run compile && node scripts/copy-artifact.mjs).");
}
if (!LINEAR_ARTIFACT.bytecode || LINEAR_ARTIFACT.bytecode === "0x") {
  throw new Error("src/constant/LinearPool.json must include non-empty bytecode.");
}

const DEPLOY_GAS_MAX = 20_000_000n;
const DEPLOY_GAS_MIN = 8_000_000n;
const INIT_GAS_MAX = 4_000_000n;
const INIT_GAS_MIN = 400_000n;

declare global {
  interface Window {
    ethereum?: {
      request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
      on: (event: string, handler: (...args: unknown[]) => void) => void;
      removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
    };
  }
}

function chainLabel(chainId: bigint): string {
  const id = Number(chainId);
  const names: Record<number, string> = {
    1: "Ethereum Mainnet",
    8453: "Base",
    84532: "Base Sepolia",
    11155111: "Sepolia",
    17000: "Holesky",
    31337: "Hardhat / Anvil",
    97: "Bsc Testnet",
  };
  return names[id] ?? `Chain ${id}`;
}

async function gasLimitWithHeadroom(
  provider: BrowserProvider,
  from: string,
  tx: { data?: string; to?: string | null; value?: bigint },
  min: bigint,
  max: bigint
): Promise<bigint> {
  try {
    const estimated = await provider.estimateGas({
      from,
      to: tx.to ?? undefined,
      data: tx.data,
      value: tx.value ?? 0n,
    });
    const bumped = (estimated * 170n) / 100n + 500_000n;
    if (bumped < min) return min;
    if (bumped > max) return max;
    return bumped;
  } catch {
    return max;
  }
}

export default function App() {
  const [account, setAccount] = useState<string | null>(null);
  const [chainId, setChainId] = useState<bigint | null>(null);
  const [walletError, setWalletError] = useState<string | null>(null);

  const [name, setName] = useState("My Token");
  const [symbol, setSymbol] = useState("MTK");
  const [decimals, setDecimals] = useState("18");
  const [initialSupply, setInitialSupply] = useState("1000000");
  const [ercError, setErcError] = useState<string | null>(null);
  const [ercDeploying, setErcDeploying] = useState(false);
  const [ercTx, setErcTx] = useState<string | null>(null);
  const [ercAddress, setErcAddress] = useState<string | null>(null);

  const [tokenAddress, setTokenAddress] = useState("");
  const [lpError, setLpError] = useState<string | null>(null);
  const [lpBusy, setLpBusy] = useState(false);
  const [deployTx, setDeployTx] = useState<string | null>(null);
  const [initTx, setInitTx] = useState<string | null>(null);
  const [poolAddress, setPoolAddress] = useState<string | null>(null);

  const provider = useMemo(() => {
    if (!window.ethereum) return null;
    return new BrowserProvider(window.ethereum);
  }, []);

  const refreshChain = useCallback(async () => {
    if (!provider) return;
    const net = await provider.getNetwork();
    setChainId(net.chainId);
  }, [provider]);

  const connect = useCallback(async () => {
    setWalletError(null);
    if (!window.ethereum) {
      setWalletError("Install MetaMask (or another injected wallet).");
      return;
    }
    try {
      const accounts = (await window.ethereum.request({
        method: "eth_requestAccounts",
      })) as string[];
      if (accounts[0]) setAccount(getAddress(accounts[0]));
      await refreshChain();
    } catch (e) {
      setWalletError(e instanceof Error ? e.message : "Connection failed");
    }
  }, [refreshChain]);

  useEffect(() => {
    if (!window.ethereum) return;
    const onAccounts = (accs: unknown) => {
      const a = (accs as string[])[0];
      setAccount(a ? getAddress(a) : null);
    };
    const onChain = () => {
      void refreshChain();
    };
    window.ethereum.on("accountsChanged", onAccounts);
    window.ethereum.on("chainChanged", onChain);
    return () => {
      window.ethereum?.removeListener?.("accountsChanged", onAccounts);
      window.ethereum?.removeListener?.("chainChanged", onChain);
    };
  }, [refreshChain]);

  const deployErc20 = useCallback(async () => {
    if (!provider || !account) return;
    setErcError(null);
    setErcTx(null);
    setErcAddress(null);

    const dec = Number.parseInt(decimals, 10);
    if (!Number.isFinite(dec) || dec < 0 || dec > 255) {
      setErcError("Decimals must be 0–255.");
      return;
    }
    const supplyStr = initialSupply.trim();
    if (!/^\d+$/.test(supplyStr)) {
      setErcError("Initial supply must be a whole number.");
      return;
    }

    setErcDeploying(true);
    try {
      const signer = await provider.getSigner();
      const factory = new ContractFactory(ERC20_ARTIFACT.abi, ERC20_ARTIFACT.bytecode, signer);
      const contract = await factory.deploy(name, symbol, dec, supplyStr);
      setErcTx(contract.deploymentTransaction()?.hash ?? null);
      await contract.waitForDeployment();
      setErcAddress(await contract.getAddress());
    } catch (e) {
      setErcError(e instanceof Error ? e.message : "ERC-20 deploy failed.");
    } finally {
      setErcDeploying(false);
    }
  }, [provider, account, name, symbol, decimals, initialSupply]);

  const deployAndInitialize = useCallback(async () => {
    if (!provider || !account) return;
    setLpError(null);
    setDeployTx(null);
    setInitTx(null);
    setPoolAddress(null);

    let tokenAddr: string;
    try {
      tokenAddr = getAddress(tokenAddress.trim());
    } catch {
      setLpError("Enter a valid ERC-20 token address for __LinearPool_init.");
      return;
    }

    setLpBusy(true);
    try {
      const signer = await provider.getSigner();

      const factory = new ContractFactory(LINEAR_ARTIFACT.abi, LINEAR_ARTIFACT.bytecode, signer);
      const deployUnsigned = await factory.getDeployTransaction();
      const deployGas = await gasLimitWithHeadroom(
        provider,
        account,
        { data: deployUnsigned.data },
        DEPLOY_GAS_MIN,
        DEPLOY_GAS_MAX
      );
      const deployed = await factory.deploy({ gasLimit: deployGas });
      setDeployTx(deployed.deploymentTransaction()?.hash ?? null);
      await deployed.waitForDeployment();
      const addr = getAddress(await deployed.getAddress());
      setPoolAddress(addr);

      const initData = LINEAR_IFACE.encodeFunctionData("__LinearPool_init", [tokenAddr]);
      if (initData.length < 10) {
        throw new Error("Failed to encode __LinearPool_init.");
      }

      try {
        await provider.call({ from: account, to: addr, data: initData });
      } catch (sim: unknown) {
        const m = sim instanceof Error ? sim.message : String(sim);
        throw new Error(
          `${m} — Init simulation failed. If your build uses constructor _disableInitializers(), you cannot call __LinearPool_init on this address; use a proxy flow instead.`
        );
      }

      const initGas = await gasLimitWithHeadroom(
        provider,
        account,
        { to: addr, data: initData },
        INIT_GAS_MIN,
        INIT_GAS_MAX
      );
      const initResponse = await signer.sendTransaction({
        to: addr,
        data: initData,
        gasLimit: initGas,
      });
      setInitTx(initResponse.hash);
      await initResponse.wait();
    } catch (e) {
      setLpError(e instanceof Error ? e.message : "Deploy or initialize failed.");
    } finally {
      setLpBusy(false);
    }
  }, [provider, account, tokenAddress]);

  return (
    <div className="app">
      <h1>Deploy</h1>
      <p className="sub">
        Deploy an ERC-20 (SimpleERC20), then LinearPool from <code>src/constant/LinearPool.json</code> (deploy +{" "}
        <code className="mono">__LinearPool_init</code>).
      </p>

      <div className="card">
        <h2>Wallet</h2>
        {!window.ethereum && <p className="err">No injected wallet.</p>}
        <div className="row">
          {!account ? (
            <button type="button" className="btn btn-primary" onClick={() => void connect()} disabled={!provider}>
              Connect
            </button>
          ) : (
            <>
              <span className="mono">{account}</span>
              <button type="button" className="btn btn-ghost" onClick={() => void connect()}>
                Reconnect
              </button>
            </>
          )}
        </div>
        {chainId !== null && (
          <p className="mono" style={{ marginTop: "0.5rem" }}>
            {chainLabel(chainId)} · {chainId.toString()}
          </p>
        )}
        {walletError && <p className="err">{walletError}</p>}
      </div>

      <div className="card">
        <h2>ERC-20 token (SimpleERC20)</h2>
        <div className="grid2">
          <div>
            <label htmlFor="t-name">Name</label>
            <input id="t-name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div>
            <label htmlFor="t-symbol">Symbol</label>
            <input id="t-symbol" value={symbol} onChange={(e) => setSymbol(e.target.value)} />
          </div>
          <div>
            <label htmlFor="t-dec">Decimals</label>
            <input id="t-dec" value={decimals} onChange={(e) => setDecimals(e.target.value)} />
          </div>
          <div>
            <label htmlFor="t-supply">Initial supply (whole)</label>
            <input id="t-supply" value={initialSupply} onChange={(e) => setInitialSupply(e.target.value)} />
          </div>
        </div>
        <div className="row" style={{ marginTop: "1rem" }}>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => void deployErc20()}
            disabled={!account || ercDeploying}
          >
            {ercDeploying ? "Deploying…" : "Deploy ERC-20"}
          </button>
        </div>
        {ercError && <p className="err">{ercError}</p>}
        {ercTx && (
          <p className="ok mono" style={{ marginTop: "0.5rem" }}>
            Tx: {ercTx.slice(0, 10)}…{ercTx.slice(-8)}
          </p>
        )}
        {ercAddress && <p className="ok mono">Token contract: {ercAddress}</p>}
      </div>

      <div className="card">
        <h2>LinearPool — deploy & initialize</h2>
        <div style={{ marginBottom: "0.75rem" }}>
          <label htmlFor="lp-token">Token address (IERC20 for __LinearPool_init)</label>
          <input
            id="lp-token"
            className="mono"
            value={tokenAddress}
            onChange={(e) => setTokenAddress(e.target.value)}
            placeholder="0x…"
          />
        </div>
        <div className="row">
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => void deployAndInitialize()}
            disabled={!account || lpBusy}
          >
            {lpBusy ? "Working…" : "Deploy then initialize"}
          </button>
        </div>
        {lpError && <p className="err">{lpError}</p>}
        {deployTx && (
          <p className="ok mono" style={{ marginTop: "0.75rem" }}>
            Deploy tx: {deployTx.slice(0, 10)}…{deployTx.slice(-8)}
          </p>
        )}
        {initTx && (
          <p className="ok mono">
            Initialize tx: {initTx.slice(0, 10)}…{initTx.slice(-8)}
          </p>
        )}
        {poolAddress && (
          <p className="ok mono" style={{ marginTop: "0.5rem" }}>
            LinearPool: {poolAddress}
          </p>
        )}
      </div>
    </div>
  );
}
