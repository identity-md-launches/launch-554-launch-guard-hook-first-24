# Vendored dependencies

All listed Solidity files are included as ordinary files under `lib/`. No package installation is needed by the verifier. Upstream `.git`, `.github`, configuration, and unrelated test trees were not imported. Original license files and source SPDX identifiers are retained.

| Directory | Source | Pinned revision | Included subset |
| --- | --- | --- | --- |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Production `src/`, excluding `src/test/`; `licenses/` |
| `lib/v4-periphery` | https://github.com/Uniswap/v4-periphery | `444c526b77d804590f0d7bc5a481af5a3277c952` | BaseHook, ImmutableState, IImmutableState; LICENSE |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` (v1.9.7) | `src/`; LICENSE files |
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | `69c8def5f222ff96f2b5beff05dfba996368aa79` (v5.1.0 tag object) | ERC20, IERC20, IERC20Metadata, IERC6093, Context; LICENSE |
| `lib/solmate` | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` | Owned (needed by the local test PoolManager); LICENSE |

The Uniswap repositories contain mixed licenses, including BUSL-1.1 for PoolManager and MIT for imported math/interfaces. The project deploys its own hook and token against an existing canonical PoolManager; local tests deploy the vendored manager. Consult individual SPDX headers and upstream license terms before reusing dependencies for other purposes. Project-authored code is MIT licensed.
