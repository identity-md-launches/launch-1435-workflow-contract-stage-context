// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockToken, MockIntake} from "./helpers/Mocks.sol";

contract TribunalHandler is Test {
    Tribunal public tribunal;
    MockToken public verdict;
    MockToken public imd;
    MockIntake public intake;
    uint256 public depositedBets;
    uint256 public claimedVerdict;
    uint256 public refundedIMD;
    mapping(uint256 => Tribunal.State) public finalStates;
    address[3] public actors = [address(0xA1), address(0xB0B), address(0xCA)];
    uint256 private constant SIGNER_KEY = 0x713b;
    bytes private constant BODY =
        '{"v":1,"question":"Did the event happen?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":900}';

    constructor(Tribunal t, MockToken v, MockToken a, MockIntake i) {
        tribunal = t;
        verdict = v;
        imd = a;
        intake = i;
        for (uint256 n; n < actors.length; ++n) {
            v.mint(actors[n], 1_000_000 ether);
            a.mint(actors[n], 100 ether);
            vm.startPrank(actors[n]);
            v.approve(address(t), type(uint256).max);
            a.approve(address(t), type(uint256).max);
            vm.stopPrank();
        }
    }

    function create(uint256 actor) public {
        if (tribunal.marketCount() >= 4) return;
        vm.prank(actors[actor % 3]);
        tribunal.createMarket(
            "event", BODY, uint64(vm.getBlockTimestamp() + 1 hours), uint64(vm.getBlockTimestamp() + 2 hours)
        );
        _rememberFinalStates();
    }

    function bet(uint256 idSeed, uint256 actor, uint256 amount, bool yes) public {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        amount = bound(amount, 100 ether, 1000 ether);
        vm.prank(actors[actor % 3]);
        if (yes) {
            try tribunal.betYes(id, amount) {
                depositedBets += amount;
            } catch {}
        } else {
            try tribunal.betNo(id, amount) {
                depositedBets += amount;
            } catch {}
        }
        _rememberFinalStates();
    }

    function advance(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 2 days));
    }

    function ask(uint256 seed) public {
        uint256 id = _id(seed);
        if (id == 0) return;
        try tribunal.requestResolution(id) {} catch {}
        _rememberFinalStates();
    }

    function answer(uint256 seed, bool yes, bool fail) public {
        uint256 id = _id(seed);
        if (id == 0) return;
        Tribunal.Market memory m = tribunal.getMarket(id);
        if (m.state != Tribunal.State.Pending || intake.getAsk(m.requestId).completed) return;
        if (fail) {
            intake.deliverFailure(m.requestId, 2, bytes32("disagreed"), 3, 5);
        } else {
            OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
                requestId: keccak256(abi.encode("UUID", id)),
                chainId: 1,
                questionHash: keccak256("canonical question"),
                answerType: 0,
                answer: abi.encode(yes),
                figure: 0,
                fromBlock: 100,
                toBlock: 200,
                blockHash: bytes32(uint256(7)),
                panelJobId: keccak256(abi.encode("panel", id)),
                panelSize: 5,
                quorum: 4,
                agreed: 4,
                issuedAt: uint64(vm.getBlockTimestamp()),
                expiresAt: uint64(vm.getBlockTimestamp() + 900)
            });
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, tribunal.attestationDigest(a));
            intake.deliverResult(m.requestId, a, abi.encodePacked(r, s, v));
        }
        _rememberFinalStates();
    }

    function timeout(uint256 seed) public {
        uint256 id = _id(seed);
        if (id == 0) return;
        try tribunal.voidMarket(id) {} catch {}
        _rememberFinalStates();
    }

    function claim(uint256 seed, uint256 actor) public {
        uint256 id = _id(seed);
        if (id == 0) return;
        address user = actors[actor % 3];
        uint256 beforeBalance = imd.balanceOf(user);
        vm.prank(user);
        try tribunal.claim(id) returns (uint256 amount) {
            claimedVerdict += amount;
            refundedIMD += imd.balanceOf(user) - beforeBalance;
        } catch {}
        _rememberFinalStates();
    }

    function _id(uint256 seed) private view returns (uint256) {
        uint256 count = tribunal.marketCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function _rememberFinalStates() private {
        for (uint256 id = 1; id <= tribunal.marketCount(); ++id) {
            Tribunal.State state = tribunal.getMarket(id).state;
            if (finalStates[id] != Tribunal.State.None) assertEq(uint256(state), uint256(finalStates[id]));
            if (state == Tribunal.State.Yes || state == Tribunal.State.No || state == Tribunal.State.Void) {
                finalStates[id] = state;
            }
        }
    }
}

contract TribunalInvariantTest is StdInvariant, Test {
    Tribunal tribunal;
    TribunalHandler handler;
    MockToken verdict;
    MockToken imd;
    MockIntake intake;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        verdict = new MockToken();
        imd = new MockToken();
        intake = new MockIntake();
        tribunal = new Tribunal(
            address(this), address(intake), address(imd), bytes32("oracle.request@oracle-1"), 0.5 ether, vm.addr(0x713b)
        );
        tribunal.setVerdictToken(address(verdict));
        handler = new TribunalHandler(tribunal, verdict, imd, intake);
        handler.create(0);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.bet.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.ask.selector;
        selectors[4] = handler.answer.selector;
        selectors[5] = handler.timeout.selector;
        selectors[6] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_verdictCustodyEqualsLiabilitiesAndDepositsMinusClaimsAndBurn() public view {
        uint256 deposits = tribunal.marketCount() * 10_000 ether + handler.depositedBets();
        uint256 balance = verdict.balanceOf(address(tribunal));
        assertEq(balance, tribunal.verdictLiability());
        assertEq(balance + handler.claimedVerdict() + verdict.balanceOf(tribunal.BURN_ADDRESS()), deposits);
    }

    function invariant_oracleFeesAreEscrowedSpentOrRefundedExactlyOnce() public view {
        uint256 deposited = tribunal.marketCount() * 0.5 ether;
        uint256 balance = imd.balanceOf(address(tribunal));
        assertEq(balance, tribunal.oracleEscrow(address(imd)));
        assertEq(balance + imd.balanceOf(address(intake)) + handler.refundedIMD(), deposited);
        assertEq(imd.allowance(address(tribunal), address(intake)), 0);
    }

    function invariant_finalStatesDoNotChange() public view {
        for (uint256 id = 1; id <= tribunal.marketCount(); ++id) {
            Tribunal.State recorded = handler.finalStates(id);
            if (recorded != Tribunal.State.None) assertEq(uint256(tribunal.getMarket(id).state), uint256(recorded));
        }
    }
}
