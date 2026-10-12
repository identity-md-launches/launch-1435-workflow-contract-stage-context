# Local validation

Checked on 2026-10-12 with Foundry 1.8.3 and the pinned Solidity 0.8.26 compiler.

- `forge build`: passed.
- `forge test`: 72 tests passed, 0 failed, 0 skipped across 8 suites.
- `forge fmt --check`: passed.
- Fuzz cases: 256 runs each for exact token transfers, valid/invalid/mutated request JSON, and payout conservation in either claim order.
- Invariant campaign: 64 runs, depth 32 (2,048 handler calls), checking custody/conservation, oracle escrow/spending/refunds, and final-state stability.
- Actual factory-construction test: fixed token supply remains at the factory; Tribunal has the explicit launch owner; constructors work without deployed dependencies; both runtimes fit EIP-170 and contain no DELEGATECALL, CALLCODE or SELFDESTRUCT when PUSH data is skipped.
- Canonical protocol vector digest and original signature accepted by the inherited verifier; actual bool callback accepted under a 200,000 gas stipend, including cold storage for both outcomes.
- Exported ABI arrays match the final compiler artifacts; production bytecode has no linking placeholders.

| Contract | Runtime bytes | ABI entries |
| --- | ---: | ---: |
| `LaunchToken` | 1,502 | 18 |
| `Tribunal` | 19,466 | 98 |

Read-only Ethereum checks through the supplied local provider found Intake v2 bytecode, IMD symbol `IMD`/18 decimals and an `oracle.request@oracle-1` price of `500000000000000000`. The published signer has no contract code (EOA). The observed head for the later checks was block 26,177,391. These observations do not deploy or audit Tribunal and should be rechecked by the deployment services.

No tests use environment reads/writes, network requests, FFI or filesystem permissions. Dependencies are vendored as ordinary files. Slither/Mythril and an independent audit were not run; independent source/manifest review is the later assigned stage. Local results carry no independent authority.
