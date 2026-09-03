// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {JobFunds} from "../../src/JobFunds.sol";

interface IEip3009TestToken {
    function mint(address to, uint256 amount) external;
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

abstract contract Eip3009TestHelper is Test {
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 private _authorizationNonce;

    function _fundAndDepositWithAuthorization(
        JobFunds jobFunds,
        address token,
        uint256 treasuryPrivateKey,
        uint256 orgId,
        uint256 amount
    ) internal {
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256(abi.encode(address(this), ++_authorizationNonce));
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            token, address(jobFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );

        IEip3009TestToken(token).mint(treasury, amount);
        vm.prank(treasury);
        jobFunds.depositWithAuthorization(orgId, amount, validAfter, validBefore, nonce, v, r, s);
    }

    function _signReceiveWithAuthorization(
        address token,
        address recipient,
        uint256 treasuryPrivateKey,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal returns (uint8 v, bytes32 r, bytes32 s) {
        address treasury = vm.addr(treasuryPrivateKey);
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, treasury, recipient, amount, validAfter, validBefore, nonce)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IEip3009TestToken(token).DOMAIN_SEPARATOR(), structHash));

        return vm.sign(treasuryPrivateKey, digest);
    }
}
