// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, StdInvariant} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JobFunds} from "../../src/JobFunds.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {IJobFunds, OrgJobBalance} from "../../src/interfaces/IJobFunds.sol";
import {USDC} from "../mocks/USDC.sol";

/// @notice Minimal OrgRegistry gate — only the three functions JobFunds calls.
/// @dev The invariant target is JobFunds' internal accounting, not org identity, so a
///      configurable gate is sufficient and keeps the handler's callers authorized.
contract MockOrgRegistryGate {
    address public treasury;
    address public manager;

    function configure(address treasury_, address manager_) external {
        treasury = treasury_;
        manager = manager_;
    }

    function orgExists(uint256) external pure returns (bool) {
        return true;
    }

    function orgTreasury(uint256) external view returns (address) {
        return treasury;
    }

    function isOrgAdmin(uint256, address account) external view returns (bool) {
        return account == manager;
    }
}

/// @notice Fuzzer-driven handler that exercises the real JobFunds funding lifecycle.
contract JobFundsHandler is Test {
    uint32 public constant commitmentVersion = 1;
    uint256 internal constant ORG_COUNT = 3;
    uint96 internal constant MAX_DEPOSIT = 1_000_000_000_000; // 1M USDC per deposit call
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    USDC internal immutable _usdc;
    JobFunds internal immutable _jobFunds;
    uint256 internal immutable _treasuryPrivateKey;
    address internal immutable _treasury;

    uint256 internal _jobCounter;
    uint256 internal _authorizationNonce;
    uint256[] internal _openJobIds;
    mapping(uint256 jobId => uint256) internal _lockedOrg;
    mapping(uint256 jobId => uint256) internal _lockedStake;

    // ghost totals — cross-check against the contract's own accounting
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostFeesPaid;
    uint256 public ghostSlashed;

    constructor(USDC usdc_, JobFunds jobFunds_, uint256 treasuryPrivateKey_) {
        _usdc = usdc_;
        _jobFunds = jobFunds_;
        _treasuryPrivateKey = treasuryPrivateKey_;
        _treasury = vm.addr(treasuryPrivateKey_);
    }

    // ---- IJobCommitmentModule (so JobFunds accepts registration) ----

    function stakeToken() external view returns (IERC20) {
        return IERC20(address(_usdc));
    }

    function jobFunds() external view returns (IJobFunds) {
        return IJobFunds(address(_jobFunds));
    }

    function createJob(uint256, address, uint256, uint256, bytes calldata) external returns (uint256 jobId) {
        require(msg.sender == address(_jobFunds), "only job funds");

        _jobCounter++;
        return _jobCounter;
    }

    // ---- fuzzed actions ----

    function depositWithAuthorization(uint256 orgSeed, uint256 amountSeed) external {
        uint256 orgId = _orgId(orgSeed);
        uint256 amount = _boundValue(amountSeed, 1, MAX_DEPOSIT);

        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256(abi.encode(address(this), ++_authorizationNonce));
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                _treasury,
                address(_jobFunds),
                amount,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_treasuryPrivateKey, digest);

        _usdc.mint(_treasury, amount);
        vm.prank(_treasury);
        _jobFunds.depositWithAuthorization(orgId, amount, validAfter, validBefore, nonce, v, r, s);
        ghostDeposited += amount;
    }

    function deposit(uint256 orgSeed, uint256 amountSeed) external {
        uint256 orgId = _orgId(orgSeed);
        uint256 amount = _boundValue(amountSeed, 1, MAX_DEPOSIT);

        _usdc.mint(_treasury, amount);
        vm.startPrank(_treasury);
        _usdc.approve(address(_jobFunds), amount);
        _jobFunds.deposit(orgId, amount);
        vm.stopPrank();

        ghostDeposited += amount;
    }

    function withdraw(uint256 orgSeed, uint256 amountSeed) external {
        uint256 orgId = _orgId(orgSeed);
        uint256 available = _jobFunds.availableBalance(orgId);
        if (available == 0) return;

        uint256 amount = _boundValue(amountSeed, 1, available);
        vm.prank(_treasury);
        _jobFunds.withdraw(orgId, amount);

        ghostWithdrawn += amount;
    }

    function publishJob(uint256 orgSeed, uint256 stakeSeed, uint256 feeSeed) external {
        uint256 orgId = _orgId(orgSeed);
        uint256 available = _jobFunds.availableBalance(orgId);
        if (available < 2) return;

        uint256 stake = _boundValue(stakeSeed, 1, available - 1);
        uint256 fee = _boundValue(feeSeed, 0, available - stake);

        uint256 jobId = _jobFunds.publishJob(address(this), orgId, stake, fee, _jobFunds.feeRecipient(), bytes(""));

        _openJobIds.push(jobId);
        _lockedOrg[jobId] = orgId;
        _lockedStake[jobId] = stake;
        ghostFeesPaid += fee;
    }

    function settleJob(uint256 jobSeed, uint256 returnSeed) external {
        if (_openJobIds.length == 0) return;

        uint256 idx = _boundValue(jobSeed, 0, _openJobIds.length - 1);
        uint256 jobId = _openJobIds[idx];
        uint256 stake = _lockedStake[jobId];
        uint256 returnAmount = _boundValue(returnSeed, 0, stake);

        _jobFunds.settleJob(_lockedOrg[jobId], jobId, returnAmount);

        ghostSlashed += stake - returnAmount;

        // swap-remove the settled lock
        _openJobIds[idx] = _openJobIds[_openJobIds.length - 1];
        _openJobIds.pop();
        delete _lockedOrg[jobId];
        delete _lockedStake[jobId];
    }

    function _orgId(uint256 seed) internal pure returns (uint256) {
        return 1 + (seed % ORG_COUNT);
    }

    function _boundValue(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) return lo;
        return lo + (x % (hi - lo + 1));
    }
}

/// @title JobFundsInvariant
/// @notice Stateful invariant suite over the REAL JobFunds. Replaces the misnamed
///         BalanceInvariant/OrgInvariantFuzz scripted tests (which declared no invariants).
contract JobFundsInvariant is StdInvariant, Test {
    uint256 internal constant ORG_COUNT = 3;
    uint256 internal constant TREASURY_PRIVATE_KEY = 0x7EA5;

    USDC internal usdc;
    MockOrgRegistryGate internal registry;
    JobFunds internal jobFunds;
    JobFundsHandler internal handler;

    address internal constant FEE_RECIPIENT = address(0xFEE);

    function setUp() public {
        usdc = new USDC();
        registry = new MockOrgRegistryGate();
        jobFunds = new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), FEE_RECIPIENT, address(this), address(0)
        );
        handler = new JobFundsHandler(usdc, jobFunds, TREASURY_PRIVATE_KEY);

        registry.configure(vm.addr(TREASURY_PRIVATE_KEY), address(handler));
        jobFunds.registerJobCommitment(address(handler), handler.commitmentVersion());
        jobFunds.setCurrentJobCommitment(address(handler));

        // only the handler's fuzzed actions drive state
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = JobFundsHandler.depositWithAuthorization.selector;
        selectors[1] = JobFundsHandler.deposit.selector;
        selectors[2] = JobFundsHandler.withdraw.selector;
        selectors[3] = JobFundsHandler.publishJob.selector;
        selectors[4] = JobFundsHandler.settleJob.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Solvency: the token the contract physically holds always covers what it accounts for.
    function invariant_solvency() public view {
        assertGe(
            usdc.balanceOf(address(jobFunds)),
            jobFunds.totalAccountedBalance(),
            "JobFunds holds less than it accounts for"
        );
    }

    /// @notice Accounting identity: totalAccounted equals the sum of every org's available + staked.
    function invariant_accountedEqualsSumOfBalances() public view {
        uint256 sum;
        for (uint256 orgId = 1; orgId <= ORG_COUNT; orgId++) {
            OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
            sum += uint256(balance.available) + uint256(balance.stakedInJobs);
        }
        assertEq(sum, jobFunds.totalAccountedBalance(), "sum of org balances != totalAccountedBalance");
    }

    /// @notice Fee + slash burns leave the contract exactly, so accounted == deposited - withdrawn - fees - slashed.
    function invariant_ledgerReconciles() public view {
        assertEq(
            jobFunds.totalAccountedBalance(),
            handler.ghostDeposited() - handler.ghostWithdrawn() - handler.ghostFeesPaid() - handler.ghostSlashed(),
            "accounted balance drifted from deposit/withdraw/fee/slash ledger"
        );
    }
}
