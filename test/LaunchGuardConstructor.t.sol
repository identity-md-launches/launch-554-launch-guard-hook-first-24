// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchGuardHook} from "src/LaunchGuardHook.sol";
import {LaunchToken} from "src/LaunchToken.sol";

// Only initialization supply boundaries use a stub; trading tests use LaunchToken.
contract FixedSupplyStub {
    uint256 public immutable totalSupply;

    constructor(uint256 supply) {
        totalSupply = supply;
    }
}

contract HookConstructorFactory {
    function deploy(IPoolManager manager, IERC20 token, bytes32 salt) external returns (LaunchGuardHook) {
        return new LaunchGuardHook{salt: salt}(manager, token);
    }
}

contract LaunchGuardConstructorTest is Test {
    HookConstructorFactory internal factory;
    IPoolManager internal manager;
    IERC20 internal token;
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    function setUp() public {
        factory = new HookConstructorFactory();
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = IERC20(address(new LaunchToken()));
    }

    function test_constructorRejectsMissingManagerCode() public {
        _expectInvalid(IPoolManager(address(0)), token);
        _expectInvalid(IPoolManager(address(0xBEEF)), token);
    }

    function test_constructorRejectsZeroTokenAddress() public {
        _expectInvalid(manager, IERC20(address(0)));
    }

    function test_initializationRejectsMissingTokenCode() public {
        _expectInvalidInitialization(IERC20(address(0xBEEF)));
    }

    function test_initializationRejectsZeroAndSubHundredSupply() public {
        _expectInvalidInitialization(IERC20(address(new FixedSupplyStub(0))));
        _expectInvalidInitialization(IERC20(address(new FixedSupplyStub(1))));
        _expectInvalidInitialization(IERC20(address(new FixedSupplyStub(99))));
    }

    function test_initializationFloorsOnePercentInTokenMinorUnits() public {
        uint256[4] memory supplies = [uint256(100), 199, 200, type(uint256).max];
        for (uint256 i; i < supplies.length; ++i) {
            IERC20 stub = IERC20(address(new FixedSupplyStub(supplies[i])));
            (bytes32 salt,) = _salt(manager, stub, true);
            LaunchGuardHook deployed = factory.deploy(manager, stub, salt);
            assertEq(deployed.maxBuyAmount(), 0);
            PoolKey memory key = _key(deployed, stub);
            assertEq(deployed.guardEndsAt(key.toId()), 0);
            manager.initialize(key, 1 << 96);
            assertEq(deployed.maxBuyAmount(), supplies[i] / 100);
            assertEq(deployed.guardEndsAt(key.toId()), block.timestamp + 24 hours);
            assertEq(address(deployed.launchToken()), address(stub));
            assertEq(address(deployed.poolManager()), address(manager));
        }
    }

    function test_revertingSupplyReadIsDeferredAndInitializationCanRetry() public {
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.totalSupply, ()), hex"deadbeef");
        (bytes32 salt,) = _salt(manager, token, true);
        LaunchGuardHook deployed = factory.deploy(manager, token, salt);
        PoolKey memory key = _key(deployed, token);
        assertEq(deployed.maxBuyAmount(), 0);

        _expectInitializationError(deployed, hex"deadbeef");
        manager.initialize(key, 1 << 96);
        assertEq(deployed.maxBuyAmount(), 0);
        assertEq(deployed.guardEndsAt(key.toId()), 0);

        vm.clearMockedCalls();
        uint256 initializedAt = vm.getBlockTimestamp() + 2 days;
        vm.warp(initializedAt);
        manager.initialize(key, 1 << 96);
        assertEq(deployed.maxBuyAmount(), token.totalSupply() / 100);
        assertEq(deployed.guardEndsAt(key.toId()), initializedAt + 24 hours);
    }

    function test_constructorRejectsIncorrectAddressPermissions() public {
        (bytes32 salt, address predicted) = _salt(manager, token, false);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        factory.deploy(manager, token, salt);
        assertEq(predicted.code.length, 0);
    }

    function _expectInvalid(IPoolManager m, IERC20 t) internal {
        // Mine correct flags first so address validation cannot mask the intended error.
        (bytes32 salt, address predicted) = _salt(m, t, true);
        vm.expectRevert(LaunchGuardHook.InvalidConfiguration.selector);
        factory.deploy(m, t, salt);
        assertEq(predicted.code.length, 0);
    }

    function _expectInvalidInitialization(IERC20 t) internal {
        (bytes32 salt,) = _salt(manager, t, true);
        LaunchGuardHook deployed = factory.deploy(manager, t, salt);
        PoolKey memory key = _key(deployed, t);
        assertEq(deployed.maxBuyAmount(), 0);
        _expectInitializationError(
            deployed, abi.encodeWithSelector(LaunchGuardHook.InvalidConfiguration.selector)
        );
        manager.initialize(key, 1 << 96);
        assertEq(deployed.maxBuyAmount(), 0);
        assertEq(deployed.guardEndsAt(key.toId()), 0);
    }

    function _expectInitializationError(LaunchGuardHook deployed, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(deployed),
                IHooks.beforeInitialize.selector,
                reason,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _key(LaunchGuardHook deployed, IERC20 t) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), 3000, 60, deployed);
    }

    function _salt(IPoolManager m, IERC20 t, bool valid) internal view returns (bytes32, address) {
        bytes32 hash = keccak256(abi.encodePacked(type(LaunchGuardHook).creationCode, abi.encode(m, t)));
        for (uint256 i; i < 300_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), bytes32(i), hash))))
            );
            if (((uint160(predicted) & Hooks.ALL_HOOK_MASK) == FLAGS) == valid) {
                return (bytes32(i), predicted);
            }
        }
        revert("salt search exhausted");
    }
}
