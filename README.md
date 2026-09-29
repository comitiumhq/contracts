# Comitium Contracts

[![CI](https://github.com/comitiumhq/contracts/actions/workflows/test.yml/badge.svg)](https://github.com/comitiumhq/contracts/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-2f2f2f.svg)](./LICENSE)

The onchain accountability layer for Comitium.

> [!NOTE]
> The current deployment is a development release on Base Sepolia. No Base mainnet deployment has been published.

## Protocol

| Component | Responsibility |
| --- | --- |
| [`OrgRegistry`](./src/OrgRegistry.sol) | Organization identity, administration, treasury authority, and public metadata |
| [`CommitmentFunds`](./src/CommitmentFunds.sol) | Organization USDC balances, commitment locks, fees, and settlement accounting |
| [`ResponseCommitment`](./src/ResponseCommitment.sol) | Optional response commitment lifecycle and response evidence |
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
