// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {JobFunds} from "../../src/JobFunds.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {IJobFunds} from "../../src/interfaces/IJobFunds.sol";
import {USDC} from "../mocks/USDC.sol";
import {SLASH_BURN_ADDRESS as PROTOCOL_SLASH_BURN_ADDRESS} from "../../src/Constants.sol";
import {Eip3009TestHelper} from "./Eip3009TestHelper.sol";
import {OrgAuthorizationLib} from "../../src/libraries/OrgAuthorizationLib.sol";

contract TestCommitmentRegistration {
    uint32 public constant commitmentVersion = 1;
    IERC20 public immutable stakeToken;
    IJobFunds public immutable jobFunds;

    constructor(IERC20 stakeToken_, IJobFunds jobFunds_) {
        stakeToken = stakeToken_;
        jobFunds = jobFunds_;
    }

    function createJob(uint256, address, uint256, uint256, bytes calldata) external returns (uint256 jobId) {
        require(msg.sender == address(jobFunds), "only job funds");

        return 1;
    }
}

/// @title OrgTestBase
/// @notice Shared base for OrgRegistry and JobFunds tests.
abstract contract OrgTestBase is Eip3009TestHelper {
    OrgRegistry public registry;
    JobFunds public jobFunds;
    ERC2771Forwarder public forwarder;
    USDC public usdc;

    address public contractOwner = makeAddr("contractOwner");
    uint256 public orgOwner1PrivateKey = 0xA11CE;
    uint256 public orgOwner2PrivateKey = 0xB0B;
    address public orgOwner1;
    address public orgOwner2;
    address public member1 = makeAddr("member1");
    address public member2 = makeAddr("member2");
    address public stranger = makeAddr("stranger");
    address public feeRecipient = makeAddr("feeRecipient");
    address public constant SLASH_BURN_ADDRESS = PROTOCOL_SLASH_BURN_ADDRESS;

    uint256 public operatorPrivateKey = 0x1234;
    address public operator;
    uint256 public domainVerificationNonce;
    uint256 public orgDomainUpdateNonce;
    uint256 private _testJobId;

    uint16 internal constant NONCE_SCOPE_DOMAIN_VERIFICATION = OrgAuthorizationLib.NONCE_SCOPE_DOMAIN_VERIFICATION;
    uint16 internal constant NONCE_SCOPE_ORG_DOMAIN_UPDATE = OrgAuthorizationLib.NONCE_SCOPE_ORG_DOMAIN_UPDATE;

    bytes32 public constant DOMAIN_VERIFICATION_TYPEHASH = OrgAuthorizationLib.DOMAIN_VERIFICATION_TYPEHASH;
    bytes32 public constant ORG_DOMAIN_UPDATE_TYPEHASH = OrgAuthorizationLib.ORG_DOMAIN_UPDATE_TYPEHASH;

    function setUp() public virtual {
        operator = vm.addr(operatorPrivateKey);
        orgOwner1 = vm.addr(orgOwner1PrivateKey);
        orgOwner2 = vm.addr(orgOwner2PrivateKey);
        vm.label(orgOwner1, "orgOwner1");
        vm.label(orgOwner2, "orgOwner2");

        usdc = new USDC();
        forwarder = new ERC2771Forwarder("ComitiumForwarder");

        registry = new OrgRegistry(contractOwner, address(forwarder), operator);
        jobFunds = new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), feeRecipient, contractOwner, address(forwarder)
        );
    }

    function _signDomain(string memory domain, address creator, uint256 keyNonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(DOMAIN_VERIFICATION_TYPEHASH, _domainHash(domain), creator, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createOrg(address orgOwner, string memory domain) internal returns (uint256 orgId) {
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signDomain(domain, orgOwner, keyNonce, expiry);

        vm.prank(orgOwner);
        orgId = registry.createOrg(_domainHash(domain), keyNonce, expiry, sig);
    }

    function _signOrgDomainUpdate(
        uint256 orgId,
        bytes32 currentDomainHash,
        bytes32 newDomainHash,
        address updater,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(ORG_DOMAIN_UPDATE_TYPEHASH, orgId, currentDomainHash, newDomainHash, updater, keyNonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _packKeyNonce(uint16 scope, uint256 randomKey) internal pure returns (uint256) {
        require(randomKey <= type(uint176).max, "random key too large");

        return (uint256(scope) << 240) | (randomKey << 64);
    }

    function _authorizationKeyFromKeyNonce(uint256 keyNonce) internal pure returns (uint192) {
        return SafeCast.toUint192(keyNonce >> 64);
    }

    function _nextDomainKeyNonce() internal returns (uint256) {
        domainVerificationNonce++;

        return _packKeyNonce(NONCE_SCOPE_DOMAIN_VERIFICATION, domainVerificationNonce);
    }

    function _nextOrgDomainUpdateKeyNonce() internal returns (uint256) {
        orgDomainUpdateNonce++;

        return _packKeyNonce(NONCE_SCOPE_ORG_DOMAIN_UPDATE, orgDomainUpdateNonce);
    }

    function _domainHash(string memory domain) internal pure returns (bytes32) {
        return keccak256(bytes(domain));
    }

    function _fundAndDeposit(uint256 orgId, address orgOwner, uint256 amount) internal {
        _fundAndDepositWithAuthorization(jobFunds, address(usdc), _orgOwnerPrivateKey(orgOwner), orgId, amount);
    }

    function _orgOwnerPrivateKey(address orgOwner) private view returns (uint256) {
        if (orgOwner == orgOwner1) return orgOwner1PrivateKey;

        if (orgOwner == orgOwner2) return orgOwner2PrivateKey;

        revert("unknown org owner");
    }

    function _assertSlashBurned(
        uint256 burnAddressBefore,
        uint256 feeRecipientBefore,
        uint256 expectedSlash,
        string memory message
    ) internal view {
        assertEq(usdc.balanceOf(SLASH_BURN_ADDRESS) - burnAddressBefore, expectedSlash, message);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore, "Fee recipient should not receive slash");
    }

    function _forwardAs(address signer, address target, bytes memory callData) internal returns (bytes memory result) {
        vm.prank(address(forwarder));
        (bool success, bytes memory returned) = target.call(bytes.concat(callData, bytes20(signer)));

        if (!success) {
            assembly {
                revert(add(returned, 32), mload(returned))
            }
        }

        return returned;
    }

    function stakeToken() external view returns (IERC20) {
        return IERC20(address(usdc));
    }

    function commitmentVersion() external pure returns (uint32) {
        return 1;
    }

    function createJob(uint256, address, uint256, uint256, bytes calldata) external returns (uint256 jobId) {
        require(msg.sender == address(jobFunds), "only job funds");

        _testJobId++;
        return _testJobId;
    }

    function _publishTestJob(address commitment, uint256 orgId, address creator, uint256 stake, uint256 fee)
        internal
        returns (uint256 jobId)
    {
        vm.prank(creator);
        return jobFunds.publishJob(commitment, orgId, stake, fee, feeRecipient, bytes(""));
    }

    function _deployTestCommitment() internal returns (address) {
        return address(new TestCommitmentRegistration(IERC20(address(usdc)), IJobFunds(address(jobFunds))));
    }
}
