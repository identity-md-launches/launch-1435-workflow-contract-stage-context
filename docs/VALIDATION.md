# Local validation

Checked on 2026-10-12 with Foundry 1.8.5 and the pinned Solidity 0.8.26 compiler.

- `forge build`: passed.
- `forge test`: 81 tests passed, 0 failed, 0 skipped across 9 suites (scratch files excluded from the deliverable).
- `forge fmt --check`: passed.
- The supplied `Proof_59260d2a3f37.t.sol` was copied unchanged into `test/scratch/`. Before the fix, its single test failed with `owner-controlled Intake settled the market`; after the fix, the same test passed. The copy was byte-for-byte compared with the supplied proof.
- Eight scratch advisory reproductions confirmed the reported timing/configuration assumptions. Before the fix, the empty-market fee and one-sided deadline assertions failed; after the fix all eight passed. These were local scaffolding, not submitted dependencies.
- New permanent regression tests cover complete configuration scheduling, exact 48-hour activation, owner cancellation, replacement delay resets, immutable existing market settings, rejected replacement-Intake results/failures, price-change recovery, empty/one-sided jury-fee refunds, and no lock extension. The signer-retirement test confirms the documented old-market timeout behavior; the pending-ownership-transfer test confirms the original owner can still configure the token.
- Fuzz cases: 256 runs each for exact token transfers, valid/invalid/mutated request JSON, and payout conservation in either claim order.
- Invariant campaign: 64 runs, depth 32 (2,048 handler calls), checking custody/conservation, oracle escrow/spending/refunds, and final-state stability.
- Actual factory-construction test: fixed token supply remains at the factory; Tribunal has the explicit launch owner; constructors work without deployed dependencies; both runtimes fit EIP-170 and contain no DELEGATECALL, CALLCODE or SELFDESTRUCT when PUSH data is skipped.
- Canonical protocol vector digest and original signature accepted by the inherited verifier; actual bool callback accepted under a 200,000 gas stipend, including cold storage for both outcomes.
- Exported ABI arrays match the final compiler artifacts; production bytecode has no linking placeholders.

| Contract | Runtime bytes | ABI entries |
| --- | ---: | ---: |
| `LaunchToken` | 1,502 | 18 |
| `Tribunal` | 20,533 | 107 |

The accepted initial contribution recorded read-only Ethereum checks through its supplied local provider: Intake v2 bytecode, IMD symbol `IMD`/18 decimals and an `oracle.request@oracle-1` price of `500000000000000000`. The signer had no contract code (EOA). The observed head for the later checks was block 26,177,391. Those earlier observations were not repeated during this revision; they do not deploy or audit Tribunal and should be rechecked by the deployment services.

No tests use environment reads/writes, network requests, FFI or filesystem permissions. Dependencies are vendored as ordinary files. Slither/Mythril were not run. The supplied independent contributor findings prompted this revision; `.imd-responses.json` records every disposition for the subsequent source/manifest review. Local results carry no independent authority.
