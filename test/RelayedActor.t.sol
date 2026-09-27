// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ResponseCommitmentTestBase} from "./shared/TestBase.sol";
import {ApplicationView, CommitmentView} from "../src/interfaces/IResponseCommitment.sol";
import {Errors} from "../src/Errors.sol";
import {CommitmentStatus} from "../src/types/CommitmentTypes.sol";

contract RelayedActorTest is ResponseCommitmentTestBase {
    bytes32 private constant FORWARDER_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );
    bytes32 private constant FORWARDER_NAME_HASH = keccak256(bytes("ComitiumForwarder"));
    bytes32 private constant FORWARDER_VERSION_HASH = keccak256(bytes("1"));

    function test_forwarderConfiguredOnRelayedTargets() public view {
        assertEq(orgRegistry.trustedForwarder(), address(forwarder));
        assertEq(commitmentFunds.trustedForwarder(), address(forwarder));
        assertEq(responseCommitment.trustedForwarder(), address(forwarder));
    }

    function test_forwardedOrgAdminOperationUsesOriginalActor() public {
        _forwardAs(
            employer, address(orgRegistry), abi.encodeCall(orgRegistry.setOrgAdmin, (DEFAULT_ORG_ID, applicant1, true))
        );

        assertTrue(orgRegistry.isOrgAdmin(DEFAULT_ORG_ID, applicant1));
    }

    function test_forwardedSetCommitmentManagerUsesOriginalActor() public {
        _forwardAs(
            employer,
            address(commitmentFunds),
            abi.encodeCall(commitmentFunds.setCommitmentManager, (DEFAULT_ORG_ID, applicant1, true))
        );

        assertTrue(commitmentFunds.isCommitmentManager(DEFAULT_ORG_ID, applicant1));
        assertTrue(commitmentFunds.canManageCommitments(DEFAULT_ORG_ID, applicant1));
    }

    function test_forwardedCreateCommitmentUsesOriginalActor() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, DEFAULT_POSTING_REF, employer, keyNonce, expiry
        );

        bytes memory result = _forwardAs(
            employer,
            address(commitmentFunds),
            abi.encodeCall(
                commitmentFunds.activateCommitment,
                (
                    address(responseCommitment),
                    DEFAULT_ORG_ID,
                    EMPLOYER_STAKE,
                    _commitmentActivateFee(EMPLOYER_STAKE, 0),
                    feeRecipient,
                    abi.encode(uint8(0), DEFAULT_POSTING_REF, keyNonce, expiry, signature)
                )
            )
        );
        uint256 commitmentId = abi.decode(result, (uint256));

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);

        assertEq(commitment.creator, employer);
        assertEq(commitment.postingRef, DEFAULT_POSTING_REF);
    }

    function test_forwardedStopAndSettleUseOriginalActor() public {
        uint256 stopCommitmentId = _activateCommitment(0);
        uint256 stopKeyNonce = _nextCommitmentStopKeyNonce();
        uint256 stopExpiry = block.timestamp + 1 hours;
        bytes memory stopSignature = _signCommitmentStop(stopCommitmentId, employer, stopKeyNonce, stopExpiry);

        _forwardAs(
            employer,
            address(responseCommitment),
            abi.encodeCall(
                responseCommitment.stopCommitment, (stopCommitmentId, stopKeyNonce, stopExpiry, stopSignature)
            )
        );

        assertEq(uint8(responseCommitment.commitment(stopCommitmentId).status), uint8(CommitmentStatus.Stopped));

        uint256 terminalCommitmentId = _activateCommitment(0);
        _stopCommitment(terminalCommitmentId);
        uint256 settleKeyNonce = _nextCommitmentSettleKeyNonce();
        uint256 settleExpiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory settleSignature = _signCommitmentSettlement(
            terminalCommitmentId, 0, 0, 0, counterSnapshotRoot, employer, settleKeyNonce, settleExpiry
        );

        _forwardAs(
            employer,
            address(responseCommitment),
            abi.encodeCall(
                responseCommitment.settleCommitment,
                (terminalCommitmentId, 0, 0, 0, counterSnapshotRoot, settleKeyNonce, settleExpiry, settleSignature)
            )
        );

        assertEq(uint8(responseCommitment.commitment(terminalCommitmentId).status), uint8(CommitmentStatus.Settled));
    }

    function test_forwardedCustodyFlowsUseOriginalActorButExecutorPathStaysRaw() public {
        uint256 depositAmount = 1_000_000;
        uint256 availableBefore = commitmentFunds.availableBalance(DEFAULT_ORG_ID);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("forwarded-commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), employerPrivateKey, depositAmount, validAfter, validBefore, nonce
        );

        usdc.mint(employer, depositAmount);
        _forwardAs(
            employer,
            address(commitmentFunds),
            abi.encodeCall(
                commitmentFunds.depositWithAuthorization,
                (DEFAULT_ORG_ID, depositAmount, validAfter, validBefore, nonce, v, r, s)
            )
        );

        assertEq(commitmentFunds.availableBalance(DEFAULT_ORG_ID), availableBefore + depositAmount);

        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory applicationSignature =
            _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        _forwardAs(
            applicant1,
            address(responseCommitment),
            abi.encodeCall(
                responseCommitment.submitApplication,
                (applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, applicationSignature)
            )
        );

        ApplicationView memory application = responseCommitment.application(applicationId);

        assertEq(application.applicant, applicant1);
        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore);

        bytes32 directApplicationId = _submitApplication(applicant1);
        bytes32 responseId = _generateResponseId(directApplicationId);

        vm.expectRevert(Errors.NotExecutor.selector);
        _forwardAs(
            operator,
            address(responseCommitment),
            abi.encodeCall(responseCommitment.recordApplicationResponse, (directApplicationId, responseId))
        );
    }

    function test_nonConfiguredForwarderCannotSpoofCommitmentCreator() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, DEFAULT_POSTING_REF, employer, keyNonce, expiry
        );
        bytes memory callData = abi.encodeCall(
            commitmentFunds.activateCommitment,
            (
                address(responseCommitment),
                DEFAULT_ORG_ID,
                EMPLOYER_STAKE,
                _commitmentActivateFee(EMPLOYER_STAKE, 0),
                feeRecipient,
                abi.encode(uint8(0), DEFAULT_POSTING_REF, keyNonce, expiry, signature)
            )
        );

        vm.prank(applicant1);
        (bool success, bytes memory revertData) =
            address(commitmentFunds).call(bytes.concat(callData, bytes20(employer)));

        assertFalse(success);
        assertEq(revertData, abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
    }

    // Owner-only controls use the raw caller, even when the owner signs a forwarded request.

    function test_forwardedCallCannotSpoofOwner_responseCommitmentPause() public {
        vm.prank(owner);
        responseCommitment.pause();
        assertTrue(responseCommitment.paused());
        vm.prank(owner);
        responseCommitment.unpause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(responseCommitment), abi.encodeCall(responseCommitment.pause, ()));
    }

    function test_forwardedCallCannotSpoofOwner_commitmentFundsPause() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(commitmentFunds), abi.encodeCall(commitmentFunds.pause, ()));
    }

    function test_forwardedCallCannotSpoofOwner_orgRegistryPause() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(orgRegistry), abi.encodeCall(orgRegistry.pause, ()));
    }

    function test_forwardedCallCannotSpoofOwner_addOperator() public {
        address rogueOperator = makeAddr("rogueOperator");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(owner, address(responseCommitment), abi.encodeCall(responseCommitment.addOperator, (rogueOperator)));
    }

    function test_forwardedCallCannotSpoofOwner_rescueTokens() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(forwarder)));
        _forwardAs(
            owner, address(commitmentFunds), abi.encodeCall(commitmentFunds.rescueTokens, (address(usdc), owner, 1))
        );
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
