// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Agent} from "../src/Agent.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentTestSupport} from "./helpers/AgentTestSupport.sol";

/// forge-config: default.fuzz.runs = 1000
contract AgentEdgeCasesTest is AgentTestSupport {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    Agent private token;

    function setUp() public {
        token = new Agent();
    }

    function test_OneBaseUnitCanMakeARoundTrip() public {
        require(token.transfer(ALICE, 1), "one-unit transfer");
        eq(token.balanceOf(ALICE), 1, "one unit was rounded away");
        eq(token.balanceOf(address(this)), SUPPLY - 1, "one-unit debit");
        vm.prank(ALICE);
        require(token.transfer(address(this), 1), "one-unit return");
        eq(token.balanceOf(ALICE), 0, "round-trip residue");
        eq(token.balanceOf(address(this)), SUPPLY, "round-trip loss");
        eq(token.totalSupply(), SUPPLY, "round-trip supply");
    }

    function test_MaxUintTransferFailsWithBalanceError() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        eq(token.balanceOf(address(this)), SUPPLY, "failed transfer debited deployer");
        eq(token.balanceOf(ALICE), 0, "failed transfer credited recipient");
        eq(token.totalSupply(), SUPPLY, "failed transfer changed supply");
    }

    function test_MaxUintDelegatedTransferPreservesInfiniteAllowanceOnFailure() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        eq(token.allowance(address(this), SPENDER), type(uint256).max, "infinite allowance changed");
        eq(token.balanceOf(address(this)), SUPPLY, "failed delegated debit");
        eq(token.balanceOf(ALICE), 0, "failed delegated credit");
        eq(token.totalSupply(), SUPPLY, "failed delegated supply");
    }

    function test_LargestFiniteAllowanceDecrementsByOne() public {
        token.approve(SPENDER, type(uint256).max - 1);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 1), "finite spend");
        eq(token.allowance(address(this), SPENDER), type(uint256).max - 2, "finite allowance treated as infinite");
        eq(token.balanceOf(ALICE), 1, "finite spend credit");
        eq(token.balanceOf(address(this)), SUPPLY - 1, "finite spend debit");
    }

    function test_InfiniteApprovalCannotSpendOneUnitAfterFullBalance() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, SUPPLY), "full-supply delegated transfer");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 1);
        eq(token.balanceOf(address(this)), 0, "empty owner changed");
        eq(token.balanceOf(ALICE), SUPPLY, "full-supply recipient changed");
        eq(token.balanceOf(BOB), 0, "empty balance spent");
        eq(token.allowance(address(this), SPENDER), type(uint256).max, "infinite approval consumed");
        eq(token.totalSupply(), SUPPLY, "full-supply delegated supply");
    }

    function test_RevokingInfiniteApprovalBlocksTheNextSpend() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        token.approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        eq(token.allowance(address(this), SPENDER), 0, "revocation did not persist");
        eq(token.balanceOf(ALICE), 1, "revoked spender received tokens");
        eq(token.balanceOf(address(this)), SUPPLY - 1, "revoked spender moved owner funds");
    }

    function test_ZeroApprovalStillRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        eq(token.allowance(address(this), address(0)), 0, "zero spender acquired permission");
        eq(token.balanceOf(address(this)), SUPPLY, "invalid approval moved funds");
    }

    function test_ZeroDelegatedTransferStillRejectsZeroRecipient() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 0);
        eq(token.allowance(address(this), SPENDER), type(uint256).max, "invalid zero transfer changed allowance");
        eq(token.balanceOf(address(this)), SUPPLY, "invalid zero transfer changed balance");
        eq(token.balanceOf(address(0)), 0, "invalid zero recipient acquired tokens");
        eq(token.totalSupply(), SUPPLY, "invalid zero transfer changed supply");
    }

    function testFuzz_InsufficientAllowanceIsAtomicDespiteSufficientBalance(
        uint256 balance,
        uint256 allowance,
        uint256 amount
    ) public {
        balance = bound(balance, 1, SUPPLY);
        allowance = bound(allowance, 0, balance - 1);
        amount = bound(amount, allowance + 1, balance);
        token.transfer(ALICE, balance);
        vm.prank(ALICE);
        token.approve(SPENDER, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, allowance, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        eq(token.balanceOf(ALICE), balance, "allowance failure debited owner");
        eq(token.balanceOf(BOB), 0, "allowance failure credited recipient");
        eq(token.balanceOf(address(this)), SUPPLY - balance, "allowance failure moved unrelated funds");
        eq(token.allowance(ALICE, SPENDER), allowance, "allowance failure changed permission");
        eq(token.totalSupply(), SUPPLY, "allowance failure changed supply");
    }

    function testFuzz_InsufficientBalanceRestoresFiniteAllowance(uint256 balance, uint256 allowance) public {
        balance = bound(balance, 0, SUPPLY);
        allowance = bound(allowance, balance + 1, type(uint256).max - 1);
        token.transfer(ALICE, balance);
        vm.prank(ALICE);
        token.approve(SPENDER, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, allowance)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, allowance);
        eq(token.allowance(ALICE, SPENDER), allowance, "balance failure consumed finite allowance");
        eq(token.balanceOf(ALICE), balance, "balance failure debited owner");
        eq(token.balanceOf(BOB), 0, "balance failure credited recipient");
        eq(token.balanceOf(address(this)), SUPPLY - balance, "balance failure moved unrelated funds");
        eq(token.totalSupply(), SUPPLY, "balance failure changed supply");
    }

    function testFuzz_ApprovalsAreIsolatedByOwnerAndSpender(uint256 approval, uint256 replacement) public {
        token.transfer(ALICE, 1);
        token.approve(SPENDER, approval);
        token.approve(BOB, 23);
        vm.prank(ALICE);
        token.approve(SPENDER, 17);
        token.approve(SPENDER, replacement);
        eq(token.allowance(address(this), SPENDER), replacement, "approval was added instead of replaced");
        eq(token.allowance(address(this), BOB), 23, "another spender's allowance changed");
        eq(token.allowance(ALICE, SPENDER), 17, "another owner's allowance changed");
        eq(token.allowance(SPENDER, address(this)), 0, "approval granted reverse permission");
        eq(token.balanceOf(address(this)), SUPPLY - 1, "approval debited owner");
        eq(token.balanceOf(ALICE), 1, "approval changed unrelated balance");
        eq(token.balanceOf(SPENDER), 0, "approval moved funds to spender");
        eq(token.balanceOf(BOB), 0, "approval moved funds to another spender");
        eq(token.totalSupply(), SUPPLY, "approval changed supply");
    }

    function testFuzz_NearMaximumFiniteAllowancesAreConsumed(uint256 distance, uint256 amount) public {
        distance = bound(distance, 1, SUPPLY);
        amount = bound(amount, 1, SUPPLY);
        uint256 allowance = type(uint256).max - distance;
        token.approve(SPENDER, allowance);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, amount), "large finite allowance spend");
        eq(token.allowance(address(this), SPENDER), allowance - amount, "large finite allowance not consumed");
        eq(token.balanceOf(ALICE), amount, "large finite allowance credit");
        eq(token.balanceOf(address(this)), SUPPLY - amount, "large finite allowance debit");
        eq(token.totalSupply(), SUPPLY, "large allowance changed supply");
    }

    /// @dev Metamorphic property: splitting an allowed payment must equal sending it in one call.
    function testFuzz_SplitDelegatedPaymentEqualsSinglePayment(uint256 total, uint256 first) public {
        total = bound(total, 1, SUPPLY);
        first = bound(first, 0, total);
        Agent single = new Agent();
        token.approve(SPENDER, total);
        single.approve(SPENDER, total);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, first), "first payment");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, total - first), "second payment");
        vm.prank(SPENDER);
        require(single.transferFrom(address(this), ALICE, total), "single payment");
        eq(token.balanceOf(ALICE), total, "split payment arrived short");
        eq(token.balanceOf(ALICE), single.balanceOf(ALICE), "splitting changed recipient balance");
        eq(token.balanceOf(address(this)), single.balanceOf(address(this)), "splitting changed owner balance");
        eq(token.allowance(address(this), SPENDER), 0, "split payment left permission");
        eq(single.allowance(address(this), SPENDER), 0, "single payment left permission");
        eq(token.totalSupply(), SUPPLY, "split payment changed supply");
        eq(single.totalSupply(), SUPPLY, "single payment changed supply");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        eq(token.balanceOf(ALICE), total, "exhausted allowance reused");
    }
}
