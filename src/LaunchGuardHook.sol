// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapPreview} from "./libraries/SwapPreview.sol";

/// @notice Caps launch-token output per swap for 24 hours from each pool's initialization.
/// @dev No owner, setters, custody, custom deltas, or fee overrides. Deploy with address flags 0x2080.
contract LaunchGuardHook is BaseHook {
    uint256 public constant GUARD_DURATION = 24 hours;
    IERC20 public immutable launchToken;
    /// @notice Zero until the first successful pool initialization, then fixed for this hook.
    uint256 public maxBuyAmount;
    mapping(PoolId => uint256) public guardEndsAt;

    error InvalidConfiguration();
    error InvalidPool();
    error AlreadyInitialized();
    error PoolNotInitialized();
    error BuyLimitExceeded(uint256 limit);

    event GuardStarted(PoolId indexed poolId, uint256 endsAt);

    /// @param manager Chain-specific canonical v4 PoolManager, supplied by the deployer.
    /// @param token The fixed-supply LaunchToken, which must be deployed before pool initialization.
    constructor(IPoolManager manager, IERC20 token) BaseHook(manager) {
        if (address(manager).code.length == 0 || address(token) == address(0)) {
            revert InvalidConfiguration();
        }
        launchToken = token;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (
            address(key.hooks) != address(this)
                || (Currency.unwrap(key.currency0) != address(launchToken)
                    && Currency.unwrap(key.currency1) != address(launchToken))
        ) revert InvalidPool();
        PoolId id = key.toId();
        if (guardEndsAt[id] != 0) revert AlreadyInitialized();
        // Admission can deploy the hook before the token. Resolve its supply only through
        // the authenticated initialization callback, before any pool can start trading.
        if (maxBuyAmount == 0) {
            if (address(launchToken).code.length == 0) revert InvalidConfiguration();
            uint256 limit = launchToken.totalSupply() / 100;
            if (limit == 0) revert InvalidConfiguration();
            maxBuyAmount = limit;
        }
        uint256 endsAt = block.timestamp + GUARD_DURATION;
        guardEndsAt[id] = endsAt;
        emit GuardStarted(id, endsAt);
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 endsAt = guardEndsAt[key.toId()];
        if (endsAt == 0) revert PoolNotInitialized();
        if (block.timestamp < endsAt) {
            Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
            if (Currency.unwrap(outputCurrency) == address(launchToken)) {
                // A positive amount is exact OUTPUT. A nonpositive amount specifies INPUT.
                // Exact output <= the cap cannot exceed it, even with a partial fill.
                if (params.amountSpecified < 0 || uint256(params.amountSpecified) > maxBuyAmount) {
                    if (SwapPreview.outputAmount(poolManager, key, params, maxBuyAmount) > maxBuyAmount) {
                        revert BuyLimitExceeded(maxBuyAmount);
                    }
                }
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
