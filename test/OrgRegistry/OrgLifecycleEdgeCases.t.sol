// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Errors} from "../../src/Errors.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract OrgLifecycleEdgeCasesTest is OrgTestBase {
    function test_acceptOrgTreasuryTransfer_revert_nonExistentOrg() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        registry.acceptOrgTreasuryTransfer(999);
    }

    function test_getOrganization_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        registry.org(999);
    }

    function test_isOrgAdmin_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        registry.isOrgAdmin(999, orgOwner1);
    }

    function test_orgAdmins_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        registry.orgAdmins(999);
    }

    function test_pendingOrgTreasury_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        registry.pendingOrgTreasury(999);
    }

    function test_removedOrgOwnershipTransferSelectorsAreAbsent() public {
        uint256 orgId = _createOrg(orgOwner1, "removed-selectors.com");

        (bool transferSuccess,) =
            address(registry).call(abi.encodeWithSignature("transferOrgOwnership(uint256,address)", orgId, orgOwner2));
        (bool acceptSuccess,) = address(registry).call(abi.encodeWithSignature("acceptOrgOwnership(uint256)", orgId));

        assertFalse(transferSuccess);
        assertFalse(acceptSuccess);
    }

    function test_createOrg_expiryAtCurrentTimestamp_succeeds() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp; // exact boundary

        bytes memory sig = _signDomain("boundary.com", orgOwner1, keyNonce, expiry);

        // expiry == block.timestamp → should succeed (check is `block.timestamp > expiry`)
        vm.prank(executor);
        uint256 orgId = registry.createOrg(orgOwner1, _domainHash("boundary.com"), keyNonce, expiry, sig);

        assertGt(orgId, 0);
    }

    function test_createOrg_expiryJustPast_reverts() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp - 1;

        bytes memory sig = _signDomain("past.com", orgOwner1, keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(Errors.SignatureExpired.selector);
        registry.createOrg(orgOwner1, _domainHash("past.com"), keyNonce, expiry, sig);
    }

    function test_proposeOrgTreasuryTransfer_toCurrentTreasury_reverts() public {
        uint256 orgId = _createOrg(orgOwner1, "self.com");

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.SameOrgTreasury.selector, orgId, orgOwner1));
        registry.proposeOrgTreasuryTransfer(orgId, orgOwner1);
    }

    function testFuzz_rescueTokens_exactBoundary(uint256 surplus) public {
        surplus = bound(surplus, 1, 1_000_000_000);

        usdc.mint(address(registry), surplus);

        vm.prank(contractOwner);
        registry.rescueTokens(address(usdc), contractOwner, surplus);

        assertEq(usdc.balanceOf(address(registry)), 0);
    }

    function test_depositWithAuthorization_nonExistentOrg() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        commitmentFunds.depositWithAuthorization(999, 1_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_withdraw_nonExistentOrg() public {
        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        commitmentFunds.withdraw(999, 1);
    }

    function test_updateContentURI_succeeds() public {
        uint256 orgId = _createOrg(orgOwner1, "content.com");

        vm.expectEmit(true, true, false, true, address(registry));
        emit IOrgRegistry.ContentURIUpdated(orgId, orgOwner1, "ipfs://QmNewContent");

        _updateOrgContent(orgId, "ipfs://QmNewContent", orgOwner1);

        assertEq(registry.org(orgId).contentURI, "ipfs://QmNewContent", "contentURI must be persisted");
    }

    function test_domainKeyNonce_beforeAndAfter() public {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint192 key = _authorizationKeyFromKeyNonce(keyNonce);

        assertEq(registry.nonces(operator, key), keyNonce);

        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain("nonce.com", orgOwner1, keyNonce, expiry);

        vm.prank(executor);
        registry.createOrg(orgOwner1, _domainHash("nonce.com"), keyNonce, expiry, sig);

        assertEq(registry.nonces(operator, key), keyNonce + 1);
    }
}
