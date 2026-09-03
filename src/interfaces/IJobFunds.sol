// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOrgRegistry} from "./IOrgRegistry.sol";

/// @notice Per-organization balance held for job publishing.
/// @dev available + stakedInJobs is the org's accounted JobFunds balance.
struct OrgJobBalance {
    /// @notice Funds that the org treasury can withdraw or spend on new jobs.
    uint96 available;

    /// @notice Funds locked behind live jobs in authorized JobCommitment contracts.
    uint96 stakedInJobs;
}

/// @notice Stake lock created by a specific JobCommitment contract for one job.
/// @dev Locks are keyed by (jobCommitment, jobId), so job IDs may overlap across deployments.
struct JobLock {
    /// @notice Original job stake still controlled by the JobCommitment lifecycle.
    uint96 stakeAmount;

    /// @notice Organization that funded the job.
    uint96 orgId;
}

/// @notice Immutable registration facts for a JobCommitment deployment.
struct RegisteredJobCommitment {
    /// @notice Commitment interface version reported by the deployment.
    uint32 commitmentVersion;

    /// @notice Whether this JobCommitment has been registered in JobFunds.
    bool exists;
}

/// @title IJobFunds
/// @notice Escrow that holds organization funds reserved for JobCommitment workflows.
interface IJobFunds {
    /// @notice Emitted after org job funds are received by JobFunds.
    event JobFundsDeposited(uint256 indexed orgId, address indexed treasury, uint256 amount);

    /// @notice Emitted after available org job funds are withdrawn by the current org treasury.
    event JobFundsWithdrawn(uint256 indexed orgId, address indexed treasury, uint256 amount);

    /// @notice Emitted when an authorized org manager publishes a job and locks its stake.
    event JobFunded(
        address indexed jobCommitment,
        uint256 indexed orgId,
        uint256 indexed jobId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount
    );

    /// @notice Emitted when an authorized JobCommitment settles a job stake.
    event JobSettled(
        address indexed jobCommitment,
        uint256 indexed orgId,
        uint256 indexed jobId,
        uint256 returnAmount,
        uint256 slashedAmount
    );

    /// @notice Emitted when slashed org stake is sent to the burn address.
    event StakeBurned(address indexed jobCommitment, uint256 indexed orgId, uint256 indexed jobId, uint256 amount);

    /// @notice Emitted when a JobCommitment deployment is authorized.
    event JobCommitmentRegistered(address indexed jobCommitment, uint32 commitmentVersion);

    /// @notice Emitted when the JobCommitment used for new jobs changes.
    event CurrentJobCommitmentUpdated(address indexed previousJobCommitment, address indexed newJobCommitment);

    /// @notice Emitted when the recipient of job publishing fees changes.
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    /// @notice Emitted when accidental token surplus is recovered.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when an org-level job manager is enabled or disabled.
    event JobManagerUpdated(
        uint256 indexed orgId, address indexed account, bool active, address indexed actor, bool changed
    );

    /// @notice Deposit job funds with an EIP-3009 token authorization.
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

    /// @notice Withdraw available job funds to the current organization treasury.
    /// @param orgId Organization ID whose current treasury must call the function.
    /// @param amount Amount of stake token to withdraw.
    function withdraw(uint256 orgId, uint256 amount) external;

    /// @notice Publish through the current JobCommitment and debit the exact user-authorized amount.
    /// @param jobCommitment Current JobCommitment that will create the job.
    /// @param orgId Organization funding the job.
    /// @param stakeAmount Amount locked for job lifecycle guarantees.
    /// @param feeAmount Exact publishing fee authorized by the caller.
    /// @param expectedFeeRecipient Exact publishing fee destination authorized by the caller.
    /// @param publishData Commitment-specific publication payload, opaque to JobFunds.
    /// @return jobId Job ID created inside the selected JobCommitment.
    function publishJob(
        address jobCommitment,
        uint256 orgId,
        uint256 stakeAmount,
        uint256 feeAmount,
        address expectedFeeRecipient,
        bytes calldata publishData
    ) external returns (uint256 jobId);

    /// @notice Settle a job lock and return any non-slashed stake to the org balance.
    /// @param orgId Organization that funded the job.
    /// @param jobId Job ID inside the calling JobCommitment contract.
    /// @param returnAmount Amount returned to available org balance.
    function settleJob(uint256 orgId, uint256 jobId, uint256 returnAmount) external;

    /// @notice Enable or disable an account that can manage org job lifecycle actions.
    /// @param orgId Organization ID.
    /// @param account Account to update.
    /// @param active Whether the account should be active.
    function setJobManager(uint256 orgId, address account, bool active) external;

    /// @notice Get available job funds for an organization.
    /// @param orgId Organization ID.
    /// @return available Available stake-token balance.
    function availableBalance(uint256 orgId) external view returns (uint256 available);

    /// @notice Get available and staked job balances for an organization.
    /// @param orgId Organization ID.
    /// @return balance Job funding balance.
    function jobBalance(uint256 orgId) external view returns (OrgJobBalance memory balance);

    /// @notice Get a job lock for a JobCommitment/job pair.
    /// @param jobCommitment JobCommitment contract address.
    /// @param jobId Job ID inside that JobCommitment contract.
    /// @return lock Job lock data.
    function jobLock(address jobCommitment, uint256 jobId) external view returns (JobLock memory lock);

    /// @notice Total stake-token amount accounted as available or staked across all organizations.
    /// @return total Accounted JobFunds balance.
    function totalAccountedBalance() external view returns (uint256 total);

    /// @notice Check whether an account has an explicit job-manager grant.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return active True when the account has an explicit job-manager grant.
    function isJobManager(uint256 orgId, address account) external view returns (bool active);

    /// @notice Check whether an account can publish, unpublish, or close jobs for an org.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return allowed True when the account has org-side job-management authority.
    function canManageJobs(uint256 orgId, address account) external view returns (bool allowed);

    /// @notice Get registration facts for a JobCommitment contract.
    /// @param jobCommitment JobCommitment contract address.
    /// @return config Registered JobCommitment data.
    function registeredJobCommitment(address jobCommitment)
        external
        view
        returns (RegisteredJobCommitment memory config);

    /// @notice JobCommitment contract used for new jobs.
    /// @return jobCommitment Current create-capable JobCommitment address.
    function currentJobCommitment() external view returns (address jobCommitment);

    /// @notice Token used for job funding, fees, and slash burns.
    function stakeToken() external view returns (IERC20);

    /// @notice Registry that defines org identity, admins, and treasury.
    function orgRegistry() external view returns (IOrgRegistry);

    /// @notice Recipient of job publishing fees.
    function feeRecipient() external view returns (address);
}
