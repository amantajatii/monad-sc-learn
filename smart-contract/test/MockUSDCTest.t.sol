// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;
    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC(1_000_000e6);
    }

    function test_Metadata() public view {
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
    }

    function test_InitialSupplyMintedToDeployer() public view {
        assertEq(usdc.totalSupply(), 1_000_000e6);
        assertEq(usdc.balanceOf(address(this)), 1_000_000e6);
    }

    function test_OwnerCanMint() public {
        usdc.mint(alice, 250e6);
        assertEq(usdc.balanceOf(alice), 250e6);
        assertEq(usdc.totalSupply(), 1_000_250e6);
    }

    function test_NonOwnerCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        usdc.mint(alice, 1e6);
    }
}
