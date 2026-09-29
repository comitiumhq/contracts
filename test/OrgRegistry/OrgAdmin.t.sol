// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {ICommitmentFunds} from "../../src/interfaces/ICommitmentFunds.sol";
import {OperatorAuthorizer} from "../../src/abstract/OperatorAuthorizer.sol";
import {Errors} from "../../src/Errors.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

/// @title OrgAdminTest
/// @notice Tests for protocol-level admin functions (pause, operator, commitment routing, contentURI)
contract OrgAdminTest is OrgTestBase {
    uint256 orgId;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.RenounceDisabled.selector);
        registry.renounceOwnership();

        assertEq(registry.owner(), contractOwner);
    }

    // ============ pause/unpause ============

    function test_pause_blocksCreation() public {
        vm.prank(contractOwner);
        registry.pause();

        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("new.com", orgOwner2, keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.createOrg(orgOwner2, _domainHash("new.com"), keyNonce, expiry, sig);
    }

    function test_commitmentFundsPause_blocksDeposit() public {
        vm.prank(contractOwner);
        commitmentFunds.pause();

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        commitmentFunds.depositWithAuthorization(orgId, 1_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_unpause() public {
        vm.startPrank(contractOwner);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        // Should work after unpause
        _fundAndDeposit(orgId, orgOwner1, 1_000_000);
        assertEq(commitmentFunds.availableBalance(orgId), 1_000_000);
    }

    // ============ addOperator ============

    function test_addOperator() public {
        address newOperator = makeAddr("newOperator");

        vm.expectEmit(true, true, true, true);
        emit OperatorAuthorizer.OperatorUpdated(newOperator, true, contractOwner);

        vm.prank(contractOwner);
        registry.addOperator(newOperator);

        assertTrue(registry.isOperator(newOperator));
        assertTrue(registry.isOperator(operator));
    }

    function test_addOperator_revert_zeroAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.addOperator(address(0));
    }

    function test_addOperator_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        registry.addOperator(makeAddr("x"));
    }

    function test_addOperator_executorAddress_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, executor));
        registry.addOperator(executor);
    }

    function test_addExecutor_operatorAddress_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, operator));
        registry.addExecutor(operator);
    }

    function test_addExecutor_trustedForwarder_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, address(forwarder)));
        registry.addExecutor(address(forwarder));
    }

    // ============ removeOperator ============

    function test_removeOperator() public {
        address newOperator = makeAddr("newOperator");
        vm.prank(contractOwner);
        registry.addOperator(newOperator);

        vm.expectEmit(true, true, true, true);
        emit OperatorAuthorizer.OperatorUpdated(newOperator, false, contractOwner);

        vm.prank(contractOwner);
        registry.removeOperator(newOperator);

        assertFalse(registry.isOperator(newOperator));
        assertTrue(registry.isOperator(operator));
    }

    function test_removeOperator_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        registry.removeOperator(operator);
    }

    // ============ commitment routing ============

    function test_registerResponseCommitmentAndSetCurrent() public {
        address newResponseCommitment = _deployTestCommitment();

        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.ResponseCommitmentRegistered(newResponseCommitment, 1);

        vm.prank(contractOwner);
        commitmentFunds.registerResponseCommitment(newResponseCommitment, 1);

        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.CurrentResponseCommitmentUpdated(address(0), newResponseCommitment);

        vm.prank(contractOwner);
        commitmentFunds.setCurrentResponseCommitment(newResponseCommitment);

        assertEq(commitmentFunds.currentResponseCommitment(), newResponseCommitment);
    }

    function test_registerResponseCommitment_revert_zeroAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        commitmentFunds.registerResponseCommitment(address(0), 1);
    }

    function test_registerResponseCommitment_revert_notContract() public {
        address notContract = makeAddr("notContract");

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ContractExpected.selector, notContract));
        commitmentFunds.registerResponseCommitment(notContract, 1);
    }

    function test_registerResponseCommitment_revert_wrongVersion() public {
        address commitment = _deployTestCommitment();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidResponseCommitment.selector, commitment));
        commitmentFunds.registerResponseCommitment(commitment, 2);
    }

    function test_registerResponseCommitment_revert_zeroVersion() public {
        address commitment = _deployTestCommitment();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidResponseCommitment.selector, commitment));
        commitmentFunds.registerResponseCommitment(commitment, 0);
    }

    // ============ updateContentURI ============

    function test_updateContentURI() public {
        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.ContentURIUpdated(orgId, orgOwner1, "ipfs://QmNewMetadata");

        _updateOrgContent(orgId, "ipfs://QmNewMetadata", orgOwner1);
    }

    function test_updateContentURI_revert_notExecutor() public {
        uint256 keyNonce = _nextOrgContentUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signOrgContentUpdate(orgId, "ipfs://QmNewMetadata", stranger, keyNonce, expiry);

        vm.prank(stranger);
        vm.expectRevert(Errors.NotExecutor.selector);
        registry.updateContentURI(orgId, "ipfs://QmNewMetadata", stranger, keyNonce, expiry, signature);
    }

    function test_updateContentURI_revert_emptyContentURI() public {
        uint256 keyNonce = _nextOrgContentUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signOrgContentUpdate(orgId, "", orgOwner1, keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(Errors.EmptyContentURI.selector);
        registry.updateContentURI(orgId, "", orgOwner1, keyNonce, expiry, signature);
    }

    // ============ View Functions ============

    function test_operators_returnsActiveOperators() public {
        address newOperator = makeAddr("newOperator");

        vm.prank(contractOwner);
        registry.addOperator(newOperator);

        address[] memory operators = registry.operators();

        assertEq(operators.length, 2);
        assertEq(operators[0], operator);
        assertEq(operators[1], newOperator);
    }
}
