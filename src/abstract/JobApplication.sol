// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JobStorageLayout} from "./JobStorageLayout.sol";
import {JobLib} from "../libraries/JobLib.sol";
import {APPLICATION_DEADLINE_DAYS_UPPER} from "../libraries/ConfigValidationLib.sol";
import {JobAuthorizationLib} from "../libraries/JobAuthorizationLib.sol";
import {Application} from "../types/JobTypes.sol";
import {IJobCommitment, StakeReturnInfo, StakeReturnOutcome, StakeReturnStatus} from "../interfaces/IJobCommitment.sol";
import {Errors} from "../Errors.sol";

/// @title JobApplication
/// @notice Applicant-stake lifecycle: submit, executor response marking, and stake withdrawal.
/// @dev The contract does not know which job an application belongs to.
///      The operator-signed payload binds the application identity, applicant, stake, and response deadline.
abstract contract JobApplication is JobStorageLayout {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Stake token (USDC)
    function _stakeToken() internal view virtual returns (IERC20);

    /// @notice Submit a privacy-preserving application authorized by an operator signature
    /// @param applicationId Unique application ID
    /// @param stake Protocol-selected application stake amount
    /// @param responseDeadlineDays Days for employer to respond (from operator signature)
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving this application
    /// @param requestHash Hash of the sender-stripped submitApplication calldata.
    function _submitApplication(
        bytes32 applicationId,
        uint96 stake,
        uint8 responseDeadlineDays,
        uint256 expiry,
        bytes calldata signature,
        bytes32 requestHash
    ) internal {
        if (applicationId == bytes32(0)) revert Errors.ZeroApplicationId();

        if (_isApplicationIdUsed(applicationId)) revert Errors.ApplicationIdAlreadyUsed(applicationId);

        if (responseDeadlineDays == 0 || responseDeadlineDays > APPLICATION_DEADLINE_DAYS_UPPER) {
            revert Errors.InvalidDeadline();
        }

        if (stake != _applicantStakeAmount) revert Errors.InvalidApplicantStake(stake, _applicantStakeAmount);

        address actor = _actor();

        _validateApplication(applicationId, actor, stake, responseDeadlineDays, expiry, signature);

        _markApplicationIdUsed(applicationId);

        uint256 responseDeadline = JobLib.getResponseDeadline(block.timestamp, responseDeadlineDays);

        Application storage application = _applications[applicationId];
        application.applicant = actor;
        application.stake = stake;
        application.appliedAt = block.timestamp.toUint40();
        application.responseDeadline = responseDeadline.toUint40();

        _totalApplicantStakes += stake;

        _stakeToken().safeTransferFrom(actor, address(this), stake);

        _checkApplicantStakeInvariant();

        emit IJobCommitment.ApplicationSubmitted(applicationId, actor, stake, responseDeadline, requestHash);
    }

    /// @notice Validate application signature using EIP-712
    function _validateApplication(
        bytes32 applicationId,
        address applicant,
        uint96 stake,
        uint8 responseDeadlineDays,
        uint256 expiry,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = JobAuthorizationLib.hashApplication(
            applicationId, applicant, stake, responseDeadlineDays, expiry
        );

        _verifyOperatorAuthorization(structHash, expiry, signature);
    }

    // ============ Response ============

    /// @notice Record an application response.
    /// @param applicationId Application to respond to
    /// @param responseId Non-zero response identifier
    function _recordApplicationResponse(bytes32 applicationId, bytes32 responseId) internal {
        _applyResponse(applicationId, responseId);
    }

    /// @notice Record multiple application responses.
    /// @param applicationIds Array of application IDs to respond to
    /// @param responseIds Array of response IDs (one per application)
    function _recordApplicationResponses(bytes32[] calldata applicationIds, bytes32[] calldata responseIds) internal {
        if (applicationIds.length != responseIds.length) revert Errors.ArrayLengthMismatch();
        if (applicationIds.length == 0) revert Errors.EmptyBatch();

        uint16 maxBatchSize = _jobConfigs[_currentConfigVersion].maxBatchSize;

        if (applicationIds.length > maxBatchSize) revert Errors.BatchTooLarge(applicationIds.length, maxBatchSize);

        for (uint256 i = 0; i < applicationIds.length; i++) {
            _applyResponse(applicationIds[i], responseIds[i]);
        }
    }

    /// @notice Mark an application as responded and emit the response event.
    /// @param applicationId Application to respond to
    /// @param responseId Non-zero response identifier
    function _applyResponse(bytes32 applicationId, bytes32 responseId) private {
        if (applicationId == bytes32(0)) revert Errors.ZeroApplicationId();
        if (responseId == bytes32(0)) revert Errors.ZeroResponseId();

        Application storage application = _application(applicationId);

        if (application.appliedAt == 0) revert Errors.ApplicationNotFound(applicationId);
        if (application.isResponded) revert Errors.ApplicationAlreadyResponded(applicationId);

        application.isResponded = true;
        application.respondedAt = block.timestamp.toUint40();

        emit IJobCommitment.ApplicationResponded(applicationId, msg.sender, responseId);
    }

    // ============ Withdrawal ============

    /// @notice Withdraw applicant stake after response or deadline passed.
    /// @dev No job lookup needed — withdrawal conditions are per-application only
    /// @param applicationId Application to withdraw from
    function _withdrawStake(bytes32 applicationId) internal {
        Application storage application = _application(applicationId);

        if (application.appliedAt == 0) revert Errors.ApplicationNotFound(applicationId);
        if (application.stakeWithdrawn) revert Errors.StakeAlreadyWithdrawn();
        if (!_isStakeReturnReady(application)) revert Errors.WithdrawalNotReady();

        _returnApplicantStake(applicationId, application);
    }

    /// @notice Return multiple eligible applicant stakes, skipping stale IDs.
    function _withdrawStakes(bytes32[] calldata applicationIds)
        internal
        returns (uint16 returnedCount, uint16 skippedCount, uint256 totalReturned)
    {
        if (applicationIds.length == 0) revert Errors.EmptyBatch();

        uint16 maxBatchSize = _jobConfigs[_currentConfigVersion].maxBatchSize;

        if (applicationIds.length > maxBatchSize) revert Errors.BatchTooLarge(applicationIds.length, maxBatchSize);

        for (uint256 i = 0; i < applicationIds.length; i++) {
            Application storage application = _application(applicationIds[i]);
            StakeReturnStatus status = _stakeReturnStatus(application);

            if (status != StakeReturnStatus.Returnable) {
                emit IJobCommitment.ApplicantStakeReturnProcessed(
                    applicationIds[i], application.applicant, application.stake, _stakeReturnOutcome(status)
                );
                skippedCount++;
                continue;
            }

            totalReturned += _returnApplicantStake(applicationIds[i], application);
            returnedCount++;
        }
    }

    /// @notice Get return eligibility and display data for an application.
    function _stakeReturnInfo(bytes32 applicationId) internal view returns (StakeReturnInfo memory info) {
        Application storage application = _application(applicationId);

        return StakeReturnInfo({
            status: _stakeReturnStatus(application),
            applicant: application.applicant,
            stake: application.stake,
            responseDeadline: application.responseDeadline,
            isResponded: application.isResponded
        });
    }

    function _returnApplicantStake(bytes32 applicationId, Application storage application)
        private
        returns (uint256 amount)
    {
        address recipient = application.applicant;
        amount = application.stake;

        application.stakeWithdrawn = true;
        _totalApplicantStakes -= amount;

        _stakeToken().safeTransfer(recipient, amount);

        _checkApplicantStakeInvariant();

        emit IJobCommitment.ApplicantStakeReturnProcessed(applicationId, recipient, amount, StakeReturnOutcome.Returned);
    }

    function _stakeReturnStatus(Application storage application) private view returns (StakeReturnStatus) {
        if (application.appliedAt == 0) return StakeReturnStatus.ApplicationNotFound;
        if (application.stakeWithdrawn) return StakeReturnStatus.AlreadyWithdrawn;
        if (_isStakeReturnReady(application)) return StakeReturnStatus.Returnable;

        return StakeReturnStatus.NotReady;
    }

    function _stakeReturnOutcome(StakeReturnStatus status) private pure returns (StakeReturnOutcome) {
        if (status == StakeReturnStatus.AlreadyWithdrawn) return StakeReturnOutcome.AlreadyWithdrawn;
        if (status == StakeReturnStatus.NotReady) return StakeReturnOutcome.NotReady;

        return StakeReturnOutcome.ApplicationNotFound;
    }

    function _isStakeReturnReady(Application storage application) private view returns (bool) {
        return application.isResponded || block.timestamp > application.responseDeadline;
    }
}
