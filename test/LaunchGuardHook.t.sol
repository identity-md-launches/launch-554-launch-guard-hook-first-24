// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchGuardHook} from "../src/LaunchGuardHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PoolActions, PreviewHarness} from "./helpers/PoolActions.sol";

abstract contract LaunchGuardTestBase is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant Q96 = 1 << 96;
    uint256 internal constant CAP = 10_000_000 ether;
    int256 internal constant LIQUIDITY = 100_000_000 ether;

    IPoolManager internal manager;
    LaunchToken internal token0;
    LaunchToken internal token1;
    LaunchToken internal token;
    LaunchGuardHook internal hook;
    PoolActions internal actions;
    PreviewHarness internal preview;
    PoolKey internal key;
    bool internal buyDirection;
    uint256 internal start;

    function tokenIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_000_000);
        start = block.timestamp;
        manager = IPoolManager(address(new PoolManager(address(this))));
        LaunchToken a = new LaunchToken();
        LaunchToken b = new LaunchToken();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token = tokenIsCurrency0() ? token0 : token1;
        buyDirection = !tokenIsCurrency0();
        hook = deployHook(manager, IERC20(address(token)));
        actions = new PoolActions(manager);
        preview = new PreviewHarness();
        token0.transfer(address(actions), 900_000_000 ether);
        token1.transfer(address(actions), 900_000_000 ether);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        manager.initialize(key, Q96);
        addLiquidity(key, -887220, 887220, LIQUIDITY);
    }

    // Real CREATE2 deployment: no address-validation override or runtime-code relocation.
    function deployHook(IPoolManager m, IERC20 t) internal returns (LaunchGuardHook deployed) {
        bytes memory code = abi.encodePacked(type(LaunchGuardHook).creationCode, abi.encode(m, t));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 300_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) continue;
            deployed = new LaunchGuardHook{salt: salt}(m, t);
            assertEq(address(deployed), predicted);
            return deployed;
        }
        revert("no hook salt found");
    }

    function addLiquidity(PoolKey memory k, int24 lower, int24 upper, int256 amount) internal {
        actions.liquidity(k, ModifyLiquidityParams(lower, upper, amount, 0));
    }

    function params(bool isBuy, int256 amount) internal view returns (SwapParams memory) {
        bool direction = isBuy ? buyDirection : !buyDirection;
        return
            SwapParams(
                direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );
    }

    function amountOut(BalanceDelta delta, bool direction) internal pure returns (uint256) {
        int128 amount = direction ? delta.amount1() : delta.amount0();
        assertGe(amount, 0);
        return uint128(amount);
    }

    function buy(int256 amount) internal returns (uint256) {
        return amountOut(actions.swap(key, params(true, amount), ""), buyDirection);
    }

    function expectBuyLimit() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(LaunchGuardHook.BuyLimitExceeded.selector, CAP),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_initializationAndPermissions() public view {
        assertEq(hook.guardEndsAt(key.toId()), start + 24 hours);
        assertEq(hook.maxBuyAmount(), token.totalSupply() / 100);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.launchToken()), address(token));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.beforeSwap = true;
        assertEq(abi.encode(p), abi.encode(expected));
    }

    function test_callbacksRejectUnauthorizedCallers() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params(true, 1), "");
    }

    function test_beforeSwapReturnsSelectorAndNoDeltasOrFee() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(123), key, params(true, 1), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_beforeSwapGas() public {
        SwapParams memory p = params(true, -int256(CAP / 2));
        vm.prank(address(manager));
        uint256 gasBefore = gasleft();
        hook.beforeSwap(address(this), key, p, "");
        emit log_named_uint("beforeSwap exact-input buy gas (single active range)", gasBefore - gasleft());
    }

    function test_noOwnerPauseUpgradeOrRuntimeEscapeHatches() public {
        bytes[4] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("transferOwnership(address)", address(this))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
        bytes memory code = address(hook).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            }
        }
    }

    function test_initializationRejectsPoolWithoutLaunchToken() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(1));
        bad.currency1 = Currency.wrap(address(2));
        vm.prank(address(manager));
        vm.expectRevert(LaunchGuardHook.InvalidPool.selector);
        hook.beforeInitialize(address(this), bad, Q96);
    }

    function test_timerCannotBeReset() public {
        vm.warp(start + 12 hours);
        vm.prank(address(manager));
        vm.expectRevert(LaunchGuardHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        assertEq(hook.guardEndsAt(key.toId()), start + 24 hours);
    }

    function test_failedInitializationRollsBackTimer() public {
        PoolKey memory other = key;
        other.fee = 500;
        vm.expectRevert();
        manager.initialize(other, 0);
        assertEq(hook.guardEndsAt(other.toId()), 0);
    }

    function test_uninitializedPoolCannotSkipGuard() public {
        PoolKey memory other = key;
        other.fee = 500;
        vm.prank(address(manager));
        vm.expectRevert(LaunchGuardHook.PoolNotInitialized.selector);
        hook.beforeSwap(address(this), other, params(true, int256(CAP * 2)), "");
    }

    function test_initializationAtTimestampZero() public {
        vm.warp(0);
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, Q96);
        assertEq(hook.guardEndsAt(other.toId()), 24 hours);
    }

    function test_differentPoolsHaveIndependentTimers() public {
        vm.warp(start + 24 hours);
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, Q96);
        addLiquidity(other, -887220, 887220, LIQUIDITY);
        assertEq(hook.guardEndsAt(other.toId()), start + 48 hours);
        assertEq(buy(int256(CAP * 2)), CAP * 2);
        expectBuyLimit();
        actions.swap(other, params(true, int256(CAP * 2)), "");
    }

    function test_exactOutputAtCapAllowed() public {
        assertEq(buy(int256(CAP)), CAP);
    }

    function test_exactOutputOneUnitOverCapRejectedBeforeSwap() public {
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.BuyLimitExceeded.selector, CAP));
        hook.beforeSwap(address(this), key, params(true, int256(CAP + 1)), "");
        expectBuyLimit();
        buy(int256(CAP + 1));
    }

    function test_exactInputSmallBuyAllowed() public {
        uint256 bought = buy(-int256(CAP / 2));
        assertGt(bought, 0);
        assertLt(bought, CAP);
    }

    function test_exactInputLargeBuyRejectedBeforeSwap() public {
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.BuyLimitExceeded.selector, CAP));
        hook.beforeSwap(address(this), key, params(true, -int256(CAP * 2)), "");
        expectBuyLimit();
        buy(-int256(CAP * 2));
    }

    function test_sellsAboveCapAllowedForBothSwapTypes() public {
        BalanceDelta exactInput = actions.swap(key, params(false, -int256(CAP * 2)), "");
        assertGt(amountOut(exactInput, !buyDirection), CAP);
        BalanceDelta exactOutput = actions.swap(key, params(false, int256(CAP * 2)), "");
        assertEq(amountOut(exactOutput, !buyDirection), CAP * 2);
    }

    function test_finalSecondGuarded() public {
        vm.warp(start + 24 hours - 1);
        expectBuyLimit();
        buy(int256(CAP + 1));
    }

    function test_exactDeadlineAllowsLargeBuys() public {
        vm.warp(start + 24 hours);
        assertEq(buy(int256(CAP * 2)), CAP * 2);
        assertGt(buy(-int256(CAP * 4)), CAP);
    }

    function test_longAfterDeadlineAllowsBothDirections() public {
        vm.warp(start + 365 days);
        assertEq(buy(int256(CAP * 2)), CAP * 2);
        assertGt(amountOut(actions.swap(key, params(false, -int256(CAP * 4)), ""), !buyDirection), CAP);
    }

    function test_limitIsPerSwapNotPerWallet() public {
        assertEq(buy(int256(CAP)), CAP);
        assertEq(buy(int256(CAP)), CAP);
    }

    function test_hookDataCannotBypassCap() public {
        expectBuyLimit();
        actions.swap(key, params(true, -int256(CAP * 2)), abi.encode(address(this), uint256(0), false));
    }

    function test_rejectedSwapLeavesBalancesAndPoolUnchanged() public {
        uint256 before0 = token0.balanceOf(address(actions));
        uint256 before1 = token1.balanceOf(address(actions));
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        expectBuyLimit();
        buy(-int256(CAP * 2));
        assertEq(token0.balanceOf(address(actions)), before0);
        assertEq(token1.balanceOf(address(actions)), before1);
        (uint160 priceAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, price);
        assertEq(tickAfter, tick);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_largeRequestWithSmallPartialFillAllowed() public {
        SwapParams memory p = params(true, int256(CAP * 10));
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(buyDirection ? int24(-60) : int24(60));
        uint256 bought = amountOut(actions.swap(key, p, ""), buyDirection);
        assertGt(bought, 0);
        assertLt(bought, CAP);
        p.amountSpecified = -int256(CAP * 10);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(buyDirection ? int24(-120) : int24(120));
        bought = amountOut(actions.swap(key, p, ""), buyDirection);
        assertGt(bought, 0);
        assertLt(bought, CAP);
    }

    function test_inputUnitsAreNotComparedToLaunchTokenCap() public {
        PoolKey memory other = key;
        other.fee = 500;
        // In either ordering, one input unit buys roughly one quarter of a launch token.
        manager.initialize(other, buyDirection ? Q96 / 2 : Q96 * 2);
        addLiquidity(other, -887220, 887220, LIQUIDITY);
        uint256 bought = amountOut(actions.swap(other, params(true, -int256(CAP * 2)), ""), buyDirection);
        assertGt(bought, 0);
        assertLt(bought, CAP);
    }

    function test_smallInputCanExceedOutputCap() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, buyDirection ? Q96 * 2 : Q96 / 2);
        addLiquidity(other, -887220, 887220, LIQUIDITY);
        expectBuyLimit();
        actions.swap(other, params(true, -int256(CAP / 2)), "");
    }

    function test_liquidityCanBeRemovedDuringGuard() public {
        uint256 beforeBalance = token.balanceOf(address(actions));
        addLiquidity(key, -887220, 887220, -LIQUIDITY);
        assertGt(token.balanceOf(address(actions)), beforeBalance);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function test_emptyLiquidityProducesNoBuy() public {
        addLiquidity(key, -887220, 887220, -LIQUIDITY);
        assertEq(buy(-int256(CAP * 2)), 0);
    }

    function test_liquidityGapAndNegativeTickTraversal() public {
        addLiquidity(key, -887220, 887220, -LIQUIDITY);
        addLiquidity(key, -600, -240, LIQUIDITY);
        addLiquidity(key, 240, 600, LIQUIDITY);
        SwapParams memory p = params(true, -int256(CAP));
        uint256 quoted = preview.output(manager, key, p);
        uint256 actual = amountOut(actions.swap(key, p, ""), buyDirection);
        assertEq(actual, quoted);
        assertGt(actual, 0);
        assertLt(actual, CAP);
    }

    function test_fullFeeExactInputHasZeroOutput() public {
        PoolKey memory other = key;
        other.fee = 1_000_000;
        manager.initialize(other, Q96);
        addLiquidity(other, -887220, 887220, LIQUIDITY);
        SwapParams memory p = params(true, -int256(CAP * 2));
        assertEq(preview.output(manager, other, p), 0);
        assertEq(amountOut(actions.swap(other, p, ""), buyDirection), 0);
    }

    function test_nativeCurrencyPair() public {
        PoolKey memory nativeKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, hook);
        vm.deal(address(actions), 200_000_000 ether);
        manager.initialize(nativeKey, Q96);
        addLiquidity(nativeKey, -887220, 887220, LIQUIDITY);
        SwapParams memory p = SwapParams(true, -int256(CAP / 2), TickMath.MIN_SQRT_PRICE + 1);
        assertGt(amountOut(actions.swap(nativeKey, p, ""), true), 0);
        p.amountSpecified = -int256(CAP * 2);
        expectBuyLimit();
        actions.swap(nativeKey, p, "");
    }

    function testFuzz_exactOutputCap(uint96 requested, uint32 elapsed) public {
        uint256 amount = bound(requested, 1, CAP * 3);
        vm.warp(start + bound(elapsed, 0, 48 hours));
        if (amount > CAP && block.timestamp < start + 24 hours) {
            expectBuyLimit();
            buy(int256(amount));
        } else {
            assertEq(buy(int256(amount)), amount);
        }
    }

    function testFuzz_previewMatchesRealSwapsAcrossTicks(
        uint96 rawAmount,
        bool direction,
        bool exactInput,
        uint16 fee0,
        uint16 fee1,
        uint16 distance
    ) public {
        addLiquidity(key, -120, 120, LIQUIDITY * 2);
        addLiquidity(key, -600, -240, LIQUIDITY);
        addLiquidity(key, 240, 600, LIQUIDITY);
        PoolManager(address(manager)).setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(bound(fee0, 0, 1000)) | (uint24(bound(fee1, 0, 1000)) << 12));
        uint256 amount = bound(rawAmount, 1, CAP * 4);
        int24 tickLimit = int24(int256(bound(distance, 1, 20_000)));
        SwapParams memory p = SwapParams(
            direction,
            exactInput ? -int256(amount) : int256(amount),
            TickMath.getSqrtPriceAtTick(direction ? -tickLimit : tickLimit)
        );
        uint256 quoted = preview.output(manager, key, p);
        // Execute without guard so even oversized quotes can be compared to canonical Pool.swap.
        vm.warp(start + 24 hours);
        uint256 actual = amountOut(actions.swap(key, p, ""), direction);
        assertEq(quoted, actual, "preview diverged from PoolManager output");
    }

    function testFuzz_exactInputMatchesActualOutputDecision(uint96 rawAmount, uint16 distance) public {
        uint256 amount = bound(rawAmount, 1, CAP * 4);
        int24 tickLimit = int24(int256(bound(distance, 1, 10_000)));
        SwapParams memory p = params(true, -int256(amount));
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(buyDirection ? -tickLimit : tickLimit);
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 24 hours);
        uint256 actual = amountOut(actions.swap(key, p, ""), buyDirection);
        assertTrue(vm.revertToState(snapshot));
        if (actual > CAP) {
            expectBuyLimit();
            actions.swap(key, p, "");
        } else {
            assertEq(amountOut(actions.swap(key, p, ""), buyDirection), actual);
        }
    }
}

contract LaunchTokenIsCurrency0Test is LaunchGuardTestBase {
    function tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract LaunchTokenIsCurrency1Test is LaunchGuardTestBase {
    function tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
