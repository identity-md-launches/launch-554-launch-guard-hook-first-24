# Launch Guard

An immutable Uniswap v4 hook that rejects a swap in `beforeSwap` if it would buy **more than 1% of the launch token's supply during the first 24 hours after pool initialization**. No owner, pause, upgrade, exemptions, withdrawal functions, or configurable cap.

`LaunchToken` is the accompanying ERC-20: **Launch Guard (GUARD)**, 18 decimals, exactly **1,000,000,000 tokens (10^27 minor units)** minted to its deployer with no constructor arguments. It uses OpenZeppelin ERC20 without extensions. There is no further minting, burning, transfer fee, blocklist, or administration.

## Behavior and assumptions

- The limit is **10,000,000 GUARD per swap** (`totalSupply() / 100`). Exactly the limit is allowed. The immutable limit is read at hook construction; deploy this hook with the supplied fixed-supply token. Rebasing, mintable, taxed, callback-bearing, or upgradeable replacement tokens are outside the supported assumptions.
- The guard applies on `[initialization timestamp, initialization timestamp + 86,400 seconds)`. Exactly at the deadline it ceases restricting swaps. Block timestamps determine the boundary; it is not a block-count timer.
- A buy has the launch token as its output currency. Both currency orderings, ERC-20 and native-currency counterpart assets, and exact-input / exact-output swaps are supported. Amounts are launch-token minor units; the quote asset's decimals and nominal input amount do not define the cap.
- Every pool using the hook must contain the launch token. Each complete `PoolId` has its own initialization deadline. Initializing another fee tier or pair cannot reset or disable an existing pool's guard. Deployment alone does not start the timer; even initialization at timestamp zero works.
- After expiry, all otherwise valid swaps in initialized pools pass the hook. PoolManager's ordinary liquidity, price-limit, amount and settlement checks still apply. Sells, liquidity changes and donations have no launch guard restriction at any time.
- This is a per-swap limit. Multiple swaps, including multiple swaps in one transaction, may buy more in aggregate. Transfers, liquidity withdrawals and pools without this hook are outside its scope. It is not a wallet holding limit or comprehensive bot / MEV protection.

## Why there is a swap preview

In v4, negative `amountSpecified` denotes exact input, while positive denotes exact output. Comparing the absolute input amount to the cap would compare different currencies and let oversized buys through when prices differ.

`SwapPreview` reads the current PoolManager state using the pinned `StateLibrary` and reproduces output using core `SwapMath`, tick bitmap traversal, liquidity transitions, LP fees, and the directional protocol fee. It respects the trader's price limit and core's rounding. This permits partial fills whose actual output remains within the cap, even when requested input or output is much larger. The preview stops as soon as output exceeds the cap. Exact-output requests already at or below the cap need no preview.

Only `beforeInitialize` and `beforeSwap` are enabled; all delta-return and fee-override permissions are disabled. `beforeSwap` returns the correct selector, a zero delta and a zero fee override. The hook holds no funds and never calls `unlock`, `swap`, `take` or `settle`. BaseHook authenticates **all callbacks** against the immutable PoolManager. `sender` and `hookData` do not grant exemptions.

The preview's external calls are static reads to that manager. No intervening mutable external call occurs between preview and the manager's swap math. Fee-growth accounting is omitted from the preview because it does not affect output. The implementation depends on canonical v4 state layout and swap semantics; a manager fork with changed layout or mathematics is unsupported without review.

Traversal is monotonic and bounded by the core tick domain, but its gas cost grows with crossed initialized ticks and empty bitmap words. Small exact-input buys usually require few steps; sparse liquidity and distant price limits cost more. During the guard, such buys perform an extra read-only traversal. Routers should estimate gas against current liquidity and supply appropriate price limits. After expiry and for sells the traversal is skipped.

## Build and tests

```sh
forge build
forge test
forge fmt --check
```

The project pins Solidity **0.8.26**, targets **Cancun**, and uses the optimizer with IR compilation. All dependencies are ordinary vendored files; no network, environment values, FFI, filesystem cheatcode permissions, or submodules are needed to build or test. See [DEPENDENCIES.md](DEPENDENCIES.md) for versions and licenses. Metadata is omitted from runtime bytecode so the admission opcode scan examines executable code without a metadata trailer.

Tests deploy a real local PoolManager and CREATE2-mine the **production hook** at an address with its required flags. They exercise token transfers and allowances, authorization, initialization rollback and timer isolation, both token orderings and swap types, native pairs, price-dependent buys, strict amount/time boundaries, unrestricted sells, partial fills, liquidity gaps, liquidity removal, and unchanged balances on rejection. Fuzz tests compare preview output byte-for-byte with actual core swaps across tick crossings and protocol fees, and compare the guard's decision against a real unguarded execution restored from a local snapshot. No network fork is needed for these checks.

Local validation: `forge build`, all **72 tests** (256 cases per fuzz test), and `forge fmt --check` passed. Hook runtime is 7,836 bytes; token runtime is 1,490 bytes. The isolated single-range exact-input callback benchmark measured 54,634 / 61,729 gas for the two token orderings, including external-call overhead. These are sample measurements, not upper bounds; run `forge test --match-test test_beforeSwapGas -vv` to reproduce them.

## Deployment parameters and responsibilities

The hook constructor is:

```solidity
LaunchGuardHook(IPoolManager manager, IERC20 token)
```

`manager` is the destination chain's canonical PoolManager, supplied by the network deployer. No manager address is hardcoded. `token` is the address of the newly deployed `LaunchToken`. Both must already have code. If producing the network's separate launch manifest, encode the manager constructor argument as `"$poolManager"`. This project does not create that manifest or broadcast transactions.

Deployment sequence:

1. The launch factory deploys `LaunchToken()` and receives its entire supply. Verify name, symbol, decimals and supply. The factory is responsible for the approved distribution and initial liquidity allocations.
2. Compute hook init code as `abi.encodePacked(type(LaunchGuardHook).creationCode, abi.encode(manager, token))`. Mine a CREATE2 salt **for the actual deploying factory, these constructor arguments, and these exact compiler settings**. Require `uint160(predictedAddress) & 0x3fff == 0x2080` (before-initialize `0x2000`, before-swap `0x0080`). Address formula: the low 20 bytes of `keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))`. Tests contain a working mining and deployment example. Changing any input requires remining.
3. Verify predicted address, constructor arguments and `getHookPermissions()`. The BaseHook constructor rejects incompatible address bits. A plain CREATE deployment will generally fail address validation.
4. **Deploy the hook and initialize its intended pool atomically through the launch factory.** Supply sorted currencies (including this launch token), a valid LP fee, tick spacing, and initial `sqrtPriceX96`. The factory/deployer chooses and independently reviews these economic parameters; there are no silent project defaults. Seed and settle the agreed liquidity. Initialization calls to a predicted hook address without code fail because the enabled callback must return its selector.
5. Check `GuardStarted(poolId, endsAt)` and `guardEndsAt(poolId)` against the initialization block timestamp. Verify source and immutable arguments on the destination explorer and confirm token allocation and pool price. The deadline starts at initialization even if liquidity arrives later.

Initialization is permissionless once the hook exists. Atomic deployment and initialization prevent someone else from setting the intended pool's opening price and starting its timer first. Other pools have independent timers. No keeper, oracle, owner or scheduled transaction is required for expiry, and no party can extend, waive, or restart a pool's guard.

The deployment operator must confirm Cancun support, the manager's canonical storage/math compatibility, token identity, selected fee/spacing/price, and router settlement/slippage behavior. Obtain independent adversarial review of the preview and hook, rehearse on the actual destination chain fork, and monitor initialization and trading before releasing a funded launch. Local tests are not a security audit. Slither, Mythril, a network fork, and an external audit are not claimed here.

## Configuration record

```json
{
  "hook": "BaseHook",
  "name": "LaunchGuardHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": false,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

`access: "none"` records the assignment's explicit no-owner requirement rather than one of the reference wizard's administrative options. Safe casts are used in the preview; the hook itself uses no transient storage, although v4 PoolManager requires Cancun.
