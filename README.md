# The Tribunal

Prediction markets judged by the IdentityMD oracle on Ethereum. This contribution delivers the contracts, offline Foundry tests, ABI exports and deployment/integration documentation for the contract stage. Publication, independent source/manifest review, admission, deployment and the website are subsequent service/contributor responsibilities.

## Contracts

- `LaunchToken`: Verdict (`VERDICT`), an ordinary ERC-20 with 18 decimals. Its argument-free constructor mints exactly `1_000_000_000 ether` (`10^27` minor units) to its deployer, the launch factory. There is no additional mint, owner, pause, blocklist, transfer fee, upgrade or token burn function.
- `Tribunal`: holds creator bonds, bets and unspent jury fees; asks Intake v2; verifies the canonical oracle EIP-712 attestation; records YES, NO or VOID; lets each participating wallet claim once. Administration has no withdrawal, market cancellation or discretionary outcome function.
- `OracleAttestation.sol`: the supplied protocol library/base consumer, copied unchanged. `OracleBody` and `IIntake` provide internal validation and the v2 interface; they are not additional deployable applications.

The ABI arrays are [docs/abi/LaunchToken.json](docs/abi/LaunchToken.json) and [docs/abi/Tribunal.json](docs/abi/Tribunal.json). Human-readable calls and callback types are in [docs/ABI.md](docs/ABI.md).

## Build and check

```sh
forge build
forge test
forge fmt --check
```

The root `foundry.toml` pins Solidity **0.8.26**, optimizer runs 200, via-IR, Cancun and `bytecode_hash = "none"`. Dependencies are ordinary vendored files with their licenses; see [DEPENDENCIES.md](DEPENDENCIES.md). No network, environment variables, FFI, filesystem permissions, external libraries, submodules or external services are needed by the tests. The verifier must supply the pinned compiler, as stipulated by the assignment.

Tests cover fixed token supply and ERC-20 transfers; factory construction with absent dependencies; runtime size and prohibited opcodes; token setup and access control; input validation; betting windows; exact oracle payment and v2 selectors; asynchronous failures/timeouts; EIP-712 domains and replay; delayed oracle configuration and signer rotation; settlement under a cold 200,000 gas stipend; public retry; YES/NO payouts, one-sided/VOID refunds, both-side positions and creator positions; double claims; failed/false-returning/taxed token transfers; reentrancy; rounding conservation and randomized sequences across concurrent markets.

The conformance suite preserves the supplied protocol's chain, consumer address, digest, attestation and signature. A test-only subclass exposes the canonical verifier for the unchanged bytes32[] vector. Tribunal's actual bool callback is separately exercised with the vector key and a 200,000 gas stipend.

## Deployment parameters

Deploy `LaunchToken` first and `Tribunal` as the sole application. Their Solidity identifiers fit the launch's 32-character limit. Tribunal's constructor is nonpayable and takes six static arguments, in this order:

| Argument | Type | Ethereum launch value |
| --- | --- | --- |
| `owner_` | address | `$owner`, resolving to `0x152d7fbf16adf2a5104d2d11bfdcc951254f746b` |
| `intake_` | address | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (Intake v2) |
| `asset_` | address | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD, 18 decimals) |
| `action_` | bytes32 | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| `price_` | uint256 | `500000000000000000` (0.5 IMD) |
| `signer_` | address | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` (published oracle signer) |

The action is the UTF-8 `oracle.request@oracle-1`, right-padded with zero bytes, **not its keccak hash**. Neither constructor calls outside contracts or requires dependency code. Tribunal checks live Intake/asset code and `priceOf` when a market is first created. The explicit owner is never the factory or `tx.origin`. The initial published signer is configured in the constructor; subsequent owner changes are delayed as described below.

The launch services/factory own allocation and pool creation: 10% swarm, 88% pool and the other 2% to the launch payer or the chain treasury under the supplied launch policy. No Tribunal allocation is reserved or transferred at launch. The pool pairs with Ethereum IMD, uses fee `12500` (1.25%), tick spacing `60` and the supplied legacy `initialPrice` value `79228162514264337593543950336`. The service derives the effective opening price from the policy's 2,500 IMD opening capitalization and the deployed token's ordering. Tribunal implements no pool or trading fees. Its settlement fee below is distinct from the pool's 1.25% trading fee.

The manifest contributor writes `launch.json` after acceptance; this contribution does not generate it. Source/ABI publication, signed artifact linkage, policy admission, explorer verification and deployment belong to the services. No keys, transactions or funded wallet operations are used here.

### After launch

Before enabling the website's market creation:

1. The owner calls `setVerdictToken(actualLaunchTokenAddress)` once. Get this address from the accepted deployment handoff, verify its bytecode/name/symbol/supply, and check `verdictToken()` afterwards. The address must have code; it is permanently locked. Code presence does not authenticate the token: selecting the Tribunal, the Intake or a different ERC-20 can permanently disable markets or use the wrong asset. There is no correction setter. Do not renounce ownership before setup; doing so leaves the token permanently unconfigured. An unaccepted ownership transfer still leaves the current owner able to complete setup. No market or bet can exist before this setting. The explicit workflow's owner setup is used because the factory makes no initialization calls.
2. Verify `oracleConfig()` and `oracleSigner()` against the published Ethereum protocol configuration. No requester-specific subscription, registry, relayer or unpublished service identifier is needed.
3. If the oracle signer changes, the owner calls `setOracleSigner(newPublishedSigner)`. The change remains pending for **48 hours**, then anyone can call `activateOracleSigner()`. Replacing a schedule restarts the delay; the owner may cancel it with `cancelSignerChange()`. Existing markets retain their creation-time signer; activation only affects new markets. If the protocol retires that old key, its new-key answers cannot settle those markets, even through public retry. They must reach VOID via failure/timeout: bonds and bets return, but any spent jury fee does not. Coordinate rotations with the protocol while old markets finish, and display this risk for live markets; accepting the new signer for old markets would change their agreed trust.
4. If the protocol moves, the owner may set a published v2 Intake with `setIntake`, a right-padded published action with `setAction`, and the published asset/price together with `setPayment`. Obtain these values from the protocol deployment/configuration announcements and verify live code and `priceOf`. Each setter stages a complete `pendingOracleConfig` and restarts a shared **48-hour** delay. Additional setters edit that pending configuration, preserving its other fields. At or after `configActivateAfter`, anyone calls `activateOracleConfig()` to apply all four fields together; elapsed time alone does not activate them. The owner can discard the entire pending change with `cancelOracleConfigChange()`. `OracleConfigScheduled` exposes all proposed values and the deadline; the existing `IntakeSet`, `ActionSet` and `PaymentSet` events now signal activation. These changes affect only markets created after activation. A new action must still accept the supported bool/panel JSON and canonical attestation. Version 1, native-coin payment and cross-chain delivery are intentionally unsupported for this v2/Ethereum workflow.

There are no settlement operators with special powers. Anyone can request resolution, activate a matured configuration/signer change or void a timed-out market. The owner should use appropriate custody for its configuration authority and may transfer ownership through the inherited two-step process. Retain ownership while continued market creation is wanted: a published Intake price change makes `createMarket` revert until the owner schedules the matching asset/price and the 48-hour delay is activated. Renouncing ownership permanently removes the ability to adapt to a future price, Intake, action or signer change, subject to already-scheduled activations, which remain permissionless and cannot then be cancelled. Existing market refund paths remain available. Renunciation is an irreversible shutdown risk, not routine launch setup.

## Market lifecycle

`createMarket(title, oracleBody, closeTime, resolveAfter)` uses Unix seconds (`uint64`). `closeTime` must be in the future; `resolveAfter` must be at or after it. The title is nonempty, valid UTF-8, at most 200 **bytes**, without raw control characters. The creator approves and deposits **10,000 VERDICT** as a bond and the configured **0.5 IMD** as a prepaid jury fee. The fee stays escrowed until resolution is requested. Each market stores its original title/body, Intake, action, fee asset/price, signer and requested panel/quorum. The owner cannot rewrite those terms.

`betYes(id, amount)` and `betNo(id, amount)` pull VERDICT from the caller. Each bet is at least **100 VERDICT**. Repeated bets and positions on both sides are allowed; amounts accumulate per wallet. Betting is allowed only while `state == Open` and **strictly before** `closeTime`. There is no early withdrawal or cancellation.

`requestResolution(id)` is permissionless at or after `resolveAfter`, before the unrequested deadline. An empty or one-sided market becomes VOID immediately with reason `uncontested`: no Intake call, no fee spending and no deadline extension. It returns a zero request ID to mean **no oracle request exists**. The creator and bettors can then claim all deposits, including the unspent jury fee. A two-sided market approves the snapshotted Intake for exactly one price, calls `requestWithFailure` with this contract's result and failure selectors, checks that exactly the price left, and clears the approval. The Intake-generated id is stored; it is distinct from the attestation's oracle UUID. A request can be made only once. Reverts, price changes or an unavailable Intake leave the market and prepaid fee intact.

| State | Meaning and next action |
| --- | --- |
| `Open` (1) | Accept bets before `closeTime`; afterwards await `resolveAfter` and `requestResolution`. |
| `Pending` (2) | The jury fee was spent; await result, failure or the answer deadline. |
| `Yes` (3), `No` (4) | Signed final result; participants call `claim`. |
| `Void` (5) | Uncontested market, failure or timeout; participants call `claim` for refunds. |

An unrequested market may be voided at **`resolveAfter + 7 days`**, even if Intake never worked or nobody summoned the jury. An accepted two-sided oracle request sets its own deadline at **`requestedAt + 7 days`**. Requesting at the unrequested deadline is refused. Thus a two-sided request made just before that deadline can extend the total wait to just under 14 days after `resolveAfter`. Results/failures at or after the pending deadline are refused; anyone then calls `voidMarket`. A late result cannot override a final state.

Intake failures with status 1 (refusal) or 2 (no result/disagreement) mark the market VOID and record the unsigned reason/counts. Only the snapshotted Intake and the market's own pending request are accepted. No value moves inside a failure callback. A failure or delivered result is attempted once by the oracle, so timeout remains necessary.

## Oracle request body

Creators submit complete JSON bytes, which are stored and passed unchanged. The contract never concatenates title/user text into JSON. A supported example is:

```json
{"v":1,"question":"Did the precisely defined event happen by its stated deadline?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":900,"definitions":{"event":"State the objective event, timezone, deadline and evidence sources here."}}
```

The nine fields through `validForSeconds` above are required, in any order. `definitions` and `allowAmbiguous` are optional. The validator requires valid JSON/UTF-8, no duplicate keys or trailing data, chain 1, bool answers, panel evidence, panel size **5–100**, quorum **4–panelSize**, question **1–2000 Unicode code points**, `validForSeconds` **60–2,592,000**, and at most **16,384 body bytes**. Window is either hours **1–720** or uint64 `fromBlock`/`toBlock` with `toBlock >= fromBlock`. Absolute windows must also meet the oracle's confirmation policy when requested.

Top-level/window keys and enum strings use their plain unescaped spelling. Definitions allow at most 64 unique, nonempty plain ASCII keys of at most 64 characters, with UTF-8 string values of at most 512 code points. Unknown fields, `consumer` and `deliver` are refused so the creator cannot redirect the signing domain or delivery. These conservative validation limits are explicit local assumptions; oracle refusal can still occur for ambiguous wording, unavailable evidence or changing service policy, and spends a requested fee.

The frontend should build and escape this JSON rather than interpolate raw text. Treat creator text as untrusted, quote it as material to judge, neutralize quotation delimiters in that quoted text, and make event definitions precise. Titles and oracle questions are independent; validation does not establish that they mean the same thing. On both the market page and the bet confirmation, render the decoded `oracleBody.question` verbatim with its definitions/window and the title as a separate label. Do not let a title substitute for the question the jury will answer. Retrieve these fields from `getMarket(id)`, not creator-supplied frontend metadata.

Relative hours windows resolve when the service processes the request, not at market creation, closing or `resolveAfter`. The first caller can choose when to request over the following seven days, and service processing adds further timing uncertainty. A question such as “Is ETH above 4000?” can therefore have different answers depending on who summons the jury and when. The create form must prompt for a fixed event date, timezone, observation time and evidence source in the question/definitions, or a confirmed absolute block window. Show that observation time on the bet confirmation; do not describe `resolveAfter` as fixing a relative evidence window. Panel size 5/quorum 4/window 24h remains the approved default form, suitable only when the question itself fixes the event being judged.

## Attestation authentication and fallback

Tribunal uses the exact 15-field canonical struct and the domain **IdentityMD Oracle / 2 / current chain id / this Tribunal address**. An accepted result must be from the market's Intake and its pending request, have a valid snapshotted signer signature, bool encoding of exactly 32 bytes, question chain 1, nonzero oracle UUID/question hash, issuance at or after the ask, an unexpired consistent validity window, panel/quorum at least the market requested, and `quorum <= agreed <= panelSize`. The canonical five-minute tolerance for a signer clock ahead is retained. The oracle UUID is consumed globally once, and the market can settle only once. A signed NO answer is a final result, not a revert.

**A public signature alone cannot authenticate which Intake request was answered.** The callback id and the signed UUID intentionally differ; relative windows also prevent pinning the question hash beforehand. The authenticated `onOracleResult` therefore records the attestation digest for that market, then attempts settlement through a bounded 120,000 gas self-call. The result callback performs no token transfers and fits the total 200,000 gas stipend with an EOA signer, including cold storage. `AttestationDeferred` means verification did not finish or the supplied payload/signature was invalid; the market remains Pending.

`submitAttestation(id, a, signature)` is a permissionless retry, outside the stipend, of that **already-bound digest**. It checks the same signature, freshness, panel, type and replay conditions. Anyone can retrieve the attestation/signature from the oracle completion transaction's callback arguments and retry while the attestation remains valid and the market has not timed out. A correctly signed unrelated question cannot be attached to an arbitrary pending market through public retry. This binding still relies on the snapshotted Intake correctly pairing the callback payload with the original request.

This fallback deliberately does **not** rescue a callback that never arrived or reverted before recording its binding. That case reaches the seven-day VOID/refund path. Invalid metadata cannot be replaced through public retry, nor can an expired attestation be refreshed; those markets also time out. This is the secure interpretation of the workflow's public fallback under the supplied protocol. An ERC-1271 signer requiring more gas may defer and use public retry; a mutable signer registry also carries the registry's own key-management trust.

## Payouts and accounting

For a two-sided YES/NO result, each winning wallet receives its winning stake plus its pro-rata share of the losing pool after fees. **The 2% settlement charge applies to the losing pool**, not the entire pool or creator bond. Each fee is `floor(losingPool / 100)` minor units: 1% to the creator and 1% to `0x000000000000000000000000000000000000dEaD`, the burn sink explicitly requested in the workflow. Tokens sent there remain part of ERC-20 total supply.

For winning pool `W`, losing pool `L`, wallet winning stake `s`, and fee `f = floor(L / 100)`, a normal winning claim is `s + floor((L - 2f) * s / W)`. The last winning wallet receives the residual profit instead, so no rounding dust remains once all participants claim. This can give the final winning wallet a few additional minor units. Computation uses full-precision `Math.mulDiv`; no iteration over bettors is needed.

Example: YES stakes 100 and 300, NO stake 1,000 VERDICT. YES winning payouts are 345 and 1,035; creator receives its 10,000 bond plus 10 fee; 10 goes to the burn sink. The loser receives zero and can still mark its claim once.

VOID and any one-sided market refund **both sides' full deposited bets**, regardless of the signed outcome. There are no creator or burn fees in those states. Every final state returns the creator's entire bond through its `claim(id)`; if the creator also bet, that same claim pays its bet entitlement and creator fee. The burn fee transfers once on the first participant/creator claim. Nonparticipants cannot claim. A zero-paying losing wallet may claim once; every repeat is rejected.

If no oracle request succeeded, the creator's claim additionally returns the unspent IMD fee. Once Intake pulls the fee for a two-sided market, it is spent and never refunded by Tribunal, including on failure or timeout. Empty and one-sided markets never spend it. Payouts are pulls, so a failed token transfer rolls back the entire claim and can be retried. Checks/effects precede transfers and all custody entry points have a reentrancy guard. `verdictLiability` and per-asset `oracleEscrow` expose outstanding accounting; unsolicited token/ETH donations cannot be swept by anyone and may remain permanently stranded.

## Assumptions and operational responsibilities

Market users trust the panel's judgment, the oracle signer and Intake writer's association of a request with its question. The signed question hash/UUID are recorded in resolution events; there is no claim that onchain code independently establishes the truth of a real-world event. A five-seat jury is suited to moderate stakes; this system is not a liquidation or leveraged-margin price oracle.

The owner chooses the locked VERDICT address and future protocol settings. It cannot redirect existing bonds/bets, alter existing question bodies, change their snapshotted signer/Intake/payment settings or set an outcome through an admin call. It can choose trust dependencies for future markets after a public 48-hour schedule. The delay provides notice; it does not make a replacement trustworthy. A malicious Intake can mispair a valid signed answer, issue an unsigned failure, or retain a requested fee for markets that selected it. Before betting, users/frontends must check `getMarket(id).oracle.intake`, the signer and other stored terms against the published protocol addresses. Monitor pending changes before creating a market; once an announced change matures, activation may precede creation in the same block. Snapshots intentionally mean a compromised old signer cannot be revoked for existing markets; those remain subject to its signatures and the timeout path. Configuration authority does not remove oracle trust.

VERDICT must be the delivered plain LaunchToken, and the payment asset must be the published non-rebasing IMD token. Deposits and jury spending check exact balance changes and reject transfer taxes; SafeERC20 handles absent/false returns. They do not make an arbitrary malicious or rebasing configured token safe. The owner must verify the actual launch token before locking it. Contracts have no administrative rescue or upgrade path.

Keepers/frontends should monitor `ResolutionRequested`, bound/deferred attestations, final-state events, configuration/signer schedules and deadlines; make permissionless maintenance calls; and let each user claim. No offchain keeper is required for authorization or accounting, but a transaction is still needed for asking, timeout and claims. Render a closed market from `closeTime` even while its enum remains Open, expose the original terms and signer address, and use deployment-handoff addresses with Etherscan links rather than guessed addresses. The frontend/pool integration uses the exact deployed pool key from the handoff.

Local adversarial checks, fuzzing and invariants are not an independent security audit. The separate contributor review must inspect accepted source, payout/refund logic, oracle/fallback assumptions and every privileged manifest argument before release. Slither/Mythril were not run. The services then publish/attest/admit/deploy; those later outcomes are not prerequisites to this source assignment.
