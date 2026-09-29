// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase, TEST_MAX_STOPPED_DURATION} from "../shared/TestBase.sol";
import {ResponseCommitment} from "../../src/ResponseCommitment.sol";
import {ICommitmentFunds} from "../../src/interfaces/ICommitmentFunds.sol";
import {Errors} from "../../src/Errors.sol";
import {FeeTier, CommitmentConfig} from "../../src/types/ConfigTypes.sol";
import {CommitmentExpiryStatus} from "../../src/types/CommitmentTypes.sol";

contract ResponseCommitmentEdgeCasesTest is ResponseCommitmentTestBase {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function test_domainSeparator_matchesProtocolDomain() public view {
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("ResponseCommitment"),
                keccak256("1"),
                block.chainid,
                address(responseCommitment)
            )
        );

        assertEq(responseCommitment.DOMAIN_SEPARATOR(), expected);
    }

    function test_constructor_zeroCommitmentFunds_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ResponseCommitment(
            ICommitmentFunds(address(0)),
            owner,
            address(forwarder),
            operator,
            executor,
            _defaultCommitmentConfig(),
            _defaultFeeTiers()
        );
    }

    function test_constructor_zeroOperator_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ResponseCommitment(
            commitmentFunds,
            owner,
            address(forwarder),
            address(0),
            executor,
            _defaultCommitmentConfig(),
            _defaultFeeTiers()
        );
    }

    function test_constructor_tierCountTiersLengthMismatch_reverts() public {
        CommitmentConfig memory config = _defaultCommitmentConfig();
        config.tierCount = 3;
        FeeTier[] memory tiers = _twoFeeTiers();

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        new ResponseCommitment(commitmentFunds, owner, address(forwarder), operator, executor, config, tiers);
    }

    function test_constructor_zeroExecutor_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ResponseCommitment(
            commitmentFunds,
            owner,
            address(forwarder),
            operator,
            address(0),
            _defaultCommitmentConfig(),
            _defaultFeeTiers()
        );
    }

    function test_constructor_overlappingRoles_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, operator));
        new ResponseCommitment(
            commitmentFunds,
            owner,
            address(forwarder),
            operator,
            operator,
            _defaultCommitmentConfig(),
            _defaultFeeTiers()
        );
    }

    function test_constructor_trustedForwarderExecutor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, address(forwarder)));
        new ResponseCommitment(
            commitmentFunds,
            owner,
            address(forwarder),
            operator,
            address(forwarder),
            _defaultCommitmentConfig(),
            _defaultFeeTiers()
        );
    }

    function test_setCommitmentConfig_tierCountTiersLengthMismatch_reverts() public {
        CommitmentConfig memory config = _defaultCommitmentConfig();
        config.tierCount = 3;
        FeeTier[] memory tiers = _twoFeeTiers();

        vm.prank(owner);
        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        responseCommitment.setCommitmentConfig(config, tiers);
    }

    function test_currentCommitmentConfig() public view {
        CommitmentConfig memory config = responseCommitment.currentCommitmentConfig();

        assertEq(config.minStake, 50_000_000);
        assertEq(config.tierCount, 3);
        assertEq(config.maxBatchSize, 50);

        assertEq(responseCommitment.feeTier(1, 0).baseFee, 25_000_000);
        assertEq(responseCommitment.feeTier(1, 1).baseFee, 35_000_000);
        assertEq(responseCommitment.feeTier(1, 2).baseFee, 50_000_000);
        assertEq(responseCommitment.feeTier(1, 0).feeBps, 150);
        assertEq(responseCommitment.feeTier(1, 1).feeBps, 250);
        assertEq(responseCommitment.feeTier(1, 2).feeBps, 350);
    }

    function test_expiredSettlementInfo_activeNotExpired() public {
        uint256 commitmentId = _activateCommitment(0);

        (bool canSettle, CommitmentExpiryStatus status) = responseCommitment.expiredSettlementInfo(commitmentId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(CommitmentExpiryStatus.NotYetExpired));
    }

    function testFuzz_nonOwner_cannotPause(address caller) public {
        vm.assume(caller != owner);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        responseCommitment.pause();
    }

    function testFuzz_nonOwner_cannotAddOperator(address caller, address newOperator) public {
        vm.assume(caller != owner);
        vm.assume(newOperator != address(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        responseCommitment.addOperator(newOperator);
    }

    function testFuzz_expiredSignature_activateCommitment(uint256 pastTime) public {
        pastTime = bound(pastTime, 1, block.timestamp);
        uint256 expiry = block.timestamp - pastTime;

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        bytes memory sig = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmExpired"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.SignatureExpired.selector);
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmExpired"), keyNonce, expiry, sig
        );
    }

    function testFuzz_expiredSignature_submitApplication(uint256 pastTime) public {
        pastTime = bound(pastTime, 1, block.timestamp);
        uint256 expiry = block.timestamp - pastTime;

        bytes32 appId = keccak256("expired-app");
        bytes memory sig = _signApplication(appId, applicant1, 3, expiry);

        vm.prank(applicant1);
        vm.expectRevert(Errors.SignatureExpired.selector);
        responseCommitment.submitApplication(appId, 3, expiry, sig);
    }

    function testFuzz_nonExecutor_cannotSettleExpiredCommitment(address caller) public {
        vm.assume(caller != executor);
        vm.assume(caller != address(0));

        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        vm.warp(block.timestamp + TEST_MAX_STOPPED_DURATION + 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), commitmentId, 0, 0, 0, _counterSnapshotRoot(0), caller
        );
    }

    function _twoFeeTiers() private pure returns (FeeTier[] memory tiers) {
        tiers = new FeeTier[](2);
        tiers[0] = FeeTier({baseFee: 25_000_000, feeBps: 150, deadlineDays: 3});
        tiers[1] = FeeTier({baseFee: 35_000_000, feeBps: 250, deadlineDays: 7});
    }
}
