// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Agent (AGENT)
/// @notice Fixed-supply ERC-20 with 18 decimals and no administrative privileges.
contract Agent is ERC20 {
    /// @notice One billion AGENT, expressed in the smallest token units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire supply to the caller deploying this contract.
    /// @dev When deployed by a factory, the factory receives the supply.
    constructor() ERC20("Agent", "AGENT") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
