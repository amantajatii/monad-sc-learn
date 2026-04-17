// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {OneStrokeTradeRegistry} from "../src/OneStrokeTradeRegistry.sol";

contract Upgrade is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("ONESTROKE_REGISTRY_PROXY");

        vm.startBroadcast(deployerPrivateKey);

        OneStrokeTradeRegistry newImplementation = new OneStrokeTradeRegistry();
        OneStrokeTradeRegistry registry = OneStrokeTradeRegistry(proxy);
        registry.upgradeToAndCall(address(newImplementation), "");

        vm.stopBroadcast();

        console2.log("New implementation deployed at:", address(newImplementation));
        console2.log("Proxy upgraded:", proxy);
        console2.log("Treasury balance preserved:", registry.getTreasuryBalance());
        console2.log("Total trades preserved:", registry.totalTrades());
    }
}
