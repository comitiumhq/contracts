// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {IOrgRegistry, OrgView, PendingOrgTreasuryView} from "../../src/interfaces/IOrgRegistry.sol";
import {Errors} from "../../src/Errors.sol";
import {OrgTestBase} from "../shared/OrgTestBase.sol";

// ============================================================
// Organization Lifecycle Tests
// ============================================================

contract OrgCreationTest is OrgTestBase {
    function test_createOrg() public {
        uint256 orgId = _createOrg(orgOwner1, "test.com");
        assertEq(orgId, 1);

        OrgView memory org = registry.org(orgId);
        assertEq(org.treasury, orgOwner1);
        assertEq(org.domainHash, _domainHash("test.com"));
        assertEq(registry.orgTreasury(orgId), orgOwner1);
        assertTrue(registry.isOrgAdmin(orgId, orgOwner1));

        address[] memory admins = registry.orgAdmins(orgId);
        assertEq(admins.length, 1);
        assertEq(admins[0], orgOwner1);
        assertEq(jobFunds.availableBalance(orgId), 0);
    }

    function test_createOrg_emitsEvent() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("test.com", orgOwner1, keyNonce, expiry);

        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgCreated(
            1,
            orgOwner1,
            keccak256("test.com"),
            keccak256(abi.encodeCall(registry.createOrg, (_domainHash("test.com"), keyNonce, expiry, sig)))
        );

        vm.prank(orgOwner1);
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);
    }

    function test_createOrg_forwardedUsesOriginalActor() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("forwarded.com", orgOwner1, keyNonce, expiry);
        bytes memory callData =
            abi.encodeCall(registry.createOrg, (_domainHash("forwarded.com"), keyNonce, expiry, sig));

        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgCreated(1, orgOwner1, _domainHash("forwarded.com"), keccak256(callData));
        bytes memory result = _forwardAs(orgOwner1, address(registry), callData);
        uint256 orgId = abi.decode(result, (uint256));

        OrgView memory org = registry.org(orgId);

        assertEq(org.treasury, orgOwner1);
        assertTrue(registry.isOrgAdmin(orgId, orgOwner1));
    }

    function test_createOrg_incrementsId() public {
        assertEq(registry.nextOrgId(), 1);
        _createOrg(orgOwner1, "a.com");
        assertEq(registry.nextOrgId(), 2);
        _createOrg(orgOwner2, "b.com");
        assertEq(registry.nextOrgId(), 3);
    }

    function test_createOrg_revert_zeroDomainHash() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("", orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroDomainHash.selector);
        registry.createOrg(bytes32(0), keyNonce, expiry, sig);
    }

    function test_createOrg_revert_expiredSignature() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp - 1; // expired
        bytes memory sig = _signDomain("test.com", orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(Errors.SignatureExpired.selector);
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);
    }

    function test_createOrg_revert_reusedNonce() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("test.com", orgOwner1, keyNonce, expiry);

        vm.startPrank(orgOwner1);
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);

        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, keyNonce + 1));
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);
        vm.stopPrank();
    }

    function test_createOrg_revert_wrongNonceScope() public {
        uint16 wrongScope = 1;
        uint256 keyNonce = _packKeyNonce(wrongScope, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("test.com", orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidNonceScope.selector, wrongScope, NONCE_SCOPE_DOMAIN_VERIFICATION)
        );
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);
    }

    function test_createOrg_revert_invalidSignature() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        // Sign with wrong key
        uint256 wrongKey = 0x9999;
        bytes32 structHash =
            keccak256(abi.encode(DOMAIN_VERIFICATION_TYPEHASH, _domainHash("test.com"), orgOwner1, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(orgOwner1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);
    }

    function test_createOrg_revert_signatureForWrongCaller() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        // Signature is for orgOwner1 but stranger calls
        bytes memory sig = _signDomain("test.com", orgOwner1, keyNonce, expiry);

        vm.prank(stranger);
        vm.expectRevert(Errors.InvalidSignature.selector);
        registry.createOrg(_domainHash("test.com"), keyNonce, expiry, sig);
    }
}

// ============================================================
// Organization Domain Update Tests
// ============================================================

contract OrgDomainUpdateTest is OrgTestBase {
    uint256 orgId;
    bytes32 currentDomainHash;
    bytes32 newDomainHash;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");
        currentDomainHash = _domainHash("test.com");
        newDomainHash = _domainHash("new-test.com");
    }

    function test_updateOrgDomain_updatesHash() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);

        bytes32 requestHash = keccak256(
            abi.encodeCall(registry.updateOrgDomain, (orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig))
        );

        vm.expectEmit(true, false, true, true);
        emit IOrgRegistry.OrgDomainUpdated(orgId, currentDomainHash, newDomainHash, orgOwner1, requestHash);

        vm.prank(orgOwner1);
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);

        OrgView memory org = registry.org(orgId);
        assertEq(org.domainHash, newDomainHash);
    }

    function test_updateOrgDomain_revert_notOrgAdmin() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, stranger, keyNonce, expiry);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, stranger));
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_forwardedUsesOriginalActor() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);
        bytes memory callData = abi.encodeWithSelector(
            registry.updateOrgDomain.selector, orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig
        );

        _forwardAs(orgOwner1, address(registry), callData);

        OrgView memory org = registry.org(orgId);

        assertEq(org.domainHash, newDomainHash);
    }

    function test_updateOrgDomain_revert_staleCurrentHash() public {
        bytes32 staleHash = _domainHash("stale.com");
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, staleHash, newDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OrgDomainHashMismatch.selector, orgId, staleHash, currentDomainHash)
        );
        registry.updateOrgDomain(orgId, staleHash, newDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_zeroDomainHash() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, bytes32(0), orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroDomainHash.selector);
        registry.updateOrgDomain(orgId, currentDomainHash, bytes32(0), keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_sameDomainHash() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig =
            _signOrgDomainUpdate(orgId, currentDomainHash, currentDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.SameOrgDomainHash.selector, orgId, currentDomainHash));
        registry.updateOrgDomain(orgId, currentDomainHash, currentDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_reusedNonce() public {
        bytes32 rollbackDomainHash = currentDomainHash;
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);

        uint256 rollbackKeyNonce = _nextOrgDomainUpdateKeyNonce();
        bytes memory rollbackSig =
            _signOrgDomainUpdate(orgId, newDomainHash, rollbackDomainHash, orgOwner1, rollbackKeyNonce, expiry);

        vm.prank(orgOwner1);
        registry.updateOrgDomain(orgId, newDomainHash, rollbackDomainHash, rollbackKeyNonce, expiry, rollbackSig);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, keyNonce + 1));
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_pausedRegistry_succeeds() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(contractOwner);
        registry.pause();

        vm.prank(orgOwner1);
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);

        OrgView memory org = registry.org(orgId);
        assertEq(org.domainHash, newDomainHash);
    }

    function test_updateOrgDomain_revert_expiredSignature() public {
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp - 1;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(Errors.SignatureExpired.selector);
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_wrongNonceScope() public {
        // Scope 3 (DomainVerification) instead of 6 (OrgDomainUpdate): the only assertion that pins the
        // distinct OrgDomainUpdate nonce namespace, preventing a DomainVerification nonce from being reused here.
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_DOMAIN_VERIFICATION, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector, NONCE_SCOPE_DOMAIN_VERIFICATION, NONCE_SCOPE_ORG_DOMAIN_UPDATE
            )
        );
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_nonExistentOrg() public {
        uint256 bogusOrgId = 999_999;
        bytes32 bogusCurrent = _domainHash("bogus-current.com");
        bytes32 bogusNew = _domainHash("bogus-new.com");
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(bogusOrgId, bogusCurrent, bogusNew, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, bogusOrgId));
        registry.updateOrgDomain(bogusOrgId, bogusCurrent, bogusNew, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_signatureBoundToDifferentUpdate() public {
        // Operator signed an update to a different target hash; the call requests newDomainHash, so the
        // recovered signer is invalid.
        bytes32 signedForHash = _domainHash("signed-for.com");
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, signedForHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);
    }

    function test_updateOrgDomain_revert_signatureBoundToDifferentActor() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        // Signature binds updater = orgOwner1, but orgOwner2 (also an admin) submits it, so the recovered
        // signer over the actor-bound struct is no longer an accepted operator.
        uint256 keyNonce = _nextOrgDomainUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signOrgDomainUpdate(orgId, currentDomainHash, newDomainHash, orgOwner1, keyNonce, expiry);

        vm.prank(orgOwner2);
        vm.expectRevert(Errors.InvalidSignature.selector);
        registry.updateOrgDomain(orgId, currentDomainHash, newDomainHash, keyNonce, expiry, sig);
    }
}

// ============================================================
// Organization Admin Tests
// ============================================================

contract OrgAdminGrantTest is OrgTestBase {
    uint256 orgId;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");
    }

    function test_setOrgAdmin_addsAndRevokesAdmin() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        assertTrue(registry.isOrgAdmin(orgId, orgOwner2));

        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, false);

        assertFalse(registry.isOrgAdmin(orgId, orgOwner2));
    }

    function test_setOrgAdmin_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgAdminUpdated(orgId, orgOwner2, true, orgOwner1, true);

        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);
    }

    function test_setOrgAdmin_existingAdminIsNoOp() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        address[] memory adminsBefore = registry.orgAdmins(orgId);
        assertEq(adminsBefore.length, 2);
        assertTrue(registry.isOrgAdmin(orgId, orgOwner2));

        vm.expectEmit(true, true, true, true, address(registry));
        emit IOrgRegistry.OrgAdminUpdated(orgId, orgOwner2, true, orgOwner1, false);

        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        address[] memory adminsAfter = registry.orgAdmins(orgId);

        assertEq(adminsAfter.length, adminsBefore.length);
        assertTrue(registry.isOrgAdmin(orgId, orgOwner1));
        assertTrue(registry.isOrgAdmin(orgId, orgOwner2));
    }

    function test_setOrgAdmin_revokingNonAdminIsNoOp() public {
        address[] memory adminsBefore = registry.orgAdmins(orgId);
        assertEq(adminsBefore.length, 1);
        assertFalse(registry.isOrgAdmin(orgId, orgOwner2));

        vm.expectEmit(true, true, true, true, address(registry));
        emit IOrgRegistry.OrgAdminUpdated(orgId, orgOwner2, false, orgOwner1, false);

        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, false);

        address[] memory adminsAfter = registry.orgAdmins(orgId);

        assertEq(adminsAfter.length, adminsBefore.length);
        assertTrue(registry.isOrgAdmin(orgId, orgOwner1));
        assertFalse(registry.isOrgAdmin(orgId, orgOwner2));
    }

    function test_setOrgAdmin_revert_notOrgAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, stranger));
        registry.setOrgAdmin(orgId, orgOwner2, true);
    }

    function test_setOrgAdmin_revert_zeroAddress() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setOrgAdmin(orgId, address(0), true);
    }

    function test_setOrgAdmin_revert_selfUpdate() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        vm.prank(orgOwner2);
        vm.expectRevert(abi.encodeWithSelector(Errors.CannotUpdateOwnOrgAdmin.selector, orgId, orgOwner2));
        registry.setOrgAdmin(orgId, orgOwner2, false);
    }

    function test_setOrgAdmin_revert_lastAdminRemoval() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.CannotRemoveLastOrgAdmin.selector, orgId));
        registry.setOrgAdmin(orgId, orgOwner1, false);
    }

    function test_orgAdminHandoverWithoutOwnershipTransfer() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        vm.prank(orgOwner2);
        registry.setOrgAdmin(orgId, orgOwner1, false);

        assertFalse(registry.isOrgAdmin(orgId, orgOwner1));
        assertTrue(registry.isOrgAdmin(orgId, orgOwner2));
        assertEq(registry.orgTreasury(orgId), orgOwner1);
    }

    function test_updateContentURI_allowedForDelegatedOrgAdmin() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        vm.prank(orgOwner2);
        registry.updateContentURI(orgId, "ipfs://QmDelegatedAdmin");

        assertEq(registry.org(orgId).contentURI, "ipfs://QmDelegatedAdmin");
    }
}

// ============================================================
// Organization Treasury Transfer Tests
// ============================================================

contract OrgTreasuryTransferTest is OrgTestBase {
    uint256 orgId;
    address newTreasury;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");
        newTreasury = makeAddr("newTreasury");
    }

    function test_treasuryTransfer_threeStepFlow() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        PendingOrgTreasuryView memory pending = registry.pendingOrgTreasury(orgId);
        assertEq(pending.proposedTreasury, newTreasury);
        assertFalse(pending.accepted);

        vm.prank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);

        pending = registry.pendingOrgTreasury(orgId);
        assertEq(pending.proposedTreasury, newTreasury);
        assertTrue(pending.accepted);

        vm.prank(orgOwner1);
        registry.finalizeOrgTreasuryTransfer(orgId);

        assertEq(registry.orgTreasury(orgId), newTreasury);

        pending = registry.pendingOrgTreasury(orgId);
        assertEq(pending.proposedTreasury, address(0));
        assertFalse(pending.accepted);
    }

    function test_treasuryTransfer_forwardedUsesOriginalActors() public {
        _forwardAs(
            orgOwner1, address(registry), abi.encodeCall(registry.proposeOrgTreasuryTransfer, (orgId, newTreasury))
        );

        _forwardAs(newTreasury, address(registry), abi.encodeCall(registry.acceptOrgTreasuryTransfer, (orgId)));

        _forwardAs(orgOwner1, address(registry), abi.encodeCall(registry.finalizeOrgTreasuryTransfer, (orgId)));

        assertEq(registry.orgTreasury(orgId), newTreasury);
    }

    function test_finalizeOrgTreasuryTransfer_revert_currentTreasuryWithoutAdminRole() public {
        address finalTreasury = makeAddr("finalTreasury");

        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);

        vm.prank(orgOwner1);
        registry.finalizeOrgTreasuryTransfer(orgId);

        vm.prank(newTreasury);
        registry.proposeOrgTreasuryTransfer(orgId, finalTreasury);

        vm.prank(finalTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);

        vm.prank(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, newTreasury));
        registry.finalizeOrgTreasuryTransfer(orgId);
    }

    function test_proposeOrgTreasuryTransfer_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgTreasuryTransferProposed(orgId, orgOwner1, newTreasury);

        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);
    }

    function test_acceptOrgTreasuryTransfer_emitsEvent() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgTreasuryTransferAccepted(orgId, newTreasury);

        vm.prank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);
    }

    function test_finalizeOrgTreasuryTransfer_emitsEvent() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);

        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgTreasuryTransferFinalized(orgId, orgOwner1, newTreasury, orgOwner1);

        vm.prank(orgOwner1);
        registry.finalizeOrgTreasuryTransfer(orgId);
    }

    function test_cancelOrgTreasuryTransfer_byTreasury() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.OrgTreasuryTransferCanceled(orgId, orgOwner1, newTreasury, orgOwner1);

        vm.prank(orgOwner1);
        registry.cancelOrgTreasuryTransfer(orgId);

        assertEq(registry.pendingOrgTreasury(orgId).proposedTreasury, address(0));
    }

    function test_cancelOrgTreasuryTransfer_byOrgAdmin() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(orgOwner2);
        registry.cancelOrgTreasuryTransfer(orgId);

        assertEq(registry.pendingOrgTreasury(orgId).proposedTreasury, address(0));
    }

    function test_proposeOrgTreasuryTransfer_revert_notCurrentTreasury() public {
        vm.prank(orgOwner2);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, orgOwner2));
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);
    }

    function test_proposeOrgTreasuryTransfer_revert_zeroAddress() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.proposeOrgTreasuryTransfer(orgId, address(0));
    }

    function test_proposeOrgTreasuryTransfer_revert_registryAddress() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidOrgTreasury.selector, address(registry)));
        registry.proposeOrgTreasuryTransfer(orgId, address(registry));
    }

    function test_proposeOrgTreasuryTransfer_revert_sameTreasury() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.SameOrgTreasury.selector, orgId, orgOwner1));
        registry.proposeOrgTreasuryTransfer(orgId, orgOwner1);
    }

    function test_proposeOrgTreasuryTransfer_revert_pendingExists() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.PendingOrgTreasuryExists.selector, orgId, newTreasury));
        registry.proposeOrgTreasuryTransfer(orgId, makeAddr("secondTreasury"));
    }

    function test_acceptOrgTreasuryTransfer_revert_noPendingTransfer() public {
        vm.prank(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoPendingOrgTreasury.selector, orgId));
        registry.acceptOrgTreasuryTransfer(orgId);
    }

    function test_acceptOrgTreasuryTransfer_secondAcceptIsIdempotent() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.startPrank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);
        registry.acceptOrgTreasuryTransfer(orgId);
        vm.stopPrank();

        PendingOrgTreasuryView memory pending = registry.pendingOrgTreasury(orgId);
        assertEq(pending.proposedTreasury, newTreasury);
        assertTrue(pending.accepted);
        assertEq(registry.orgTreasury(orgId), orgOwner1);
    }

    function test_acceptOrgTreasuryTransfer_revert_wrongCaller() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotProposedOrgTreasury.selector, orgId, stranger));
        registry.acceptOrgTreasuryTransfer(orgId);
    }

    function test_finalizeOrgTreasuryTransfer_revert_notOrgAdmin() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, stranger));
        registry.finalizeOrgTreasuryTransfer(orgId);
    }

    function test_finalizeOrgTreasuryTransfer_revert_noPendingTransfer() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoPendingOrgTreasury.selector, orgId));
        registry.finalizeOrgTreasuryTransfer(orgId);
    }

    function test_finalizeOrgTreasuryTransfer_revert_notAccepted() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgTreasuryNotAccepted.selector, orgId));
        registry.finalizeOrgTreasuryTransfer(orgId);
    }

    function test_cancelOrgTreasuryTransfer_revert_notTreasuryOrAdmin() public {
        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasuryOrAdmin.selector, orgId, stranger));
        registry.cancelOrgTreasuryTransfer(orgId);
    }

    function test_cancelOrgTreasuryTransfer_revert_noPendingTransferByTreasury() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoPendingOrgTreasury.selector, orgId));
        registry.cancelOrgTreasuryTransfer(orgId);
    }

    function test_cancelOrgTreasuryTransfer_revert_noPendingTransferByOrgAdmin() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, orgOwner2, true);

        vm.prank(orgOwner2);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoPendingOrgTreasury.selector, orgId));
        registry.cancelOrgTreasuryTransfer(orgId);
    }
}
