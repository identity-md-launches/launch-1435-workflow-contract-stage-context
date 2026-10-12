// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "src/Tribunal.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {TribunalFixture} from "./helpers/TribunalFixture.sol";

/// forge-config: default.fuzz.runs = 512
contract TribunalOracleBoundariesTest is TribunalFixture {
    /// @dev Mutate every signed field independently; most variants remain structurally valid.
    function testFuzz_everyAttestationFieldIsAuthenticated(uint8 fieldSeed, bool yes) public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("untampered UUID"), yes);
        a.agreed = 5;
        bytes memory signature = _sign(a);
        bytes32 originalUUID = a.requestId;
        uint8 field = fieldSeed % 15;
        if (field == 0) a.requestId ^= bytes32(uint256(1));
        else if (field == 1) a.chainId = 4663;
        else if (field == 2) a.questionHash ^= bytes32(uint256(1));
        else if (field == 3) a.answerType = 1;
        else if (field == 4) a.answer = abi.encode(!yes);
        else if (field == 5) a.figure = 1;
        else if (field == 6) ++a.fromBlock;
        else if (field == 7) ++a.toBlock;
        else if (field == 8) a.blockHash ^= bytes32(uint256(1));
        else if (field == 9) a.panelJobId ^= bytes32(uint256(1));
        else if (field == 10) a.panelSize = 6;
        else if (field == 11) a.quorum = 5;
        else if (field == 12) a.agreed = 4;
        else if (field == 13) ++a.issuedAt;
        else ++a.expiresAt;

        assertTrue(intake.deliverResult(rid, a, signature));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        assertFalse(tribunal.consumed(originalUUID));
        assertFalse(tribunal.consumed(a.requestId));
        vm.expectRevert(
            field == 1 ? Tribunal.InvalidAttestation.selector : OracleAttestationConsumer.BadSignature.selector
        );
        tribunal.submitAttestation(id, a, signature);
        _assertSolvent();
    }

    function testFuzz_nonCanonicalBooleanWordsCannotBeConsumed(uint256 word) public {
        word = bound(word, 2, type(uint256).max);
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("noncanonical bool"), true);
        a.answer = abi.encode(word);
        bytes memory signature = _sign(a);
        assertTrue(intake.deliverResult(rid, a, signature));
        // Solidity's ABI decoder rejects bool words other than 0 and 1 without a custom error.
        vm.expectRevert();
        tribunal.submitAttestation(id, a, signature);
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        assertFalse(tribunal.consumed(a.requestId));
        vm.warp(tribunal.getMarket(id).deadline);
        tribunal.voidMarket(id);
        assertEq(_claim(id, creator), 10_000 ether);
        _assertSolvent();
    }

    function testFuzz_wrongBooleanAnswerLengthIsRejected(uint256 size) public {
        size = bound(size, 0, 96);
        if (size == 32) size = 33;
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("wrong answer length"), false);
        a.answer = new bytes(size);
        bytes memory signature = _sign(a);
        assertTrue(intake.deliverResult(rid, a, signature));
        vm.expectRevert(Tribunal.InvalidAttestation.selector);
        tribunal.submitAttestation(id, a, signature);
        assertFalse(tribunal.consumed(a.requestId));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
    }

    function test_zeroUUIDZeroQuestionAndPreRequestTimestampAreRejected() public {
        for (uint256 variant; variant < 3; ++variant) {
            uint256 id = _createContested();
            bytes32 rid = _request(id);
            OracleAttestation.Attestation memory a = _attestation(keccak256(abi.encode(variant)), true);
            if (variant == 0) a.requestId = bytes32(0);
            else if (variant == 1) a.questionHash = bytes32(0);
            else --a.issuedAt;
            bytes memory signature = _sign(a);
            assertTrue(intake.deliverResult(rid, a, signature));
            vm.expectRevert(Tribunal.InvalidAttestation.selector);
            tribunal.submitAttestation(id, a, signature);
            assertFalse(tribunal.consumed(a.requestId));
            assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        }
    }

    function test_expiryIsInclusiveAndClockToleranceBoundaryIsAccepted() public {
        uint256 first = _createContested();
        bytes32 rid = _request(first);
        OracleAttestation.Attestation memory a = _attestation(keccak256("at expiry"), false);
        bytes memory signature = _sign(a);
        vm.warp(a.expiresAt);
        assertTrue(intake.deliverResult(rid, a, signature));
        assertEq(uint256(tribunal.getMarket(first).state), uint256(Tribunal.State.No));

        uint256 second = _createContested();
        rid = _request(second);
        a = _attestation(keccak256("at allowed clock drift"), true);
        a.issuedAt += 300;
        assertTrue(intake.deliverResult(rid, a, _sign(a)));
        assertEq(uint256(tribunal.getMarket(second).state), uint256(Tribunal.State.Yes));
    }

    function test_failureAtDeadlineCannotChangeOutcomeAndAnyoneCanUnlockRefunds() public {
        uint256 id = _create();
        _bet(id, alice, false, 100 ether);
        _bet(id, bob, true, 300 ether);
        bytes32 rid = _request(id);
        vm.warp(tribunal.getMarket(id).deadline);
        assertFalse(intake.deliverFailure(rid, 1, bytes32("body_invalid"), 0, 0));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        vm.prank(carol);
        tribunal.voidMarket(id);
        assertEq(_claim(id, alice), 100 ether);
        assertEq(_claim(id, bob), 300 ether);
        assertEq(_claim(id, creator), 10_000 ether);
        assertEq(imd.balanceOf(creator), 99.5 ether, "a jury that was summoned stays paid");
        _assertSolvent();
    }

    function test_deferredResultCannotExtendDeadlineOrSurviveTimeout() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        Tribunal.Market memory pending = tribunal.getMarket(id);
        vm.warp(pending.deadline - 1);
        OracleAttestation.Attestation memory a = _attestation(keccak256("deferred at deadline"), true);
        assertTrue(intake.deliverResult(rid, a, _signWith(0xBAD, a)));
        assertEq(tribunal.getMarket(id).requestedAt, pending.requestedAt);
        assertEq(tribunal.getMarket(id).deadline, pending.deadline);
        bytes memory validSignature = _sign(a);
        vm.warp(pending.deadline);
        vm.expectRevert(Tribunal.DeadlinePassed.selector);
        tribunal.submitAttestation(id, a, validSignature);
        tribunal.voidMarket(id);
        vm.expectRevert(Tribunal.UnknownRequest.selector);
        tribunal.submitAttestation(id, a, validSignature);
        assertFalse(tribunal.consumed(a.requestId));
        assertEq(_claim(id, creator), 10_000 ether);
        _assertSolvent();
    }

    function test_newAndOldMarketsRejectEachOthersSignerAfterRotation() public {
        uint256 oldMarket = _createContested();
        bytes32 oldRequest = _request(oldMarket);
        uint256 newKey = 0x715b;
        vm.prank(owner);
        tribunal.setOracleSigner(vm.addr(newKey));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        tribunal.activateOracleSigner();

        OracleAttestation.Attestation memory a = _attestation(keccak256("old market"), true);
        assertTrue(intake.deliverResult(oldRequest, a, _signWith(newKey, a)));
        bytes memory wrongSignature = _signWith(newKey, a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(oldMarket, a, wrongSignature);
        tribunal.submitAttestation(oldMarket, a, _sign(a));
        assertEq(uint256(tribunal.getMarket(oldMarket).state), uint256(Tribunal.State.Yes));

        uint256 newMarket = _createContested();
        bytes32 newRequest = _request(newMarket);
        a = _attestation(keccak256("new market"), false);
        assertTrue(intake.deliverResult(newRequest, a, _sign(a)));
        wrongSignature = _sign(a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(newMarket, a, wrongSignature);
        tribunal.submitAttestation(newMarket, a, _signWith(newKey, a));
        assertEq(uint256(tribunal.getMarket(newMarket).state), uint256(Tribunal.State.No));
    }

    function test_signatureFromAnotherChainCannotSettleHere() public {
        uint256 id = _createContested();
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256("other chain domain"), true);
        vm.chainId(4663);
        bytes32 otherChainDigest = tribunal.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, otherChainDigest);
        bytes memory otherChainSignature = abi.encodePacked(r, s, v);
        vm.chainId(1);
        assertNotEq(tribunal.attestationDigest(a), otherChainDigest);
        assertTrue(intake.deliverResult(rid, a, otherChainSignature));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.submitAttestation(id, a, otherChainSignature);
        assertFalse(tribunal.consumed(a.requestId));
        tribunal.submitAttestation(id, a, _sign(a));
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Yes));
    }
}
