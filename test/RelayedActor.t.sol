// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {JobCommitmentTestBase} from "./shared/TestBase.sol";
import {ApplicationView, JobView} from "../src/interfaces/IJobCommitment.sol";
import {OrgView} from "../src/interfaces/IOrgRegistry.sol";
import {Errors} from "../src/Errors.sol";
import {JobStatus} from "../src/types/JobTypes.sol";

contract RelayedActorTest is JobCommitmentTestBase {
    bytes32 private constant FORWARDER_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );
    bytes32 private constant FORWARDER_NAME_HASH = keccak256(bytes("ComitiumForwarder"));
    bytes32 private constant FORWARDER_VERSION_HASH = keccak256(bytes("1"));

    function test_forwarderConfiguredOnRelayedTargets() public view {
        assertEq(orgRegistry.trustedForwarder(), address(forwarder));
        assertEq(jobFunds.trustedForwarder(), address(forwarder));
        assertEq(jobCommitment.trustedForwarder(), address(forwarder));
    }

    function test_forwardedOrgAdminOperationsUseOriginalActor() public {
        _forwardAs(
            employer, address(orgRegistry), abi.encodeCall(orgRegistry.setOrgAdmin, (DEFAULT_ORG_ID, applicant1, true))
        );

        assertTrue(orgRegistry.isOrgAdmin(DEFAULT_ORG_ID, applicant1));

        _forwardAs(
            employer,
            address(orgRegistry),
            abi.encodeCall(orgRegistry.updateContentURI, (DEFAULT_ORG_ID, "ipfs://org-metadata"))
        );

        OrgView memory org = orgRegistry.org(DEFAULT_ORG_ID);

        assertEq(org.contentURI, "ipfs://org-metadata");
    }

    function test_forwardedSetJobManagerUsesOriginalActor() public {
        _forwardAs(
            employer, address(jobFunds), abi.encodeCall(jobFunds.setJobManager, (DEFAULT_ORG_ID, applicant1, true))
        );

        assertTrue(jobFunds.isJobManager(DEFAULT_ORG_ID, applicant1));
        assertTrue(jobFunds.canManageJobs(DEFAULT_ORG_ID, applicant1));
    }

    function test_forwardedCreateJobUsesOriginalActor() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "ipfs://job-v1", employer, keyNonce, expiry);

        bytes memory result = _forwardAs(
            employer,
            address(jobFunds),
            abi.encodeCall(
                jobFunds.publishJob,
                (
                    address(jobCommitment),
                    DEFAULT_ORG_ID,
                    EMPLOYER_STAKE,
                    _jobPublishFee(EMPLOYER_STAKE, 0),
                    feeRecipient,
                    abi.encode(uint8(0), "ipfs://job-v1", keyNonce, expiry, signature)
                )
            )
        );
        uint256 jobId = abi.decode(result, (uint256));

        JobView memory job = jobCommitment.job(jobId);

        assertEq(job.creator, employer);
        assertEq(job.contentURI, "ipfs://job-v1");
    }

    function test_forwardedUnpublishAndCloseUseOriginalActor() public {
        uint256 unpublishJobId = _publishJob(0);
        uint256 unpublishKeyNonce = _nextJobUnpublishKeyNonce();
        uint256 unpublishExpiry = block.timestamp + 1 hours;
        bytes memory unpublishSignature =
            _signJobUnpublish(unpublishJobId, employer, unpublishKeyNonce, unpublishExpiry);

        _forwardAs(
            employer,
            address(jobCommitment),
            abi.encodeCall(
                jobCommitment.unpublishJob, (unpublishJobId, unpublishKeyNonce, unpublishExpiry, unpublishSignature)
            )
        );

        assertEq(uint8(jobCommitment.job(unpublishJobId).status), uint8(JobStatus.Unpublished));

        uint256 terminalJobId = _publishJob(0);
        _unpublishJob(terminalJobId);
        uint256 closeKeyNonce = _nextJobCloseKeyNonce();
        uint256 closeExpiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory closeSignature =
            _signJobClose(terminalJobId, 0, 0, 0, counterSnapshotRoot, employer, closeKeyNonce, closeExpiry);

        _forwardAs(
            employer,
            address(jobCommitment),
            abi.encodeCall(
                jobCommitment.closeJob,
                (terminalJobId, 0, 0, 0, counterSnapshotRoot, closeKeyNonce, closeExpiry, closeSignature)
            )
        );

        assertEq(uint8(jobCommitment.job(terminalJobId).status), uint8(JobStatus.Closed));
    }

    function test_ozForwarderExecuteRelaysJobContentURIUpdate() public {
        uint256 relayedManagerPrivateKey = 0xA11CE;
        address relayedManager = vm.addr(relayedManagerPrivateKey);

        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, relayedManager, true);

        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory operatorSignature =
            _signJobContentURIUpdate(jobId, "ipfs://job-forwarder", relayedManager, keyNonce, expiry);
        bytes memory callData = abi.encodeCall(
            jobCommitment.updateJobContentURI, (jobId, "ipfs://job-forwarder", keyNonce, expiry, operatorSignature)
        );

        ERC2771Forwarder.ForwardRequestData memory request =
            _forwardRequest(relayedManagerPrivateKey, address(jobCommitment), callData);

        assertTrue(forwarder.verify(request));

        vm.prank(operator);
        forwarder.execute(request);

        assertEq(jobCommitment.job(jobId).contentURI, "ipfs://job-forwarder");
        assertEq(forwarder.nonces(relayedManager), 1);
    }

    function test_updateJobContentURI_success() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        _forwardAs(
            employer,
            address(jobCommitment),
            abi.encodeCall(jobCommitment.updateJobContentURI, (jobId, "ipfs://job-v2", keyNonce, expiry, signature))
        );

        assertEq(jobCommitment.job(jobId).contentURI, "ipfs://job-v2");
    }

    function test_updateJobContentURI_revertsForUnpublishedJob() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidJobStatus.selector, JobStatus.Unpublished, JobStatus.Published)
        );
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, signature);
    }

    function test_updateJobContentURI_revertsForNonManager() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobContentURIUpdate(jobId, "ipfs://job-v2", applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, signature);
    }

    function test_updateJobContentURI_revertsForWrongNonceScope() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_JOB_UNPUBLISH, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector, NONCE_SCOPE_JOB_UNPUBLISH, NONCE_SCOPE_JOB_CONTENT_URI_UPDATE
            )
        );
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, signature);
    }

    function test_forwardedCustodyFlowsUseOriginalActorButExecutorPathStaysRaw() public {
        uint256 depositAmount = 1_000_000;
        uint256 availableBefore = jobFunds.availableBalance(DEFAULT_ORG_ID);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("forwarded-job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(jobFunds), employerPrivateKey, depositAmount, validAfter, validBefore, nonce
        );

        usdc.mint(employer, depositAmount);
        _forwardAs(
            employer,
            address(jobFunds),
            abi.encodeCall(
                jobFunds.depositWithAuthorization,
                (DEFAULT_ORG_ID, depositAmount, validAfter, validBefore, nonce, v, r, s)
            )
        );

        assertEq(jobFunds.availableBalance(DEFAULT_ORG_ID), availableBefore + depositAmount);

        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory applicationSignature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        _forwardAs(
            applicant1,
            address(jobCommitment),
            abi.encodeCall(
                jobCommitment.submitApplication,
                (applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, applicationSignature)
            )
        );

        ApplicationView memory application = jobCommitment.application(applicationId);

        assertEq(application.applicant, applicant1);
        assertEq(application.stake, APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore - APPLICANT_STAKE);

        bytes32 directApplicationId = _applyToJob(applicant1);
        bytes32 responseId = _generateResponseId(directApplicationId);

        vm.expectRevert(Errors.NotExecutor.selector);
        _forwardAs(
            operator,
            address(jobCommitment),
            abi.encodeCall(jobCommitment.recordApplicationResponse, (directApplicationId, responseId))
        );
    }

    function test_nonConfiguredForwarderCannotSpoofJobCreator() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "ipfs://job-v1", employer, keyNonce, expiry);
        bytes memory callData = abi.encodeCall(
            jobFunds.publishJob,
            (
                address(jobCommitment),
                DEFAULT_ORG_ID,
                EMPLOYER_STAKE,
                _jobPublishFee(EMPLOYER_STAKE, 0),
                feeRecipient,
                abi.encode(uint8(0), "ipfs://job-v1", keyNonce, expiry, signature)
            )
        );

        vm.prank(applicant1);
        (bool success, bytes memory revertData) = address(jobFunds).call(bytes.concat(callData, bytes20(employer)));

        assertFalse(success);
        assertEq(revertData, abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
    }

    // ============ Owner-control spoof resistance ============
    // A relayed call appends the actor as a 20-byte suffix, but OwnerControls._msgSender() deliberately
    // returns the raw sender (the forwarder), so onlyOwner can never be satisfied through the ERC-2771
    // forwarder — even when the real owner signs the forward request. If _msgSender() ever regressed to
    // _actor(), these would fail, which is exactly the regression we want to catch.

    function test_forwardedCallCannotSpoofOwner_jobCommitmentPause() public {
        // Sanity control: a direct owner call works, so the revert below is caused by the forwarding,
        // not by an incorrect owner address.
        vm.prank(owner);
        jobCommitment.pause();
        assertTrue(jobCommitment.paused());
        vm.prank(owner);
        jobCommitment.unpause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(jobCommitment), abi.encodeCall(jobCommitment.pause, ()));
    }

    function test_forwardedCallCannotSpoofOwner_jobFundsPause() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(jobFunds), abi.encodeCall(jobFunds.pause, ()));
    }

    function test_forwardedCallCannotSpoofOwner_orgRegistryPause() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(orgRegistry), abi.encodeCall(orgRegistry.pause, ()));
    }

    function test_forwardedCallCannotSpoofOwner_addOperator() public {
        address rogueOperator = makeAddr("rogueOperator");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(jobCommitment), abi.encodeCall(jobCommitment.addOperator, (rogueOperator)));
    }

    function test_forwardedCallCannotSpoofOwner_rescueTokens() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(jobFunds), abi.encodeCall(jobFunds.rescueTokens, (address(usdc), owner, 1)));
    }

    function _forwardRequest(uint256 signerPrivateKey, address to, bytes memory callData)
        private
        view
        returns (ERC2771Forwarder.ForwardRequestData memory)
    {
        address signer = vm.addr(signerPrivateKey);
        uint256 gasLimit = 1_000_000;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        return ERC2771Forwarder.ForwardRequestData({
            from: signer,
            to: to,
            value: 0,
            gas: gasLimit,
            deadline: deadline,
            data: callData,
            signature: _signForwardRequest(signerPrivateKey, to, gasLimit, deadline, callData)
        });
    }

    function _signForwardRequest(
        uint256 signerPrivateKey,
        address to,
        uint256 gasLimit,
        uint48 deadline,
        bytes memory callData
    ) private view returns (bytes memory) {
        address signer = vm.addr(signerPrivateKey);
        bytes32 structHash = keccak256(
            abi.encode(
                FORWARD_REQUEST_TYPEHASH,
                signer,
                to,
                uint256(0),
                gasLimit,
                forwarder.nonces(signer),
                deadline,
                keccak256(callData)
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                FORWARDER_DOMAIN_TYPEHASH,
                FORWARDER_NAME_HASH,
                FORWARDER_VERSION_HASH,
                block.chainid,
                address(forwarder)
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }
}
