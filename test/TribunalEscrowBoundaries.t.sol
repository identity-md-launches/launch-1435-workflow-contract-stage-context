// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "src/Tribunal.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {TribunalFixture} from "./helpers/TribunalFixture.sol";
import {MockIntake, MockToken} from "./helpers/Mocks.sol";

contract TribunalEscrowBoundariesTest is TribunalFixture {
    /// @dev Scheduled configuration only applies after the 48-hour delay and an explicit activation.
    function _activateScheduledConfig() internal {
        vm.warp(vm.getBlockTimestamp() + tribunal.CONFIG_DELAY());
        vm.prank(carol); // Anyone may activate a matured schedule.
        tribunal.activateOracleConfig();
    }

    function test_replacementIntakeCanReuseAnIdWithoutOverwritingOldMarket() public {
        bytes32 sharedId = keccak256("same id issued by independent intakes");
        intake.setForcedId(sharedId);
        uint256 oldMarket = _create();
        _bet(oldMarket, alice, true, 100 ether);
        _bet(oldMarket, bob, false, 300 ether);

        MockIntake replacement = new MockIntake();
        MockToken nextAsset = new MockToken();
        replacement.setForcedId(sharedId);
        replacement.setPrice(1 ether);
        nextAsset.mint(creator, 1 ether);
        vm.prank(creator);
        nextAsset.approve(address(tribunal), 1 ether);
        vm.startPrank(owner);
        tribunal.setIntake(address(replacement));
        tribunal.setAction(bytes32("oracle.request@oracle-2"));
        tribunal.setPayment(address(nextAsset), 1 ether);
        vm.stopPrank();
        _activateScheduledConfig();
        uint256 newMarket = _create();
        _bet(newMarket, alice, true, 200 ether);
        _bet(newMarket, bob, false, 100 ether);
        vm.warp(tribunal.getMarket(newMarket).resolveAfter);
        assertLt(vm.getBlockTimestamp(), tribunal.getMarket(oldMarket).deadline);
        assertEq(tribunal.requestResolution(oldMarket), sharedId);
        assertEq(tribunal.requestResolution(newMarket), sharedId);
        assertEq(tribunal.requestMarket(address(intake), sharedId), oldMarket);
        assertEq(tribunal.requestMarket(address(replacement), sharedId), newMarket);
        assertEq(intake.getAsk(sharedId).asset, address(imd));
        assertEq(replacement.getAsk(sharedId).asset, address(nextAsset));
        assertEq(intake.getAsk(sharedId).action, ACTION);
        assertEq(replacement.getAsk(sharedId).action, bytes32("oracle.request@oracle-2"));

        OracleAttestation.Attestation memory a = _attestation(keccak256("old intake answer"), true);
        assertTrue(intake.deliverResult(sharedId, a, _sign(a)));
        assertEq(uint256(tribunal.getMarket(oldMarket).state), uint256(Tribunal.State.Yes));
        assertEq(uint256(tribunal.getMarket(newMarket).state), uint256(Tribunal.State.Pending));
        assertTrue(replacement.deliverFailure(sharedId, 2, bytes32("disagreed"), 3, 5));
        assertEq(uint256(tribunal.getMarket(newMarket).state), uint256(Tribunal.State.Void));
        assertEq(uint256(tribunal.getMarket(oldMarket).state), uint256(Tribunal.State.Yes));

        assertEq(_claim(oldMarket, alice), 394 ether);
        assertEq(_claim(oldMarket, bob), 0);
        assertEq(_claim(oldMarket, creator), 10_003 ether);
        assertEq(_claim(newMarket, bob), 100 ether);
        assertEq(_claim(newMarket, alice), 200 ether);
        assertEq(_claim(newMarket, creator), 10_000 ether);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(nextAsset.balanceOf(address(replacement)), 1 ether);
        assertEq(nextAsset.balanceOf(address(tribunal)), 0);
        assertEq(tribunal.oracleEscrow(address(nextAsset)), 0);
        assertEq(nextAsset.allowance(address(tribunal), address(replacement)), 0);
        _assertSolvent();
    }

    function test_feeRefundUsesOriginalAssetAndPriceAfterConfigurationChanges() public {
        uint256 oldMarket = _create();
        MockToken nextAsset = new MockToken();
        MockIntake nextIntake = new MockIntake();
        nextIntake.setPrice(2 ether);
        nextAsset.mint(creator, 2 ether);
        vm.prank(creator);
        nextAsset.approve(address(tribunal), 2 ether);
        vm.startPrank(owner);
        tribunal.setIntake(address(nextIntake));
        tribunal.setPayment(address(nextAsset), 2 ether);
        vm.stopPrank();
        _activateScheduledConfig();
        uint256 newMarket = _create();
        assertEq(tribunal.oracleEscrow(address(imd)), 0.5 ether);
        assertEq(tribunal.oracleEscrow(address(nextAsset)), 2 ether);
        vm.warp(tribunal.getMarket(newMarket).deadline);
        tribunal.voidMarket(newMarket);
        tribunal.voidMarket(oldMarket);
        _claim(newMarket, creator);
        assertEq(nextAsset.balanceOf(creator), 2 ether);
        assertEq(imd.balanceOf(creator), 99.5 ether);
        assertEq(tribunal.oracleEscrow(address(imd)), 0.5 ether);
        _claim(oldMarket, creator);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(tribunal.oracleEscrow(address(nextAsset)), 0);
        _assertSolvent();
    }

    function test_paymentAssetCanEqualVerdictWithoutMixingBondAndFeeLiabilities() public {
        uint256 oldMarket = _create(); // Its prepaid IMD must remain untouched.
        vm.prank(owner);
        tribunal.setPayment(address(verdict), 0.5 ether);
        _activateScheduledConfig();
        uint256 sharedAssetMarket = _create();
        uint256 unrequestedMarket = _create();
        _bet(sharedAssetMarket, alice, true, 100 ether);
        _bet(sharedAssetMarket, bob, false, 200 ether);
        assertEq(verdict.balanceOf(address(tribunal)), tribunal.verdictLiability() + 1 ether);
        assertEq(tribunal.oracleEscrow(address(verdict)), 1 ether);
        _resolve(sharedAssetMarket, true);
        assertEq(tribunal.oracleEscrow(address(verdict)), 0.5 ether);
        assertEq(verdict.balanceOf(address(intake)), 0.5 ether);
        assertEq(_claim(sharedAssetMarket, alice), 296 ether);
        assertEq(_claim(sharedAssetMarket, creator), 10_002 ether);
        assertEq(_claim(sharedAssetMarket, bob), 0);

        vm.warp(tribunal.getMarket(unrequestedMarket).deadline);
        tribunal.voidMarket(unrequestedMarket);
        uint256 beforeCreator = verdict.balanceOf(creator);
        assertEq(_claim(unrequestedMarket, creator), 10_000 ether);
        assertEq(verdict.balanceOf(creator) - beforeCreator, 10_000.5 ether);
        assertEq(tribunal.oracleEscrow(address(verdict)), 0);
        assertEq(verdict.balanceOf(address(tribunal)), 10_000 ether);
        assertEq(tribunal.oracleEscrow(address(imd)), 0.5 ether);
        tribunal.voidMarket(oldMarket);
        _claim(oldMarket, creator);
        assertEq(imd.balanceOf(creator), 100 ether);
        _assertSolvent();
    }

    function test_failedSecondCreationTransferRollsBackFirstTransferAndId() public {
        vm.prank(creator);
        imd.approve(address(tribunal), 0);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(tribunal), 0, 0.5 ether
            )
        );
        tribunal.createMarket(
            "unfunded jury", BODY, uint64(vm.getBlockTimestamp() + 1), uint64(vm.getBlockTimestamp() + 2)
        );
        assertEq(tribunal.marketCount(), 0);
        assertEq(verdict.balanceOf(creator), 1_000_000 ether);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(tribunal.verdictLiability(), 0);
        assertEq(tribunal.oracleEscrow(address(imd)), 0);
        vm.expectRevert(Tribunal.UnknownMarket.selector);
        tribunal.getMarket(1);
        vm.prank(creator);
        imd.approve(address(tribunal), 0.5 ether);
        assertEq(_create(), 1, "a reverted creation must not consume an id");
        _assertSolvent();
    }

    function test_taxedOracleFeeRollsBackBondAndEscrow() public {
        imd.setTax(1);
        vm.prank(creator);
        vm.expectRevert(Tribunal.UnexpectedTokenAmount.selector);
        tribunal.createMarket(
            "taxed payment", BODY, uint64(vm.getBlockTimestamp() + 1), uint64(vm.getBlockTimestamp() + 2)
        );
        assertEq(tribunal.marketCount(), 0);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(verdict.balanceOf(creator), 1_000_000 ether);
        _assertSolvent();
    }

    function test_zeroOneWeiAndMaximumBetsCannotCorruptEitherPool() public {
        uint256 id = _create();
        for (uint256 side; side < 2; ++side) {
            for (uint256 variant; variant < 3; ++variant) {
                uint256 amount = variant == 2 ? type(uint256).max : variant;
                vm.prank(alice);
                if (variant == 2) vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
                else vm.expectRevert(Tribunal.BetTooSmall.selector);
                if (side == 0) tribunal.betYes(id, amount);
                else tribunal.betNo(id, amount);
                assertEq(tribunal.getMarket(id).yesPool, 0);
                assertEq(tribunal.getMarket(id).noPool, 0);
                (uint256 yes, uint256 no, bool claimed) = tribunal.positions(id, alice);
                assertEq(yes + no, 0);
                assertFalse(claimed);
                assertEq(tribunal.verdictLiability(), 10_000 ether);
            }
        }
        _assertSolvent();
    }

    /// @dev The uncontested ask refunds the fee in the asset the market was created with, even after
    /// the payment configuration changed and even if the current Intake would reject a request.
    function test_uncontestedAskRefundsFeeInOriginalAssetAfterReconfiguration() public {
        uint256 oneSided = _create();
        _bet(oneSided, alice, true, 100 ether);
        _bet(oneSided, bob, true, 250 ether);
        MockToken nextAsset = new MockToken();
        vm.prank(owner);
        tribunal.setPayment(address(nextAsset), 3 ether);
        _activateScheduledConfig();
        intake.setReject(true);
        vm.warp(tribunal.getMarket(oneSided).resolveAfter);
        Tribunal.Market memory before = tribunal.getMarket(oneSided);
        vm.prank(carol);
        assertEq(tribunal.requestResolution(oneSided), bytes32(0));
        Tribunal.Market memory m = tribunal.getMarket(oneSided);
        assertEq(uint256(m.state), uint256(Tribunal.State.Void));
        assertEq(m.failureReason, bytes32("uncontested"));
        assertFalse(m.oracleSpent);
        assertEq(m.requestId, bytes32(0));
        assertEq(m.requestedAt, 0);
        assertEq(m.deadline, before.deadline);
        assertEq(tribunal.oracleEscrow(address(imd)), 0.5 ether, "fee stays escrowed until the creator claims");
        assertEq(imd.allowance(address(tribunal), address(intake)), 0);
        assertEq(intake.nonce(), 0, "no request may reach the Intake");

        assertEq(_claim(oneSided, alice), 100 ether);
        assertEq(_claim(oneSided, bob), 250 ether);
        assertEq(_claim(oneSided, creator), 10_000 ether);
        assertEq(imd.balanceOf(creator), 100 ether, "refund uses the original asset");
        assertEq(nextAsset.balanceOf(creator), 0);
        assertEq(tribunal.oracleEscrow(address(imd)), 0);
        assertEq(tribunal.verdictLiability(), 0);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 0, "a refund must not burn");
        _assertSolvent();
    }

    function test_creatorBettingBothSidesAloneIsContestedAndPaysTheJury() public {
        uint256 id = _create();
        _bet(id, creator, true, 100 ether);
        _bet(id, creator, false, 100 ether);
        _resolve(id, true);
        assertTrue(tribunal.getMarket(id).oracleSpent);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        // Stake 100 + profit 98 + bond 10,000 + creator fee 1; 1 burned.
        assertEq(_claim(id, creator), 10_199 ether);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 1 ether);
        assertEq(imd.balanceOf(creator), 99.5 ether);
        assertEq(tribunal.verdictLiability(), 0);
        _assertSolvent();
    }

    function test_uncontestedVoidIsFinalAndTheLastAskableSecondMatchesTheTimeoutPath() public {
        uint256 early = _create();
        uint256 late = _create();
        _bet(early, alice, false, 100 ether);
        _bet(late, bob, false, 100 ether);
        uint64 deadline = tribunal.getMarket(early).deadline;

        vm.warp(deadline - 1);
        assertEq(tribunal.requestResolution(early), bytes32(0));
        assertEq(uint256(tribunal.getMarket(early).state), uint256(Tribunal.State.Void));
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.requestResolution(early);
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.voidMarket(early);
        vm.prank(alice);
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.betYes(early, 100 ether);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleFailure(bytes32(0), 2, bytes32("disagreed"), 0, 0, "");

        vm.warp(deadline);
        vm.expectRevert(Tribunal.DeadlinePassed.selector);
        tribunal.requestResolution(late);
        tribunal.voidMarket(late);
        assertEq(tribunal.getMarket(late).failureReason, bytes32("timeout"));
        assertFalse(tribunal.getMarket(late).oracleSpent);

        assertEq(_claim(early, alice), 100 ether);
        assertEq(_claim(late, bob), 100 ether);
        assertEq(_claim(early, creator), 10_000 ether);
        assertEq(_claim(late, creator), 10_000 ether);
        assertEq(imd.balanceOf(creator), 100 ether, "both paths return the unspent fee");
        vm.expectRevert(Tribunal.AlreadyClaimed.selector);
        _claim(early, creator);
        assertEq(tribunal.verdictLiability(), 0);
        _assertSolvent();
    }

    function test_losingClaimBurnDoesNotConsumeAnotherMarketsRefund() public {
        uint256 resolved = _create();
        uint256 untouched = _create();
        _bet(resolved, alice, true, 100 ether);
        _bet(resolved, bob, false, 10_000 ether + 99);
        _bet(untouched, carol, false, 123 ether + 1);
        _resolve(resolved, true);
        assertEq(_claim(resolved, bob), 0);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 100 ether);
        vm.warp(tribunal.getMarket(untouched).deadline);
        tribunal.voidMarket(untouched);
        assertEq(_claim(untouched, carol), 123 ether + 1);
        assertEq(_claim(untouched, creator), 10_000 ether);
        assertEq(_claim(resolved, creator), 10_100 ether);
        assertEq(_claim(resolved, alice), 9_900 ether + 99);
        assertEq(tribunal.verdictLiability(), 0);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 100 ether);
        _assertSolvent();
    }
}
