// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OneStrokeTradeRegistry} from "../src/OneStrokeTradeRegistry.sol";

contract Deploy is Script {
    uint256 internal constant INITIAL_SUPPLY = 10_000_000e6;
    uint256 internal constant TREASURY_SEED = 1_000_000e6;
    address internal constant PYTH_MONAD_TESTNET = 0x2880aB155794e7179c9eE2e38200202908C17B43;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        MockUSDC usdc = new MockUSDC(INITIAL_SUPPLY);
        OneStrokeTradeRegistry implementation = new OneStrokeTradeRegistry();
        bytes memory initData =
            abi.encodeCall(OneStrokeTradeRegistry.initialize, (deployer, address(usdc), PYTH_MONAD_TESTNET));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        OneStrokeTradeRegistry registry = OneStrokeTradeRegistry(address(proxy));

        registry.grantRole(registry.EXECUTOR_ROLE(), deployer);
        usdc.approve(address(registry), TREASURY_SEED);
        registry.seedTreasury(TREASURY_SEED);

        vm.stopBroadcast();

        console2.log("MockUSDC deployed at:", address(usdc));
        console2.log("OneStrokeTradeRegistry implementation:", address(implementation));
        console2.log("OneStrokeTradeRegistry proxy:", address(registry));
        console2.log("Pyth contract:", PYTH_MONAD_TESTNET);
        console2.log("EXECUTOR_ROLE granted to deployer:", deployer);
        console2.log("Treasury seeded with:", TREASURY_SEED);
        console2.log("Next step: call setPriceFeed for each asset with its Pyth feed ID on Monad testnet");
    }
}
