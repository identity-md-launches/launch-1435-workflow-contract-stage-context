# Contract ABI and integration

The JSON files in `docs/abi/` are raw compiler ABI arrays for `LaunchToken` and `Tribunal`, generated using Solidity 0.8.26 with the root Foundry configuration.

Regenerate after a source change:

```sh
forge inspect LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect Tribunal abi --json > docs/abi/Tribunal.json
```

All token amounts are uint256 minor units with 18 decimals. All timestamps are uint64 Unix seconds. Market IDs start at 1. The full tuple component order is defined by the JSON ABI.

| User operation | Signature | Behavior |
| --- | --- | --- |
| Create | `createMarket(string,bytes,uint64,uint64) -> uint256` | Approve VERDICT for 10,000 tokens and IMD for the configured price first. Stores exact body/terms and escrows both deposits. |
| YES bet | `betYes(uint256,uint256)` | Approve VERDICT, at least 100 tokens, before closing. |
| NO bet | `betNo(uint256,uint256)` | Same requirements, adds to NO position. |
| Summon jury | `requestResolution(uint256) -> bytes32` | Anyone after resolveAfter, before unrequested timeout. Two-sided markets pay from escrow and return the Intake ID. Empty/one-sided markets become VOID without payment and return zero (no request). |
| Timed-out VOID | `voidMarket(uint256)` | Anyone at/after stored deadline while Open/Pending. |
| Claim | `claim(uint256) -> uint256` | Caller must be bettor or creator; once after a final result. Return is VERDICT payout; event also shows any unspent oracle fee refund. |
| Public retry | `submitAttestation(uint256,Attestation,bytes)` | Only an attestation digest already bound by the authentic callback. Same result checks, without callback gas limit. |
| Read terms | `getMarket(uint256) -> Market` | Complete stored market, oracle settings, signer, pools, deadlines, body and accounting. Unknown IDs revert. |
| Read position | `positions(uint256,address) -> (uint256 yes,uint256 no,bool claimed)` | Wallet's aggregate stakes and claim marker. |

`State` codes are None=0, Open=1, Pending=2, Yes=3, No=4, Void=5. Derive a UI's "closed/awaiting jury" state from `closeTime` while enum Open. Fees apply only to two-sided Yes/No; otherwise show refundable deposits.

Owner setup/configuration functions are `setVerdictToken(address)` (once), `setIntake(address)`, `setAction(bytes32)`, `setPayment(address,uint256)`, `setOracleSigner(address)` (signer schedule), `cancelSignerChange()` and `cancelOracleConfigChange()`. The Intake/action/payment setters edit one complete pending configuration and restart its 48-hour delay; active values do not change. `activateOracleConfig()` is permissionless at/after `configActivateAfter` and applies all pending fields atomically, clears the schedule and emits `IntakeSet`, `ActionSet` and `PaymentSet`. `OracleConfigScheduled(intake,asset,action,price,activateAfter)` announces each edit; `OracleConfigScheduleCancelled()` announces cancellation. After cancellation, the next setter starts from the active configuration. `activateOracleSigner()` independently activates its signer schedule after 48 hours. Neither activation changes existing market snapshots.

Read `oracleConfig`, `pendingOracleConfig` (both return intake/asset/action/price), `configActivateAfter`, `CONFIG_DELAY`, `oracleSigner`, `pendingSigner`, `signerActivateAfter`, `owner` and `pendingOwner`. A zero activation timestamp means there is no pending configuration. A matured schedule still needs an activation transaction. Ownership uses `transferOwnership(address)` followed by the nominated address's `acceptOwnership()`; renunciation is inherited and leaves existing schedules activatable. Retain ownership for ongoing price/protocol maintenance; renouncing before token setup permanently disables creation.

Only the Intake may call result/failure callbacks, for its own pending request. The exact result signature is:

```text
onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)
```

The tuple fields, in order, are `requestId`, `chainId`, `questionHash`, `answerType`, `answer`, `figure`, `fromBlock`, `toBlock`, `blockHash`, `panelJobId`, `panelSize`, `quorum`, `agreed`, `issuedAt`, `expiresAt`. A bool answer has `answerType = 0` and `answer = abi.encode(bool)` (32 bytes). Its `requestId` is the oracle UUID, **not** the first callback argument, which is the Intake request id.

Failure signature:

```text
onOracleFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)
```

Arguments are Intake request id, status, reason, agreed, answered, signature. Failure data is unsigned; statuses 1/2 can void a pending request. Reasons such as `bytes32("disagreed")` are right-padded text. `finalizeOracleResult(uint256,Attestation,bytes)` is a callback implementation detail exposed for a bounded self-call; every outside caller is rejected with `OnlySelf`.

Use `attestationDigest(Attestation)` to obtain the canonical EIP-712 digest. `consumed(bytes32)` tracks accepted oracle UUIDs. `requestMarket(address,bytes32)` indexes Intake id to market id under the Intake address. `verdictLiability()` and `oracleEscrow(address)` expose accounting, not withdrawable admin balances.

Events for indexing are `MarketCreated` (including original body hash and times), `BetPlaced`, `ResolutionRequested`, `AttestationBound`, `AttestationDeferred`, `MarketResolved` (oracle UUID/question hash), `MarketVoided` (reason/counts), `Claimed`, `LosingPoolBurned` and configuration/signer/ownership events. Fetch the full original title/body with `getMarket`. Display the decoded body question verbatim, definitions/window and the snapshotted Intake/signer on the market page and bet confirmation. A title does not bind or replace the question, and a relative window does not fix the observation time to `resolveAfter`. Show `MarketVoided` reason `uncontested` as refundable without any oracle request. `AttestationDeferred` leaves the market Pending; do not display a final verdict from that event. No callback pays tokens.

Custom errors are included in the ABI. Normal deadline/configuration errors include `NotConfigured`, `TokenAlreadySet`, `InvalidTimes`, `BetTooSmall`, `BettingClosed`, `TooEarly`, `DeadlinePassed`, `WrongState`, `AlreadyClaimed`, `NoPosition`, `UnexpectedTokenAmount`, `ConfigDelayPending` and `NoPendingConfig`. Oracle errors include `NotTheIntake`, `UnknownRequest`, `UnboundAttestation`, `PanelTooWeak`, `InvalidAttestation`, `BadSignature`, `AttestationExpired`, `AttestationNotYetValid`, `WrongAnswerType` and `AlreadyConsumed`. A failed verification inside the bounded callback is caught and reported as `AttestationDeferred`; a public retry returns the concrete revert.
