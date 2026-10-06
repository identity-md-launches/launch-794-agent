# Agent (AGENT)

Agent is an immutable, fixed-supply ERC-20. Deployment mints **1,000,000,000
AGENT**, with **18 decimals**, to the constructor caller in one operation.

| Deployment field | Value |
| --- | --- |
| Contract | `src/Agent.sol:Agent` |
| Name | `Agent` |
| Symbol | `AGENT` |
| Decimals | `18` |
| Total supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`; ABI encoding `0x`) |
| Deployment value | `0` |
| Initial recipient | Constructor `msg.sender` |
| Solidity | `0.8.26` |
| EVM target | `cancun` |
| Optimizer | Enabled, 200 runs |
| Metadata bytecode hash | `none` |
| Application contracts | None |

## Build and test

Install Foundry and make Solidity 0.8.26 available, then run:

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are included as ordinary files. Once the pinned
compiler is installed, these commands need no network, RPC, wallet, or environment
configuration. FFI is disabled and no filesystem cheatcode permissions are granted.
Tests deploy fresh instances in `setUp()` and do not read or modify environment
variables. They can run independently and in parallel.

The implementation inherits the unmodified ERC-20 from OpenZeppelin Contracts
v5.0.2. The minimal dependency subset, license, upstream commit, and checksums are
in `lib/openzeppelin-contracts/`. The tests use a small interface to Foundry's
built-in cheatcodes and do not need forge-std.

## Token behavior and assumptions

The task specifies the name, symbol, decimals, and initial mint. Ordinary ERC-20
behavior is assumed for everything else:

- Transfers deliver exactly the requested amount and leave total supply unchanged.
  There are no fees, burns, rebases, exemptions, or transfer callbacks.
- `transfer`, `approve`, and `transferFrom` return `true` on success and revert on
  invalid operations using OpenZeppelin's ERC-6093 errors.
- Zero-value transfers between nonzero addresses succeed and emit `Transfer`.
  Transfers to the zero address and approvals to a zero spender revert.
- Finite allowances decrease on delegated spending; `type(uint256).max` remains
  unchanged as an unlimited allowance. `approve` replaces the previous allowance.
  `Approval` is emitted by `approve`; this OpenZeppelin version does not emit it
  when spending an allowance. Read `allowance` for the authoritative value.
- The constructor emits `Transfer(address(0), deployer, 10^27)`. There is no
  callable mint or burn function and no initialization step.
- There is no owner, pause, blacklist, seizure, upgrade, or asset recovery power.
  The deployer has only the rights associated with holding the initial supply.
- This is a standalone deployment, not a proxy implementation. The build targets
  a Cancun-compatible EVM. No chain, RPC, factory address, pool address, or launch
  economics have been supplied or hard-coded. zkSync's distinct compiler/deployment
  workflow is not supported by this project.

## Deployment and launch integration

The deployment artifact is `out/Agent.sol/Agent.json`. The ABI and creation bytecode
can also be obtained without sending transactions:

```sh
forge inspect src/Agent.sol:Agent abi
forge inspect src/Agent.sol:Agent bytecode
```

Deploy that creation bytecode with no appended constructor arguments and zero
native currency. A direct EOA deployment credits that EOA. When a factory calls
CREATE or CREATE2, **the factory receives the entire supply**; the transaction
originator receives nothing automatically. A Solidity integration is simply:

```solidity
Agent token = new Agent(); // This calling contract holds the entire supply.
```

For CREATE2, the operator chooses the salt and uses the actual factory address and
the hash of the compiled creation bytecode to predict the token address. There
are no constructor address substitutions, library linking steps, or subsequent
initialization calls.

For the contributor network's custom-token launch, record the contract and token
parameters from the table above, with `constructorArgs: []` and `contracts: []`.
The factory/distributor infrastructure handles allocations after deployment,
including the network's swarm allocation. Exact ordinary transfers support those
flows without token-specific exemptions. The token does not embed allocation
policy, pool setup, price, or requester addresses. Those deployment-specific
parameters must come from the launch job; no complete launch manifest is invented
here.

The local flow test exercises a factory, distributor, pool-like holder, and trader
as contract/address recipients with exact balance checks. Its 50% pool allocation
is only a test fixture. It is **not** a Uniswap v4 liquidity or swap simulation.
The pinned `CustomTokenProtectedTest` requires the network's factory libraries,
Uniswap v4 dependencies, and launch-specific environment configuration, which
are not part of this empty token project. That full integration check remains the
launch verifier's responsibility.

## Operational responsibilities

The deployment operator must select a compatible chain, preserve the compiler and
build settings, independently review the token and factory integration, verify the
deployed source/bytecode, and confirm metadata, total supply, the mint event, and
the factory's initial balance. Factory deployments must forward allocations as
specified by the launch job; the token cannot recover a supply stranded in a
factory. Record the deployed address and transaction in deployment records.

Custody and distribution of the initial supply belong to its recipient. Holders
and applications are responsible for spender approvals: prefer limited allowances,
revoke unused approvals, and confirm a zero allowance before replacing an existing
nonzero allowance to mitigate the standard ERC-20 approval race. A spender may
still use an old allowance before the revocation is mined. Unlimited approvals
expose future balances as well as current ones.

Transfers to contracts do not check whether the recipient can return tokens.
Tokens sent to the token contract itself or another incapable recipient cannot
be recovered administratively. Ordinary native-currency sends revert; forced
native currency and accidentally sent assets have no withdrawal mechanism.
There is no ongoing keeper, oracle, administrator, or upgrade operation.

## Validation scope

The test suite covers constructor metadata and mint events, direct and factory
deployment (including CREATE2), exact and zero transfers, self-transfers, contract
recipients, approval replacement/revocation, finite and unlimited allowances,
unauthorized spending, zero-address errors, atomic rollback on failure, native
currency rejection, absent admin/mint/burn selectors, and the forbidden runtime
opcodes named in the pinned floor. Three fuzz properties exercise balance
conservation, delegated spending, and overdraw rejection with 512 cases each.

Foundry build, tests, and formatting checks are the local validation tools used.
Slither, Mythril, and the network's complete deployment harness have not been run.
Passing tests is not an independent security audit. Production release and any
broadcasting, signing, liquidity setup, or wallet custody are separate operator
responsibilities; this project performs none of them.
