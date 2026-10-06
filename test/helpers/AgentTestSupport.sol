// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface AgentVm {
    function prank(address sender) external;
    function expectRevert(bytes calldata reason) external;
}

/// @dev Uses only built-in cheatcodes, so the suite also runs without network dependencies.
abstract contract AgentTestSupport {
    AgentVm internal constant vm = AgentVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @dev Inclusive bounds preserve in-range inputs and never discard a fuzz case.
    function bound(uint256 value, uint256 minimum, uint256 maximum) internal pure returns (uint256) {
        require(minimum <= maximum, "invalid test bounds");
        if (value >= minimum && value <= maximum) return value;
        return minimum + value % (maximum - minimum + 1);
    }

    function eq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }
}
