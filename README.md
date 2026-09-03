# Comitium Contracts

[![CI](https://github.com/comitiumhq/contracts/actions/workflows/test.yml/badge.svg)](https://github.com/comitiumhq/contracts/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-2f2f2f.svg)](./LICENSE)

The onchain accountability layer for Comitium.

> [!NOTE]
> The current deployment is a development release on Base Sepolia. No Base mainnet deployment has been published.

## Mechanism design

Public hiring has a credibility problem: organizations can publish roles with little accountability for following through, while automated tools make it cheap to submit applications at scale.

Comitium uses a two-sided commitment mechanism.

Organizations choose a USDC commitment above the protocol minimum and an application-review window. Larger commitments receive greater visibility in the default job ordering. The commitment is fully refundable when every application is answered on time; otherwise a response-rate-based share is burned.

Applicants temporarily lock a small amount for each application. It becomes fully withdrawable after the organization responds or the review deadline passes, so applying at scale ties up proportionally more capital. Applicant commitments are not fees and never affect candidate ranking.

## Protocol

| Component | Responsibility |
| --- | --- |
| [`OrgRegistry`](./src/OrgRegistry.sol) | Organization identity, administration, treasury authority, and public metadata |
| [`JobFunds`](./src/JobFunds.sol) | Organization USDC balances, job locks, fees, and settlement routing |
| [`JobCommitment`](./src/JobCommitment.sol) | Public job and application commitments, response evidence, applicant withdrawals, and settlement |
| `ERC2771Forwarder` | Sponsored transactions while preserving the original actor |

## Deployments

Deployment addresses and metadata are published in [`deployment-catalog.json`](./deployments/deployment-catalog.json).

| Network | Chain ID | Status |
| --- | ---: | --- |
| Base Sepolia | `84532` | Development |

## Development

[Foundry](https://book.getfoundry.sh/getting-started/installation) is required.

```bash
git clone --recurse-submodules https://github.com/comitiumhq/contracts.git
cd contracts

forge build
forge test
forge fmt --check
```

Additional commands:

```bash
forge lint
make coverage
make gas-check
make gas-snapshots # update after intentional gas changes
make slither # requires Slither
```

## Repository structure

| Path | Contents |
| --- | --- |
| [`src/`](./src) | Core contracts, interfaces, shared types, libraries, and lifecycle modules |
| [`test/`](./test) | Foundry tests, invariants, Halmos checks, and Medusa harnesses |
| [`snapshots/`](./snapshots) | Gas baselines for selected protocol operations |
| [`script/`](./script) | Deployment and post-deployment validation scripts |
| [`deployments/`](./deployments) | Versioned deployment registry |

## Security

Please report security vulnerabilities privately as described in [SECURITY.md](./SECURITY.md).

## License

[MIT](./LICENSE)
