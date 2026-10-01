// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply launch token; all tokens belong to its deployer at creation.
contract LaunchToken is ERC20 {
    constructor() ERC20("Launch Guard", "GUARD") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
