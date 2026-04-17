// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OneStrokeTradeRegistry} from "../src/OneStrokeTradeRegistry.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract OneStrokeTradeRegistryFuzzTest is Test {
    MockUSDC internal usdc;
    MockPyth internal pyth;
    OneStrokeTradeRegistry internal registry;

    address internal alice = address(0xA11CE);
    address internal executor = address(0xE11E);

    bytes32 internal constant ETH_FEED_ID = keccak256("ETH/USD");
    uint256 internal constant INITIAL_DEPLOYER_BALANCE = 5_000_000e6;
    uint256 internal constant INITIAL_ALICE_BALANCE = 1_000_000e6;
    uint256 internal constant SEEDED_TREASURY = 1_000_000e6;

    function setUp() public {
        usdc = new MockUSDC(INITIAL_DEPLOYER_BALANCE);
        pyth = new MockPyth();
        pyth.setPrice(ETH_FEED_ID, int64(int256(2_000e8)), -8, block.timestamp);

        OneStrokeTradeRegistry implementation = new OneStrokeTradeRegistry();
        bytes memory initData =
            abi.encodeCall(OneStrokeTradeRegistry.initialize, (address(this), address(usdc), address(pyth)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        registry = OneStrokeTradeRegistry(address(proxy));

        registry.setPriceFeed("ETH", ETH_FEED_ID);

        usdc.approve(address(registry), SEEDED_TREASURY);
        registry.seedTreasury(SEEDED_TREASURY);

        usdc.mint(alice, INITIAL_ALICE_BALANCE);
        vm.prank(alice);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.deposit(INITIAL_ALICE_BALANCE);

        registry.grantRole(registry.EXECUTOR_ROLE(), executor);
    }

    function testFuzz_CreateTradeAccountingConserved(uint256 seed, uint8 rawTradeCount) public {
        uint256 tradeCount = bound(uint256(rawTradeCount), 1, 12);

        for (uint256 i = 0; i < tradeCount; ++i) {
            uint256 salt = uint256(keccak256(abi.encode(seed, i)));
            bool isLong = salt & 1 == 0;
            uint256 stakeAmount = bound((salt >> 8) % 50_000e6, 1e6, 5_000e6);
            uint256 duration = bound((salt >> 24) % 1 days, registry.MIN_DURATION(), registry.MAX_DURATION());

            uint256 tradeId = _createTrade(isLong, stakeAmount, duration);

            uint256 action = (salt >> 40) % 3;
            if (action == 0) {
                vm.prank(alice);
                registry.cancelTrade(tradeId);
            } else {
                uint256 price = _settlementPriceForAction(isLong, action);
                vm.prank(executor);
                registry.executorForceSettle(tradeId, price);
            }
        }

        uint256 openEscrow;
        for (uint256 tradeId = 1; tradeId <= registry.totalTrades(); ++tradeId) {
            OneStrokeTradeRegistry.Trade memory trade = registry.getTrade(tradeId);
            if (trade.status == OneStrokeTradeRegistry.Status.OPEN) openEscrow += trade.stakeAmount;
        }

        uint256 registryBalance = usdc.balanceOf(address(registry));
        assertEq(registryBalance, openEscrow + registry.getTreasuryBalance() + registry.getUserBalance(alice));

        uint256[] memory tradeIds = registry.getTradesByUser(alice);
        assertEq(tradeIds.length, tradeCount);

        uint256 totalTracked =
            usdc.balanceOf(address(this)) + usdc.balanceOf(alice) + usdc.balanceOf(address(registry));
        assertEq(totalTracked, usdc.totalSupply());
    }

    function testFuzz_ExecutorSettlementStatusMatchesRules(
        bool isLong,
        uint256 rawPrice,
        uint256 rawDuration,
        bool shouldExpire
    ) public {
        uint256 duration = bound(rawDuration, registry.MIN_DURATION(), registry.MAX_DURATION());
        uint256 tradeId = _createTrade(isLong, 1_000e6, duration);

        uint256 marketPrice = bound(rawPrice, 1, type(uint64).max);

        if (shouldExpire) {
            vm.warp(block.timestamp + duration + 1);
            vm.prank(executor);
            registry.executorForceSettle(tradeId, marketPrice);
            assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.EXPIRED));
            return;
        }

        bool shouldTp;
        bool shouldSl;
        if (isLong) {
            shouldTp = marketPrice >= 2_100e8;
            shouldSl = marketPrice <= 1_900e8;
        } else {
            shouldTp = marketPrice <= 1_900e8;
            shouldSl = marketPrice >= 2_100e8;
        }

        vm.prank(executor);
        if (!shouldTp && !shouldSl) {
            vm.expectRevert(OneStrokeTradeRegistry.NoSettlementConditionMet.selector);
            registry.executorForceSettle(tradeId, marketPrice);
            assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.OPEN));
        } else {
            registry.executorForceSettle(tradeId, marketPrice);
            OneStrokeTradeRegistry.Status expected =
                shouldTp ? OneStrokeTradeRegistry.Status.HIT_TP : OneStrokeTradeRegistry.Status.HIT_SL;
            assertEq(uint8(registry.getTrade(tradeId).status), uint8(expected));
        }
    }

    function _createTrade(bool isLong, uint256 stakeAmount, uint256 duration) internal returns (uint256) {
        vm.prank(alice);
        return registry.createTrade(
            "ETH",
            isLong ? OneStrokeTradeRegistry.Direction.LONG : OneStrokeTradeRegistry.Direction.SHORT,
            2_000e8,
            isLong ? 1_800e8 : 2_100e8,
            isLong ? 1_900e8 : 2_200e8,
            isLong ? 2_100e8 : 1_800e8,
            isLong ? 2_200e8 : 1_900e8,
            block.timestamp + duration,
            stakeAmount
        );
    }

    function _settlementPriceForAction(bool isLong, uint256 action) internal pure returns (uint256) {
        if (action == 1) return isLong ? 2_150e8 : 1_850e8;
        return isLong ? 1_850e8 : 2_150e8;
    }
}
