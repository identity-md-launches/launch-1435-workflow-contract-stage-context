// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Tribunal} from "../src/Tribunal.sol";

contract LocalFactory {
    function deployToken() external returns (LaunchToken) {
        return new LaunchToken();
    }

    function deployTribunal(address owner, address intake, address asset, bytes32 action, uint256 price, address signer)
        external
        returns (Tribunal)
    {
        return new Tribunal(owner, intake, asset, action, price, signer);
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentLeavesTokenSupplyUntouchedAndExplicitOwnerInControl() public {
        LocalFactory factory = new LocalFactory();
        LaunchToken token = factory.deployToken();
        // The real Ethereum constructor arguments, with dependencies absent on this test chain.
        address owner = 0x152D7FBf16aDF2a5104D2d11bfDcc951254F746B;
        Tribunal tribunal = factory.deployTribunal(
            owner,
            0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
            0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
            bytes32("oracle.request@oracle-1"),
            500_000_000_000_000_000,
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982
        );
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), token.totalSupply());
        assertEq(token.balanceOf(address(tribunal)), 0);
        assertEq(tribunal.owner(), owner);
        vm.prank(address(factory));
        vm.expectRevert();
        tribunal.setVerdictToken(address(token));
        vm.prank(owner);
        tribunal.setVerdictToken(address(token));
        assertEq(address(tribunal.verdictToken()), address(token));
        _checkRuntime(address(token));
        _checkRuntime(address(tribunal));
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
