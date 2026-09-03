// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IOrgRegistry} from "./interfaces/IOrgRegistry.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";
import {Errors} from "./Errors.sol";
import {SLASH_BURN_ADDRESS} from "./Constants.sol";
import {InvariantsLib} from "./libraries/InvariantsLib.sol";
import {IJobCommitmentModule} from "./interfaces/IJobCommitmentModule.sol";
import {IJobFunds, RegisteredJobCommitment, OrgJobBalance, JobLock} from "./interfaces/IJobFunds.sol";
import {OwnerControls} from "./abstract/OwnerControls.sol";

/// @title JobFunds
/// @notice Holds organization funds in escrow for user-authorized JobCommitment workflows.
/// @dev JobCommitment contracts can settle their own locks but cannot initiate org debits.
/// @custom:security-contact security@comitium.co
contract JobFunds is IJobFunds, OwnerControls {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Token used for job funding, fees, and slash burns.
    IERC20 public immutable stakeToken;

    /// @notice Registry that defines organization existence, admins, and treasury.
    IOrgRegistry public immutable orgRegistry;

    /// @notice Recipient of job publishing fees.
    address public feeRecipient;

    /// @dev Sole JobCommitment allowed to create new locks.
    address private _currentJobCommitment;

    /// @dev Sum of all available and staked org balances tracked by this contract.
    uint256 private _totalAccountedBalance;

    /// @dev Per-org job funding balances.
    mapping(uint256 orgId => OrgJobBalance) private _jobBalances;

    /// @dev Stake locks keyed by JobCommitment address and local job ID.
    mapping(address jobCommitment => mapping(uint256 jobId => JobLock)) private _jobLocks;

    /// @dev Registration facts for each JobCommitment deployment.
    mapping(address jobCommitment => RegisteredJobCommitment) private _registeredJobCommitments;

    /// @dev Per-org accounts that can manage job lifecycle actions.
    mapping(uint256 orgId => EnumerableSet.AddressSet) private _jobManagers;

    /// @param stakeToken_ Token used for job funding.
    /// @param orgRegistry_ OrgRegistry that owns org identity and ownership.
    /// @param feeRecipient_ Initial recipient of job publishing fees.
    /// @param owner_ Initial contract owner.
    /// @param forwarder_ ERC-2771 forwarder for relayed org treasury and job-manager operations.
    constructor(
        IERC20 stakeToken_,
        IOrgRegistry orgRegistry_,
        address feeRecipient_,
        address owner_,
        address forwarder_
    ) OwnerControls(owner_, forwarder_) {
        if (address(stakeToken_) == address(0)) revert Errors.ZeroAddress();
        if (address(orgRegistry_) == address(0)) revert Errors.ZeroAddress();
        if (feeRecipient_ == address(0) || owner_ == address(0)) revert Errors.ZeroAddress();
        if (feeRecipient_ == address(this)) revert Errors.InvalidFeeRecipient(feeRecipient_);

        stakeToken = stakeToken_;
        orgRegistry = orgRegistry_;
        feeRecipient = feeRecipient_;
    }

    /// @inheritdoc IJobFunds
    function depositWithAuthorization(
        uint256 orgId,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        address actor = _requireDepositActor(orgId, amount);

        IERC3009(address(stakeToken))
            .receiveWithAuthorization(actor, address(this), amount, validAfter, validBefore, nonce, v, r, s);
        _creditDeposit(orgId, actor, amount);
    }

    /// @inheritdoc IJobFunds
    function deposit(uint256 orgId, uint256 amount) external nonReentrant whenNotPaused {
        address actor = _requireDepositActor(orgId, amount);

        stakeToken.safeTransferFrom(actor, address(this), amount);
        _creditDeposit(orgId, actor, amount);
    }

    /// @inheritdoc IJobFunds
    /// @dev Withdrawals stay available while paused so owners are not trapped by an operational pause.
    function withdraw(uint256 orgId, uint256 amount) external nonReentrant {
        address actor = _actor();
        address orgTreasury_ = _requireOrgTreasury(orgId, actor);

        if (amount == 0) revert Errors.ZeroAmount();

        OrgJobBalance storage balance = _jobBalances[orgId];
        uint256 available = balance.available;

        if (amount > available) revert Errors.InsufficientBalance(amount, available);

        balance.available -= amount.toUint96();
        _totalAccountedBalance -= amount;

        stakeToken.safeTransfer(orgTreasury_, amount);

        _checkBalanceInvariant();

        emit JobFundsWithdrawn(orgId, orgTreasury_, amount);
    }

    /// @inheritdoc IJobFunds
    function publishJob(
        address jobCommitment,
        uint256 orgId,
        uint256 stakeAmount,
        uint256 feeAmount,
        address expectedFeeRecipient,
        bytes calldata publishData
    ) external nonReentrant whenNotPaused returns (uint256 jobId) {
        RegisteredJobCommitment memory config = _registeredJobCommitments[jobCommitment];
        address creator = _actor();

        if (!config.exists) revert Errors.JobCommitmentNotRegistered(jobCommitment);
        if (jobCommitment != _currentJobCommitment) {
            revert Errors.JobCommitmentNotCurrent(jobCommitment, _currentJobCommitment);
        }
        if (!orgRegistry.orgExists(orgId)) revert Errors.OrgNotFound(orgId);
        if (!_canManageJobs(orgId, creator)) revert Errors.NotJobManager(orgId, creator);
        if (stakeAmount == 0) revert Errors.ZeroAmount();
        if (expectedFeeRecipient != feeRecipient) {
            revert Errors.FeeRecipientMismatch(expectedFeeRecipient, feeRecipient);
        }

        uint96 packedOrgId = orgId.toUint96();
        uint96 packedStake = stakeAmount.toUint96();
        uint256 totalCost = stakeAmount + feeAmount;

        OrgJobBalance storage balance = _jobBalances[orgId];
        uint256 available = balance.available;

        if (available < totalCost) revert Errors.InsufficientBalance(totalCost, available);

        jobId = IJobCommitmentModule(jobCommitment).createJob(orgId, creator, stakeAmount, feeAmount, publishData);

        if (_jobLocks[jobCommitment][jobId].stakeAmount != 0) revert Errors.JobAlreadyLocked(jobCommitment, jobId);

        balance.available -= totalCost.toUint96();
        balance.stakedInJobs += packedStake;
        _totalAccountedBalance -= feeAmount;
        _jobLocks[jobCommitment][jobId] = JobLock({stakeAmount: packedStake, orgId: packedOrgId});

        if (feeAmount > 0) stakeToken.safeTransfer(expectedFeeRecipient, feeAmount);

        _checkBalanceInvariant();

        emit JobFunded(jobCommitment, orgId, jobId, creator, stakeAmount, feeAmount);
    }

    /// @inheritdoc IJobFunds
    /// @dev Settlement stays available while paused so authorized commitments can unwind existing obligations.
    function settleJob(uint256 orgId, uint256 jobId, uint256 returnAmount) external nonReentrant {
        RegisteredJobCommitment memory config = _registeredJobCommitments[msg.sender];

        if (!config.exists) revert Errors.JobCommitmentNotRegistered(msg.sender);

        JobLock memory lock = _jobLocks[msg.sender][jobId];

        if (lock.stakeAmount == 0) revert Errors.JobNotLocked(msg.sender, jobId);
        if (lock.orgId != orgId) revert Errors.JobLockOrgMismatch(orgId, lock.orgId);
        if (returnAmount > lock.stakeAmount) revert Errors.ExceedsLockedAmount(returnAmount, lock.stakeAmount);

        delete _jobLocks[msg.sender][jobId];

        OrgJobBalance storage balance = _jobBalances[orgId];
        uint256 slashedAmount = lock.stakeAmount - returnAmount;

        balance.stakedInJobs -= lock.stakeAmount;
        balance.available += returnAmount.toUint96();
        _totalAccountedBalance -= slashedAmount;

        if (slashedAmount > 0) {
            stakeToken.safeTransfer(SLASH_BURN_ADDRESS, slashedAmount);
            emit StakeBurned(msg.sender, orgId, jobId, slashedAmount);
        }

        _checkBalanceInvariant();

        emit JobSettled(msg.sender, orgId, jobId, returnAmount, slashedAmount);
    }

    /// @inheritdoc IJobFunds
    function setJobManager(uint256 orgId, address account, bool active) external {
        if (account == address(0)) revert Errors.ZeroAddress();

        address actor = _actor();

        _requireOrgAdmin(orgId, actor);

        bool changed = _setActive(_jobManagers[orgId], account, active);

        emit JobManagerUpdated(orgId, account, active, actor, changed);
    }

    /// @notice Authorize a JobCommitment deployment for settlement and possible routing.
    /// @param jobCommitment JobCommitment address to authorize.
    /// @param expectedVersion Exact immutable version expected from the deployment.
    function registerJobCommitment(address jobCommitment, uint32 expectedVersion) external onlyOwner {
        if (jobCommitment == address(0)) revert Errors.ZeroAddress();
        if (_registeredJobCommitments[jobCommitment].exists) {
            revert Errors.JobCommitmentAlreadyRegistered(jobCommitment);
        }

        if (expectedVersion == 0) revert Errors.InvalidJobCommitment(jobCommitment);
        _validateJobCommitment(jobCommitment, expectedVersion);

        _registeredJobCommitments[jobCommitment] =
            RegisteredJobCommitment({commitmentVersion: expectedVersion, exists: true});

        emit JobCommitmentRegistered(jobCommitment, expectedVersion);
    }

    /// @notice Set the current create-capable JobCommitment contract.
    /// @param jobCommitment Authorized JobCommitment that can create jobs.
    function setCurrentJobCommitment(address jobCommitment) external onlyOwner {
        if (jobCommitment == address(0)) revert Errors.ZeroAddress();

        RegisteredJobCommitment memory config = _registeredJobCommitments[jobCommitment];

        if (!config.exists) revert Errors.JobCommitmentNotRegistered(jobCommitment);
        _validateJobCommitment(jobCommitment, config.commitmentVersion);

        address previous = _currentJobCommitment;
        _currentJobCommitment = jobCommitment;

        emit CurrentJobCommitmentUpdated(previous, jobCommitment);
    }

    /// @notice Update the recipient of job publishing fees.
    /// @param recipient New recipient address.
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (recipient == address(this)) revert Errors.InvalidFeeRecipient(recipient);

        address previous = feeRecipient;
        feeRecipient = recipient;

        emit FeeRecipientUpdated(previous, recipient);
    }

    /// @dev For stakeToken, only balance above totalAccountedBalance can be rescued.
    function _validateTokenRescue(address token, uint256 amount) internal view override {
        if (token == address(stakeToken)) {
            uint256 balance = stakeToken.balanceOf(address(this));
            uint256 surplus = balance > _totalAccountedBalance ? balance - _totalAccountedBalance : 0;

            if (amount > surplus) revert Errors.RescueExceedsSurplus(amount, surplus);
        }
    }

    /// @dev Emits the JobFunds rescue event after the shared rescue transfer succeeds.
    function _emitTokensRescued(address token, address to, uint256 amount) internal override {
        emit TokensRescued(token, to, amount);
    }

    /// @inheritdoc IJobFunds
    function availableBalance(uint256 orgId) external view returns (uint256 available) {
        return _jobBalances[orgId].available;
    }

    /// @inheritdoc IJobFunds
    function jobBalance(uint256 orgId) external view returns (OrgJobBalance memory balance) {
        return _jobBalances[orgId];
    }

    /// @inheritdoc IJobFunds
    function jobLock(address jobCommitment, uint256 jobId) external view returns (JobLock memory lock) {
        return _jobLocks[jobCommitment][jobId];
    }

    /// @inheritdoc IJobFunds
    function totalAccountedBalance() external view returns (uint256 total) {
        return _totalAccountedBalance;
    }

    /// @inheritdoc IJobFunds
    function isJobManager(uint256 orgId, address account) external view returns (bool active) {
        if (!orgRegistry.orgExists(orgId)) revert Errors.OrgNotFound(orgId);

        return _jobManagers[orgId].contains(account);
    }

    /// @inheritdoc IJobFunds
    function canManageJobs(uint256 orgId, address account) public view returns (bool allowed) {
        return _canManageJobs(orgId, account);
    }

    /// @inheritdoc IJobFunds
    function registeredJobCommitment(address jobCommitment)
        external
        view
        returns (RegisteredJobCommitment memory config)
    {
        return _registeredJobCommitments[jobCommitment];
    }

    /// @inheritdoc IJobFunds
    function currentJobCommitment() external view returns (address jobCommitment) {
        return _currentJobCommitment;
    }

    function _creditDeposit(uint256 orgId, address orgTreasury_, uint256 amount) private {
        _jobBalances[orgId].available += amount.toUint96();
        _totalAccountedBalance += amount;

        _checkBalanceInvariant();

        emit JobFundsDeposited(orgId, orgTreasury_, amount);
    }

    function _requireDepositActor(uint256 orgId, uint256 amount) private view returns (address actor) {
        actor = _actor();

        _requireOrgTreasury(orgId, actor);
        if (amount == 0) revert Errors.ZeroAmount();
    }

    function _requireOrgTreasury(uint256 orgId, address actor) private view returns (address orgTreasury_) {
        orgTreasury_ = orgRegistry.orgTreasury(orgId);

        if (actor != orgTreasury_) revert Errors.NotOrgTreasury(orgId, actor);
    }

    function _requireOrgAdmin(uint256 orgId, address account) private view {
        if (!orgRegistry.isOrgAdmin(orgId, account)) revert Errors.NotOrgAdmin(orgId, account);
    }

    function _canManageJobs(uint256 orgId, address account) private view returns (bool) {
        return orgRegistry.isOrgAdmin(orgId, account) || _jobManagers[orgId].contains(account);
    }

    function _setActive(EnumerableSet.AddressSet storage set, address account, bool active) private returns (bool) {
        return active ? set.add(account) : set.remove(account);
    }

    function _validateJobCommitment(address jobCommitment, uint32 expectedVersion) private view {
        if (jobCommitment.code.length == 0) revert Errors.ContractExpected(jobCommitment);
        if (!_matchesJobCommitmentRegistration(jobCommitment, expectedVersion)) {
            revert Errors.InvalidJobCommitment(jobCommitment);
        }
    }

    function _matchesJobCommitmentRegistration(address jobCommitment, uint32 expectedVersion)
        private
        view
        returns (bool)
    {
        IJobCommitmentModule registered = IJobCommitmentModule(jobCommitment);

        try registered.commitmentVersion() returns (uint32 version) {
            if (version != expectedVersion) return false;
        } catch {
            return false;
        }

        try registered.stakeToken() returns (IERC20 token) {
            if (address(token) != address(stakeToken)) return false;
        } catch {
            return false;
        }

        try registered.jobFunds() returns (IJobFunds funds) {
            return address(funds) == address(this);
        } catch {
            return false;
        }
    }

    function _checkBalanceInvariant() private view {
        InvariantsLib.assertBalanceGte(stakeToken, address(this), _totalAccountedBalance);
    }
}
