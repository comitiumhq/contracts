// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {CommitmentFunds} from "../../src/CommitmentFunds.sol";

import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {OrgTestBase} from "../shared/OrgTestBase.sol";

/// @title OrgReentrancyTest
/// @notice Reentrancy tests for OrgRegistry using a malicious token
contract OrgReentrancyTest is OrgTestBase {
    ReentrantOrgToken reentrantToken;
    OrgRegistry reentrantRegistry;
    CommitmentFunds reentrantCommitmentFunds;

    function setUp() public override {
        // Don't call super - custom setup with reentrant token
        operator = vm.addr(operatorPrivateKey);
        orgOwner1 = vm.addr(orgOwner1PrivateKey);
        orgOwner2 = vm.addr(orgOwner2PrivateKey);
        vm.label(orgOwner1, "orgOwner1");
        vm.label(orgOwner2, "orgOwner2");

        reentrantToken = new ReentrantOrgToken();
        forwarder = new ERC2771Forwarder("ComitiumForwarder");

        reentrantRegistry = new OrgRegistry(contractOwner, address(forwarder), operator, executor);
        reentrantCommitmentFunds = new CommitmentFunds(
            IERC20(address(reentrantToken)),
            IOrgRegistry(address(reentrantRegistry)),
            feeRecipient,
            contractOwner,
            address(forwarder)
        );
    }

    function test_reentrancy_depositWithAuthorization_guardPreventsDoubleDeposit() public {
        // Create org with reentrant token
        uint256 keyNonce = _nextDomainKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        // Sign domain for reentrant registry
        bytes32 structHash =
            keccak256(abi.encode(DOMAIN_VERIFICATION_TYPEHASH, _domainHash("test.com"), orgOwner1, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", reentrantRegistry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        reentrantToken.mint(orgOwner1, 10_000_000_000);
        vm.prank(executor);
        uint256 orgId = reentrantRegistry.createOrg(orgOwner1, _domainHash("test.com"), keyNonce, expiry, sig);

        uint256 depositAmount = 5_000_000_000;

        reentrantToken.setAttack(
            address(reentrantCommitmentFunds),
            false, // not on transfer
            true, // on transferFrom
            abi.encodeWithSelector(
                reentrantCommitmentFunds.depositWithAuthorization.selector,
                orgId,
                1_000_000,
                0,
                block.timestamp + 1 hours,
                bytes32(0),
                0,
                bytes32(0),
                bytes32(0)
            )
        );

        vm.prank(orgOwner1);
        reentrantCommitmentFunds.depositWithAuthorization(
            orgId, depositAmount, 0, block.timestamp + 1 hours, bytes32(uint256(1)), 0, bytes32(0), bytes32(0)
        );

        assertEq(
            reentrantCommitmentFunds.availableBalance(orgId),
            depositAmount,
            "Only one deposit should have been recorded"
        );
        assertFalse(reentrantToken.lastAttackSucceeded(), "Nested deposit should be blocked by the guard");
        assertEq(reentrantToken.lastAttackRevertData(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
    }
}

/// @notice Token that attempts reentrancy on transfer
contract ReentrantOrgToken is ERC20 {
    address public target;
    bool public attackOnTransfer;
    bool public attackOnTransferFrom;
    bool public lastAttackSucceeded;
    bytes public lastAttackRevertData;
    bytes public attackCalldata;
    bool private _entered;

    constructor() ERC20("Reentrant Token", "REENT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(to == msg.sender, "caller must be payee");
        _maybeAttack(attackOnTransferFrom);
        _transfer(from, to, value);
    }

    function setAttack(address _target, bool _onTransfer, bool _onTransferFrom, bytes memory _calldata) external {
        target = _target;
        attackOnTransfer = _onTransfer;
        attackOnTransferFrom = _onTransferFrom;
        attackCalldata = _calldata;
        lastAttackSucceeded = false;
        lastAttackRevertData = "";
        _entered = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _maybeAttack(attackOnTransfer);

        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _maybeAttack(attackOnTransferFrom);

        return super.transferFrom(from, to, amount);
    }

    function _maybeAttack(bool enabled) private {
        if (!enabled || _entered || target == address(0) || attackCalldata.length == 0) return;

        _entered = true;
        (bool success, bytes memory revertData) = target.call(attackCalldata);
        lastAttackSucceeded = success;
        lastAttackRevertData = revertData;
        _entered = false;
    }
}
