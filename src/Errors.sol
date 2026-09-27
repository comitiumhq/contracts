// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CommitmentStatus} from "./types/CommitmentTypes.sol";

/// @title Errors
/// @notice Custom errors shared across Comitium contracts.
library Errors {
    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Invalid signature
    error InvalidSignature();

    /// @notice Contract ownership cannot be renounced
    error RenounceDisabled();

    /// @notice Signature has expired
    error SignatureExpired();

    /// @notice Packed NoncesKeyed nonce uses the wrong operation scope
    error InvalidNonceScope(uint16 provided, uint16 expected);

    /// @notice Zero amount provided where positive value required
    error ZeroAmount();

    /// @notice Caller/address is not an EIP-712 signing operator
    error NotOperator();

    /// @notice Address is already registered as an EIP-712 signing operator
    error OperatorAlreadyRegistered(address operator);

    /// @notice Cannot remove the last EIP-712 signing operator
    error CannotRemoveLastOperator();

    /// @notice Caller/address is not a privileged direct-call executor
    error NotExecutor();

    /// @notice Address is already registered as a privileged direct-call executor
    error ExecutorAlreadyRegistered(address executor);

    /// @notice Cannot remove the last privileged direct-call executor
    error CannotRemoveLastExecutor();

    /// @notice EIP-712 signing operator and direct-call executor roles must remain separate
    error ProtocolRoleConflict(address account);

    /// @notice Rescue amount exceeds available surplus
    error RescueExceedsSurplus(uint256 requested, uint256 available);

    /// @notice Expected a deployed contract at the provided address
    error ContractExpected(address target);

    /// @notice Protocol fee recipient address is not allowed
    error InvalidFeeRecipient(address recipient);

    /// @notice Signed fee recipient no longer matches the current protocol recipient
    error FeeRecipientMismatch(address expected, address current);

    /// @notice Signed activation fee does not match the selected commitment configuration
    error FeeAmountMismatch(uint256 expected, uint256 actual);

    /// @notice Commitment contract does not match this CommitmentFunds configuration
    error InvalidResponseCommitment(address responseCommitment);

    // ============ Organization ============

    /// @notice Caller/address is not an org admin
    error NotOrgAdmin(uint256 orgId, address account);

    /// @notice Caller/address is not the org treasury
    error NotOrgTreasury(uint256 orgId, address account);

    /// @notice Caller/address is not the org treasury or an org admin
    error NotOrgTreasuryOrAdmin(uint256 orgId, address account);

    /// @notice Org treasury address is not allowed
    error InvalidOrgTreasury(address treasury);

    /// @notice Cannot remove the last active org admin
    error CannotRemoveLastOrgAdmin(uint256 orgId);

    /// @notice Org admins cannot change their own org-admin status
    error CannotUpdateOwnOrgAdmin(uint256 orgId, address account);

    /// @notice Organization does not exist
    error OrgNotFound(uint256 orgId);

    /// @notice Zero domain hash not allowed
    error ZeroDomainHash();

    /// @notice New org domain hash must differ from the current hash
    error SameOrgDomainHash(uint256 orgId, bytes32 domainHash);

    /// @notice Provided current domain hash does not match stored org state
    error OrgDomainHashMismatch(uint256 orgId, bytes32 provided, bytes32 expected);

    /// @notice A treasury transfer proposal already exists
    error PendingOrgTreasuryExists(uint256 orgId, address proposedTreasury);

    /// @notice No treasury transfer proposal exists
    error NoPendingOrgTreasury(uint256 orgId);

    /// @notice Caller is not the proposed org treasury
    error NotProposedOrgTreasury(uint256 orgId, address account);

    /// @notice Proposed treasury has not accepted yet
    error OrgTreasuryNotAccepted(uint256 orgId);

    /// @notice Proposed treasury must differ from the current org treasury
    error SameOrgTreasury(uint256 orgId, address treasury);

    // ============ Commitment Funds ============

    /// @notice Commitment contract is not registered
    error ResponseCommitmentNotRegistered(address responseCommitment);

    /// @notice Commitment contract is already registered
    error ResponseCommitmentAlreadyRegistered(address responseCommitment);

    /// @notice Commitment contract is not the current deployment used for new commitments
    error ResponseCommitmentNotCurrent(address requested, address current);

    /// @notice Commitment is already locked for this ResponseCommitment
    error CommitmentAlreadyLocked(address responseCommitment, uint256 commitmentId);

    /// @notice Commitment is not locked for this ResponseCommitment
    error CommitmentNotLocked(address responseCommitment, uint256 commitmentId);

    /// @notice Provided org ID does not match the stored lock org ID
    error CommitmentLockOrgMismatch(uint256 providedOrgId, uint256 lockedOrgId);

    /// @notice Return amount exceeds the original locked amount
    error ExceedsLockedAmount(uint256 returnAmount, uint256 originalAmount);

    /// @notice Available balance is too low
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Account is not authorized to manage commitments for the org
    error NotCommitmentManager(uint256 orgId, address account);

    /// @notice Caller is not the CommitmentFunds contract bound to this ResponseCommitment
    error NotCommitmentFunds(address caller);

    // ============ Response Commitment ============

    /// @notice Stake amount is below minimum
    error StakeTooLow(uint256 provided, uint256 minimum);

    /// @notice Invalid fee tier
    error InvalidFeeTier(uint8 provided);

    /// @notice Commitment does not exist
    error CommitmentNotFound(uint256 commitmentId);

    /// @notice Commitment is not in the expected status
    error InvalidCommitmentStatus(CommitmentStatus current, CommitmentStatus expected);

    /// @notice Commitment has already been settled
    error CommitmentAlreadySettled(uint256 commitmentId);

    /// @notice Application does not exist
    error ApplicationNotFound(bytes32 applicationId);

    /// @notice Application ID cannot be zero
    error ZeroApplicationId();

    /// @notice Response ID cannot be zero
    error ZeroResponseId();

    /// @notice Application already responded to
    error ApplicationAlreadyResponded(bytes32 applicationId);

    /// @notice Commitment has not expired yet
    error CommitmentNotExpired(uint256 referenceTime, uint256 expirationPeriod, uint256 currentTime);

    /// @notice Application ID already used
    error ApplicationIdAlreadyUsed(bytes32 applicationId);

    /// @notice Posting reference cannot be zero
    error ZeroPostingRef();

    /// @notice Content URI cannot be empty
    error EmptyContentURI();

    /// @notice Counters mismatch: not all applications responded
    error NotAllResponded(uint32 responded, uint32 total);

    /// @notice Counter invariant violated
    error InvalidCounters(uint32 totalApplications, uint32 respondedApplications, uint32 onTimeResponses);

    /// @notice Non-zero counter snapshot root is required when counters include applications
    error CounterSnapshotRootRequired();

    /// @notice Response deadline days must be valid for the active config
    error InvalidDeadline();

    /// @notice Array lengths do not match
    error ArrayLengthMismatch();

    /// @notice Batch cannot be empty
    error EmptyBatch();

    /// @notice Batch exceeds maximum size
    error BatchTooLarge(uint256 provided, uint256 maximum);

    // ============ Slashing ============

    /// @notice On-time response count exceeds total applications
    error InvalidSlashCounters(uint256 totalApplications, uint256 onTimeResponses);

    /// @notice Slash rate exceeds 100%
    error InvalidSlashRate(uint256 slashBps);

    // ============ Config Validation ============

    /// @notice Config value below allowed minimum
    /// @param field Name of the config field that failed validation
    error ConfigValueTooLow(bytes32 field);

    /// @notice Config value above allowed maximum
    /// @param field Name of the config field that failed validation
    error ConfigValueTooHigh(bytes32 field);

    /// @notice Config value outside allowed range
    /// @param field Name of the config field that failed validation
    error ConfigValueOutOfRange(bytes32 field);

    /// @notice Configuration tier or slashing ordering violated
    error InvalidTierOrdering();

    /// @notice Commitment duration ordering violated (active must exceed stopped)
    error InvalidDurationOrdering();

    /// @notice Slashing rate ordering violated (must be monotonically decreasing)
    error InvalidSlashingOrdering();
}
