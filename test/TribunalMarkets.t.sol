// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "../src/Tribunal.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TribunalFixture} from "./helpers/TribunalFixture.sol";
import {MockToken, MockIntake} from "./helpers/Mocks.sol";

contract TribunalMarketsTest is TribunalFixture {
    function test_creationEscrowsBondAndFeeAndLocksTerms() public {
        uint256 id = _create();
        Tribunal.Market memory m = tribunal.getMarket(id);
        assertEq(id, 1);
        assertEq(m.creator, creator);
        assertEq(m.title, "An event");
        assertEq(m.oracleBody, BODY);
        assertEq(m.panelSize, 5);
        assertEq(m.quorum, 4);
        assertEq(m.oracle.intake, address(intake));
        assertEq(m.oracle.asset, address(imd));
        assertEq(m.signer, vm.addr(SIGNER_KEY));
        assertEq(m.deadline, m.resolveAfter + 7 days);
        assertEq(verdict.balanceOf(creator), 990_000 ether);
        assertEq(imd.balanceOf(creator), 99.5 ether);
        _assertSolvent();
    }

    function test_unsetTokenRevertsThenOwnerConfiguresOnce() public {
        Tribunal fresh = new Tribunal(owner, address(intake), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.expectRevert(Tribunal.NotConfigured.selector);
        fresh.createMarket(
            "title", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setVerdictToken(address(verdict));
        vm.startPrank(owner);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        fresh.setVerdictToken(address(0));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        fresh.setVerdictToken(alice);
        fresh.setVerdictToken(address(verdict));
        vm.expectRevert(Tribunal.TokenAlreadySet.selector);
        fresh.setVerdictToken(address(imd));
        vm.stopPrank();
    }

    function test_constructorWorksWithoutDependencyCodeAndDoesNotOwnFactory() public {
        address emptyIntake = address(0x1001);
        address emptyAsset = address(0x1002);
        Tribunal fresh = new Tribunal(owner, emptyIntake, emptyAsset, ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        assertEq(fresh.owner(), owner);
        assertEq(emptyIntake.code.length, 0);
        vm.prank(owner);
        fresh.setVerdictToken(address(verdict));
        vm.expectRevert(Tribunal.NotConfigured.selector);
        fresh.createMarket(
            "title", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
    }

    function test_invalidConstructorConfigRejected() public {
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        new Tribunal(owner, address(0), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        new Tribunal(owner, address(intake), address(0), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        new Tribunal(owner, address(intake), address(imd), bytes32(0), 0.5 ether, vm.addr(SIGNER_KEY));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        new Tribunal(owner, address(intake), address(imd), ACTION, 0, vm.addr(SIGNER_KEY));
        vm.expectRevert();
        new Tribunal(address(0), address(intake), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.expectRevert();
        new Tribunal(owner, address(intake), address(imd), ACTION, 0.5 ether, address(0));
    }

    function test_invalidTimeAndUnknownMarketRejected() public {
        vm.startPrank(creator);
        vm.expectRevert(Tribunal.InvalidTimes.selector);
        tribunal.createMarket("title", BODY, uint64(vm.getBlockTimestamp()), uint64(vm.getBlockTimestamp() + 1 days));
        vm.expectRevert(Tribunal.InvalidTimes.selector);
        tribunal.createMarket(
            "title", BODY, uint64(vm.getBlockTimestamp() + 2 days), uint64(vm.getBlockTimestamp() + 1 days)
        );
        vm.expectRevert(Tribunal.InvalidTimes.selector);
        tribunal.createMarket("title", BODY, uint64(vm.getBlockTimestamp() + 1 days), type(uint64).max);
        vm.stopPrank();
        vm.expectRevert(Tribunal.UnknownMarket.selector);
        tribunal.betYes(100, 100 ether);
        vm.expectRevert(Tribunal.UnknownMarket.selector);
        tribunal.getMarket(0);
    }

    function test_betsOnBothSidesAggregateAndMinimumAndWindowAreEnforced() public {
        uint256 id = _create();
        _bet(id, alice, true, 100 ether);
        _bet(id, alice, true, 200 ether);
        _bet(id, alice, false, 100 ether);
        _bet(id, bob, false, 500 ether);
        (uint256 yes, uint256 no, bool claimed) = tribunal.positions(id, alice);
        assertEq(yes, 300 ether);
        assertEq(no, 100 ether);
        assertFalse(claimed);
        assertEq(tribunal.getMarket(id).yesPool, 300 ether);
        assertEq(tribunal.getMarket(id).noPool, 600 ether);
        vm.prank(alice);
        vm.expectRevert(Tribunal.BetTooSmall.selector);
        tribunal.betYes(id, 100 ether - 1);
        vm.warp(tribunal.getMarket(id).closeTime - 1);
        _bet(id, bob, true, 100 ether);
        vm.warp(tribunal.getMarket(id).closeTime);
        vm.prank(alice);
        vm.expectRevert(Tribunal.BettingClosed.selector);
        tribunal.betNo(id, 100 ether);
        _assertSolvent();
    }

    function test_failedDepositsRollbackEverything() public {
        uint256 id = _create();
        verdict.setReject(true);
        vm.prank(alice);
        vm.expectRevert("token rejected transfer");
        tribunal.betYes(id, 100 ether);
        assertEq(tribunal.getMarket(id).yesPool, 0);
        assertEq(tribunal.verdictLiability(), 10_000 ether);
        verdict.setReject(false);
        imd.setReject(true);
        vm.prank(creator);
        vm.expectRevert("token rejected transfer");
        tribunal.createMarket(
            "other", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
        assertEq(tribunal.marketCount(), 1);
        assertEq(verdict.balanceOf(creator), 990_000 ether);
        _assertSolvent();
    }

    function test_taxedDepositRejectedRatherThanInsolvent() public {
        uint256 id = _create();
        verdict.setTax(1 ether);
        vm.prank(alice);
        vm.expectRevert(Tribunal.UnexpectedTokenAmount.selector);
        tribunal.betYes(id, 100 ether);
        assertEq(tribunal.getMarket(id).yesPool, 0);
        _assertSolvent();
    }

    function test_depositReentrancyIsBlocked() public {
        uint256 id = _create();
        verdict.setHook(address(tribunal), alice, abi.encodeCall(tribunal.betYes, (id, 100 ether)));
        _bet(id, alice, true, 100 ether);
        assertTrue(verdict.hookAttempted());
        assertFalse(verdict.hookSucceeded());
        assertEq(bytes4(verdict.hookReturn()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(tribunal.getMarket(id).yesPool, 100 ether);
        _assertSolvent();
    }

    function test_requestTimingAndExactV2PaymentAndCallbacks() public {
        uint256 id = _createContested();
        vm.expectRevert(Tribunal.TooEarly.selector);
        tribunal.requestResolution(id);
        bytes32 rid = _request(id);
        MockIntake.Ask memory ask = intake.getAsk(rid);
        assertEq(ask.payer, address(tribunal));
        assertEq(ask.callback.target, address(tribunal));
        assertEq(ask.callback.selector, tribunal.onOracleResult.selector);
        assertEq(ask.failure, tribunal.onOracleFailure.selector);
        assertEq(ask.action, ACTION);
        assertEq(ask.body, BODY);
        assertEq(ask.asset, address(imd));
        assertEq(ask.amount, 0.5 ether);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(imd.allowance(address(tribunal), address(intake)), 0);
        assertEq(tribunal.requestMarket(address(intake), rid), id);
        assertEq(tribunal.getMarket(id).deadline, vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.requestResolution(id);
        vm.expectRevert(Tribunal.WrongState.selector);
        tribunal.betYes(id, 100 ether);
        _assertSolvent();
    }

    function test_intakeFailureAndPriceChangeDoNotLockFunds() public {
        uint256 id = _createContested();
        vm.warp(tribunal.getMarket(id).resolveAfter);
        intake.setReject(true);
        vm.expectRevert("Intake unavailable");
        tribunal.requestResolution(id);
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Open));
        assertFalse(tribunal.getMarket(id).oracleSpent);
        assertEq(imd.allowance(address(tribunal), address(intake)), 0);
        intake.setReject(false);
        intake.setPrice(1 ether);
        vm.expectRevert("wrong payment");
        tribunal.requestResolution(id);
        vm.prank(creator);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.createMarket(
            "other", BODY, uint64(vm.getBlockTimestamp() + 1 days), uint64(vm.getBlockTimestamp() + 2 days)
        );
        vm.warp(tribunal.getMarket(id).deadline);
        tribunal.voidMarket(id);
        _claim(id, creator);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(verdict.balanceOf(creator), 1_000_000 ether);
        _assertSolvent();
    }

    function test_zeroCollidingAndUnpaidRequestIdsRollback() public {
        uint256 id = _createContested();
        uint256 id2 = _createContested();
        vm.warp(tribunal.getMarket(id).resolveAfter);
        intake.setForcedId(bytes32(0));
        vm.expectRevert(Tribunal.InvalidRequestId.selector);
        tribunal.requestResolution(id);
        intake.setForcedId(bytes32(uint256(123)));
        tribunal.requestResolution(id);
        vm.expectRevert(Tribunal.InvalidRequestId.selector);
        tribunal.requestResolution(id2);
        assertEq(uint256(tribunal.getMarket(id2).state), uint256(Tribunal.State.Open));
        intake.setForcedId(bytes32(uint256(456)));
        intake.setSkipPull(true);
        vm.expectRevert(Tribunal.UnexpectedTokenAmount.selector);
        tribunal.requestResolution(id2);
        _assertSolvent();
    }

    function test_configurationIsOwnerOnlyAndCannotRewriteExistingMarket() public {
        uint256 id = _createContested();
        MockIntake replacement = new MockIntake();
        MockToken replacementAsset = new MockToken();
        vm.startPrank(alice);
        vm.expectRevert();
        tribunal.setIntake(address(replacement));
        vm.expectRevert();
        tribunal.setAction(bytes32("other"));
        vm.expectRevert();
        tribunal.setPayment(address(replacementAsset), 0.5 ether);
        vm.expectRevert();
        tribunal.setOracleSigner(alice);
        vm.expectRevert();
        tribunal.cancelSignerChange();
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setIntake(address(0));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setAction(bytes32(0));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setPayment(address(0), 1);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setPayment(address(imd), 0);
        tribunal.setIntake(address(replacement));
        tribunal.setAction(bytes32("other"));
        tribunal.setPayment(address(replacementAsset), 0.5 ether);
        vm.stopPrank();
        vm.warp(tribunal.configActivateAfter());
        tribunal.activateOracleConfig();
        bytes32 rid = _request(id);
        assertEq(intake.getAsk(rid).body, BODY);
        assertEq(replacement.nonce(), 0);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        _assertSolvent();
    }

    function test_ownerHasNoWithdrawOrResolutionEntrypoint() public {
        uint256 id = _create();
        vm.startPrank(owner);
        (bool withdrew,) = address(tribunal)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(verdict), owner, 10_000 ether));
        (bool resolved,) = address(tribunal).call(abi.encodeWithSignature("resolveMarket(uint256,bool)", id, true));
        assertFalse(withdrew);
        assertFalse(resolved);
        vm.expectRevert(Tribunal.TooEarly.selector);
        tribunal.voidMarket(id);
        vm.stopPrank();
        _assertSolvent();
    }

    function test_ownerTransferNeedsAcceptanceAndDoesNotMoveFunds() public {
        vm.prank(owner);
        tribunal.transferOwnership(alice);
        assertEq(tribunal.owner(), owner);
        assertEq(tribunal.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert();
        tribunal.acceptOwnership();
        vm.prank(alice);
        tribunal.acceptOwnership();
        assertEq(tribunal.owner(), alice);
        _assertSolvent();
    }

    function test_pendingOwnershipTransferDoesNotBlockInitialTokenSetup() public {
        Tribunal fresh = new Tribunal(owner, address(intake), address(imd), ACTION, 0.5 ether, vm.addr(SIGNER_KEY));
        vm.prank(owner);
        fresh.transferOwnership(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setVerdictToken(address(verdict));
        vm.prank(owner);
        fresh.setVerdictToken(address(verdict));
        assertEq(address(fresh.verdictToken()), address(verdict));
        assertEq(fresh.owner(), owner);
        assertEq(fresh.pendingOwner(), alice);
    }
}
