// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "../src/Tribunal.sol";
import {TribunalFixture} from "./helpers/TribunalFixture.sol";
import {FalseToken} from "./helpers/Mocks.sol";

contract TribunalPayoutsTest is TribunalFixture {
    function test_yesWinnersShareLosingPoolMinusTwoPercent() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, carol, true, 300 ether);
        _bet(id, bob, false, 1000 ether);
        _resolve(id, true);
        assertEq(_claim(id, alice), 345 ether); // 100 + 25% * 980
        assertEq(_claim(id, carol), 1035 ether); // 300 + 75% * 980
        assertEq(_claim(id, bob), 0);
        assertEq(_claim(id, creator), 10_010 ether);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 10 ether);
        assertEq(verdict.balanceOf(address(tribunal)), 0);
        assertEq(imd.balanceOf(creator), 99.5 ether); // jury cost is spent
        _assertSolvent();
    }

    function test_noWinnerCreatorWithBothPositionsGetsBondFeeAndWinningStake() public {
        uint256 id = _create();
        _bet(id, alice, true, 400 ether);
        _bet(id, creator, true, 100 ether);
        _bet(id, creator, false, 200 ether);
        _bet(id, bob, false, 300 ether);
        _resolve(id, false);
        // Losing pool 500; net profit 490; creator gets 2/5 and bond + 5 fee.
        assertEq(_claim(id, creator), 10_401 ether);
        assertEq(_claim(id, bob), 594 ether);
        assertEq(_claim(id, alice), 0);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 5 ether);
        _assertSolvent();
        assertEq(tribunal.verdictLiability(), 0);
    }

    function test_voidRefundsBothSidesAndBondButNotSpentOracleFee() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, alice, false, 200 ether);
        _bet(id, bob, false, 300 ether);
        bytes32 rid = _request(id);
        assertTrue(intake.deliverFailure(rid, 2, bytes32("disagreed"), 3, 5));
        assertEq(_claim(id, creator), 10_000 ether);
        assertEq(_claim(id, alice), 300 ether);
        assertEq(_claim(id, bob), 300 ether);
        assertEq(verdict.balanceOf(alice), 1_000_000 ether);
        assertEq(verdict.balanceOf(bob), 1_000_000 ether);
        assertEq(verdict.balanceOf(creator), 1_000_000 ether);
        assertEq(imd.balanceOf(creator), 99.5 ether);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 0);
        _assertSolvent();
    }

    function test_bodyRefusalRefundsAndRecordsReason() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        bytes32 rid = _request(id);
        assertTrue(intake.deliverFailure(rid, 1, bytes32("body_refused"), 0, 0));
        assertEq(tribunal.getMarket(id).failureReason, bytes32("body_refused"));
        assertEq(_claim(id, alice), 100 ether);
        assertEq(_claim(id, creator), 10_000 ether);
        _assertSolvent();
    }

    function test_pendingTimeoutRefundsButJuryCostRemainsSpent() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _request(id);
        vm.warp(tribunal.getMarket(id).deadline);
        tribunal.voidMarket(id);
        _claim(id, alice);
        _claim(id, creator);
        assertEq(imd.balanceOf(creator), 99.5 ether);
        _assertSolvent();
    }

    function test_unrequestedTimeoutRefundsAlsoReturnUnspentIMD() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 200 ether);
        vm.warp(tribunal.getMarket(id).deadline);
        tribunal.voidMarket(id);
        _claim(id, bob);
        _claim(id, creator);
        _claim(id, alice);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(verdict.balanceOf(creator), 1_000_000 ether);
        assertEq(verdict.balanceOf(alice), 1_000_000 ether);
        assertEq(verdict.balanceOf(bob), 1_000_000 ether);
        _assertSolvent();
    }

    function test_oneSidedWinningAndLosingMarketsAndEmptyMarketReturnFullDeposits() public {
        uint256 id1 = _create();
        uint256 id2 = _create();
        uint256 id3 = _create();
        _bet(id1, alice, true, 100 ether);
        _bet(id2, bob, false, 200 ether);
        _resolve(id1, true);
        _resolve(id2, true); // Even the only losing side gets its deposit back.
        _resolve(id3, false);
        assertEq(_claim(id1, alice), 100 ether);
        assertEq(_claim(id2, bob), 200 ether);
        assertEq(_claim(id1, creator), 10_000 ether);
        assertEq(_claim(id2, creator), 10_000 ether);
        assertEq(_claim(id3, creator), 10_000 ether);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 0);
        _assertSolvent();
    }

    function test_invalidClaimsAndNoDoubleClaimEvenForZeroPayout() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.claim(id);
        _resolve(id, true);
        vm.prank(carol);
        vm.expectRevert(Tribunal.NoPosition.selector);
        tribunal.claim(id);
        _claim(id, bob);
        vm.prank(bob);
        vm.expectRevert(Tribunal.AlreadyClaimed.selector);
        tribunal.claim(id);
        _claim(id, alice);
        vm.prank(alice);
        vm.expectRevert(Tribunal.AlreadyClaimed.selector);
        tribunal.claim(id);
        _claim(id, creator);
        vm.prank(creator);
        vm.expectRevert(Tribunal.AlreadyClaimed.selector);
        tribunal.claim(id);
        _assertSolvent();
    }

    function test_failedPayoutRollsBackClaimsBurnAndAccountingThenCanRetry() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 100 ether);
        _resolve(id, true);
        verdict.setReject(true);
        vm.prank(alice);
        vm.expectRevert("token rejected transfer");
        tribunal.claim(id);
        (,, bool claimed) = tribunal.positions(id, alice);
        assertFalse(claimed);
        assertFalse(tribunal.getMarket(id).burnPaid);
        assertEq(tribunal.getMarket(id).paidProfit, 0);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), 0);
        _assertSolvent();
        verdict.setReject(false);
        assertEq(_claim(id, alice), 198 ether);
        _claim(id, creator);
        _claim(id, bob);
        _assertSolvent();
    }

    function test_failedOracleRefundAlsoRollsBackReturnedBond() public {
        uint256 id = _create();
        vm.warp(tribunal.getMarket(id).deadline);
        tribunal.voidMarket(id);
        imd.setReject(true);
        vm.prank(creator);
        vm.expectRevert("token rejected transfer");
        tribunal.claim(id);
        (,, bool claimed) = tribunal.positions(id, creator);
        assertFalse(claimed);
        assertEq(verdict.balanceOf(creator), 990_000 ether);
        _assertSolvent();
        imd.setReject(false);
        _claim(id, creator);
        _assertSolvent();
    }

    function test_claimReentrancyIsBlockedAndUserPaidOnce() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, bob, false, 100 ether);
        _resolve(id, true);
        verdict.setHook(address(tribunal), address(tribunal), abi.encodeCall(tribunal.claim, (id)));
        assertEq(_claim(id, alice), 198 ether);
        assertTrue(verdict.hookAttempted());
        assertFalse(verdict.hookSucceeded());
        assertEq(bytes4(verdict.hookReturn()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        _claim(id, creator);
        _claim(id, bob);
        _assertSolvent();
    }

    function test_falseReturningTokenDepositsAndClaimsRevertSafely() public {
        FalseToken token = new FalseToken();
        Tribunal fresh = new Tribunal(owner, address(intake), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.prank(owner);
        fresh.setVerdictToken(address(token));
        token.mint(creator, 10_000 ether);
        vm.startPrank(creator);
        token.approve(address(fresh), 10_000 ether);
        imd.approve(address(fresh), 0.5 ether);
        token.setFalse(true);
        vm.expectRevert();
        fresh.createMarket(
            "market", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
        token.setFalse(false);
        uint256 id = fresh.createMarket(
            "market", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
        vm.stopPrank();
        vm.warp(fresh.getMarket(id).deadline);
        fresh.voidMarket(id);
        token.setFalse(true);
        vm.prank(creator);
        vm.expectRevert();
        fresh.claim(id);
        assertEq(fresh.verdictLiability(), 10_000 ether);
        (,, bool claimed) = fresh.positions(id, creator);
        assertFalse(claimed);
        token.setFalse(false);
        vm.prank(creator);
        fresh.claim(id);
        assertEq(fresh.verdictLiability(), 0);
    }

    function testFuzz_proRataConservesAllFundsWithRoundingAndAnyClaimOrder(
        uint256 stakeA,
        uint256 stakeC,
        uint256 losing,
        bool yesWins,
        uint8 order
    ) public {
        stakeA = bound(stakeA, 100 ether, 20_000 ether);
        stakeC = bound(stakeC, 100 ether, 20_000 ether);
        losing = bound(losing, 100 ether, 20_000 ether);
        uint256 id = _create();
        _bet(id, alice, yesWins, stakeA);
        _bet(id, carol, yesWins, stakeC);
        _bet(id, bob, !yesWins, losing);
        _resolve(id, yesWins);
        uint256 fee = losing / 100;
        uint256 net = losing - 2 * fee;
        uint256 amountA;
        uint256 amountC;
        if (order % 2 == 0) {
            _claim(id, creator);
            amountA = _claim(id, alice);
            _claim(id, bob);
            amountC = _claim(id, carol);
            assertEq(amountA, stakeA + net * stakeA / (stakeA + stakeC));
        } else {
            amountC = _claim(id, carol);
            _claim(id, bob);
            amountA = _claim(id, alice);
            _claim(id, creator);
            assertEq(amountC, stakeC + net * stakeC / (stakeA + stakeC));
        }
        assertEq(amountA + amountC + 2 * fee, stakeA + stakeC + losing);
        assertEq(verdict.balanceOf(tribunal.BURN_ADDRESS()), fee);
        assertEq(tribunal.verdictLiability(), 0);
        _assertSolvent();
    }

    function test_parallelMarketsKeepEscrowsAndClaimsSeparate() public {
        uint256 id1 = _create();
        uint256 id2 = _create();
        _bet(id1, alice, true, 100 ether);
        _bet(id1, bob, false, 200 ether);
        _bet(id2, bob, true, 300 ether);
        _resolve(id1, true);
        _claim(id1, creator);
        _claim(id1, alice);
        _claim(id1, bob);
        assertEq(tribunal.verdictLiability(), 10_300 ether);
        assertEq(tribunal.oracleEscrow(address(imd)), 0.5 ether);
        vm.warp(tribunal.getMarket(id2).deadline);
        tribunal.voidMarket(id2);
        _claim(id2, bob);
        _claim(id2, creator);
        _assertSolvent();
        assertEq(tribunal.verdictLiability(), 0);
    }
}
