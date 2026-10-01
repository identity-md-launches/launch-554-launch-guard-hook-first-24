// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapPreview} from "../../src/libraries/SwapPreview.sol";

/// @dev Test-only router: spends its own prefunded balances, settles every delta with a real manager.
contract PoolActions is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params, hookData))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool isSwap, PoolKey memory key, bytes memory args) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (isSwap) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(args, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        }
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(
                    IERC20(Currency.unwrap(currency)).transfer(address(manager), amount), "transfer failed"
                );
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}

contract PreviewHarness {
    function output(IPoolManager manager, PoolKey calldata key, SwapParams calldata params)
        external
        view
        returns (uint256)
    {
        return SwapPreview.outputAmount(manager, key, params, type(uint256).max);
    }
}
