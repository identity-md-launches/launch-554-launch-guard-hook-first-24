// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchGuardHook} from "src/LaunchGuardHook.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {PoolActions} from "./helpers/PoolActions.sol";

contract GuardSequenceHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant CAP = 10_000_000 ether;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    IPoolManager public manager;
    LaunchGuardHook public hook;
    LaunchToken public token0;
    LaunchToken public token1;
    PoolActions public actions;
    PoolKey internal key;
    bool public buyDirection;
    uint256 public immutable deadline;
    uint256 public guardedBuys;
    uint256 public rejectedBuys;
    uint256 public expiredSwaps;
    uint256 public largestGuardedBuy;
    uint256[2] public expectedRouterBalance;
    uint256[4] public positionLiquidity;
    int24[4] internal lower = [int24(-887220), -1200, -600, 240];
    int24[4] internal upper = [int24(887220), 1200, -240, 600];

    constructor(bool launchIsCurrency0) {
        manager = IPoolManager(address(new PoolManager(address(this))));
        LaunchToken a = new LaunchToken();
        LaunchToken b = new LaunchToken();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        buyDirection = !launchIsCurrency0;
        IERC20 launch = IERC20(address(launchIsCurrency0 ? token0 : token1));
        bytes32 hash =
            keccak256(abi.encodePacked(type(LaunchGuardHook).creationCode, abi.encode(manager, launch)));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        for (uint256 salt; salt < 300_000; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), bytes32(salt), hash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != flags) continue;
            hook = new LaunchGuardHook{salt: bytes32(salt)}(manager, launch);
            break;
        }
        require(address(hook) != address(0), "salt search exhausted");
        actions = new PoolActions(manager);
        token0.transfer(address(actions), 900_000_000 ether);
        token1.transfer(address(actions), 900_000_000 ether);
        expectedRouterBalance = [uint256(900_000_000 ether), uint256(900_000_000 ether)];
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        manager.initialize(key, 1 << 96);
        deadline = block.timestamp + 24 hours;
        _setLiquidity(0, 100_000_000 ether);
        PoolManager(address(manager)).setProtocolFeeController(address(this));
    }

    function swap(uint96 rawAmount, uint16 rawDistance, bool direction, bool exactInput, bytes32 data)
        public
    {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        // Keep prices finite so the funded router can settle every generated trade.
        if (price == TickMath.getSqrtPriceAtTick(-4000)) direction = false;
        if (price == TickMath.getSqrtPriceAtTick(4000)) direction = true;
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int24 distance = int24(int256(bound(rawDistance, 1, 6000)));
        int24 limit = direction ? tick - distance : tick + distance;
        if (limit < -4000) limit = -4000;
        if (limit > 4000) limit = 4000;
        uint256 amount = bound(rawAmount, 1, CAP * 3);
        SwapParams memory p = SwapParams(
            direction, exactInput ? -int256(amount) : int256(amount), TickMath.getSqrtPriceAtTick(limit)
        );
        bytes memory hookData = abi.encode(data);
        uint256 now_ = vm.getBlockTimestamp();
        bytes32 beforeState = _stateDigest();
        uint256 snapshot = vm.snapshotState();
        if (now_ < deadline) vm.warp(deadline);
        // Independent oracle: execute canonical PoolManager math, never SwapPreview.
        BalanceDelta oracle = actions.swap(key, p, hookData);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertEq(vm.getBlockTimestamp(), now_);
        assertEq(_stateDigest(), beforeState, "oracle snapshot did not restore state");
        uint256 output = uint128(direction ? oracle.amount1() : oracle.amount0());
        bool guardedBuy = now_ < deadline && direction == buyDirection;
        if (guardedBuy && output > CAP) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(LaunchGuardHook.BuyLimitExceeded.selector, CAP),
                    abi.encodePacked(Hooks.HookCallFailed.selector)
                )
            );
            actions.swap(key, p, hookData);
            assertEq(_stateDigest(), beforeState, "rejected swap changed state");
            ++rejectedBuys;
        } else {
            BalanceDelta actual = actions.swap(key, p, hookData);
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(oracle), "guard changed execution");
            _account(actual);
            if (guardedBuy) {
                ++guardedBuys;
                if (output > largestGuardedBuy) largestGuardedBuy = output;
            }
            if (now_ >= deadline) ++expiredSwaps;
        }
    }

    function liquidity(uint8 position, uint96 rawLiquidity) external {
        _setLiquidity(position % 4, bound(rawLiquidity, 0, 100_000_000 ether));
    }

    function fees(uint16 fee0, uint16 fee1) external {
        manager.setProtocolFee(key, uint24(bound(fee0, 0, 1000)) | (uint24(bound(fee1, 0, 1000)) << 12));
    }

    function advanceTime(uint32 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 2 hours));
    }

    function assertState() external view {
        assertEq(hook.guardEndsAt(key.toId()), deadline, "timer was reset");
        assertEq(hook.maxBuyAmount(), CAP);
        assertLe(largestGuardedBuy, CAP);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 active;
        for (uint256 i; i < 4; ++i) {
            if (lower[i] <= tick && tick < upper[i]) active += positionLiquidity[i];
        }
        assertEq(manager.getLiquidity(key.toId()), active, "wrong active liquidity after crossing ticks");
        LaunchToken[2] memory tokens = [token0, token1];
        for (uint256 i; i < 2; ++i) {
            assertEq(tokens[i].balanceOf(address(actions)), expectedRouterBalance[i], "settlement mismatch");
            assertEq(tokens[i].balanceOf(address(manager)), 900_000_000 ether - expectedRouterBalance[i]);
            assertEq(tokens[i].balanceOf(address(this)), 100_000_000 ether);
            assertEq(tokens[i].balanceOf(address(hook)), 0, "hook took custody");
            assertEq(tokens[i].totalSupply(), SUPPLY);
        }
    }

    function _setLiquidity(uint256 i, uint256 next) internal {
        int256 change = int256(next) - int256(positionLiquidity[i]);
        // A zero poke on a never-created position is invalid in canonical PoolManager.
        if (change == 0) return;
        _account(actions.liquidity(key, ModifyLiquidityParams(lower[i], upper[i], change, bytes32(i))));
        positionLiquidity[i] = next;
    }

    function _account(BalanceDelta delta) internal {
        expectedRouterBalance[0] = uint256(int256(expectedRouterBalance[0]) + delta.amount0());
        expectedRouterBalance[1] = uint256(int256(expectedRouterBalance[1]) + delta.amount1());
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                manager.getLiquidity(key.toId()),
                manager.protocolFeesAccrued(key.currency0),
                manager.protocolFeesAccrued(key.currency1),
                token0.balanceOf(address(actions)),
                token1.balanceOf(address(actions)),
                token0.balanceOf(address(manager)),
                token1.balanceOf(address(manager)),
                hook.guardEndsAt(key.toId())
            )
        );
    }
}

abstract contract GuardInvariantBase is Test {
    GuardSequenceHandler internal handler;

    function launchIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_000_000);
        handler = new GuardSequenceHandler(launchIsCurrency0());
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.liquidity.selector;
        selectors[2] = handler.fees.selector;
        selectors[3] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_guardAndSettlementSurviveRandomSequences() public view {
        handler.assertState();
    }

    function test_sequenceExercisesBothDecisionsAndExpiry() public {
        handler.swap(1 ether, 4000, handler.buyDirection(), false, 0);
        handler.swap(20_000_000 ether, 4000, handler.buyDirection(), false, 0);
        handler.liquidity(1, 100_000_000 ether);
        handler.fees(1000, 999);
        handler.swap(1 ether, 4000, !handler.buyDirection(), true, 0);
        for (uint256 i; i < 12; ++i) {
            handler.advanceTime(2 hours);
        }
        handler.swap(20_000_000 ether, 4000, handler.buyDirection(), true, 0);
        assertGt(handler.guardedBuys(), 0);
        assertGt(handler.rejectedBuys(), 0);
        assertGt(handler.expiredSwaps(), 0);
        handler.assertState();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract GuardCurrency0InvariantTest is GuardInvariantBase {
    function launchIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract GuardCurrency1InvariantTest is GuardInvariantBase {
    function launchIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
