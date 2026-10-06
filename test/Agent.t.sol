// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Agent} from "../src/Agent.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Only the built-in Foundry cheatcodes used by these tests; no test library dependency.
interface Vm {
    function prank(address sender) external;
    function expectRevert(bytes calldata reason) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function deal(address account, uint256 balance) external;
}

/// @dev Models a factory or distributor holding and forwarding tokens.
contract TokenActor {
    function deploy() external returns (Agent) {
        return new Agent();
    }

    function deployDeterministic(bytes32 salt) external returns (Agent) {
        return new Agent{salt: salt}();
    }

    function move(Agent token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract RejectingRecipient {
    fallback() external {
        revert("token transfers must not call the recipient");
    }
}

contract AgentTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);

    Agent private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new Agent();
    }

    function test_MetadataAndInitialSupply() public view {
        require(keccak256(bytes(token.name())) == keccak256("Agent"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("AGENT"), "symbol");
        _eq(token.decimals(), 18);
        _eq(token.INITIAL_SUPPLY(), SUPPLY);
        _eq(token.totalSupply(), SUPPLY);
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(address(0)), 0);
        _eq(token.allowance(address(this), SPENDER), 0);
    }

    function test_ConstructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        Agent deployed = new Agent();
        _eq(deployed.balanceOf(address(this)), SUPPLY);
    }

    function test_FactoryReceivesEntireSupply() public {
        TokenActor factory = new TokenActor();
        Agent deployed = factory.deploy();
        _eq(deployed.balanceOf(address(factory)), SUPPLY);
        _eq(deployed.balanceOf(address(this)), 0);
        _eq(deployed.totalSupply(), SUPPLY);
    }

    function test_Create2DeploymentNeedsNoConstructorArguments() public {
        TokenActor factory = new TokenActor();
        bytes32 salt = keccak256("Agent launch");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(Agent).creationCode))
                    )
                )
            )
        );
        Agent deployed = factory.deployDeterministic(salt);
        require(address(deployed) == predicted, "CREATE2 prediction");
        _eq(deployed.balanceOf(address(factory)), SUPPLY);
        _eq(deployed.totalSupply(), SUPPLY);
    }

    function test_TransferEmitsEventAndReturnsTrue() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 7 ether);
        require(token.transfer(ALICE, 7 ether), "transfer return");
        _eq(token.balanceOf(address(this)), SUPPLY - 7 ether);
        _eq(token.balanceOf(ALICE), 7 ether);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_EntireSupplyCanMove() public {
        require(token.transfer(ALICE, SUPPLY), "transfer return");
        _eq(token.balanceOf(address(this)), 0);
        _eq(token.balanceOf(ALICE), SUPPLY);
        vm.prank(ALICE);
        require(token.transfer(BOB, SUPPLY), "holder transfer return");
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(BOB), SUPPLY);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        require(token.transfer(BOB, 0), "zero transfer return");
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(BOB), 0);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        require(token.transfer(address(this), SUPPLY), "self transfer return");
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_ContractRecipientNeedsNoCallback() public {
        RejectingRecipient recipient = new RejectingRecipient();
        require(token.transfer(address(recipient), 1 ether), "contract transfer return");
        _eq(token.balanceOf(address(recipient)), 1 ether);
    }

    function test_TransferRejectsInsufficientBalanceWithoutChangingState() public {
        token.transfer(ALICE, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10, 11));
        vm.prank(ALICE);
        token.transfer(BOB, 11);
        _eq(token.balanceOf(ALICE), 10);
        _eq(token.balanceOf(BOB), 0);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferStillRequiresBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(ALICE, 1);
        _eq(token.balanceOf(ALICE), 0);
    }

    function test_TransferRejectsZeroRecipientEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.balanceOf(address(0)), 0);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveEmitsEventAndReturnsTrue() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 7 ether);
        require(token.approve(SPENDER, 7 ether), "approve return");
        _eq(token.allowance(address(this), SPENDER), 7 ether);
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.balanceOf(SPENDER), 0);
    }

    function test_ApprovalCanBeReplacedAndRevoked() public {
        token.approve(SPENDER, 100);
        token.approve(SPENDER, 20);
        _eq(token.allowance(address(this), SPENDER), 20);
        token.approve(SPENDER, 0);
        _eq(token.allowance(address(this), SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 1);
        _eq(token.balanceOf(BOB), 0);
    }

    function test_ApproveRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 100);
        _eq(token.allowance(address(this), address(0)), 0);
    }

    function test_TransferFromConsumesAllowanceAndEmitsTransfer() public {
        token.approve(SPENDER, 10 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 7 ether);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 7 ether), "transferFrom return");
        _eq(token.allowance(address(this), SPENDER), 3 ether);
        _eq(token.balanceOf(ALICE), 7 ether);
        _eq(token.balanceOf(address(this)), SUPPLY - 7 ether);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_ExactAllowanceCanBeSpentOnlyOnce() public {
        token.approve(SPENDER, 10);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 10);
        _eq(token.allowance(address(this), SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        _eq(token.balanceOf(ALICE), 10);
    }

    function test_InfiniteAllowanceIsPreserved() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 7 ether);
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 3 ether);
        _eq(token.allowance(address(this), SPENDER), type(uint256).max);
        _eq(token.balanceOf(ALICE), 7 ether);
        _eq(token.balanceOf(BOB), 3 ether);
    }

    function test_AllowanceCannotBeUsedByAnotherSpender() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 10));
        vm.prank(ALICE);
        token.transferFrom(address(this), ALICE, 10);
        _eq(token.allowance(address(this), SPENDER), 10);
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromRejectsInsufficientAllowanceAtomically() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 10, 11));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 11);
        _eq(token.allowance(address(this), SPENDER), 10);
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.balanceOf(ALICE), 0);
    }

    function test_TransferFromBalanceFailureRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 10);
        _eq(token.allowance(ALICE, SPENDER), 10);
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(BOB), 0);
    }

    function test_TransferFromZeroRecipientRestoresAllowance() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 10);
        _eq(token.allowance(address(this), SPENDER), 10);
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromRejectsZeroSender() public {
        // OpenZeppelin checks the allowance owner before entering the transfer.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromNeedsNoAllowance() public {
        require(token.transferFrom(ALICE, BOB, 0), "zero transferFrom return");
        _eq(token.allowance(ALICE, address(this)), 0);
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(BOB), 0);
    }

    function test_DelegatedSelfTransferConsumesAllowanceWithoutMovingBalance() public {
        token.approve(SPENDER, 10);
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(this), 10);
        _eq(token.balanceOf(address(this)), SUPPLY);
        _eq(token.allowance(address(this), SPENDER), 0);
    }

    function test_DeployerCannotSpendHolderFundsWithoutApproval() public {
        token.transfer(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, address(this), 1);
        _eq(token.balanceOf(ALICE), 100);
        vm.prank(ALICE);
        require(token.transfer(BOB, 100), "holder transfer");
        _eq(token.balanceOf(BOB), 100);
    }

    function test_NoMintBurnOrAdminEntryPoints() public {
        token.transfer(ALICE, 100);
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", BOB, SUPPLY);
        calls[1] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[2] = abi.encodeWithSignature("initialize(address)", BOB);
        calls[3] = abi.encodeWithSignature("setMinter(address)", BOB);
        calls[4] = abi.encodeWithSignature("transferOwnership(address)", BOB);
        calls[5] = abi.encodeWithSignature("upgradeTo(address)", BOB);
        calls[6] = abi.encodeWithSignature("pause()");
        calls[7] = abi.encodeWithSignature("blacklist(address)", ALICE);
        calls[8] = abi.encodeWithSignature("freeze(address)", ALICE);
        calls[9] = abi.encodeWithSignature("seize(address)", ALICE);
        calls[10] = abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 100);
        calls[11] = abi.encodeWithSignature("burn(uint256)", 100);
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(calls[i]);
            require(!deployerSucceeded, "deployer reached unexpected entry point");
            vm.prank(BOB);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            require(!strangerSucceeded, "stranger reached unexpected entry point");
        }
        _eq(token.totalSupply(), SUPPLY);
        _eq(token.balanceOf(ALICE), 100);
        _eq(token.balanceOf(BOB), 0);
        vm.prank(ALICE);
        require(token.transfer(BOB, 100), "holder remains transferable");
    }

    function test_RejectsNativeCurrency() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(token).call{value: 1 ether}("");
        require(!success, "unexpected payable entry point");
        _eq(address(token).balance, 0);
    }

    function test_FactoryDistributorAndPoolStyleTransfersArriveWhole() public {
        TokenActor factory = new TokenActor();
        TokenActor distributor = new TokenActor();
        TokenActor pool = new TokenActor();
        Agent deployed = factory.deploy();
        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY / 2; // Illustrative test allocation, not launch economics.
        uint256 remainder = SUPPLY - swarmShare - poolShare;
        require(factory.move(deployed, address(distributor), swarmShare), "distributor funding");
        require(distributor.move(deployed, ALICE, swarmShare), "claim");
        require(factory.move(deployed, address(pool), poolShare), "pool funding");
        require(factory.move(deployed, BOB, remainder), "remainder");
        _eq(deployed.balanceOf(address(factory)), 0);
        _eq(deployed.balanceOf(address(distributor)), 0);
        _eq(deployed.balanceOf(ALICE), swarmShare);
        _eq(deployed.balanceOf(BOB), remainder);
        _eq(deployed.balanceOf(address(pool)), poolShare);
        require(pool.move(deployed, SPENDER, 7 ether), "pool output");
        _eq(deployed.balanceOf(SPENDER), 7 ether);
        vm.prank(SPENDER);
        require(deployed.transfer(address(pool), 7 ether), "pool input");
        _eq(deployed.balanceOf(SPENDER), 0);
        _eq(deployed.balanceOf(address(pool)), poolShare);
        _eq(deployed.totalSupply(), SUPPLY);
    }

    function test_RuntimeHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            require(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_TransfersConserveSupply(uint256 initialAmount, uint256 forwardedAmount) public {
        initialAmount %= SUPPLY + 1;
        forwardedAmount %= initialAmount + 1;
        require(token.transfer(ALICE, initialAmount), "initial transfer");
        vm.prank(ALICE);
        require(token.transfer(BOB, forwardedAmount), "forwarded transfer");
        _eq(token.balanceOf(address(this)), SUPPLY - initialAmount);
        _eq(token.balanceOf(ALICE), initialAmount - forwardedAmount);
        _eq(token.balanceOf(BOB), forwardedAmount);
        _eq(token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
        _eq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedSpendingConservesSupply(uint256 approval, uint256 spent) public {
        approval %= SUPPLY + 1;
        spent %= approval + 1;
        token.approve(SPENDER, approval);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, spent), "delegated transfer");
        _eq(token.allowance(address(this), SPENDER), approval - spent);
        _eq(token.balanceOf(address(this)), SUPPLY - spent);
        _eq(token.balanceOf(ALICE), spent);
        _eq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_OverdrawAlwaysReverts(uint256 balance, uint256 excess) public {
        balance %= SUPPLY + 1;
        excess = excess % (type(uint256).max - balance) + 1;
        token.transfer(ALICE, balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, balance + excess)
        );
        vm.prank(ALICE);
        token.transfer(BOB, balance + excess);
        _eq(token.balanceOf(ALICE), balance);
        _eq(token.balanceOf(BOB), 0);
        _eq(token.totalSupply(), SUPPLY);
    }

    function _eq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "unexpected value");
    }
}
