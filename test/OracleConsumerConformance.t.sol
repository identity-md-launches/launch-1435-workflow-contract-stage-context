// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ConformanceHarness} from "./helpers/ConformanceHarness.sol";
import {MockToken, MockIntake} from "./helpers/Mocks.sol";

/// @notice Constants and vector copied from the supplied protocol reference, unchanged.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    address constant WRITER = address(0x717E);
    address constant SOURCE_INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;

    ConformanceHarness consumer;
    MockIntake intake;
    MockToken asset;
    MockToken verdict;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        intake = new MockIntake();
        asset = new MockToken();
        verdict = new MockToken();
        deployCodeTo(
            "ConformanceHarness.sol:ConformanceHarness",
            abi.encode(
                address(this), address(intake), address(asset), bytes32("oracle.request@oracle-1"), 0.5 ether, SIGNER
            ),
            VECTOR_CONSUMER
        );
        consumer = ConformanceHarness(VECTOR_CONSUMER);
        consumer.setVerdictToken(address(verdict));
        verdict.mint(address(this), 10_000 ether);
        asset.mint(address(this), 0.5 ether);
        verdict.approve(address(consumer), 10_000 ether);
        asset.approve(address(consumer), 0.5 ether);
    }

    function caller() internal view returns (address) {
        return address(intake);
    }

    /// @dev The vector attestation: a `bytes32[]` answer with one element, figure 12345, blocks
    /// 100–200, a panel of five with a quorum of four that agreed unanimously.
    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(keccak256(bytes(CALLBACK))),
            "callback parameters differ from the protocol's"
        );
    }

    function test_acceptsTheUnchangedProtocolSignature() public view {
        consumer.verifyProtocolVector(vector(), VECTOR_SIGNATURE);
    }

    /// @dev Tribunal only accepts bool. As permitted by the supplied conformance test, sign a
    /// bool with the vector key and deliver it through the actual callback under 200,000 gas.
    function test_acceptsAFreshBoolSignatureFromTheVectorKeyUnder200k() public {
        bytes memory body =
            '{"v":1,"question":"Did the event happen?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":900}';
        uint256 id = consumer.createMarket("event", body, ISSUED_AT + 1, ISSUED_AT + 2);
        verdict.mint(address(this), 200 ether);
        verdict.approve(address(consumer), 200 ether);
        consumer.betYes(id, 100 ether);
        consumer.betNo(id, 100 ether);
        vm.warp(ISSUED_AT + 2);
        bytes32 sourceRequestId = consumer.requestResolution(id);
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        a.answerType = 0;
        a.answer = abi.encode(true);
        a.issuedAt = ISSUED_AT + 2;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        assertTrue(
            intake.deliverResult(sourceRequestId, a, abi.encodePacked(r, s, v)), "callback did not finish under stipend"
        );
        assertTrue(consumer.consumed(a.requestId));
        assertEq(uint256(consumer.getMarket(id).state), uint256(Tribunal.State.Yes));
    }
}
