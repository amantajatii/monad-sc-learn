// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OneStrokeTradeRegistry} from "../src/OneStrokeTradeRegistry.sol";

contract TestGoldsky is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proxyAddr = vm.envAddress("ONESTROKE_REGISTRY_PROXY");
        address usdcAddr = vm.envAddress("MOCK_USDC_ADDRESS");

        OneStrokeTradeRegistry registry = OneStrokeTradeRegistry(proxyAddr);
        IERC20 usdc = IERC20(usdcAddr);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Approve + Deposit 1000 USDC
        uint256 depositAmount = 1_000e6;
        usdc.approve(proxyAddr, depositAmount);
        registry.deposit(depositAmount);
        console2.log("Deposited:", depositAmount);
        console2.log("User balance after deposit:", registry.getUserBalance(deployer));

        // 2. Create a LONG ETH trade
        uint256 tradeId = registry.createTrade(
            "ETH",
            OneStrokeTradeRegistry.Direction.LONG,
            2_000e8,      // entryPrice
            1_800e8,      // stopLossLower
            1_900e8,      // stopLossUpper
            2_100e8,      // takeProfitLower
            2_200e8,      // takeProfitUpper
            block.timestamp + 1 hours,
            500e6          // stake 500 USDC
        );
        console2.log("Trade created, ID:", tradeId);
        console2.log("User balance after trade:", registry.getUserBalance(deployer));

        vm.stopBroadcast();

        console2.log("--- Check Goldsky for UserDeposited + TradeCreated events ---");
    }
}
