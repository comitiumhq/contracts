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
import {IResponseCommitmentModule} from "./interfaces/IResponseCommitmentModule.sol";
import {
    ICommitmentFunds,
    RegisteredResponseCommitment,
    OrgCommitmentBalance,
    CommitmentLock
} from "./interfaces/ICommitmentFunds.sol";
import {OwnerControls} from "./abstract/OwnerControls.sol";

/// @title CommitmentFunds
/// @notice Holds organization funds in escrow for user-authorized ResponseCommitment workflows.
/// @dev ResponseCommitment contracts can settle their own locks but cannot initiate org debits.
/// @custom:security-contact security@comitium.co
contract CommitmentFunds is ICommitmentFunds, OwnerControls {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Token used for commitment funding, fees, and slash burns.
    IERC20 public immutable stakeToken;

    /// @notice Registry that defines organization existence, admins, and treasury.
    IOrgRegistry public immutable orgRegistry;

    /// @notice Recipient of commitment activation fees.
    address public feeRecipient;

    /// @dev Sole ResponseCommitment allowed to create new locks.
    address private _currentResponseCommitment;

    /// @dev Sum of all available and staked org balances tracked by this contract.
    uint256 private _totalAccountedBalance;

    /// @dev Per-org commitment funding balances.
    mapping(uint256 orgId => OrgCommitmentBalance) private _commitmentBalances;

    /// @dev Stake locks keyed by ResponseCommitment address and local commitment ID.
    mapping(address responseCommitment => mapping(uint256 commitmentId => CommitmentLock)) private _commitmentLocks;

    /// @dev Registration facts for each ResponseCommitment deployment.
    mapping(address responseCommitment => RegisteredResponseCommitment) private _registeredResponseCommitments;

    /// @dev Per-org accounts that can manage commitment lifecycle actions.
    mapping(uint256 orgId => EnumerableSet.AddressSet) private _commitmentManagers;

    /// @param stakeToken_ Token used for commitment funding.
    /// @param orgRegistry_ OrgRegistry that owns org identity and ownership.
    /// @param feeRecipient_ Initial recipient of commitment activation fees.
    /// @param owner_ Initial contract owner.
    /// @param forwarder_ ERC-2771 forwarder for relayed org treasury and commitment-manager operations.
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

    /// @inheritdoc ICommitmentFunds
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

    /// @inheritdoc ICommitmentFunds
    function deposit(uint256 orgId, uint256 amount) external nonReentrant whenNotPaused {
        address actor = _requireDepositActor(orgId, amount);

        stakeToken.safeTransferFrom(actor, address(this), amount);
        _creditDeposit(orgId, actor, amount);
    }

    /// @inheritdoc ICommitmentFunds
    /// @dev Org treasuries can withdraw during an operational pause.
    function withdraw(uint256 orgId, uint256 amount) external nonReentrant {
        address actor = _actor();
        address orgTreasury_ = _requireOrgTreasury(orgId, actor);

        if (amount == 0) revert Errors.ZeroAmount();

        OrgCommitmentBalance storage balance = _commitmentBalances[orgId];
        uint256 available = balance.available;

        if (amount > available) revert Errors.InsufficientBalance(amount, available);

        balance.available -= amount.toUint96();
        _totalAccountedBalance -= amount;

        stakeToken.safeTransfer(orgTreasury_, amount);

        _checkBalanceInvariant();

        emit CommitmentFundsWithdrawn(orgId, orgTreasury_, amount);
    }

    /// @inheritdoc ICommitmentFunds
    function activateCommitment(
        address responseCommitment,
        uint256 orgId,
        uint256 stakeAmount,
        uint256 feeAmount,
        address expectedFeeRecipient,
        bytes calldata activateData
    ) external nonReentrant whenNotPaused returns (uint256 commitmentId) {
        RegisteredResponseCommitment memory config = _registeredResponseCommitments[responseCommitment];
        address creator = _actor();

        if (!config.exists) revert Errors.ResponseCommitmentNotRegistered(responseCommitment);
        if (responseCommitment != _currentResponseCommitment) {
            revert Errors.ResponseCommitmentNotCurrent(responseCommitment, _currentResponseCommitment);
        }
        if (!orgRegistry.orgExists(orgId)) revert Errors.OrgNotFound(orgId);
        if (!_canManageCommitments(orgId, creator)) revert Errors.NotCommitmentManager(orgId, creator);
        if (stakeAmount == 0) revert Errors.ZeroAmount();
        if (expectedFeeRecipient != feeRecipient) {
            revert Errors.FeeRecipientMismatch(expectedFeeRecipient, feeRecipient);
        }

        uint96 packedOrgId = orgId.toUint96();
        uint96 packedStake = stakeAmount.toUint96();
        uint256 totalCost = stakeAmount + feeAmount;

        OrgCommitmentBalance storage balance = _commitmentBalances[orgId];
        uint256 available = balance.available;

        if (available < totalCost) revert Errors.InsufficientBalance(totalCost, available);

        commitmentId = IResponseCommitmentModule(responseCommitment)
            .activateCommitment(orgId, creator, stakeAmount, feeAmount, activateData);

        if (_commitmentLocks[responseCommitment][commitmentId].stakeAmount != 0) {
            revert Errors.CommitmentAlreadyLocked(responseCommitment, commitmentId);
        }

        balance.available -= totalCost.toUint96();
        balance.lockedInCommitments += packedStake;
        _totalAccountedBalance -= feeAmount;
        _commitmentLocks[responseCommitment][commitmentId] =
            CommitmentLock({stakeAmount: packedStake, orgId: packedOrgId});

        if (feeAmount > 0) stakeToken.safeTransfer(expectedFeeRecipient, feeAmount);

        _checkBalanceInvariant();

        emit CommitmentStakeLocked(responseCommitment, orgId, commitmentId, creator, stakeAmount, feeAmount);
    }

    /// @inheritdoc ICommitmentFunds
    /// @dev Settlement stays available while paused so authorized commitments can unwind existing obligations.
    function settleCommitment(uint256 orgId, uint256 commitmentId, uint256 returnAmount) external nonReentrant {
        RegisteredResponseCommitment memory config = _registeredResponseCommitments[msg.sender];

        if (!config.exists) revert Errors.ResponseCommitmentNotRegistered(msg.sender);

        CommitmentLock memory lock = _commitmentLocks[msg.sender][commitmentId];

        if (lock.stakeAmount == 0) revert Errors.CommitmentNotLocked(msg.sender, commitmentId);
        if (lock.orgId != orgId) revert Errors.CommitmentLockOrgMismatch(orgId, lock.orgId);
        if (returnAmount > lock.stakeAmount) revert Errors.ExceedsLockedAmount(returnAmount, lock.stakeAmount);

        delete _commitmentLocks[msg.sender][commitmentId];

        OrgCommitmentBalance storage balance = _commitmentBalances[orgId];
        uint256 slashedAmount = lock.stakeAmount - returnAmount;

        balance.lockedInCommitments -= lock.stakeAmount;
        balance.available += returnAmount.toUint96();
        _totalAccountedBalance -= slashedAmount;

        if (slashedAmount > 0) {
            stakeToken.safeTransfer(SLASH_BURN_ADDRESS, slashedAmount);
            emit StakeBurned(msg.sender, orgId, commitmentId, slashedAmount);
        }

        _checkBalanceInvariant();

        emit CommitmentStakeSettled(msg.sender, orgId, commitmentId, returnAmount, slashedAmount);
    }

    /// @inheritdoc ICommitmentFunds
    function setCommitmentManager(uint256 orgId, address account, bool active) external {
        if (account == address(0)) revert Errors.ZeroAddress();

        address actor = _actor();

        _requireOrgAdmin(orgId, actor);

        bool changed = _setActive(_commitmentManagers[orgId], account, active);

        emit CommitmentManagerUpdated(orgId, account, active, actor, changed);
    }

    /// @notice Authorize a ResponseCommitment deployment for activation and settlement.
    /// @param responseCommitment ResponseCommitment address to authorize.
    /// @param expectedVersion Exact immutable version expected from the deployment.
    function registerResponseCommitment(address responseCommitment, uint32 expectedVersion) external onlyOwner {
        if (responseCommitment == address(0)) revert Errors.ZeroAddress();
        if (_registeredResponseCommitments[responseCommitment].exists) {
            revert Errors.ResponseCommitmentAlreadyRegistered(responseCommitment);
        }

        if (expectedVersion == 0) revert Errors.InvalidResponseCommitment(responseCommitment);
        _validateResponseCommitment(responseCommitment, expectedVersion);

        _registeredResponseCommitments[responseCommitment] =
            RegisteredResponseCommitment({commitmentVersion: expectedVersion, exists: true});

        emit ResponseCommitmentRegistered(responseCommitment, expectedVersion);
    }

    /// @notice Set the current create-capable ResponseCommitment contract.
    /// @param responseCommitment Authorized ResponseCommitment that can create commitments.
    function setCurrentResponseCommitment(address responseCommitment) external onlyOwner {
        if (responseCommitment == address(0)) revert Errors.ZeroAddress();

        RegisteredResponseCommitment memory config = _registeredResponseCommitments[responseCommitment];

        if (!config.exists) revert Errors.ResponseCommitmentNotRegistered(responseCommitment);
        _validateResponseCommitment(responseCommitment, config.commitmentVersion);

        address previous = _currentResponseCommitment;
        _currentResponseCommitment = responseCommitment;

        emit CurrentResponseCommitmentUpdated(previous, responseCommitment);
    }

    /// @notice Update the recipient of commitment activation fees.
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

    /// @dev Emits the CommitmentFunds rescue event after the shared rescue transfer succeeds.
    function _emitTokensRescued(address token, address to, uint256 amount) internal override {
        emit TokensRescued(token, to, amount);
    }

    /// @inheritdoc ICommitmentFunds
    function availableBalance(uint256 orgId) external view returns (uint256 available) {
        return _commitmentBalances[orgId].available;
    }

    /// @inheritdoc ICommitmentFunds
    function commitmentBalance(uint256 orgId) external view returns (OrgCommitmentBalance memory balance) {
        return _commitmentBalances[orgId];
    }

    /// @inheritdoc ICommitmentFunds
    function commitmentLock(address responseCommitment, uint256 commitmentId)
        external
        view
        returns (CommitmentLock memory lock)
    {
        return _commitmentLocks[responseCommitment][commitmentId];
    }

    /// @inheritdoc ICommitmentFunds
    function totalAccountedBalance() external view returns (uint256 total) {
        return _totalAccountedBalance;
    }

    /// @inheritdoc ICommitmentFunds
    function isCommitmentManager(uint256 orgId, address account) external view returns (bool active) {
        if (!orgRegistry.orgExists(orgId)) revert Errors.OrgNotFound(orgId);

        return _commitmentManagers[orgId].contains(account);
    }

    /// @inheritdoc ICommitmentFunds
    function canManageCommitments(uint256 orgId, address account) public view returns (bool allowed) {
        return _canManageCommitments(orgId, account);
    }

    /// @inheritdoc ICommitmentFunds
    function registeredResponseCommitment(address responseCommitment)
        external
        view
        returns (RegisteredResponseCommitment memory config)
    {
        return _registeredResponseCommitments[responseCommitment];
    }

    /// @inheritdoc ICommitmentFunds
    function currentResponseCommitment() external view returns (address responseCommitment) {
        return _currentResponseCommitment;
    }

    function _creditDeposit(uint256 orgId, address orgTreasury_, uint256 amount) private {
        _commitmentBalances[orgId].available += amount.toUint96();
        _totalAccountedBalance += amount;

        _checkBalanceInvariant();

        emit CommitmentFundsDeposited(orgId, orgTreasury_, amount);
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

    function _canManageCommitments(uint256 orgId, address account) private view returns (bool) {
        return orgRegistry.isOrgAdmin(orgId, account) || _commitmentManagers[orgId].contains(account);
    }

    function _setActive(EnumerableSet.AddressSet storage set, address account, bool active) private returns (bool) {
        return active ? set.add(account) : set.remove(account);
    }

    function _validateResponseCommitment(address responseCommitment, uint32 expectedVersion) private view {
        if (responseCommitment.code.length == 0) revert Errors.ContractExpected(responseCommitment);
        if (!_matchesResponseCommitmentRegistration(responseCommitment, expectedVersion)) {
            revert Errors.InvalidResponseCommitment(responseCommitment);
        }
    }

    function _matchesResponseCommitmentRegistration(address responseCommitment, uint32 expectedVersion)
        private
        view
        returns (bool)
    {
        IResponseCommitmentModule registered = IResponseCommitmentModule(responseCommitment);

        try registered.commitmentVersion() returns (uint32 version) {
            if (version != expectedVersion) return false;
        } catch {
            return false;
        }

        try registered.commitmentFunds() returns (ICommitmentFunds funds) {
            return address(funds) == address(this);
        } catch {
            return false;
        }
    }

    function _checkBalanceInvariant() private view {
        InvariantsLib.assertBalanceGte(stakeToken, address(this), _totalAccountedBalance);
    }
}
