# [High] Sovereign bridgeManager can map an arbitrary token to a mainnet origin, enabling zero-cost theft of other users' imported funds from the mainnet bridge

Proof of Concept for a High-severity finding in the Polygon AggLayer
contracts (`agglayer/agglayer-contracts` @
`110bda5a03e70ee7331bc06407a8e79226d3e520`).

## Summary

`AgglayerBridgeL2.setMultipleSovereignTokenAddress` (gated only by the
per-sovereign-chain `bridgeManager` role) lets the caller map an arbitrary
attacker-controlled token to an arbitrary `(originNetwork,
originTokenAddress)` — including mainnet `(0, <any ERC20>)` — with no check
that the origin is not mainnet and no check that the token is a
bridge-deployed wrapped token. `bridgeAsset` then creates an exit leaf with
that forged origin, trusting the token's `burn()` to enforce the economics.
The only on-chain guard, the Local Balance Tree (LBT) decrease in
`_addLeafBridge`, enforces a global per-token balance, not a per-user one.
So an attacker whose token has a no-op `burn()` can exit up to the entire
net-imported balance of that token on that chain — including other users'
funds — at zero cost, and claim real tokens from the mainnet bridge.

The PoC (`test/AgglayerR8GER.t.sol`, `test_R8F_forgedOriginDrainsImportedBalance`)
shows it end to end: a victim imports 1000 USDC to sovereign chain S; the
chain's `bridgeManager` maps a no-op-burn token to origin `(0, USDC)`; an
attacker holding 0 wrapped USDC and 0 fake tokens bridges 1000, the leaf is
created, the LBT drops 1000 → 0, and the attacker claims 1000 real USDC on
mainnet. The victim can no longer exit (reverts
`LocalBalanceTreeUnderflow`). A negative control (no import → bridge reverts)
shows the theft is capped at the chain's net imported balance per token.

## Repo layout

- `src/` — the `agglayer-contracts` tree at commit `110bda5a` (see "Upstream"
  below). The vulnerable code is in
  `src/sovereignChains/AgglayerBridgeL2.sol` (`setMultipleSovereignTokenAddress`,
  `_setSovereignTokenAddress`, `_addLeafBridge`) and
  `src/AgglayerBridge.sol` (`bridgeAsset`, `_bridgeWrappedAsset`).
- `test/` — Foundry tests. The finding's PoC is
  `test/AgglayerR8GER.t.sol` (`AgglayerR8GERTest`); the other `AgglayerR*.t.sol`
  files are regression tests from the same audit round.
- `foundry.toml`, `remappings.txt` — build config (optimizer on, `via_ir`,
  `optimizer_runs = 999999`).

## Setup

Dependencies are **not** vendored in this repo; fetch them into `lib/` with
the exact directory names used by `remappings.txt`:

```sh
git clone --branch v4.8.2 --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/oz-contracts-4.8.2
git clone --branch v5.0.0 --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/oz-contracts-5.0.0
git clone --branch v5.2.0 --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/oz-contracts-5.2.0
git clone --branch v4.8.2 --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git lib/oz-upgradeable-4.8.2
git clone --branch v5.0.0 --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git lib/oz-upgradeable-5.0.0
git clone --branch v1.10.0 --depth 1 https://github.com/foundry-rs/forge-std.git lib/forge-std
```

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation)
(`forge` 1.9.0 was used for verification).

## Run

```sh
# PoC for this finding only — expect 13/13 pass
forge test --match-contract AgglayerR8GERTest

# Full regression — expect 96/96 pass
forge test
```

Note: the build uses `via_ir`, so the first compile can take several minutes.

> Verified 2026-11-18 in this exact staging layout (forge 1.9.0):
> `forge test --match-contract AgglayerR8GERTest` → **13/13 pass**;
> `forge test` → **96/96 pass** across 9 suites (including
> `test_R8F_forgedOriginDrainsImportedBalance` and
> `test_R8F_forgedOriginBlockedWithoutImport`).

## Upstream

`src/` is the `agglayer-contracts` repository at commit
`110bda5a03e70ee7331bc06407a8e79226d3e520` (main; develop `cfdca3c2`
identical for these files). Only the files needed to build and run the
tests are included.

## License

AGPL-3.0 — see `LICENSE` (the upstream repository's license file at the
same commit).
