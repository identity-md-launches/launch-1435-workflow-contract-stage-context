// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Tribunal} from "src/Tribunal.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MockToken, MockIntake} from "./helpers/Mocks.sol";

/// @dev Ghosts come from submitted inputs and observed transfers, not Tribunal's liability counters.
/// Invalid lifecycle calls must return the specific error; valid calls may not silently revert.
contract TribunalAccountingHandler is Test {
    uint256 internal constant BOND = 10_000 ether;
    uint256 internal constant MINIMUM = 100 ether;
    uint256 internal constant PRICE = 0.5 ether;
    uint256 internal constant SIGNER_KEY = 0x713b;
    bytes internal constant BODY =
        '{"v":1,"question":"Did the specified event occur?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":900}';

    struct GhostMarket {
        address creator;
        Tribunal.State state;
        uint256 yes;
        uint256 no;
        uint256 paid;
        uint256 burned;
        bool spent;
        bool refunded;
    }

    struct GhostPosition {
        uint256 yes;
        uint256 no;
        bool claimed;
    }

    Tribunal public immutable tribunal;
    LaunchToken public immutable token;
    MockToken public immutable payment;
    MockIntake public immutable intake;
    address[4] public actors;
    mapping(uint256 => GhostMarket) internal markets;
    mapping(uint256 => mapping(address => GhostPosition)) internal positions;
    uint256 public count;
    uint256 public donations;
    uint256 public paymentDonations;
    uint256 public successfulBets;
    uint256 public successfulRequests;
    uint256 public successfulAnswers;
    uint256 public successfulClaims;

    constructor(Tribunal tribunal_, LaunchToken token_, MockToken payment_, MockIntake intake_) {
        tribunal = tribunal_;
        token = token_;
        payment = payment_;
        intake = intake_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("accounting actor ", vm.toString(i)));
            vm.startPrank(actors[i]);
            token.approve(address(tribunal), type(uint256).max);
            payment.approve(address(tribunal), type(uint256).max);
            vm.stopPrank();
        }
    }

    function create(uint256 who, uint256 duration) public {
        if (count == 12) return;
        address creator = actors[who % 4];
        uint64 close = uint64(vm.getBlockTimestamp() + bound(duration, 1 hours, 2 days));
        vm.prank(creator);
        uint256 id = tribunal.createMarket("accounting market", BODY, close, close + 1 hours);
        assertEq(id, ++count, "successful creation must allocate exactly one id");
        markets[id].creator = creator;
        markets[id].state = Tribunal.State.Open;
    }

    function bet(uint256 seed, uint256 who, uint256 amount, bool yes) public {
        uint256 id = _id(seed);
        address actor = actors[who % 4];
        amount = bound(amount, MINIMUM, 100_000 ether);
        Tribunal.Market memory m = tribunal.getMarket(id);
        if (markets[id].state != Tribunal.State.Open) vm.expectRevert(Tribunal.WrongState.selector);
        else if (vm.getBlockTimestamp() >= m.closeTime) vm.expectRevert(Tribunal.BettingClosed.selector);
        vm.prank(actor);
        if (yes) tribunal.betYes(id, amount);
        else tribunal.betNo(id, amount);
        if (markets[id].state != Tribunal.State.Open || vm.getBlockTimestamp() >= m.closeTime) return;
        if (yes) {
            markets[id].yes += amount;
            positions[id][actor].yes += amount;
        } else {
            markets[id].no += amount;
            positions[id][actor].no += amount;
        }
        ++successfulBets;
    }

    function advance(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 1 days));
    }

    function ask(uint256 seed) public {
        uint256 id = _id(seed);
        Tribunal.Market memory m = tribunal.getMarket(id);
        bool valid = markets[id].state == Tribunal.State.Open && vm.getBlockTimestamp() >= m.resolveAfter
            && vm.getBlockTimestamp() < m.deadline;
        if (markets[id].state != Tribunal.State.Open) vm.expectRevert(Tribunal.WrongState.selector);
        else if (vm.getBlockTimestamp() < m.resolveAfter) vm.expectRevert(Tribunal.TooEarly.selector);
        else if (vm.getBlockTimestamp() >= m.deadline) vm.expectRevert(Tribunal.DeadlinePassed.selector);
        tribunal.requestResolution(id);
        if (valid) {
            markets[id].state = Tribunal.State.Pending;
            markets[id].spent = true;
            ++successfulRequests;
        }
    }

    /// @dev Time advances only forward, and calls the real callback through the 200k mock stipend.
    function answer(uint256 seed, bool yes, bool failure) public {
        uint256 id = _id(seed);
        Tribunal.Market memory m = tribunal.getMarket(id);
        if (markets[id].state != Tribunal.State.Pending || intake.getAsk(m.requestId).completed) return;
        bool timely = vm.getBlockTimestamp() < m.deadline;
        bool called;
        if (failure) {
            called = intake.deliverFailure(m.requestId, 2, bytes32("disagreed"), 3, 5);
        } else {
            OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
                requestId: keccak256(abi.encode("accounting oracle UUID", id)),
                chainId: 1,
                questionHash: keccak256(abi.encode("accounting question", id)),
                answerType: 0,
                answer: abi.encode(yes),
                figure: 0,
                fromBlock: 100,
                toBlock: 200,
                blockHash: keccak256("block"),
                panelJobId: keccak256(abi.encode("panel", id)),
                panelSize: 5,
                quorum: 4,
                agreed: 4,
                issuedAt: uint64(vm.getBlockTimestamp()),
                expiresAt: uint64(vm.getBlockTimestamp() + 900)
            });
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, tribunal.attestationDigest(a));
            called = intake.deliverResult(m.requestId, a, abi.encodePacked(r, s, v));
            assertEq(tribunal.consumed(a.requestId), timely, "only timely answers may be consumed");
        }
        assertEq(called, timely, "callback must finish under its stipend before the deadline");
        if (timely) {
            markets[id].state = failure ? Tribunal.State.Void : (yes ? Tribunal.State.Yes : Tribunal.State.No);
            ++successfulAnswers;
        }
    }

    function timeout(uint256 seed) public {
        uint256 id = _id(seed);
        Tribunal.Market memory m = tribunal.getMarket(id);
        bool open = markets[id].state == Tribunal.State.Open || markets[id].state == Tribunal.State.Pending;
        if (!open) vm.expectRevert(Tribunal.WrongState.selector);
        else if (vm.getBlockTimestamp() < m.deadline) vm.expectRevert(Tribunal.TooEarly.selector);
        tribunal.voidMarket(id);
        if (open && vm.getBlockTimestamp() >= m.deadline) markets[id].state = Tribunal.State.Void;
    }

    function claim(uint256 seed, uint256 who) public {
        uint256 id = _id(seed);
        address actor = actors[who % 4];
        GhostMarket storage m = markets[id];
        GhostPosition storage p = positions[id][actor];
        bool finalState =
            m.state == Tribunal.State.Yes || m.state == Tribunal.State.No || m.state == Tribunal.State.Void;
        bool eligible = actor == m.creator || p.yes != 0 || p.no != 0;
        uint256 beforeToken = token.balanceOf(actor);
        uint256 beforePayment = payment.balanceOf(actor);
        uint256 beforeBurn = token.balanceOf(tribunal.BURN_ADDRESS());
        if (!finalState) vm.expectRevert(Tribunal.WrongState.selector);
        else if (p.claimed) vm.expectRevert(Tribunal.AlreadyClaimed.selector);
        else if (!eligible) vm.expectRevert(Tribunal.NoPosition.selector);
        vm.prank(actor);
        uint256 reported = tribunal.claim(id);
        if (!finalState || p.claimed || !eligible) return;
        uint256 received = token.balanceOf(actor) - beforeToken;
        assertEq(reported, received, "claim return value must equal tokens received");
        bool refund = m.state == Tribunal.State.Void || m.yes == 0 || m.no == 0;
        uint256 loserPool = m.state == Tribunal.State.Yes ? m.no : m.yes;
        uint256 fee = refund ? 0 : loserPool / 100;
        uint256 entitlement = actor == m.creator ? BOND + fee : 0;
        uint256 roundingSlack;
        if (refund) {
            entitlement += p.yes + p.no;
        } else {
            uint256 winnerStake = m.state == Tribunal.State.Yes ? p.yes : p.no;
            uint256 winnerPool = m.state == Tribunal.State.Yes ? m.yes : m.no;
            entitlement += winnerStake + (loserPool - 2 * fee) * winnerStake / winnerPool;
            // At most four winning wallets: at most three earlier fractional wei can remain.
            if (winnerStake != 0) roundingSlack = 3;
        }
        assertGe(received, entitlement, "claimant received less than its pro-rata floor");
        assertLe(received, entitlement + roundingSlack, "claimant extracted another wallet's stake");
        uint256 refundPayment = actor == m.creator && !m.spent ? PRICE : 0;
        assertEq(payment.balanceOf(actor) - beforePayment, refundPayment, "incorrect prepaid fee refund");
        m.paid += received;
        m.burned += token.balanceOf(tribunal.BURN_ADDRESS()) - beforeBurn;
        assertEq(m.burned, fee, "burn must occur once, including when a losing wallet claims first");
        if (refundPayment != 0) m.refunded = true;
        p.claimed = true;
        ++successfulClaims;
    }

    function donate(uint256 who, uint256 amount, bool oracleAsset) public {
        address actor = actors[who % 4];
        amount = bound(amount, 0, oracleAsset ? 0.1 ether : 1_000 ether);
        vm.prank(actor);
        if (oracleAsset) {
            payment.transfer(address(tribunal), amount);
            paymentDonations += amount;
        } else {
            token.transfer(address(tribunal), amount);
            donations += amount;
        }
    }

    /// @dev Runs after every random sequence. Every outstanding claim must remain executable.
    function finishAndClaimAll() external {
        uint256 latest = vm.getBlockTimestamp();
        for (uint256 id = 1; id <= count; ++id) {
            uint256 deadline = tribunal.getMarket(id).deadline;
            if (deadline > latest) latest = deadline;
        }
        vm.warp(latest);
        for (uint256 id = 1; id <= count; ++id) {
            if (markets[id].state == Tribunal.State.Open || markets[id].state == Tribunal.State.Pending) {
                timeout(id - 1);
            }
            for (uint256 i; i < 4; ++i) {
                GhostPosition memory p = positions[id][actors[i]];
                if (!p.claimed && (p.yes != 0 || p.no != 0 || actors[i] == markets[id].creator)) claim(id - 1, i);
            }
        }
        assertAccounting();
        assertEq(tribunal.verdictLiability(), 0, "a random sequence stranded VERDICT");
        assertEq(tribunal.oracleEscrow(address(payment)), 0, "a random sequence stranded prepaid fees");
        assertEq(token.balanceOf(address(tribunal)), donations);
        assertEq(payment.balanceOf(address(tribunal)), paymentDonations);
    }

    function assertAccounting() public view {
        uint256 outstanding;
        uint256 escrow;
        uint256 spent;
        uint256 burned;
        assertEq(tribunal.marketCount(), count);
        for (uint256 id = 1; id <= count; ++id) {
            GhostMarket memory g = markets[id];
            Tribunal.Market memory m = tribunal.getMarket(id);
            assertEq(uint256(m.state), uint256(g.state), "unexpected transition or reopened final market");
            assertEq(m.creator, g.creator);
            assertEq(m.yesPool, g.yes);
            assertEq(m.noPool, g.no);
            assertEq(m.oracleSpent, g.spent);
            uint256 yes;
            uint256 no;
            for (uint256 i; i < 4; ++i) {
                GhostPosition memory p = positions[id][actors[i]];
                (uint256 actualYes, uint256 actualNo, bool claimed) = tribunal.positions(id, actors[i]);
                assertEq(actualYes, p.yes);
                assertEq(actualNo, p.no);
                assertEq(claimed, p.claimed);
                yes += actualYes;
                no += actualNo;
            }
            assertEq(yes, g.yes, "YES pool differs from individual stakes");
            assertEq(no, g.no, "NO pool differs from individual stakes");
            outstanding += BOND + g.yes + g.no - g.paid - g.burned;
            if (!g.spent && !g.refunded) escrow += PRICE;
            if (g.spent) spent += PRICE;
            burned += g.burned;
        }
        assertEq(tribunal.verdictLiability(), outstanding, "liability differs from independent deposits less payments");
        assertEq(token.balanceOf(address(tribunal)), outstanding + donations);
        assertEq(token.balanceOf(tribunal.BURN_ADDRESS()), burned);
        assertEq(tribunal.oracleEscrow(address(payment)), escrow);
        assertEq(payment.balanceOf(address(tribunal)), escrow + paymentDonations);
        assertEq(payment.balanceOf(address(intake)), spent);
        assertEq(payment.allowance(address(tribunal), address(intake)), 0);
    }

    function _id(uint256 seed) private view returns (uint256) {
        return seed % count + 1;
    }
}

/// @dev Fail on unexpected reverts, including assertions inside the handler; no catch-all paths.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TribunalAccountingInvariantTest is StdInvariant, Test {
    Tribunal internal tribunal;
    LaunchToken internal token;
    MockToken internal payment;
    MockIntake internal intake;
    TribunalAccountingHandler internal handler;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        token = new LaunchToken();
        payment = new MockToken();
        intake = new MockIntake();
        tribunal = new Tribunal(
            address(this),
            address(intake),
            address(payment),
            bytes32("oracle.request@oracle-1"),
            0.5 ether,
            vm.addr(0x713b)
        );
        tribunal.setVerdictToken(address(token));
        handler = new TribunalAccountingHandler(tribunal, token, payment, intake);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 200_000_000 ether);
            payment.mint(handler.actors(i), 100 ether);
        }
        // Nonempty, two-sided pools with odd minor units; one creator also holds both sides.
        handler.create(0, 1 hours);
        handler.bet(0, 0, 100 ether + 1, true);
        handler.bet(0, 0, 100 ether + 2, false);
        handler.bet(0, 1, 100 ether + 3, true);
        handler.bet(0, 2, 100 ether + 4, false);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.bet.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.ask.selector;
        selectors[4] = handler.answer.selector;
        selectors[5] = handler.timeout.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_independentCustodyAndPositionAccounting() public view {
        handler.assertAccounting();
    }

    function invariant_fixedSupplyAcrossCustodyClaimsAndBurnAddressTransfers() public view {
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(address(tribunal))
            + token.balanceOf(tribunal.BURN_ADDRESS());
        for (uint256 i; i < 4; ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(balances, 1_000_000_000 ether);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function afterInvariant() public {
        handler.finishAndClaimAll();
        invariant_fixedSupplyAcrossCustodyClaimsAndBurnAddressTransfers();
    }

    /// @dev Keeps every success branch reachable independently of the random seed.
    function test_handlerExercisesResolutionFailureTimeoutDonationsAndRepeatedClaims() public {
        handler.create(1, 1 hours);
        handler.create(2, 1 hours);
        handler.advance(2 hours);
        handler.ask(0);
        handler.answer(0, false, false);
        handler.ask(1);
        handler.answer(1, true, true);
        handler.claim(0, 1); // Loser claims first and triggers the one burn.
        handler.claim(0, 1); // Must reject even a repeated zero-value claim.
        handler.donate(0, 1, false);
        handler.donate(1, 1, true);
        assertEq(handler.successfulBets(), 4);
        assertEq(handler.successfulRequests(), 2);
        assertEq(handler.successfulAnswers(), 2);
        handler.finishAndClaimAll();
        assertGe(handler.successfulClaims(), 5);
        invariant_fixedSupplyAcrossCustodyClaimsAndBurnAddressTransfers();
    }
}
