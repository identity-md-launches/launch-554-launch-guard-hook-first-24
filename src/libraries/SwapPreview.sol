// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @notice Read-only output preview for the pinned v4 PoolManager, without fee overrides or hook deltas.
/// @dev Uses the same step math, rounding, bitmap boundaries, liquidity and fees as v4-core.
/// Fee growth does not affect swap output and is intentionally not calculated or written.
library SwapPreview {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;
    using SafeCast for uint256;

    error InvalidPriceLimit();
    error InvalidExactOutputFee();

    struct State {
        uint160 price;
        int24 tick;
        uint128 liquidity;
        int256 remaining;
        uint24 fee;
    }

    struct Step {
        int24 tick;
        bool initialized;
        uint160 price;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /// @return output Actual output, or an early partial sum strictly above stopAbove.
    /// @dev Traversal terminates at the requested amount, price limit, or cap violation.
    function outputAmount(
        IPoolManager manager,
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 stopAbove
    ) internal view returns (uint256 output) {
        PoolId id = key.toId();
        State memory s;
        uint24 protocolFees;
        (s.price, s.tick, protocolFees, s.fee) = manager.getSlot0(id);
        uint16 protocolFee =
            params.zeroForOne ? protocolFees.getZeroForOneFee() : protocolFees.getOneForZeroFee();
        s.fee = protocolFee.calculateSwapFee(s.fee);
        if (params.amountSpecified > 0 && s.fee == SwapMath.MAX_SWAP_FEE) revert InvalidExactOutputFee();
        if (params.amountSpecified == 0) return 0;
        if (params.zeroForOne
                ? params.sqrtPriceLimitX96 >= s.price || params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
                : params.sqrtPriceLimitX96 <= s.price || params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) revert InvalidPriceLimit();

        s.liquidity = manager.getLiquidity(id);
        s.remaining = params.amountSpecified;
        Step memory step;
        while (s.remaining != 0 && s.price != params.sqrtPriceLimitX96) {
            (step.tick, step.initialized) =
                nextTickInWord(manager, id, s.tick, key.tickSpacing, params.zeroForOne);
            if (step.tick < TickMath.MIN_TICK) step.tick = TickMath.MIN_TICK;
            if (step.tick > TickMath.MAX_TICK) step.tick = TickMath.MAX_TICK;
            step.price = TickMath.getSqrtPriceAtTick(step.tick);
            (s.price, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                s.price,
                SwapMath.getSqrtPriceTarget(params.zeroForOne, step.price, params.sqrtPriceLimitX96),
                s.liquidity,
                s.remaining,
                s.fee
            );
            output += step.amountOut;
            if (output > stopAbove) return output;
            if (params.amountSpecified < 0) {
                s.remaining += (step.amountIn + step.feeAmount).toInt256();
            } else {
                s.remaining -= step.amountOut.toInt256();
            }
            // A step ending inside a tick has exhausted the amount or hit the price limit.
            // Only a step reaching the next tick needs a new tick / liquidity for another iteration.
            if (s.price == step.price) {
                if (step.initialized) {
                    (, int128 net) = manager.getTickLiquidity(id, step.tick);
                    if (params.zeroForOne) net = -net;
                    s.liquidity = LiquidityMath.addDelta(s.liquidity, net);
                }
                s.tick = params.zeroForOne ? step.tick - 1 : step.tick;
            }
        }
    }

    /// @dev v4 TickBitmap traversal with extsload in place of direct storage reads.
    function nextTickInWord(IPoolManager manager, PoolId id, int24 tick, int24 spacing, bool left)
        private
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = TickBitmap.compress(tick, spacing);
        if (!left) ++compressed;
        (int16 word, uint8 bit) = TickBitmap.position(compressed);
        uint256 bitmap = manager.getTickBitmap(id, word);
        uint256 mask = left ? type(uint256).max >> (255 - bit) : type(uint256).max << bit;
        uint256 masked = bitmap & mask;
        initialized = masked != 0;
        if (left) {
            uint8 distance = initialized ? bit - BitMath.mostSignificantBit(masked) : bit;
            next = (compressed - int24(uint24(distance))) * spacing;
        } else {
            uint8 distance = initialized ? BitMath.leastSignificantBit(masked) - bit : 255 - bit;
            next = (compressed + int24(uint24(distance))) * spacing;
        }
    }
}
