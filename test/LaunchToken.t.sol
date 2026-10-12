// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address alice = address(0xA1);
    address bob = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_supplyMetadataAndFactoryBalance() public view {
        assertEq(token.name(), "Verdict");
        assertEq(token.symbol(), "VERDICT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferAndAllowancePreserveSupply() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 40 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
    }

    function test_failureInsufficientBalanceAndZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function test_noMintOwnerPauseOrUpgradeEntryPoints() public {
        string[5] memory selectors = [
            "mint(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool called,) = address(token).call(abi.encodeWithSignature(selectors[i], alice, 1 ether));
            assertFalse(called);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_transferIsExact(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        uint256 supply = token.totalSupply();
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), supply - amount);
        assertEq(token.totalSupply(), supply);
    }
}
