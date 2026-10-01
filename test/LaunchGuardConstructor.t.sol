// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchGuardHook} from "src/LaunchGuardHook.sol";
import {LaunchToken} from "src/LaunchToken.sol";

// Only constructor supply boundaries use a stub; trading tests use LaunchToken.
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

    function test_constructorRejectsMissingTokenCode() public {
        _expectInvalid(manager, IERC20(address(0)));
        _expectInvalid(manager, IERC20(address(0xBEEF)));
    }

    function test_constructorRejectsZeroAndSubHundredSupply() public {
        _expectInvalid(manager, IERC20(address(new FixedSupplyStub(0))));
        _expectInvalid(manager, IERC20(address(new FixedSupplyStub(1))));
        _expectInvalid(manager, IERC20(address(new FixedSupplyStub(99))));
    }

    function test_constructorFloorsOnePercentInTokenMinorUnits() public {
        uint256[4] memory supplies = [uint256(100), 199, 200, type(uint256).max];
        for (uint256 i; i < supplies.length; ++i) {
            IERC20 stub = IERC20(address(new FixedSupplyStub(supplies[i])));
            (bytes32 salt,) = _salt(manager, stub, true);
            LaunchGuardHook deployed = factory.deploy(manager, stub, salt);
            assertEq(deployed.maxBuyAmount(), supplies[i] / 100);
            assertEq(address(deployed.launchToken()), address(stub));
            assertEq(address(deployed.poolManager()), address(manager));
        }
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
