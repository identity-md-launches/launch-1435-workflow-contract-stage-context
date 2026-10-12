// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "../src/Tribunal.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {TribunalFixture} from "./helpers/TribunalFixture.sol";
import {SlowSigner} from "./helpers/Mocks.sol";

contract TribunalOracleTest is TribunalFixture {
    function test_yesCallbackResolvesUnder200k() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 100 ether);
        _resolve(id, true);
        _assertSolvent();
    }

    function test_coldCallbackStateFits200kForBothOutcomes() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("cold yes"), true);
        bytes memory signature = _sign(a);
        vm.cool(address(tribunal));
        assertTrue(intake.deliverResult(rid, a, signature));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Yes));
        uint256 id2 = _createContested();
        rid = _request(id2);
        a = _attestation(keccak256("cold no"), false);
        signature = _sign(a);
        vm.cool(address(tribunal));
        assertTrue(intake.deliverResult(rid, a, signature));
        assertEq(uint256(tribunal.getMarket(id2).state), uint256(Tribunal.State.No));
    }

    function test_noAnswerIsAResultAndNoTransfersOccurAtSettlement() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 200 ether);
        bytes32 rid = _request(id);
        verdict.setReject(true);
        imd.setReject(true);
        OracleAttestation.Attestation memory a = _attestation(keccak256("no UUID"), false);
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.No));
        assertTrue(tribunal.consumed(a.requestId));
        assertEq(verdict.balanceOf(address(tribunal)), 10_300 ether);
    }

    function test_wrongCallerUnknownRequestAndOnlySelfRejected() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("UUID"), true);
        bytes memory sig = _sign(a);
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleResult(rid, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleResult(keccak256("unknown"), a, sig);
        vm.expectRevert(Tribunal.OnlySelf.selector);
        tribunal.finalizeOracleResult(id, a, sig);
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleFailure(rid, 2, bytes32("disagreed"), 3, 5, "");
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
    }

    function test_unboundPublicFallbackCannotPairAnUnrelatedSignedQuestion() public {
        uint256 id = _createContested();
        _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("attacker's UUID"), true);
        a.questionHash = keccak256("an unrelated question signed for this consumer");
        bytes memory signature = _sign(a);
        vm.expectRevert(Tribunal.UnboundAttestation.selector);
        tribunal.submitAttestation(id, a, signature);
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        assertFalse(tribunal.consumed(a.requestId));
    }

    function test_invalidSignatureDefersAndPublicFallbackRequiresValidSignatureAndBinding() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("UUID"), true);
        assertTrue(intake.deliverResult(rid, a, _signWith(0xBAD, a)));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        assertEq(tribunal.getMarket(id).boundDigest, tribunal.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(id, a, _signWith(0xBAD, a));
        OracleAttestation.Attestation memory tampered = _attestation(a.requestId, true);
        tampered.figure = 1;
        vm.expectRevert(Tribunal.UnboundAttestation.selector);
        tribunal.submitAttestation(id, tampered, _sign(tampered));
        tribunal.submitAttestation(id, a, _sign(a));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Yes));
        assertTrue(tribunal.consumed(a.requestId));
        vm.expectRevert(Tribunal.UnknownRequest.selector);
        tribunal.submitAttestation(id, a, _sign(a));
    }

    function test_expiredAndFutureAttestationsCannotSettle() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("expired"), true);
        vm.warp(vm.getBlockTimestamp() + 901);
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        tribunal.submitAttestation(id, a, _sign(a));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        uint256 id2 = _createContested();
        bytes32 rid2 = _request(id2);
        a = _attestation(keccak256("future"), true);
        a.issuedAt += 301;
        a.expiresAt += 301;
        assertTrue(intake.deliverResult(rid2, a, _sign(a)));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        tribunal.submitAttestation(id2, a, _sign(a));
    }

    function test_tamperedSignatureCannotFinalize() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("UUID"), true);
        bytes memory signature = _sign(a);
        a.answer = abi.encode(false);
        assertTrue(intake.deliverResult(rid, a, signature));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(id, a, signature);
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        assertFalse(tribunal.consumed(a.requestId));
    }

    function test_panelMinimumsMatchTheStoredRequestNotJustAgreement() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("small panel"), true);
        a.panelSize = 4;
        a.quorum = 3;
        a.agreed = 3;
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert(Tribunal.PanelTooWeak.selector);
        tribunal.submitAttestation(id, a, _sign(a));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
    }

    function test_disagreementAndImpossibleCountsAreRejected() public {
        _invalidPanel(5, 4, 3, "disagreement");
        _invalidPanel(5, 6, 6, "impossible quorum");
        _invalidPanel(5, 4, 6, "impossible agreement");
    }

    function _invalidPanel(uint16 panel, uint16 quorum, uint16 agreed, string memory salt) internal {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256(bytes(salt)), true);
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert(Tribunal.PanelTooWeak.selector);
        tribunal.submitAttestation(id, a, _sign(a));
    }

    function test_bodyWithStrongerPanelCannotBeSettledByWeakerPanel() public {
        bytes memory body =
            '{"v":1,"question":"Did the event happen?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":10,"quorum":8,"validForSeconds":900}';
        vm.prank(creator);
        uint256 id = tribunal.createMarket(
            "event", body, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 100 ether);
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("weaker"), true);
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert(Tribunal.PanelTooWeak.selector);
        tribunal.submitAttestation(id, a, _sign(a));
    }

    function test_wrongAnswerTypeAndMalformedBooleanAreRejected() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("wrong type"), true);
        a.answerType = 3;
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(0), uint8(3)));
        tribunal.submitAttestation(id, a, _sign(a));
        uint256 id2 = _createContested();
        rid = _request(id2);
        a = _attestation(keccak256("malformed bool"), true);
        a.answer = abi.encode(uint256(2));
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert();
        tribunal.submitAttestation(id2, a, _sign(a));
    }

    function test_invalidMetadataCannotSettle() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("metadata"), true);
        a.chainId = 4663;
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        vm.expectRevert(Tribunal.InvalidAttestation.selector);
        tribunal.submitAttestation(id, a, _sign(a));
    }

    function test_oracleUUIDCannotSettleTwoMarketsAndCallbackCannotReplay() public {
        uint256 id = _createContested();
        uint256 id2 = _createContested();
        bytes32 rid = _request(id);
        bytes32 rid2 = tribunal.requestResolution(id2);
        OracleAttestation.Attestation memory a = _attestation(keccak256("same UUID"), true);
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        assertTrue(intake.deliverResult(rid2, a, _sign(a)));
        assertEq(uint256(tribunal.getMarket(id2).state), uint256(Tribunal.State.Pending));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        tribunal.submitAttestation(id2, a, _sign(a));
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.UnknownRequest.selector);
        tribunal.onOracleResult(rid, a, _sign(a));
    }

    function test_signedPayloadFromOtherConsumerCannotSettle() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        Tribunal other = new Tribunal(owner, address(intake), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        OracleAttestation.Attestation memory a = _attestation(keccak256("other domain"), true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        bytes memory signature = abi.encodePacked(r, s, v);
        assertTrue(intake.deliverResult(rid, a, signature));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(id, a, signature);
    }

    function test_failureVoidsOnlyOwnPendingRequestUnder200k() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        assertTrue(intake.deliverFailure(rid, 2, bytes32("disagreed"), 3, 5));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Void));
        assertEq(tribunal.getMarket(id).failureReason, bytes32("disagreed"));
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.UnknownRequest.selector);
        tribunal.onOracleFailure(rid, 2, bytes32("disagreed"), 3, 5, "");
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleFailure(keccak256("attacker paid request"), 1, bytes32("body_invalid"), 0, 0, "");
    }

    function test_invalidFailureStatusDoesNotVoid() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        assertFalse(intake.deliverFailure(rid, 0, bytes32(0), 0, 0));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
    }

    function test_noAnswerTimesOutAtSevenDaysAndLateCallbackCannotOverrideVoid() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        uint64 deadline = tribunal.getMarket(id).deadline;
        vm.warp(deadline - 1);
        vm.expectRevert(Tribunal.TooEarly.selector);
        tribunal.voidMarket(id);
        vm.warp(deadline);
        OracleAttestation.Attestation memory a = _attestation(keccak256("late"), true);
        assertFalse(intake.deliverResult(rid, a, _sign(a)));
        tribunal.voidMarket(id);
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Void));
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.voidMarket(id);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.UnknownRequest.selector);
        tribunal.onOracleResult(rid, a, _sign(a));
    }

    function test_unrequestedMarketCanVoidAndCannotAskAtDeadline() public {
        uint256 id = _createContested();
        vm.warp(tribunal.getMarket(id).deadline);
        vm.expectRevert(Tribunal.DeadlinePassed.selector);
        tribunal.requestResolution(id);
        tribunal.voidMarket(id);
        _claim(id, creator);
        assertEq(imd.balanceOf(creator), 100 ether);
        _assertSolvent();
    }

    function test_slowERC1271VerificationCanBeRetriedPublicly() public {
        SlowSigner slow = new SlowSigner();
        vm.prank(owner);
        tribunal.setOracleSigner(address(slow));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        tribunal.activateOracleSigner();
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("slow registry"), true);
        assertTrue(intake.deliverResult(rid, a, ""), "binding callback should complete under 200k");
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        tribunal.submitAttestation(id, a, "");
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Yes));
    }

    function test_signerRotationWaits48HoursAndCannotChangeExistingMarketTrust() public {
        uint256 id = _createContested();
        uint256 newKey = 0x715b;
        address nextSigner = vm.addr(newKey);
        vm.prank(owner);
        tribunal.setOracleSigner(nextSigner);
        assertEq(tribunal.oracleSigner(), vm.addr(SIGNER_KEY));
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert(Tribunal.SignerDelayPending.selector);
        tribunal.activateOracleSigner();
        vm.warp(vm.getBlockTimestamp() + 1);
        tribunal.activateOracleSigner();
        assertEq(tribunal.oracleSigner(), nextSigner);
        assertEq(tribunal.pendingSigner(), address(0));
        assertEq(tribunal.getMarket(id).signer, vm.addr(SIGNER_KEY));
        bytes32 rid = tribunal.requestResolution(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("old signer still works"), false);
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.No));
        uint256 id2 = _createContested();
        assertEq(tribunal.getMarket(id2).signer, nextSigner);
        rid = _request(id2);
        a = _attestation(keccak256("new signer"), true);
        assertTrue(intake.deliverResult(rid, a, _signWith(newKey, a)));
        assertEq(uint256(tribunal.getMarket(id2).state), uint256(Tribunal.State.Yes));
    }

    function test_rotationReplacementRestartsDelayAndCanBeCancelled() public {
        vm.expectRevert(Tribunal.NoPendingSigner.selector);
        tribunal.activateOracleSigner();
        vm.startPrank(owner);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        tribunal.setOracleSigner(address(0));
        tribunal.setOracleSigner(alice);
        vm.warp(vm.getBlockTimestamp() + 47 hours);
        tribunal.setOracleSigner(bob);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(Tribunal.SignerDelayPending.selector);
        tribunal.activateOracleSigner();
        vm.prank(owner);
        tribunal.cancelSignerChange();
        vm.expectRevert(Tribunal.NoPendingSigner.selector);
        tribunal.activateOracleSigner();
        vm.prank(owner);
        vm.expectRevert(Tribunal.NoPendingSigner.selector);
        tribunal.cancelSignerChange();
        assertEq(tribunal.oracleSigner(), vm.addr(SIGNER_KEY));
    }

    function test_newSignerCannotResolveOldMarketAndOnlyTimeoutRefundsIfOldKeyIsRetired() public {
        uint256 id = _createContested();
        uint256 newKey = 0x715b;
        vm.prank(owner);
        tribunal.setOracleSigner(vm.addr(newKey));
        vm.warp(tribunal.signerActivateAfter());
        tribunal.activateOracleSigner();
        bytes32 rid = tribunal.requestResolution(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("retired signer"), true);
        bytes memory signature = _signWith(newKey, a);
        assertTrue(intake.deliverResult(rid, a, signature));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(id, a, signature);
        vm.warp(tribunal.getMarket(id).deadline);
        tribunal.voidMarket(id);
        assertEq(_claim(id, alice), 100 ether);
        assertEq(_claim(id, bob), 100 ether);
        assertEq(_claim(id, creator), 10_000 ether);
        assertEq(imd.balanceOf(creator), 99.5 ether);
        _assertSolvent();
    }
}
