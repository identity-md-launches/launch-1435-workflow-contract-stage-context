// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../../src/Tribunal.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {MockToken, MockIntake} from "./Mocks.sol";

abstract contract TribunalFixture is Test {
    Tribunal internal tribunal;
    MockToken internal verdict;
    MockToken internal imd;
    MockIntake internal intake;
    address internal owner = address(0xA11CE);
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA);
    uint256 internal constant SIGNER_KEY = 0x713b;
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    bytes internal constant BODY =
        '{"v":1,"question":"Did the event happen?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":900,"definitions":{"event":"The event as described in the market terms."}}';

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(1);
        verdict = new MockToken();
        imd = new MockToken();
        intake = new MockIntake();
        tribunal = new Tribunal(owner, address(intake), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.prank(owner);
        tribunal.setVerdictToken(address(verdict));
        _fund(creator);
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address user) internal {
        verdict.mint(user, 1_000_000 ether);
        imd.mint(user, 100 ether);
        vm.startPrank(user);
        verdict.approve(address(tribunal), type(uint256).max);
        imd.approve(address(tribunal), type(uint256).max);
        vm.stopPrank();
    }

    function _create() internal returns (uint256 id) {
        vm.prank(creator);
        id = tribunal.createMarket(
            "An event", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
    }

    function _bet(uint256 id, address user, bool yes, uint256 amount) internal {
        vm.prank(user);
        if (yes) tribunal.betYes(id, amount);
        else tribunal.betNo(id, amount);
    }

    function _request(uint256 id) internal returns (bytes32 rid) {
        vm.warp(tribunal.getMarket(id).resolveAfter);
        rid = tribunal.requestResolution(id);
    }

    function _attestation(bytes32 uuid, bool yes) internal view returns (OracleAttestation.Attestation memory a) {
        a = OracleAttestation.Attestation({
            requestId: uuid,
            chainId: 1,
            questionHash: keccak256("resolved canonical question"),
            answerType: 0,
            answer: abi.encode(yes),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: keccak256("closing block"),
            panelJobId: keccak256("panel"),
            panelSize: 5,
            quorum: 4,
            agreed: 4,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 900)
        });
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return _signWith(SIGNER_KEY, a);
    }

    function _signWith(uint256 key, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(a));
        return abi.encodePacked(r, s, v);
    }

    function _digest(OracleAttestation.Attestation memory a) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
        );
        bytes32 message = keccak256(
            abi.encode(
                typeHash,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(tribunal)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, message));
    }

    function _resolve(uint256 id, bool yes) internal {
        bytes32 rid = _request(id);
        OracleAttestation.Attestation memory a = _attestation(keccak256(abi.encode("UUID", id)), yes);
        assertTrue(intake.deliverResult(rid, a, _sign(a)), "callback exceeded 200k or reverted");
        assertEq(uint256(tribunal.getMarket(id).state), uint256(yes ? Tribunal.State.Yes : Tribunal.State.No));
    }

    function _claim(uint256 id, address user) internal returns (uint256 amount) {
        vm.prank(user);
        return tribunal.claim(id);
    }

    function _assertSolvent() internal view {
        assertEq(verdict.balanceOf(address(tribunal)), tribunal.verdictLiability());
        assertEq(imd.balanceOf(address(tribunal)), tribunal.oracleEscrow(address(imd)));
    }
}
