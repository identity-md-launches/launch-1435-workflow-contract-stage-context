# Additional adversarial tests

Run `forge build` and `forge test`. All dependencies are already vendored by the accepted implementation. These tests need no network, fork, environment variables, or shared configuration changes.

## Coverage

| Suite | Properties checked |
| --- | --- |
| `TribunalAccountingInvariant.t.sol` | Actual `LaunchToken` custody, pool totals versus individual stakes, independent deposit/payment accounting, exact oracle escrow, final-state permanence, fixed supply, donations, claim entitlements, and eventual withdrawal of every position. |
| `TribunalOracleBoundaries.t.sol` | Every signed field, noncanonical booleans and incorrect lengths, zero metadata, inclusive expiry and clock tolerance, deadline enforcement on failures and public retries, signer snapshots, and chain-domain separation. |
| `TribunalEscrowBoundaries.t.sol` | Identical IDs at different intakes after a scheduled configuration activates, asset/price snapshots, shared payment and betting asset, atomic failed deposits, zero/one/max inputs, isolation between a payout and another market's refund, and the uncontested ask: fee refunded in the original asset without reaching the Intake, no lock extension, finality, the last askable second versus the timeout path, and a creator alone on both sides still summoning the jury. |
| `LaunchTokenProperties.t.sol` | Transfer round trips, finite/infinite allowances, insufficient allowance/balance rollback, revocation, zero/one/full-supply/max amounts, self transfers, and invalid recipients/spenders. |

The existing protocol-vector conformance tests remain part of the full suite. Locally signed adversarial cases supplement that independent vector.

## Stateful accounting model

The additional invariant handler drives eight operations with four funded actors, up to twelve markets, 256 runs and 96 calls per run. It uses inline Foundry configuration, including `fail-on-revert = true`. Expected invalid calls have explicit revert assertions; valid calls are not hidden by `try/catch`.

Ghost positions record successful input amounts. An ask on a contested market must return a request id paired with that market and marks the fee spent; an ask on an empty or one-sided market must return a zero id, record no request, keep the deadline and void the market with the fee still refundable to its creator. Ghost payments record actual recipient and burn-address balance changes. Each claimant must receive at least its independently calculated entitlement; a winning claimant can receive at most three extra minor units from rounding among four wallets. Refunds, creator bonds/fees and burns have exact bounds. Position sums, ghost liabilities and external custody must agree after every call. Donations are tracked separately because they do not create claims.

After every generated sequence, `afterInvariant` advances to all outstanding deadlines, voids unfinished markets and claims every eligible position. All liabilities and fee escrows must reach zero; only deliberate donations may remain. A deterministic scenario also exercises successful resolutions, failures, one-sided and empty uncontested voids, refunds and repeated zero-payout claims so those branches do not depend solely on random selection. Oracle configuration scheduling is not driven by the handler; the accepted `TribunalConfig.t.sol` covers it, and the escrow boundary suite checks that activated changes do not reach existing markets' escrow.

These are local contract tests. The external Intake and payment token are mocked; the custody invariant uses the actual fixed-supply launch token. They do not establish the truth of an oracle answer, live service availability, or deployment/admission outcomes.
