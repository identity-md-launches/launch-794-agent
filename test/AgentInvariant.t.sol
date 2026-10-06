// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Agent} from "../src/Agent.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentTestSupport} from "./helpers/AgentTestSupport.sol";

/// @dev Four actors (including the deployer) can send and approve. The token itself is an
/// additional recipient, but is never impersonated to spend tokens it cannot actually move.
contract AgentHandler is AgentTestSupport {
    Agent public immutable token;
    address[4] public actors;
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public successfulTransfers;
    uint256 public successfulSpends;
    uint256 public rejectedCalls;

    constructor() {
        token = new Agent();
        actors = [address(this), address(0xA11CE), address(0xB0B), address(0xCA401)];
        eq(token.totalSupply(), SUPPLY, "constructor supply");
        eq(token.balanceOf(address(this)), SUPPLY, "constructor allocation");
        for (uint256 i = 1; i < actors.length; ++i) {
            _transfer(address(this), actors[i], SUPPLY / 4);
        }
        // Both finite and infinite permissions are reachable from the first random call.
        for (uint256 i; i < actors.length; ++i) {
            _approve(actors[i], actors[(i + 1) % actors.length], SUPPLY / 8);
            _approve(actors[i], actors[(i + 2) % actors.length], type(uint256).max);
        }
    }

    /// @dev Independent cash-flow ledger; never copies a balance returned by the token.
    function expectedBalance(address account) public view returns (uint256) {
        uint256 initial = account == address(this) ? SUPPLY : 0;
        return initial + received[account] - sent[account];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _recipient(toSeed), _amount(amountSeed, expectedBalance(from)));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 amount = amountSeed;
        uint256 edge = amountSeed % 6;
        if (edge == 0) amount = 0;
        else if (edge == 1) amount = 1;
        else if (edge == 2) amount = type(uint256).max;
        else if (edge == 3) amount = type(uint256).max - 1;
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance(owner);
        uint256 amount = _amount(amountSeed, balance < allowance ? balance : allowance);
        vm.prank(spender);
        address to = _recipient(toSeed);
        require(token.transferFrom(owner, to, amount), "valid delegated transfer returned false");
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] = allowance - amount;
        _recordTransfer(owner, to, amount);
        ++successfulSpends;
    }

    function roundTrip(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 amount = _amount(amountSeed, expectedBalance(from));
        _transfer(from, to, amount);
        _transfer(to, from, amount);
        eq(token.balanceOf(from), beforeFrom, "round trip changed sender balance");
        eq(token.balanceOf(to), beforeTo, "round trip changed receiver balance");
    }

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance(from);
        uint256 amount = balance + bound(excessSeed, 1, type(uint256).max - balance);
        _mustRevert(
            from,
            abi.encodeCall(token.transfer, (_recipient(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
        );
    }

    function transferFromOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 excessSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance(owner);
        uint256 amount = balance + bound(excessSeed, 1, type(uint256).max - balance);
        _approve(owner, spender, amount);
        // A balance failure must roll back even the allowance spent earlier in transferFrom.
        _mustRevert(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
    }

    function spendOverAllowance(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        if (allowance == type(uint256).max) {
            // Revoking an unlimited approval must prevent the very next spend.
            _approve(owner, spender, 0);
            allowance = 0;
        }
        _mustRevert(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, allowance + 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1)
        );
    }

    function zeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = expectedBalance(owner);
        uint256 allowance = expectedAllowance[owner][spender];
        if (delegated && allowance < limit) limit = allowance;
        uint256 amount = _amount(amountSeed, limit);
        _mustRevert(
            delegated ? spender : owner,
            delegated
                ? abi.encodeCall(token.transferFrom, (owner, address(0), amount))
                : abi.encodeCall(token.transfer, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = seed % (actors.length + 1);
        return index == actors.length ? address(token) : actors[index];
    }

    /// @dev Bias valid operations to zero, one base unit, full balance, and arbitrary amounts.
    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return maximum == 0 ? 0 : 1;
        if (seed % 4 == 2) return maximum;
        return bound(seed, 0, maximum);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        require(token.approve(spender, amount), "valid approval returned false");
        expectedAllowance[owner][spender] = amount;
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        require(token.transfer(to, amount), "valid transfer returned false");
        _recordTransfer(from, to, amount);
        ++successfulTransfers;
    }

    function _recordTransfer(address from, address to, uint256 amount) private {
        sent[from] += amount;
        received[to] += amount;
    }

    function _mustRevert(address caller, bytes memory data, bytes memory expectedError) private {
        vm.prank(caller);
        (bool success, bytes memory reason) = address(token).call(data);
        require(!success, "invalid operation succeeded");
        require(keccak256(reason) == keccak256(expectedError), "unexpected failure reason");
        // The global invariants compare all balances and allowances with the unchanged ledger.
        ++rejectedCalls;
    }
}

/// @dev Only the handler is targeted: every mutation must be represented in its ghost ledger.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract AgentInvariantTest is AgentTestSupport {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    AgentHandler private handler;
    Agent private token;

    function setUp() public {
        handler = new AgentHandler();
        token = handler.token();
    }

    // Foundry's targeting interface, with no dependency on forge-std's wrapper.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = AgentHandler.transfer.selector;
        selectors[1] = AgentHandler.approve.selector;
        selectors[2] = AgentHandler.transferFrom.selector;
        selectors[3] = AgentHandler.roundTrip.selector;
        selectors[4] = AgentHandler.transferOverBalance.selector;
        selectors[5] = AgentHandler.transferFromOverBalance.selector;
        selectors[6] = AgentHandler.spendOverAllowance.selector;
        selectors[7] = AgentHandler.zeroRecipient.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    /// @notice The specified one-time mint is conserved, including tokens sent to the token itself.
    function invariant_FixedSupplyAndBalanceConservation() public view {
        eq(token.totalSupply(), SUPPLY, "fixed supply changed");
        uint256 sum = token.balanceOf(address(token));
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        eq(sum, SUPPLY, "tokens created, destroyed, or credited outside tracked recipients");
        eq(token.balanceOf(address(0)), 0, "zero address acquired tokens");
    }

    /// @notice Conservation alone cannot detect theft between holders; every holder must be correct.
    function invariant_BalancesMatchAuthorizedCashFlows() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            eq(token.balanceOf(actor), handler.expectedBalance(actor), "holder cash-flow mismatch");
        }
        eq(token.balanceOf(address(token)), handler.expectedBalance(address(token)), "token recipient mismatch");
    }

    /// @notice Approvals replace/revoke permissions, finite spends consume them, and failures roll back.
    function invariant_AllowancesMatchOwnerPermissions() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                eq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender), "allowance mismatch");
            }
            eq(token.allowance(owner, address(0)), 0, "zero spender allowance");
        }
    }

    /// @dev A pinned sequence ensures positive transfers, revocation, and every failure handler
    /// execute meaningfully even if a particular randomized sequence mostly picks empty accounts.
    function test_HandlerSequenceExercisesSuccessesAndFailures() public {
        handler.transfer(0, 1, 1);
        _checkAll();
        handler.approve(1, 2, 2); // Unlimited permission.
        handler.transferFrom(1, 2, 3, 1);
        _checkAll();
        handler.roundTrip(3, 0, 2); // Full-balance round trip.
        _checkAll();
        handler.transferOverBalance(0, 1, type(uint256).max);
        _checkAll();
        handler.transferFromOverBalance(1, 2, 1);
        _checkAll();
        handler.spendOverAllowance(1, 2);
        _checkAll();
        handler.zeroRecipient(2, 3, 1, false);
        _checkAll();
        handler.zeroRecipient(2, 3, 1, true);
        _checkAll();
        handler.approve(1, 2, 0);
        handler.spendOverAllowance(1, 2);
        _checkAll();
        handler.transfer(3, 4, 1); // Include a real token-contract recipient in conservation.
        _checkAll();
        eq(token.balanceOf(address(token)), 1, "token recipient was not exercised");
        eq(handler.successfulSpends(), 1, "no delegated transfer exercised");
        eq(handler.rejectedCalls(), 6, "failure handlers were not exercised");
        require(handler.successfulTransfers() > 3, "only setup transfers executed");
    }

    function _checkAll() private view {
        invariant_FixedSupplyAndBalanceConservation();
        invariant_BalancesMatchAuthorizedCashFlows();
        invariant_AllowancesMatchOwnerPermissions();
    }
}
