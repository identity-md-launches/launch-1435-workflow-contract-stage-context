// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./IIntake.sol";
import {OracleBody} from "./OracleBody.sol";

/// @title The Tribunal — prediction markets judged by the IMD oracle
/// @notice Oracle configuration is snapshotted at creation. No administrator can withdraw custody.
contract Tribunal is OracleAttestationConsumer, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CREATOR_BOND = 10_000 ether;
    uint256 public constant MIN_BET = 100 ether;
    uint64 public constant ANSWER_TIMEOUT = 7 days;
    uint64 public constant SIGNER_DELAY = 48 hours;
    uint64 public constant CONFIG_DELAY = 48 hours;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant FINALIZE_GAS = 120_000;

    enum State {
        None,
        Open,
        Pending,
        Yes,
        No,
        Void
    }

    struct OracleConfig {
        address intake;
        address asset;
        bytes32 action;
        uint256 price;
    }

    struct Market {
        address creator;
        State state;
        uint64 closeTime;
        uint64 resolveAfter;
        uint64 requestedAt;
        uint64 deadline;
        uint16 panelSize;
        uint16 quorum;
        bool oracleSpent;
        bool burnPaid;
        address signer;
        OracleConfig oracle;
        bytes32 requestId;
        bytes32 boundDigest;
        bytes32 failureReason;
        uint256 yesPool;
        uint256 noPool;
        uint256 claimedWinnerStake;
        uint256 paidProfit;
        string title;
        bytes oracleBody;
    }

    struct Position {
        uint256 yes;
        uint256 no;
        bool claimed;
    }

    error NotConfigured();
    error InvalidConfiguration();
    error TokenAlreadySet();
    error InvalidTimes();
    error UnknownMarket();
    error WrongState();
    error BettingClosed();
    error BetTooSmall();
    error TooEarly();
    error DeadlinePassed();
    error NotTheIntake();
    error UnknownRequest();
    error InvalidRequestId();
    error InvalidFailureStatus();
    error PanelTooWeak();
    error InvalidAttestation();
    error UnboundAttestation();
    error OnlySelf();
    error AlreadyClaimed();
    error NoPosition();
    error UnexpectedTokenAmount();
    error SignerDelayPending();
    error NoPendingSigner();
    error ConfigDelayPending();
    error NoPendingConfig();

    event VerdictTokenSet(address indexed token);
    event IntakeSet(address indexed intake);
    event ActionSet(bytes32 indexed action);
    event PaymentSet(address indexed asset, uint256 price);
    event OracleConfigScheduled(
        address indexed intake, address indexed asset, bytes32 action, uint256 price, uint64 activateAfter
    );
    event OracleConfigScheduleCancelled();
    event SignerScheduled(address indexed signer, uint64 activateAfter);
    event SignerScheduleCancelled(address indexed signer);
    event MarketCreated(
        uint256 indexed id,
        address indexed creator,
        string title,
        bytes32 bodyHash,
        uint64 closeTime,
        uint64 resolveAfter,
        uint16 panelSize,
        uint16 quorum
    );
    event BetPlaced(uint256 indexed id, address indexed bettor, bool yes, uint256 amount);
    event ResolutionRequested(uint256 indexed id, bytes32 indexed requestId, uint64 deadline);
    event AttestationBound(uint256 indexed id, bytes32 indexed requestId, bytes32 digest);
    event AttestationDeferred(uint256 indexed id);
    event MarketResolved(uint256 indexed id, State outcome, bytes32 indexed oracleRequestId, bytes32 questionHash);
    event MarketVoided(uint256 indexed id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event Claimed(uint256 indexed id, address indexed account, uint256 verdictAmount, uint256 oracleRefund);
    event LosingPoolBurned(uint256 indexed id, uint256 amount);

    IERC20 public verdictToken;
    OracleConfig public oracleConfig;
    OracleConfig public pendingOracleConfig;
    uint64 public configActivateAfter;
    address public pendingSigner;
    uint64 public signerActivateAfter;
    uint256 public marketCount;
    uint256 public verdictLiability;
    mapping(address asset => uint256 amount) public oracleEscrow;
    mapping(uint256 id => Market) private _markets;
    mapping(uint256 id => mapping(address account => Position)) public positions;
    // Indexed by intake as well as id, so a replacement intake cannot collide with an old id.
    mapping(address intake => mapping(bytes32 requestId => uint256 id)) public requestMarket;

    /// @dev No calls to outside contracts: factory construction also works on an empty chain.
    constructor(address owner_, address intake_, address asset_, bytes32 action_, uint256 price_, address signer_)
        OracleAttestationConsumer(signer_)
        Ownable(owner_)
    {
        _validateConfig(intake_, asset_, action_, price_);
        oracleConfig = OracleConfig(intake_, asset_, action_, price_);
    }

    /// @notice The owner sets the actual LaunchToken once, after the factory deployment.
    function setVerdictToken(address token) external onlyOwner nonReentrant {
        if (address(verdictToken) != address(0)) revert TokenAlreadySet();
        if (token == address(0) || token.code.length == 0) revert InvalidConfiguration();
        verdictToken = IERC20(token);
        emit VerdictTokenSet(token);
    }

    /// @notice Schedules an Intake for future markets, subject to a fresh 48-hour delay.
    /// @dev Each setter edits the pending configuration, or the active one if no schedule exists.
    function setIntake(address intake_) external onlyOwner {
        if (intake_ == address(0)) revert InvalidConfiguration();
        OracleConfig memory config = _configToSchedule();
        config.intake = intake_;
        _scheduleConfig(config);
    }

    /// @notice Edits the pending action and restarts the delay for the entire configuration.
    function setAction(bytes32 action_) external onlyOwner {
        if (action_ == bytes32(0)) revert InvalidConfiguration();
        OracleConfig memory config = _configToSchedule();
        config.action = action_;
        _scheduleConfig(config);
    }

    /// @notice Edits the pending asset/price together and restarts the configuration delay.
    function setPayment(address asset_, uint256 price_) external onlyOwner {
        if (asset_ == address(0) || price_ == 0) revert InvalidConfiguration();
        OracleConfig memory config = _configToSchedule();
        config.asset = asset_;
        config.price = price_;
        _scheduleConfig(config);
    }

    function cancelOracleConfigChange() external onlyOwner {
        if (configActivateAfter == 0) revert NoPendingConfig();
        delete pendingOracleConfig;
        delete configActivateAfter;
        emit OracleConfigScheduleCancelled();
    }

    /// @notice Anyone may activate the complete matured configuration. Existing markets keep theirs.
    function activateOracleConfig() external {
        if (configActivateAfter == 0) revert NoPendingConfig();
        if (block.timestamp < configActivateAfter) revert ConfigDelayPending();
        OracleConfig memory config = pendingOracleConfig;
        delete pendingOracleConfig;
        delete configActivateAfter;
        oracleConfig = config;
        emit IntakeSet(config.intake);
        emit ActionSet(config.action);
        emit PaymentSet(config.asset, config.price);
    }

    function _configToSchedule() private view returns (OracleConfig memory) {
        return configActivateAfter == 0 ? oracleConfig : pendingOracleConfig;
    }

    function _scheduleConfig(OracleConfig memory config) private {
        pendingOracleConfig = config;
        configActivateAfter = uint64(block.timestamp + CONFIG_DELAY);
        emit OracleConfigScheduled(config.intake, config.asset, config.action, config.price, configActivateAfter);
    }

    /// @notice Schedules a signer for future markets; replacing a schedule restarts the delay.
    function setOracleSigner(address signer_) external onlyOwner {
        if (signer_ == address(0)) revert ZeroSigner();
        pendingSigner = signer_;
        signerActivateAfter = uint64(block.timestamp + SIGNER_DELAY);
        emit SignerScheduled(signer_, signerActivateAfter);
    }

    function cancelSignerChange() external onlyOwner {
        if (pendingSigner == address(0)) revert NoPendingSigner();
        emit SignerScheduleCancelled(pendingSigner);
        delete pendingSigner;
        delete signerActivateAfter;
    }

    /// @notice Anyone may activate a matured schedule. Existing markets retain their signer.
    function activateOracleSigner() external {
        if (pendingSigner == address(0)) revert NoPendingSigner();
        if (block.timestamp < signerActivateAfter) revert SignerDelayPending();
        address signer_ = pendingSigner;
        delete pendingSigner;
        delete signerActivateAfter;
        _setOracleSigner(signer_);
    }

    function createMarket(string calldata title, bytes calldata oracleBody, uint64 closeTime, uint64 resolveAfter)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (address(verdictToken) == address(0)) revert NotConfigured();
        if (
            closeTime <= block.timestamp || resolveAfter < closeTime
                || resolveAfter > type(uint64).max - 2 * ANSWER_TIMEOUT
        ) {
            revert InvalidTimes();
        }
        OracleBody.validateTitle(title);
        (uint16 panel, uint16 quorum) = OracleBody.validate(oracleBody);
        OracleConfig memory config = oracleConfig;
        if (config.intake.code.length == 0 || config.asset.code.length == 0) revert NotConfigured();
        // Refuse new markets at an obsolete price rather than accepting an unfunded jury.
        if (IIntake(config.intake).priceOf(config.action, config.asset) != config.price) revert InvalidConfiguration();

        id = ++marketCount;
        Market storage m = _markets[id];
        m.creator = msg.sender;
        m.state = State.Open;
        m.closeTime = closeTime;
        m.resolveAfter = resolveAfter;
        m.deadline = resolveAfter + ANSWER_TIMEOUT;
        m.panelSize = panel;
        m.quorum = quorum;
        m.signer = oracleSigner;
        m.oracle = config;
        m.title = title;
        m.oracleBody = oracleBody;
        verdictLiability += CREATOR_BOND;
        oracleEscrow[config.asset] += config.price;
        _pullExact(verdictToken, msg.sender, CREATOR_BOND);
        _pullExact(IERC20(config.asset), msg.sender, config.price);
        emit MarketCreated(id, msg.sender, title, keccak256(oracleBody), closeTime, resolveAfter, panel, quorum);
    }

    function betYes(uint256 id, uint256 amount) external nonReentrant {
        _bet(id, amount, true);
    }

    function betNo(uint256 id, uint256 amount) external nonReentrant {
        _bet(id, amount, false);
    }

    function _bet(uint256 id, uint256 amount, bool yes) private {
        Market storage m = _market(id);
        if (m.state != State.Open) revert WrongState();
        if (block.timestamp >= m.closeTime) revert BettingClosed();
        if (amount < MIN_BET) revert BetTooSmall();
        Position storage p = positions[id][msg.sender];
        if (yes) {
            p.yes += amount;
            m.yesPool += amount;
        } else {
            p.no += amount;
            m.noPool += amount;
        }
        verdictLiability += amount;
        _pullExact(verdictToken, msg.sender, amount);
        emit BetPlaced(id, msg.sender, yes, amount);
    }

    /// @notice Uncontested markets become VOID for full refunds without spending the oracle fee.
    /// A contested market spends its prepaid fee here; a reverting Intake call leaves it escrowed.
    function requestResolution(uint256 id) external nonReentrant returns (bytes32 requestId) {
        Market storage m = _market(id);
        if (m.state != State.Open) revert WrongState();
        if (block.timestamp < m.resolveAfter) revert TooEarly();
        if (block.timestamp >= m.deadline) revert DeadlinePassed();
        if (m.yesPool == 0 || m.noPool == 0) {
            m.state = State.Void;
            m.failureReason = bytes32("uncontested");
            emit MarketVoided(id, 0, m.failureReason, 0, 0);
            return bytes32(0);
        }
        OracleConfig memory config = m.oracle;
        m.state = State.Pending;
        m.requestedAt = uint64(block.timestamp);
        m.deadline = uint64(block.timestamp + ANSWER_TIMEOUT);
        m.oracleSpent = true;
        oracleEscrow[config.asset] -= config.price;
        IERC20(config.asset).forceApprove(config.intake, config.price);
        uint256 beforeBalance = IERC20(config.asset).balanceOf(address(this));
        requestId = IIntake(config.intake)
            .requestWithFailure(
                config.action,
                m.oracleBody,
                IIntake.Callback(address(this), this.onOracleResult.selector),
                this.onOracleFailure.selector,
                config.asset,
                config.price
            );
        IERC20(config.asset).forceApprove(config.intake, 0);
        if (IERC20(config.asset).balanceOf(address(this)) != beforeBalance - config.price) {
            revert UnexpectedTokenAmount();
        }
        if (requestId == bytes32(0) || requestMarket[config.intake][requestId] != 0) revert InvalidRequestId();
        m.requestId = requestId;
        requestMarket[config.intake][requestId] = id;
        emit ResolutionRequested(id, requestId, m.deadline);
    }

    /// @notice Authenticates the pairing, then attempts verification/settlement under a bounded gas budget.
    /// @dev If verification cannot finish, retain the authenticated digest for submitAttestation.
    /// No ERC-20 calls occur in either the callback or its self-call.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 id = requestMarket[msg.sender][requestId];
        if (id == 0) revert NotTheIntake();
        Market storage m = _pending(id, requestId);
        if (msg.sender != m.oracle.intake) revert NotTheIntake();
        m.boundDigest = attestationDigest(a);
        emit AttestationBound(id, requestId, m.boundDigest);
        try this.finalizeOracleResult{gas: FINALIZE_GAS}(id, a, signature) {}
        catch {
            emit AttestationDeferred(id);
        }
    }

    /// @dev Only the authenticated callback may use this unguarded self-call. Its caller holds the guard.
    function finalizeOracleResult(uint256 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        if (msg.sender != address(this)) revert OnlySelf();
        _acceptResult(id, a, signature);
    }

    /// @notice Public retry of a payload bound by the Intake callback, with the same settlement checks.
    /// @dev An arbitrary signature for this consumer is not proof of a question this market asked.
    function submitAttestation(uint256 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Market storage m = _market(id);
        if (m.boundDigest == bytes32(0) || m.boundDigest != attestationDigest(a)) revert UnboundAttestation();
        _acceptResult(id, a, signature);
    }

    function _acceptResult(uint256 id, OracleAttestation.Attestation calldata a, bytes calldata signature) private {
        Market storage m = _market(id);
        _pending(id, m.requestId);
        if (
            a.panelSize < m.panelSize || a.quorum < m.quorum || a.quorum > a.panelSize || a.agreed < a.quorum
                || a.agreed > a.panelSize
        ) revert PanelTooWeak();
        if (
            a.chainId != 1 || a.requestId == bytes32(0) || a.questionHash == bytes32(0) || a.issuedAt < m.requestedAt
                || a.expiresAt < a.issuedAt || a.answer.length != 32
        ) revert InvalidAttestation();
        _verifyMarketAttestation(m.signer, a, signature);
        bool yes = decodeBool(a);
        _consume(a.requestId);
        m.state = yes ? State.Yes : State.No;
        emit MarketResolved(id, m.state, a.requestId, a.questionHash);
    }

    /// @dev Keep the canonical consumer unchanged. A market created under an earlier signer still
    /// uses its snapshot, with the identical canonical time checks, digest, and SignatureChecker.
    function _verifyMarketAttestation(
        address signer,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) private view {
        if (signer == oracleSigner) {
            _verifyAttestation(a, signature);
        } else {
            if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt);
            if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE) revert AttestationNotYetValid(a.issuedAt);
            if (!SignatureChecker.isValidSignatureNowCalldata(signer, attestationDigest(a), signature)) {
                revert BadSignature();
            }
        }
    }

    /// @notice Unsigned failure data can only void this contract's own pending request.
    function onOracleFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes calldata
    ) external nonReentrant {
        uint256 id = requestMarket[msg.sender][requestId];
        if (id == 0) revert NotTheIntake();
        Market storage m = _pending(id, requestId);
        if (msg.sender != m.oracle.intake) revert NotTheIntake();
        if (status != 1 && status != 2) revert InvalidFailureStatus();
        m.state = State.Void;
        m.failureReason = reason;
        emit MarketVoided(id, status, reason, agreed, answered);
    }

    /// @notice No keeper or administrator is required. Also unlocks markets whose ask never succeeded.
    function voidMarket(uint256 id) external nonReentrant {
        Market storage m = _market(id);
        if (m.state != State.Open && m.state != State.Pending) revert WrongState();
        if (block.timestamp < m.deadline) revert TooEarly();
        m.state = State.Void;
        m.failureReason = bytes32("timeout");
        emit MarketVoided(id, 0, m.failureReason, 0, 0);
    }

    /// @notice Claims bets and, for the creator, the bond and creator fee in one transaction.
    function claim(uint256 id) external nonReentrant returns (uint256 payout) {
        Market storage m = _market(id);
        if (!_final(m.state)) revert WrongState();
        Position storage p = positions[id][msg.sender];
        if (p.claimed) revert AlreadyClaimed();
        if (p.yes == 0 && p.no == 0 && msg.sender != m.creator) revert NoPosition();
        p.claimed = true;
        bool refund = m.state == State.Void || m.yesPool == 0 || m.noPool == 0;
        uint256 fee;
        if (refund) {
            payout = p.yes + p.no;
        } else {
            uint256 winningPool = m.state == State.Yes ? m.yesPool : m.noPool;
            uint256 losingPool = m.state == State.Yes ? m.noPool : m.yesPool;
            uint256 stake = m.state == State.Yes ? p.yes : p.no;
            fee = losingPool / 100;
            uint256 profit = losingPool - 2 * fee;
            if (stake != 0) {
                // Fixed pro-rata floors; the last winning wallet receives the remaining minor units.
                uint256 share = stake == winningPool - m.claimedWinnerStake
                    ? profit - m.paidProfit
                    : Math.mulDiv(profit, stake, winningPool);
                m.claimedWinnerStake += stake;
                m.paidProfit += share;
                payout = stake + share;
            }
        }
        uint256 oracleRefund;
        if (msg.sender == m.creator) {
            payout += CREATOR_BOND + fee;
            if (!m.oracleSpent) {
                oracleRefund = m.oracle.price;
                oracleEscrow[m.oracle.asset] -= oracleRefund;
            }
        }
        uint256 burn;
        if (!m.burnPaid) {
            m.burnPaid = true;
            burn = fee;
        }
        verdictLiability -= payout + burn;
        if (burn != 0) {
            verdictToken.safeTransfer(BURN_ADDRESS, burn);
            emit LosingPoolBurned(id, burn);
        }
        if (payout != 0) verdictToken.safeTransfer(msg.sender, payout);
        if (oracleRefund != 0) IERC20(m.oracle.asset).safeTransfer(msg.sender, oracleRefund);
        emit Claimed(id, msg.sender, payout, oracleRefund);
    }

    function getMarket(uint256 id) external view returns (Market memory) {
        return _market(id);
    }

    function _pending(uint256 id, bytes32 requestId) private view returns (Market storage m) {
        m = _market(id);
        if (m.state != State.Pending || m.requestId != requestId) revert UnknownRequest();
        if (block.timestamp >= m.deadline) revert DeadlinePassed();
    }

    function _market(uint256 id) private view returns (Market storage m) {
        m = _markets[id];
        if (m.state == State.None) revert UnknownMarket();
    }

    function _final(State state) private pure returns (bool) {
        return state == State.Yes || state == State.No || state == State.Void;
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedTokenAmount();
    }

    function _validateConfig(address intake_, address asset_, bytes32 action_, uint256 price_) private pure {
        if (intake_ == address(0) || asset_ == address(0) || action_ == bytes32(0) || price_ == 0) {
            revert InvalidConfiguration();
        }
    }
}
