// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JobStorageLayout} from "./JobStorageLayout.sol";
import {JobLib} from "../libraries/JobLib.sol";
import {APPLICATION_DEADLINE_DAYS_UPPER} from "../libraries/ConfigValidationLib.sol";
import {JobAuthorizationLib} from "../libraries/JobAuthorizationLib.sol";
import {Application} from "../types/JobTypes.sol";
import {IJobCommitment} from "../interfaces/IJobCommitment.sol";
import {Errors} from "../Errors.sol";

/// @title JobApplication
/// @notice Application submission and executor response marking.
/// @dev The contract does not know which job an application belongs to.
///      The operator-signed payload binds the application identity, applicant, and response deadline.
abstract contract JobApplication is JobStorageLayout {
    using SafeCast for uint256;

    /// @notice Record an application authorized by an operator signature.
    /// @param applicationId Unique application ID
    /// @param responseDeadlineDays Days for employer to respond (from operator signature)
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving this application
    /// @param requestHash Hash of the sender-stripped submitApplication calldata.
    function _submitApplication(
        bytes32 applicationId,
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

        address actor = _actor();
        bytes32 structHash = JobAuthorizationLib.hashApplication(applicationId, actor, responseDeadlineDays, expiry);
        _verifyOperatorAuthorization(structHash, expiry, signature);

        _markApplicationIdUsed(applicationId);

        uint256 responseDeadline = JobLib.getResponseDeadline(block.timestamp, responseDeadlineDays);

        Application storage application = _applications[applicationId];
        application.applicant = actor;
        application.appliedAt = block.timestamp.toUint40();
        application.responseDeadline = responseDeadline.toUint40();

        emit IJobCommitment.ApplicationSubmitted(applicationId, actor, responseDeadline, requestHash);
    }

    // ============ Response ============

    /// @notice Record multiple application responses.
    /// @param applicationIds Array of application IDs to respond to
    /// @param responseIds Array of response IDs (one per application)
    function _recordApplicationResponses(bytes32[] calldata applicationIds, bytes32[] calldata responseIds) internal {
        if (applicationIds.length != responseIds.length) revert Errors.ArrayLengthMismatch();
        if (applicationIds.length == 0) revert Errors.EmptyBatch();

        uint16 maxBatchSize = _jobConfigs[_currentConfigVersion].maxBatchSize;

        if (applicationIds.length > maxBatchSize) revert Errors.BatchTooLarge(applicationIds.length, maxBatchSize);

        for (uint256 i = 0; i < applicationIds.length; i++) {
            _recordApplicationResponse(applicationIds[i], responseIds[i]);
        }
    }

    /// @notice Record an application response.
    /// @param applicationId Application to respond to
    /// @param responseId Non-zero response identifier
    function _recordApplicationResponse(bytes32 applicationId, bytes32 responseId) internal {
        if (applicationId == bytes32(0)) revert Errors.ZeroApplicationId();
        if (responseId == bytes32(0)) revert Errors.ZeroResponseId();

        Application storage application = _application(applicationId);

        if (application.appliedAt == 0) revert Errors.ApplicationNotFound(applicationId);
        if (application.isResponded) revert Errors.ApplicationAlreadyResponded(applicationId);

        application.isResponded = true;
        application.respondedAt = block.timestamp.toUint40();

        emit IJobCommitment.ApplicationResponded(applicationId, msg.sender, responseId);
    }
}
