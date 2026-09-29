// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOrgRegistry} from "./IOrgRegistry.sol";

/// @notice Per-organization balance held for commitment activation.
/// @dev available + lockedInCommitments is the org's accounted CommitmentFunds balance.
struct OrgCommitmentBalance {
    /// @notice Funds that the org treasury can withdraw or spend on new commitments.
    uint96 available;

    /// @notice Funds locked behind live commitments in authorized ResponseCommitment contracts.
    uint96 lockedInCommitments;
}

/// @notice Stake lock created by a specific ResponseCommitment contract for one commitment.
/// @dev Locks are keyed by (responseCommitment, commitmentId), so commitment IDs may overlap across deployments.
struct CommitmentLock {
    /// @notice Original commitment stake still controlled by the ResponseCommitment lifecycle.
    uint96 stakeAmount;

    /// @notice Organization that funded the commitment.
    uint96 orgId;
}

/// @notice Immutable registration facts for a ResponseCommitment deployment.
struct RegisteredResponseCommitment {
    /// @notice Commitment interface version reported by the deployment.
    uint32 commitmentVersion;

    /// @notice Whether this ResponseCommitment has been registered in CommitmentFunds.
    bool exists;
}

/// @title ICommitmentFunds
/// @notice Escrow that holds organization funds reserved for ResponseCommitment workflows.
interface ICommitmentFunds {
    /// @notice Emitted after org commitment funds are received by CommitmentFunds.
    event CommitmentFundsDeposited(uint256 indexed orgId, address indexed treasury, uint256 amount);

    /// @notice Emitted after available org commitment funds are withdrawn by the current org treasury.
    event CommitmentFundsWithdrawn(uint256 indexed orgId, address indexed treasury, uint256 amount);

    /// @notice Emitted when an org admin or commitment manager activates a commitment and locks its stake.
    event CommitmentStakeLocked(
        address indexed responseCommitment,
        uint256 indexed orgId,
        uint256 indexed commitmentId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount
    );

    /// @notice Emitted when an authorized ResponseCommitment settles a commitment stake.
    event CommitmentStakeSettled(
        address indexed responseCommitment,
        uint256 indexed orgId,
        uint256 indexed commitmentId,
        uint256 returnAmount,
        uint256 slashedAmount
    );

    /// @notice Emitted when slashed org stake is sent to the burn address.
    event StakeBurned(
        address indexed responseCommitment, uint256 indexed orgId, uint256 indexed commitmentId, uint256 amount
    );

    /// @notice Emitted when a ResponseCommitment deployment is authorized.
    event ResponseCommitmentRegistered(address indexed responseCommitment, uint32 commitmentVersion);

    /// @notice Emitted when the ResponseCommitment used for new commitments changes.
    event CurrentResponseCommitmentUpdated(
        address indexed previousResponseCommitment, address indexed newResponseCommitment
    );

    /// @notice Emitted when the recipient of commitment activation fees changes.
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    /// @notice Emitted when accidental token surplus is recovered.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when an org-level commitment manager is enabled or disabled.
    event CommitmentManagerUpdated(
        uint256 indexed orgId, address indexed account, bool active, address indexed actor, bool changed
    );

    /// @notice Deposit commitment funds with an EIP-3009 token authorization.
    /// @param orgId Organization ID whose current treasury signed the authorization.
    /// @param amount Amount of stake token to deposit.
    /// @param validAfter Earliest timestamp after which the token authorization is valid.
    /// @param validBefore Timestamp before which the token authorization is valid.
    /// @param nonce Unique token authorization nonce.
    /// @param v ECDSA recovery identifier.
    /// @param r ECDSA signature r value.
    /// @param s ECDSA signature s value.
    function depositWithAuthorization(
        uint256 orgId,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Deposit approved stake tokens from the current organization treasury.
    /// @param orgId Organization ID whose current treasury must call the function.
    /// @param amount Amount of stake token to deposit.
    function deposit(uint256 orgId, uint256 amount) external;

    /// @notice Withdraw available commitment funds to the current organization treasury.
    /// @param orgId Organization ID whose current treasury must call the function.
    /// @param amount Amount of stake token to withdraw.
    function withdraw(uint256 orgId, uint256 amount) external;

    /// @notice Activate through the current ResponseCommitment and debit the exact user-authorized amount.
    /// @param responseCommitment Current ResponseCommitment that will create the commitment.
    /// @param orgId Organization funding the commitment.
    /// @param stakeAmount Amount locked for commitment lifecycle guarantees.
    /// @param feeAmount Exact activation fee authorized by the caller.
    /// @param expectedFeeRecipient Exact activation fee destination authorized by the caller.
    /// @param activateData Commitment-specific activation payload, opaque to CommitmentFunds.
    /// @return commitmentId Commitment ID created inside the selected ResponseCommitment.
    function activateCommitment(
        address responseCommitment,
        uint256 orgId,
        uint256 stakeAmount,
        uint256 feeAmount,
        address expectedFeeRecipient,
        bytes calldata activateData
    ) external returns (uint256 commitmentId);

    /// @notice Settle a commitment lock and return any non-slashed stake to the org balance.
    /// @param orgId Organization that funded the commitment.
    /// @param commitmentId Commitment ID inside the calling ResponseCommitment contract.
    /// @param returnAmount Amount returned to available org balance.
    function settleCommitment(uint256 orgId, uint256 commitmentId, uint256 returnAmount) external;

    /// @notice Enable or disable an account that can manage org commitment lifecycle actions.
    /// @param orgId Organization ID.
    /// @param account Account to update.
    /// @param active Whether the account should be active.
    function setCommitmentManager(uint256 orgId, address account, bool active) external;

    /// @notice Get available commitment funds for an organization.
    /// @param orgId Organization ID.
    /// @return available Available stake-token balance.
    function availableBalance(uint256 orgId) external view returns (uint256 available);

    /// @notice Get available and staked commitment balances for an organization.
    /// @param orgId Organization ID.
    /// @return balance Commitment funding balance.
    function commitmentBalance(uint256 orgId) external view returns (OrgCommitmentBalance memory balance);

    /// @notice Get a commitment lock for a ResponseCommitment/commitment pair.
    /// @param responseCommitment ResponseCommitment contract address.
    /// @param commitmentId Commitment ID inside that ResponseCommitment contract.
    /// @return lock Commitment lock data.
    function commitmentLock(address responseCommitment, uint256 commitmentId)
        external
        view
        returns (CommitmentLock memory lock);

    /// @notice Total stake-token amount accounted as available or staked across all organizations.
    /// @return total Accounted CommitmentFunds balance.
    function totalAccountedBalance() external view returns (uint256 total);

    /// @notice Check whether an account has an explicit commitment-manager grant.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return active True when the account has an explicit commitment-manager grant.
    function isCommitmentManager(uint256 orgId, address account) external view returns (bool active);

    /// @notice Check whether an account can activate, stop, or settle commitments for an org.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return allowed True when the account has org-side commitment-management authority.
    function canManageCommitments(uint256 orgId, address account) external view returns (bool allowed);

    /// @notice Get registration facts for a ResponseCommitment contract.
    /// @param responseCommitment ResponseCommitment contract address.
    /// @return config Registered ResponseCommitment data.
    function registeredResponseCommitment(address responseCommitment)
        external
        view
        returns (RegisteredResponseCommitment memory config);

    /// @notice ResponseCommitment contract used for new commitments.
    /// @return responseCommitment Current create-capable ResponseCommitment address.
    function currentResponseCommitment() external view returns (address responseCommitment);

    /// @notice Token used for commitment funding, fees, and slash burns.
    function stakeToken() external view returns (IERC20);

    /// @notice Registry that defines org identity, admins, and treasury.
    function orgRegistry() external view returns (IOrgRegistry);

    /// @notice Recipient of commitment activation fees.
    function feeRecipient() external view returns (address);
}
