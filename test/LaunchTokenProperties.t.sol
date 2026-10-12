// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    LaunchToken internal token;
    address internal holder;
    address internal recipient;
    address internal spender;

    function setUp() public {
        token = new LaunchToken();
        holder = makeAddr("VERDICT holder");
        recipient = makeAddr("VERDICT recipient");
        spender = makeAddr("VERDICT spender");
        token.transfer(holder, SUPPLY);
    }

    function testFuzz_transferAndReturnPreserveBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        vm.prank(recipient);
        assertTrue(token.transfer(holder, amount));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_finiteAndInfiniteAllowancesSpendOnlyAuthorizedTokens(
        uint256 amount,
        uint256 approval,
        bool infinite
    ) public {
        amount = bound(amount, 0, SUPPLY);
        approval = infinite ? type(uint256).max : bound(approval, amount, SUPPLY);
        vm.prank(holder);
        assertTrue(token.approve(spender, approval));
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, amount));
        assertEq(token.allowance(holder, spender), infinite ? type(uint256).max : approval - amount);
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientAllowanceCannotMoveTokensOrConsumeApproval(uint256 amount, uint256 approval) public {
        amount = bound(amount, 1, SUPPLY);
        approval = bound(approval, 0, amount - 1);
        vm.prank(holder);
        token.approve(spender, approval);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", spender, approval, amount)
        );
        token.transferFrom(holder, recipient, amount);
        assertEq(token.allowance(holder, spender), approval);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_failedTransferFromRollsBackFiniteAllowanceThenRevocationTakesEffect() public {
        vm.startPrank(holder);
        token.approve(spender, SUPPLY + 1);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", holder, SUPPLY, SUPPLY + 1)
        );
        token.transferFrom(holder, recipient, SUPPLY + 1);
        assertEq(token.allowance(holder, spender), SUPPLY + 1);
        vm.prank(holder);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_zeroOneWeiFullSupplyAndSelfTransfers() public {
        vm.startPrank(holder);
        assertTrue(token.transfer(holder, SUPPLY));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertTrue(token.transfer(recipient, 0));
        assertTrue(token.transfer(recipient, 1));
        assertEq(token.balanceOf(recipient), 1);
        assertTrue(token.transfer(recipient, SUPPLY - 1));
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", holder, 0, 1));
        token.transfer(recipient, 1);
        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", recipient, SUPPLY, type(uint256).max
            )
        );
        token.transfer(holder, type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(recipient), SUPPLY);
    }

    function test_zeroAddressesRejectWithoutBurningOrSpendingAllowance() public {
        vm.prank(holder);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        token.transferFrom(holder, address(0), 1);
        assertEq(token.allowance(holder, spender), 1);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidSpender(address)", address(0)));
        token.approve(address(0), 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
