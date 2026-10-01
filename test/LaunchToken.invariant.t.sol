// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract TokenSequenceHandler is Test {
    LaunchToken public immutable token;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xD00D)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new LaunchToken();
        for (uint256 i; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / actors.length);
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        // Keep the full uint256 allowance domain, including infinite approval.
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 rawAmount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 amount = bound(rawAmount, 0, allowance < available ? allowance : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectOverspend(uint8 seed, bool delegated) external {
        address owner = actors[seed % 4];
        address spender = actors[(uint256(seed) + 1) % 4];
        uint256 balance = expectedBalance[owner];
        if (delegated) {
            vm.prank(owner);
            assertTrue(token.approve(spender, balance + 1));
            expectedAllowance[owner][spender] = balance + 1;
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1
            )
        );
        vm.prank(delegated ? spender : owner);
        if (delegated) token.transferFrom(owner, spender, balance + 1);
        else token.transfer(spender, balance + 1);
        // The invariants also check that a failed transferFrom restores the spent allowance.
    }

    function rejectRevokedAllowance(uint8 seed) external {
        address owner = actors[seed % 4];
        address spender = actors[(uint256(seed) + 1) % 4];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, spender, 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    TokenSequenceHandler internal handler;
    LaunchToken internal token;

    function setUp() public {
        handler = new TokenSequenceHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.rejectRevokedAllowance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesAndAllowancesMatchIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            sum += balance;
            assertEq(balance, handler.expectedBalance(actor), "unexpected balance change");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(actor, spender));
            }
        }
        assertEq(sum, 1_000_000_000 ether, "tokens created or lost");
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_sequenceFullBalanceSelfTransferAndInfiniteApproval() public {
        handler.transfer(0, 0, 250_000_000 ether);
        handler.approve(0, 1, type(uint256).max);
        handler.transferFrom(0, 1, 2, 250_000_000 ether);
        invariant_balancesAndAllowancesMatchIndependentLedger();
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), type(uint256).max);
        assertEq(token.balanceOf(handler.actors(0)), 0);
        handler.transferFrom(0, 1, 0, 0);
        handler.rejectOverspend(2, true);
        invariant_balancesAndAllowancesMatchIndependentLedger();
        handler.rejectRevokedAllowance(0);
        invariant_balancesAndAllowancesMatchIndependentLedger();
    }
}
