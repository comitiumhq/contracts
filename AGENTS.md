# Comitium Contracts

This repository owns Comitium's Solidity protocol, contract tests, deployment scripts, and deployment registry.

## Context first

Before editing, read `../PRODUCT.md`, the relevant contract architecture, and its ADRs:

- `../comitium-docs/architecture/response-commitment-architecture.md`;
- `../comitium-docs/architecture/commitment-funds-architecture.md`;
- `../comitium-docs/architecture/organization-registry-architecture.md`;
- `../comitium-docs/architecture/contract-versioning-and-deployment.md`;
- `../comitium-docs/architecture/indexer-event-projections.md` when events change;
- any active contract spec governing the change.

Confirm current behavior in Solidity and tests. Architecture documents explain intent but do not replace source-level verification.

## Implementation rules

- Prefer established OpenZeppelin primitives and existing repository libraries over custom access control, signature, token, upgrade, or cryptographic code.
- Preserve explicit role separation among owner, operator, executor/relayer, fee recipient, and treasury. Never collapse roles for convenience.
- Treat storage layout, event schemas, custom errors, EIP-712 domains/type hashes, replay protection, and external-call order as public protocol contracts.
- Follow checks-effects-interactions and make reentrancy assumptions explicit. Do not add external calls inside partially updated state.
- State transitions must have one authoritative guard and emit enough information for deterministic indexing without leaking private data.
- Keep amounts in exact integer units. Do not introduce floating-point or lossy off-chain conversions into protocol expectations.
- When changing an event or public interface, trace the affected ABI, indexer handlers, API bindings/workflows, web bindings, and architecture docs.
- Add comments only for protocol intent or non-obvious invariants; do not narrate the code.

## Deployment safety

- Building and testing do not authorize broadcasting, deployment, ownership transfer, verification, or fund movement.
- Do not hand-edit `broadcast/` output or `deployments/{chainId}.json`. They are produced by the deployment workflow and must correspond to an actual deployment.
- Do not use or expose private keys, keystore secrets, RPC credentials, or explorer tokens.
- Existing dirty deployment artifacts belong to the user unless the current task explicitly includes them.

## Verification

Use Foundry:

```bash
forge fmt --check
forge build --sizes
forge test
```

Start with `forge test --match-path test/Path.t.sol` while iterating. Run the relevant invariant/fuzz suite for funds, authorization, signatures, lifecycle, accounting, or cross-contract changes. Gas or size regressions are findings when they threaten configured or network limits, not merely because a number changed.

## Definition of done

Walk every affected transaction through authorization, preconditions, state changes, external calls, emitted events, and downstream indexing. Update current-state architecture and deployment documentation in the same chunk when protocol behavior or its integration contract changes.
