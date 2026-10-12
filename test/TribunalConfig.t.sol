// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "../src/Tribunal.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TribunalFixture} from "./helpers/TribunalFixture.sol";
import {MockIntake, MockToken} from "./helpers/Mocks.sol";

contract TribunalConfigTest is TribunalFixture {
    function test_intakeChangeCannotRedirectNewMarketsOrAuthenticateResultOrFailure() public {
        MockIntake replacement = new MockIntake();
        vm.prank(owner);
        tribunal.setIntake(address(replacement));
        uint256 id = _createContested();
        assertEq(tribunal.getMarket(id).oracle.intake, address(intake));

        // Activating later must not change the market created in the scheduling block.
        vm.warp(tribunal.configActivateAfter());
        vm.prank(carol);
        tribunal.activateOracleConfig();
        bytes32 rid = tribunal.requestResolution(id);
        assertEq(imd.balanceOf(address(replacement)), 0);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);

        OracleAttestation.Attestation memory a = _attestation(keccak256("unrelated purchased answer"), false);
        bytes memory signature = _sign(a);
        vm.prank(address(replacement));
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleResult(rid, a, signature);
        vm.prank(address(replacement));
        vm.expectRevert(Tribunal.NotTheIntake.selector);
        tribunal.onOracleFailure(rid, 2, bytes32("disagreed"), 3, 5, "");
        vm.expectRevert(Tribunal.UnboundAttestation.selector);
        tribunal.submitAttestation(id, a, signature);
        assertEq(uint256(tribunal.getMarket(id).state), uint256(Tribunal.State.Pending));
        assertEq(tribunal.getMarket(id).boundDigest, bytes32(0));
        assertFalse(tribunal.consumed(a.requestId));
        _assertSolvent();
    }

    function test_configIsPublicFor48HoursAndActivatesOnlyExplicitlyForFutureMarkets() public {
        MockIntake replacement = new MockIntake();
        MockToken asset = new MockToken();
        replacement.setPrice(0.6 ether);
        uint64 activateAfter = uint64(vm.getBlockTimestamp() + 48 hours);
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit Tribunal.OracleConfigScheduled(address(replacement), address(imd), ACTION, 0.5 ether, activateAfter);
        tribunal.setIntake(address(replacement));
        tribunal.setAction(bytes32("oracle.request@oracle-2"));
        tribunal.setPayment(address(asset), 0.6 ether);
        vm.stopPrank();
        (address nextIntake, address nextAsset, bytes32 nextAction, uint256 nextPrice) = tribunal.pendingOracleConfig();
        assertEq(nextIntake, address(replacement));
        assertEq(nextAsset, address(asset));
        assertEq(nextAction, bytes32("oracle.request@oracle-2"));
        assertEq(nextPrice, 0.6 ether);
        assertEq(tribunal.configActivateAfter(), activateAfter);

        _assertOriginalConfig();
        vm.warp(activateAfter - 1);
        vm.expectRevert(Tribunal.ConfigDelayPending.selector);
        tribunal.activateOracleConfig();
        uint256 beforeId = _create();
        vm.warp(activateAfter);
        _assertOriginalConfig(); // Maturity alone does not activate the schedule.
        vm.prank(alice);
        tribunal.activateOracleConfig();
        assertEq(tribunal.configActivateAfter(), 0);
        (nextIntake, nextAsset, nextAction, nextPrice) = tribunal.pendingOracleConfig();
        assertEq(nextIntake, address(0));
        assertEq(nextAsset, address(0));
        assertEq(nextAction, bytes32(0));
        assertEq(nextPrice, 0);
        vm.expectRevert(Tribunal.NoPendingConfig.selector);
        tribunal.activateOracleConfig();

        asset.mint(creator, 0.6 ether);
        vm.prank(creator);
        asset.approve(address(tribunal), 0.6 ether);
        uint256 afterId = _createContested();
        Tribunal.Market memory beforeMarket = tribunal.getMarket(beforeId);
        Tribunal.Market memory afterMarket = tribunal.getMarket(afterId);
        assertEq(beforeMarket.oracle.intake, address(intake));
        assertEq(beforeMarket.oracle.asset, address(imd));
        assertEq(beforeMarket.oracle.action, ACTION);
        assertEq(beforeMarket.oracle.price, 0.5 ether);
        assertEq(afterMarket.oracle.intake, address(replacement));
        assertEq(afterMarket.oracle.asset, address(asset));
        assertEq(afterMarket.oracle.action, bytes32("oracle.request@oracle-2"));
        assertEq(afterMarket.oracle.price, 0.6 ether);
        bytes32 rid = _request(afterId);
        assertEq(replacement.getAsk(rid).action, afterMarket.oracle.action);
        assertEq(asset.balanceOf(address(replacement)), 0.6 ether);
        assertEq(tribunal.oracleEscrow(address(asset)), 0);
        assertEq(tribunal.oracleEscrow(address(imd)), 0.5 ether);
        assertEq(intake.nonce(), 0);
        _assertSolvent();
    }

    function test_eachEditRestartsTheWholeDelayAndPreservesOtherPendingFields() public {
        MockIntake replacement = new MockIntake();
        uint256 start = vm.getBlockTimestamp();
        vm.prank(owner);
        tribunal.setIntake(address(replacement));
        vm.warp(start + 47 hours);
        vm.prank(owner);
        tribunal.setAction(bytes32("next-action"));
        assertEq(tribunal.configActivateAfter(), start + 95 hours);
        vm.warp(start + 48 hours);
        vm.expectRevert(Tribunal.ConfigDelayPending.selector);
        tribunal.activateOracleConfig();
        vm.warp(start + 94 hours);
        vm.prank(owner);
        tribunal.setPayment(address(imd), 0.6 ether);
        assertEq(tribunal.configActivateAfter(), start + 142 hours);
        vm.warp(start + 95 hours);
        vm.expectRevert(Tribunal.ConfigDelayPending.selector);
        tribunal.activateOracleConfig();
        _assertOriginalConfig();
        vm.warp(start + 142 hours);
        tribunal.activateOracleConfig();
        (address nextIntake,, bytes32 nextAction, uint256 nextPrice) = tribunal.oracleConfig();
        assertEq(nextIntake, address(replacement));
        assertEq(nextAction, bytes32("next-action"));
        assertEq(nextPrice, 0.6 ether);
    }

    function test_cancelIsOwnerOnlyAndNextScheduleStartsFromActiveConfig() public {
        vm.expectRevert(Tribunal.NoPendingConfig.selector);
        tribunal.activateOracleConfig();
        vm.prank(owner);
        vm.expectRevert(Tribunal.NoPendingConfig.selector);
        tribunal.cancelOracleConfigChange();
        MockIntake replacement = new MockIntake();
        vm.prank(owner);
        tribunal.setIntake(address(replacement));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        tribunal.cancelOracleConfigChange();
        vm.warp(tribunal.configActivateAfter());
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit Tribunal.OracleConfigScheduleCancelled();
        tribunal.cancelOracleConfigChange();
        vm.expectRevert(Tribunal.NoPendingConfig.selector);
        tribunal.activateOracleConfig();
        _assertOriginalConfig();
        vm.prank(owner);
        tribunal.setPayment(address(imd), 0.6 ether);
        (address nextIntake,, bytes32 nextAction, uint256 nextPrice) = tribunal.pendingOracleConfig();
        assertEq(nextIntake, address(intake));
        assertEq(nextAction, ACTION);
        assertEq(nextPrice, 0.6 ether);
        assertEq(tribunal.configActivateAfter(), vm.getBlockTimestamp() + 48 hours);
    }

    function test_invalidEditCannotCorruptOrDelayPendingConfig() public {
        vm.prank(owner);
        tribunal.setPayment(address(imd), 0.6 ether);
        uint64 activateAfter = tribunal.configActivateAfter();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(owner);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setIntake(address(0));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setAction(bytes32(0));
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setPayment(address(0), 1);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        tribunal.setPayment(address(imd), 0);
        vm.stopPrank();
        assertEq(tribunal.configActivateAfter(), activateAfter);
        (address nextIntake, address nextAsset, bytes32 nextAction, uint256 nextPrice) = tribunal.pendingOracleConfig();
        assertEq(nextIntake, address(intake));
        assertEq(nextAsset, address(imd));
        assertEq(nextAction, ACTION);
        assertEq(nextPrice, 0.6 ether);
    }

    function test_priceMoveCanBeConfiguredWithoutRedeployAfterDelay() public {
        intake.setPrice(0.6 ether);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        _create();
        vm.prank(owner);
        tribunal.setPayment(address(imd), 0.6 ether);
        vm.expectRevert(Tribunal.InvalidConfiguration.selector);
        _create();
        vm.warp(tribunal.configActivateAfter());
        tribunal.activateOracleConfig();
        uint256 id = _createContested();
        _request(id);
        assertEq(imd.balanceOf(address(intake)), 0.6 ether);
        assertEq(imd.balanceOf(creator), 99.4 ether);
        _assertSolvent();
    }

    function _assertOriginalConfig() private view {
        (address activeIntake, address activeAsset, bytes32 activeAction, uint256 activePrice) = tribunal.oracleConfig();
        assertEq(activeIntake, address(intake));
        assertEq(activeAsset, address(imd));
        assertEq(activeAction, ACTION);
        assertEq(activePrice, 0.5 ether);
    }
}
