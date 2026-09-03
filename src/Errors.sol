// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobStatus} from "./types/JobTypes.sol";

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

    /// @notice Signed publishing fee does not match the selected commitment configuration
    error FeeAmountMismatch(uint256 expected, uint256 actual);

    /// @notice Commitment contract does not match this JobFunds configuration
    error InvalidJobCommitment(address jobCommitment);

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

    // ============ Job Funds ============

    /// @notice Commitment contract is not registered
    error JobCommitmentNotRegistered(address jobCommitment);

    /// @notice Commitment contract is already registered
    error JobCommitmentAlreadyRegistered(address jobCommitment);

    /// @notice Commitment contract is not the current deployment used for new jobs
    error JobCommitmentNotCurrent(address requested, address current);

    /// @notice Job is already locked for this JobCommitment
    error JobAlreadyLocked(address jobCommitment, uint256 jobId);

    /// @notice Job is not locked for this JobCommitment
    error JobNotLocked(address jobCommitment, uint256 jobId);

    /// @notice Provided org ID does not match the stored lock org ID
    error JobLockOrgMismatch(uint256 providedOrgId, uint256 lockedOrgId);

    /// @notice Return amount exceeds the original locked amount
    error ExceedsLockedAmount(uint256 returnAmount, uint256 originalAmount);

    /// @notice Available balance is too low
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Account is not authorized to manage jobs for the org
    error NotJobManager(uint256 orgId, address account);

    /// @notice Caller is not the JobFunds contract bound to this JobCommitment
    error NotJobFunds(address caller);

    // ============ Job Commitment ============

    /// @notice Stake amount is below minimum
    error StakeTooLow(uint256 provided, uint256 minimum);

    /// @notice Application stake does not match the current amount
    error InvalidApplicantStake(uint96 provided, uint96 current);

    /// @notice New applicant stake amount must differ from the current amount
    error ApplicantStakeAmountUnchanged(uint96 amount);

    /// @notice Invalid fee tier
    error InvalidFeeTier(uint8 provided);

    /// @notice Job does not exist
    error JobNotFound(uint256 jobId);

    /// @notice Job is not in the expected status
    error InvalidJobStatus(JobStatus current, JobStatus expected);

    /// @notice Job has already been closed
    error JobAlreadyClosed(uint256 jobId);

    /// @notice Job org stake has already been settled
    error OrgStakeAlreadySettled(uint256 jobId);

    /// @notice Application does not exist
    error ApplicationNotFound(bytes32 applicationId);

    /// @notice Application ID cannot be zero
    error ZeroApplicationId();

    /// @notice Response ID cannot be zero
    error ZeroResponseId();

    /// @notice Application already responded to
    error ApplicationAlreadyResponded(bytes32 applicationId);

    /// @notice Stake already withdrawn
    error StakeAlreadyWithdrawn();

    /// @notice Cannot withdraw applicant stake yet
    error WithdrawalNotReady();

    /// @notice Job has not expired yet
    error JobNotExpired(uint256 referenceTime, uint256 expirationPeriod, uint256 currentTime);

    /// @notice Application ID already used
    error ApplicationIdAlreadyUsed(bytes32 applicationId);

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

    /// @notice Job duration ordering violated (published must exceed unpublished)
    error InvalidDurationOrdering();

    /// @notice Slashing rate ordering violated (must be monotonically decreasing)
    error InvalidSlashingOrdering();
}
