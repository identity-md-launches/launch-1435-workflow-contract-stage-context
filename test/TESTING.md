# Additional adversarial tests

Run `forge build` and `forge test`. All dependencies are already vendored by the accepted implementation. These tests need no network, fork, environment variables, or shared configuration changes.

## Coverage

| Suite | Properties checked |
| --- | --- |
| `TribunalAccountingInvariant.t.sol` | Actual `LaunchToken` custody, pool totals versus individual stakes, independent deposit/payment accounting, exact oracle escrow, final-state permanence, fixed supply, donations, claim entitlements, and eventual withdrawal of every position. |
| `TribunalOracleBoundaries.t.sol` | Every signed field, noncanonical booleans and incorrect lengths, zero metadata, inclusive expiry and clock tolerance, deadline enforcement on failures and public retries, signer snapshots, and chain-domain separation. |
| `TribunalEscrowBoundaries.t.sol` | Identical IDs at different intakes, asset/price snapshots, shared payment and betting asset, atomic failed deposits, zero/one/max inputs, and isolation between a payout and another market's refund. |
| `LaunchTokenProperties.t.sol` | Transfer round trips, finite/infinite allowances, insufficient allowance/balance rollback, revocation, zero/one/full-supply/max amounts, self transfers, and invalid recipients/spenders. |

The existing protocol-vector conformance tests remain part of the full suite. Locally signed adversarial cases supplement that independent vector.

## Stateful accounting model

The additional invariant handler drives eight operations with four funded actors, up to twelve markets, 256 runs and 96 calls per run. It uses inline Foundry configuration, including `fail-on-revert = true`. Expected invalid calls have explicit revert assertions; valid calls are not hidden by `try/catch`.

Ghost positions record successful input amounts. Ghost payments record actual recipient and burn-address balance changes. Each claimant must receive at least its independently calculated entitlement; a winning claimant can receive at most three extra minor units from rounding among four wallets. Refunds, creator bonds/fees and burns have exact bounds. Position sums, ghost liabilities and external custody must agree after every call. Donations are tracked separately because they do not create claims.

After every generated sequence, `afterInvariant` advances to all outstanding deadlines, voids unfinished markets and claims every eligible position. All liabilities and fee escrows must reach zero; only deliberate donations may remain. A deterministic scenario also exercises successful resolutions, failures, refunds and repeated zero-payout claims so those branches do not depend solely on random selection.

These are local contract tests. The external Intake and payment token are mocked; the custody invariant uses the actual fixed-supply launch token. They do not establish the truth of an oracle answer, live service availability, or deployment/admission outcomes.
