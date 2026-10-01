// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyMetadataAndDeployerAllocation() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Launch Guard");
        assertEq(token.symbol(), "GUARD");
    }

    function testFuzz_transferConservesSupply(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(address(0xCAFE), amount));
        assertEq(token.balanceOf(address(0xCAFE)), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowanceAndTransferFrom() public {
        token.approve(address(0xBEEF), 100);
        vm.prank(address(0xBEEF));
        assertTrue(token.transferFrom(address(this), address(0xCAFE), 60));
        assertEq(token.allowance(address(this), address(0xBEEF)), 40);
        assertEq(token.balanceOf(address(0xCAFE)), 60);
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(0xBEEF), 40, 41)
        );
        token.transferFrom(address(this), address(0xCAFE), 41);
    }

    function test_transferFailures() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(address(0xCAFE));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(0xCAFE), 0, 1)
        );
        token.transfer(address(this), 1);
    }

    function test_noMintOwnerPauseOrUpgradeEntryPoints() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", address(this), 1),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoEscapeHatches() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            }
        }
    }
}
