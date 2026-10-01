# Launch guard test coverage

The original integration suite is retained and extended. All swaps use the production
hook deployed with CREATE2 at its actual permission bits and a local, canonical
PoolManager. No forks, environment changes, downloaded dependencies, or permission
validation overrides are needed.

| Suite | Added checks |
| --- | --- |
| `LaunchGuardHook.t.sol` | Invalid hook identity, delayed pool initialization, zero and one-wei requests, cap minus one, full-supply and extreme signed requests with partial fills, invalid price limits, impossible exact-output trades at a 100% fee. Both token orderings run every case. |
| `LaunchGuardConstructor.t.sol` | Missing manager/token code, supplies below 100 minor units, supply rounding boundaries, maximum uint256 supply, and incorrect deployment permissions. Constructor failures are tested at correctly mined addresses so permission errors cannot hide configuration errors. |
| `LaunchGuard.invariant.t.sol` | Random sequences of swaps, liquidity additions/removals, directional protocol fees, and forward time changes; both launch-token orderings. |
| `LaunchToken.invariant.t.sol` | Four actors transferring, approving, spending allowances, attempting overspends, and revoking approvals in random order. |

Each invariant campaign runs 256 sequences of 128 calls with `fail-on-revert = true`,
configured inline. Target selectors expose only the handler actions; unexpected
reverts fail the campaign. Expected reverts match complete error data.

The guard handler checks each generated trade against a real settled swap at or after
expiry, then restores the entire snapshot before executing the original guarded
trade. It never uses `SwapPreview` as its oracle. Oversized guarded buys must revert;
every other generated swap must return the identical balance delta. Rejected swaps
must preserve balances, price, tick, active liquidity, fees, and the deadline.

Always-on checks compare settled token balances to a separate ledger of returned
deltas, reconcile active liquidity with the handler's positions, and require the cap,
deadline, supply, and zero hook custody to remain unchanged. The token campaign checks
every actor balance and every actor-pair allowance against its own ledger, total
balance conservation, and rollback of allowances when delegated transfers fail.

The guard campaign bounds prices to ticks [-4000, 4000], swap requests to three times
the cap, and each of four liquidity positions to 100 million units. These bounds keep
the router solvent while exercising tick crossings, partial fills, and liquidity
gaps. The original fuzz suite separately covers larger price distances; deterministic
tests pin signed integer extremes. Fixed-supply stubs are confined to constructor
tests. Trading and token invariants use the actual LaunchToken.

Deterministic sequence tests verify that allowed buys, rejected buys, expiry, full
balance transfers, self-transfers, and infinite approval are reachable in the
handlers. The monetary limit is per swap, not cumulative per wallet or per day.

Run from the repository root:

```sh
forge build --out /tmp/launch-guard-out --cache-path /tmp/launch-guard-cache
forge test --out /tmp/launch-guard-out --cache-path /tmp/launch-guard-cache
```
