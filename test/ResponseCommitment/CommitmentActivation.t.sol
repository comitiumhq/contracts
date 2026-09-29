// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";
import {Errors} from "../../src/Errors.sol";
import {TEST_TIER_0_BASE_FEE, TEST_TIER_1_BASE_FEE, TEST_TIER_2_BASE_FEE, TEST_MIN_STAKE} from "../shared/TestBase.sol";

/// @title CommitmentActivationTest
/// @notice Tests for commitment creation functionality
contract CommitmentActivationTest is ResponseCommitmentTestBase {
    function test_activateCommitment_success() public {
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        assertEq(responseCommitment.nextCommitmentId(), 1);

        uint256 commitmentId = _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest123"));

        assertEq(commitmentId, 1);
        assertEq(responseCommitment.nextCommitmentId(), 2);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(commitment.creator, employer);
        assertEq(commitment.orgId, DEFAULT_ORG_ID);
        assertEq(commitment.stake, EMPLOYER_STAKE);
        assertEq(commitment.feeTier, 0);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Active));
        assertEq(commitment.postingRef, keccak256("QmTest123"));

        // Fee goes to the protocol fee recipient; stake stays accounted in CommitmentFunds.
        uint256 expectedFee = TEST_TIER_0_BASE_FEE + ((EMPLOYER_STAKE * 150) / 10_000);
        assertEq(usdc.balanceOf(address(responseCommitment)), 0);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalBefore + expectedFee);
    }

    function test_activateCommitment_stakeTooLow_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, TEST_MIN_STAKE - 1, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(TEST_MIN_STAKE - 1, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.StakeTooLow.selector, TEST_MIN_STAKE - 1, TEST_MIN_STAKE));
        _executeCommitmentActivationWithFee(
            employer,
            DEFAULT_ORG_ID,
            TEST_MIN_STAKE - 1,
            0,
            expectedFee,
            keccak256("QmTest"),
            keyNonce,
            expiry,
            signature
        );
    }

    function test_activateCommitment_invalidFeeTier_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 3, keccak256("QmTest"), employer, keyNonce, expiry
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeTier.selector, 3));
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 3, 0, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_activateCommitment_commitmentManager_succeeds() public {
        vm.prank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);

        uint256 commitmentId = _activateCommitmentAs(applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(commitment.creator, applicant1);
        assertEq(commitment.orgId, DEFAULT_ORG_ID);
    }

    function test_activateCommitment_nonManagerWithValidSignature_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), applicant1, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
        _executeCommitmentActivationWithFee(
            applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_activateCommitment_revokedCommitmentManager_reverts() public {
        vm.startPrank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, false);
        vm.stopPrank();

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), applicant1, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
        _executeCommitmentActivationWithFee(
            applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_activateCommitment_zeroPostingRef_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signCommitmentActivation(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, bytes32(0), employer, keyNonce, expiry);
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.ZeroPostingRef.selector);
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, bytes32(0), keyNonce, expiry, signature
        );
    }

    function test_activateCommitment_feeAmountMismatch_revertsWithoutDebit() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmFeeMismatch"), employer, keyNonce, expiry
        );
        uint256 availableBefore = commitmentFunds.availableBalance(DEFAULT_ORG_ID);
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.expectRevert(abi.encodeWithSelector(Errors.FeeAmountMismatch.selector, expectedFee + 1, expectedFee));
        _executeCommitmentActivationWithFee(
            employer,
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE,
            0,
            expectedFee + 1,
            keccak256("QmFeeMismatch"),
            keyNonce,
            expiry,
            signature
        );

        assertEq(commitmentFunds.availableBalance(DEFAULT_ORG_ID), availableBefore);
        assertEq(usdc.balanceOf(feeRecipient), recipientBalanceBefore);
        assertEq(responseCommitment.nextCommitmentId(), 1);
    }

    function test_activateCommitment_feeRecipientMismatch_revertsWithoutDebit() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmRecipientMismatch"), employer, keyNonce, expiry
        );
        uint256 availableBefore = commitmentFunds.availableBalance(DEFAULT_ORG_ID);
        address unexpectedRecipient = makeAddr("unexpectedRecipient");
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.FeeRecipientMismatch.selector, unexpectedRecipient, feeRecipient));
        commitmentFunds.activateCommitment(
            address(responseCommitment),
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE,
            expectedFee,
            unexpectedRecipient,
            abi.encode(uint8(0), keccak256("QmRecipientMismatch"), keyNonce, expiry, signature)
        );

        assertEq(commitmentFunds.availableBalance(DEFAULT_ORG_ID), availableBefore);
        assertEq(usdc.balanceOf(unexpectedRecipient), 0);
        assertEq(responseCommitment.nextCommitmentId(), 1);
    }

    function test_activateCommitment_revert_callerIsNotCommitmentFunds() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmDirect"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentFunds.selector, employer));
        responseCommitment.activateCommitment(
            DEFAULT_ORG_ID,
            employer,
            EMPLOYER_STAKE,
            expectedFee,
            abi.encode(uint8(0), keccak256("QmDirect"), keyNonce, expiry, signature)
        );
    }

    function test_activateCommitment_allFeeTiers_correctFees() public {
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 tier0Fee = TEST_TIER_0_BASE_FEE + ((EMPLOYER_STAKE * 150) / 10_000);
        uint256 tier1Fee = TEST_TIER_1_BASE_FEE + ((EMPLOYER_STAKE * 250) / 10_000);
        uint256 tier2Fee = TEST_TIER_2_BASE_FEE + ((EMPLOYER_STAKE * 350) / 10_000);

        uint256 commitmentId0 = _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTier0"));
        CommitmentView memory commitment0 = responseCommitment.commitment(commitmentId0);
        assertEq(commitment0.feeTier, 0);
        assertEq(commitment0.feeAmount, tier0Fee);

        uint256 commitmentId1 = _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 1, keccak256("QmTier1"));
        CommitmentView memory commitment1 = responseCommitment.commitment(commitmentId1);
        assertEq(commitment1.feeTier, 1);
        assertEq(commitment1.feeAmount, tier1Fee);

        uint256 commitmentId2 = _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 2, keccak256("QmTier2"));
        CommitmentView memory commitment2 = responseCommitment.commitment(commitmentId2);
        assertEq(commitment2.feeTier, 2);
        assertEq(commitment2.feeAmount, tier2Fee);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + tier0Fee + tier1Fee + tier2Fee);
    }

    // ============ EIP-712 Signature Tests ============

    function test_activateCommitment_expiredSignature_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.warp(expiry + 1);

        vm.expectRevert(Errors.SignatureExpired.selector);
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_activateCommitment_expiryAtCurrentTimestamp_succeeds() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmBoundary"), employer, keyNonce, expiry
        );

        uint256 commitmentId = _executeCommitmentActivation(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmBoundary"), keyNonce, expiry, signature
        );

        assertEq(commitmentId, 1);
    }

    function test_activateCommitment_invalidSignature_wrongSigner_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        uint256 wrongKey = 0x9999;
        bytes32 structHash = keccak256(
            abi.encode(
                COMMITMENT_ACTIVATION_TYPEHASH,
                DEFAULT_ORG_ID,
                EMPLOYER_STAKE,
                uint8(0),
                keccak256("QmTest"),
                employer,
                responseCommitment.currentConfigVersion(),
                keyNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, badSig
        );
    }

    function test_activateCommitment_staleConfigSignature_revertsAfterConfigUpdate() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmStaleConfig"), employer, keyNonce, expiry
        );

        vm.prank(owner);
        responseCommitment.setCommitmentConfig(_defaultCommitmentConfig(), _defaultFeeTiers());
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeCommitmentActivationWithFee(
            employer,
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE,
            0,
            expectedFee,
            keccak256("QmStaleConfig"),
            keyNonce,
            expiry,
            signature
        );
    }

    function test_activateCommitment_nonceReplay_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest1"), employer, keyNonce, expiry
        );
        _executeCommitmentActivation(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest1"), keyNonce, expiry, signature
        );

        bytes memory signature2 = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest2"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, keyNonce + 1));
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest2"), keyNonce, expiry, signature2
        );
    }

    function test_activateCommitment_wrongNonceScope_reverts() public {
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_COMMITMENT_SETTLEMENT, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector, NONCE_SCOPE_COMMITMENT_SETTLEMENT, NONCE_SCOPE_COMMITMENT_ACTIVATION
            )
        );
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_activateCommitment_mismatchedParams_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE + 1, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeCommitmentActivationWithFee(
            employer,
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE + 1,
            0,
            expectedFee,
            keccak256("QmTest"),
            keyNonce,
            expiry,
            signature
        );
    }

    function test_activateCommitment_mismatchedCreator_reverts() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);

        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeCommitmentActivationWithFee(
            applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }
}
