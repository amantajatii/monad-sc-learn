// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OneStrokeTradeRegistry} from "../src/OneStrokeTradeRegistry.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {OneStrokeTradeRegistryV2} from "./mocks/OneStrokeTradeRegistryV2.sol";

contract OneStrokeTradeRegistryTest is Test {
    MockUSDC internal usdc;
    MockPyth internal pyth;
    OneStrokeTradeRegistry internal registry;
    OneStrokeTradeRegistry internal implementation;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal executor = address(0xE11E);

    bytes32 internal constant ETH_FEED_ID = keccak256("ETH/USD");
    bytes32 internal constant BTC_FEED_ID = keccak256("BTC/USD");
    bytes32 internal constant MON_FEED_ID = keccak256("MON/USD");
    bytes32 internal constant ETH6_FEED_ID = keccak256("ETH6/USD");
    bytes32 internal constant ETH18_FEED_ID = keccak256("ETH18/USD");

    uint256 internal constant INITIAL_USER_BALANCE = 50_000e6;
    uint256 internal constant SEEDED_TREASURY = 1_000_000e6;
    uint256 internal constant ENTRY = 2_000e8;
    uint256 internal constant STAKE = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC(20_000_000e6);
        pyth = new MockPyth();
        _setPrice(ETH_FEED_ID, 2_000e8, -8, block.timestamp);
        _setPrice(BTC_FEED_ID, 30_000e8, -8, block.timestamp);
        _setPrice(MON_FEED_ID, 100e8, -8, block.timestamp);

        implementation = new OneStrokeTradeRegistry();
        bytes memory initData =
            abi.encodeCall(OneStrokeTradeRegistry.initialize, (address(this), address(usdc), address(pyth)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        registry = OneStrokeTradeRegistry(address(proxy));

        registry.setPriceFeed("ETH", ETH_FEED_ID);
        registry.setPriceFeed("BTC", BTC_FEED_ID);
        registry.setPriceFeed("MON", MON_FEED_ID);

        usdc.approve(address(registry), SEEDED_TREASURY);
        registry.seedTreasury(SEEDED_TREASURY);

        usdc.mint(alice, INITIAL_USER_BALANCE);
        usdc.mint(bob, INITIAL_USER_BALANCE);

        vm.prank(alice);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.deposit(INITIAL_USER_BALANCE);

        vm.prank(bob);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(bob);
        registry.deposit(INITIAL_USER_BALANCE);

        registry.grantRole(registry.EXECUTOR_ROLE(), executor);
    }

    function test_InitializeCannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(this), address(usdc), address(pyth));
    }

    function test_CreateLongTradeWithStake() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        OneStrokeTradeRegistry.Trade memory trade = registry.getTrade(tradeId);

        assertEq(trade.tradeId, 1);
        assertEq(trade.creator, alice);
        assertEq(trade.asset, "ETH");
        assertEq(uint8(trade.direction), uint8(OneStrokeTradeRegistry.Direction.LONG));
        assertEq(trade.entryPrice, ENTRY);
        assertEq(trade.stakeAmount, STAKE);
        assertEq(uint8(trade.status), uint8(OneStrokeTradeRegistry.Status.OPEN));
        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE - STAKE);
    }

    function test_CreateShortTradeWithStake() public {
        uint256 tradeId = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 2 hours);
        OneStrokeTradeRegistry.Trade memory trade = registry.getTrade(tradeId);

        assertEq(trade.tradeId, 1);
        assertEq(trade.asset, "BTC");
        assertEq(uint8(trade.direction), uint8(OneStrokeTradeRegistry.Direction.SHORT));
        assertEq(trade.stakeAmount, STAKE);
    }

    function test_DepositAndWithdrawFlow() public {
        address carol = address(0xCAFE);
        usdc.mint(carol, 2_000e6);

        vm.startPrank(carol);
        usdc.approve(address(registry), type(uint256).max);
        registry.deposit(2_000e6);
        registry.withdraw(500e6);
        vm.stopPrank();

        assertEq(registry.getUserBalance(carol), 1_500e6);
        assertEq(usdc.balanceOf(carol), 500e6);
    }

    function test_RevertUnregisteredAsset() public {
        vm.prank(alice);
        vm.expectRevert(OneStrokeTradeRegistry.InvalidAsset.selector);
        registry.createTrade(
            "DOGE",
            OneStrokeTradeRegistry.Direction.LONG,
            ENTRY,
            1_800e8,
            1_900e8,
            2_100e8,
            2_200e8,
            block.timestamp + 1 hours,
            STAKE
        );
    }

    function test_RevertExpiryTooShort() public {
        vm.prank(alice);
        vm.expectRevert(OneStrokeTradeRegistry.InvalidExpiry.selector);
        registry.createTrade(
            "ETH",
            OneStrokeTradeRegistry.Direction.LONG,
            ENTRY,
            1_800e8,
            1_900e8,
            2_100e8,
            2_200e8,
            block.timestamp + 59,
            STAKE
        );
    }

    function test_RevertExpiryTooLong() public {
        vm.prank(alice);
        vm.expectRevert(OneStrokeTradeRegistry.InvalidExpiry.selector);
        registry.createTrade(
            "ETH",
            OneStrokeTradeRegistry.Direction.LONG,
            ENTRY,
            1_800e8,
            1_900e8,
            2_100e8,
            2_200e8,
            block.timestamp + 24 hours + 1,
            STAKE
        );
    }

    function test_RevertZeroStake() public {
        vm.prank(alice);
        vm.expectRevert(OneStrokeTradeRegistry.InvalidStakeAmount.selector);
        registry.createTrade(
            "ETH",
            OneStrokeTradeRegistry.Direction.LONG,
            ENTRY,
            1_800e8,
            1_900e8,
            2_100e8,
            2_200e8,
            block.timestamp + 1 hours,
            0
        );
    }

    function test_RevertInvalidLongZones() public {
        vm.prank(alice);
        vm.expectRevert(OneStrokeTradeRegistry.InvalidDirectionZones.selector);
        registry.createTrade(
            "ETH",
            OneStrokeTradeRegistry.Direction.LONG,
            ENTRY,
            1_800e8,
            1_900e8,
            1_900e8,
            1_950e8,
            block.timestamp + 1 hours,
            STAKE
        );
    }

    function test_RevertInvalidShortZones() public {
        vm.prank(alice);
        vm.expectRevert(OneStrokeTradeRegistry.InvalidDirectionZones.selector);
        registry.createTrade(
            "BTC",
            OneStrokeTradeRegistry.Direction.SHORT,
            30_000e8,
            29_000e8,
            29_500e8,
            28_000e8,
            29_000e8,
            block.timestamp + 1 hours,
            STAKE
        );
    }

    function test_CancelOwnTradeReturnsFullStake() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);

        vm.prank(alice);
        registry.cancelTrade(tradeId);

        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE);
        assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.CANCELLED));
    }

    function test_CancelNonOwnerReverts() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);

        vm.prank(bob);
        vm.expectRevert(OneStrokeTradeRegistry.NotTradeCreator.selector);
        registry.cancelTrade(tradeId);
    }

    function test_SettleLongHitTp() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);

        registry.settleTrade(tradeId, _emptyUpdates());

        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE + 100e6);
        assertEq(registry.getTreasuryBalance(), SEEDED_TREASURY - 100e6);
        (uint256 wins, uint256 losses, uint256 settled, int256 netPnl) = registry.getUserStats(alice);
        assertEq(wins, 1);
        assertEq(losses, 0);
        assertEq(settled, 1);
        assertEq(netPnl, int256(100e6));
    }

    function test_SettleLongHitSl() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 1_850e8, -8, block.timestamp);

        registry.settleTrade(tradeId, _emptyUpdates());

        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE - 500e6);
        assertEq(registry.getTreasuryBalance(), SEEDED_TREASURY + 500e6);
    }

    function test_SettleShortHitTpMirrored() public {
        uint256 tradeId = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);
        _setPrice(BTC_FEED_ID, 28_500e8, -8, block.timestamp);

        registry.settleTrade(tradeId, _emptyUpdates());

        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE + 100e6);
        assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.HIT_TP));
    }

    function test_SettleShortHitSlMirrored() public {
        uint256 tradeId = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);
        _setPrice(BTC_FEED_ID, 31_500e8, -8, block.timestamp);

        registry.settleTrade(tradeId, _emptyUpdates());

        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE - 500e6);
        assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.HIT_SL));
    }

    function test_SettleExpiredReturnsFullRefund() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 60);
        vm.warp(block.timestamp + 61);

        registry.settleTrade(tradeId, _emptyUpdates());

        assertEq(registry.getUserBalance(alice), INITIAL_USER_BALANCE);
        assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.EXPIRED));
    }

    function test_RevertNoSettlementConditionMetInNeutralZone() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 2_050e8, -8, block.timestamp);

        vm.expectRevert(OneStrokeTradeRegistry.NoSettlementConditionMet.selector);
        registry.settleTrade(tradeId, _emptyUpdates());
    }

    function test_PreviewSettlementShowsTakeProfitPath() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);

        (
            bool settleable,
            OneStrokeTradeRegistry.Status expectedStatus,
            uint256 marketPrice,
            uint256 payoutAmount,
            int256 pnl,
            bool priceFresh
        ) = registry.previewSettlement(tradeId);

        assertTrue(settleable);
        assertEq(uint8(expectedStatus), uint8(OneStrokeTradeRegistry.Status.HIT_TP));
        assertEq(marketPrice, 2_150e8);
        assertEq(payoutAmount, STAKE + 100e6);
        assertEq(pnl, int256(100e6));
        assertTrue(priceFresh);
    }

    function test_PreviewSettlementShowsNeutralPath() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 2_050e8, -8, block.timestamp);

        (bool settleable, OneStrokeTradeRegistry.Status expectedStatus,,,, bool priceFresh) =
            registry.previewSettlement(tradeId);

        assertFalse(settleable);
        assertEq(uint8(expectedStatus), uint8(OneStrokeTradeRegistry.Status.OPEN));
        assertTrue(priceFresh);
    }

    function test_PreviewSettlementShowsStalePath() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 24 hours);
        vm.warp(registry.MAX_PRICE_AGE() + 2);
        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp - registry.MAX_PRICE_AGE() - 1);

        (bool settleable, OneStrokeTradeRegistry.Status expectedStatus,,,, bool priceFresh) =
            registry.previewSettlement(tradeId);

        assertFalse(settleable);
        assertEq(uint8(expectedStatus), uint8(OneStrokeTradeRegistry.Status.OPEN));
        assertFalse(priceFresh);
    }

    function test_CanSettleTradeUsesPreviewLogic() public {
        uint256 tradeId = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);
        _setPrice(BTC_FEED_ID, 28_500e8, -8, block.timestamp);

        (bool settleable, OneStrokeTradeRegistry.Status expectedStatus) = registry.canSettleTrade(tradeId);
        assertTrue(settleable);
        assertEq(uint8(expectedStatus), uint8(OneStrokeTradeRegistry.Status.HIT_TP));
    }

    function test_QuoteUpdateFeeReflectsPythFee() public {
        pyth.setUpdateFee(7 wei);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"beef";

        assertEq(registry.quoteUpdateFee(updateData), 7 wei);
        assertEq(registry.quoteUpdateFee(_emptyUpdates()), 0);
    }

    function test_RevertInsufficientTreasury() public {
        registry.withdrawTreasury(SEEDED_TREASURY);
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);

        vm.expectRevert(OneStrokeTradeRegistry.InsufficientTreasury.selector);
        registry.settleTrade(tradeId, _emptyUpdates());
    }

    function test_RevertStalePrice() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        vm.warp(registry.MAX_PRICE_AGE() + 2);
        _setPrice(ETH_FEED_ID, 2_000e8, -8, block.timestamp - registry.MAX_PRICE_AGE() - 1);

        vm.expectRevert();
        registry.settleTrade(tradeId, _emptyUpdates());
    }

    function test_RevertInvalidPrice() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 0, -8, block.timestamp);

        vm.expectRevert(OneStrokeTradeRegistry.InvalidPrice.selector);
        registry.settleTrade(tradeId, _emptyUpdates());
    }

    function test_BatchSettleMixedResults() public {
        uint256 trade1 = _createLongTrade(alice, "ETH", ENTRY, 1_700e8, 1_800e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        uint256 trade2 = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);
        uint256 trade3 = _createLongTrade(alice, "MON", 100e8, 80e8, 90e8, 120e8, 130e8, STAKE, 1 hours);
        uint256 trade4 = _createLongTrade(alice, "ETH", ENTRY, 1_600e8, 1_700e8, 2_300e8, 2_400e8, STAKE, 1 hours);
        uint256 trade5 = _createShortTrade(alice, "BTC", 30_000e8, 31_500e8, 32_000e8, 26_000e8, 27_000e8, STAKE, 1 hours);

        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);
        _setPrice(BTC_FEED_ID, 28_500e8, -8, block.timestamp);
        _setPrice(MON_FEED_ID, 85e8, -8, block.timestamp);

        uint256[] memory tradeIds = new uint256[](5);
        tradeIds[0] = trade1;
        tradeIds[1] = trade2;
        tradeIds[2] = trade3;
        tradeIds[3] = trade4;
        tradeIds[4] = trade5;

        vm.recordLogs();
        registry.settleBatch(tradeIds, _emptyUpdates());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("BatchSettled(uint256,uint256)")) {
                (uint256 totalAttempted, uint256 successCount) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(totalAttempted, 5);
                assertEq(successCount, 3);
                found = true;
            }
        }
        assertTrue(found);
        assertEq(uint8(registry.getTrade(trade4).status), uint8(OneStrokeTradeRegistry.Status.OPEN));
        assertEq(uint8(registry.getTrade(trade5).status), uint8(OneStrokeTradeRegistry.Status.OPEN));
    }

    function test_SettleTradePaysPythFeeAndRefundsExcess() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);
        pyth.setUpdateFee(1 wei);
        vm.deal(alice, 10 wei);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"1234";

        uint256 callerBalanceBefore = alice.balance;
        vm.prank(alice);
        registry.settleTrade{value: 5 wei}(tradeId, updateData);

        assertEq(alice.balance, callerBalanceBefore - 1 wei);
    }

    function test_ExecutorForceSettleWorksWithRole() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);

        vm.prank(executor);
        registry.executorForceSettle(tradeId, 2_150e8);

        assertEq(uint8(registry.getTrade(tradeId).status), uint8(OneStrokeTradeRegistry.Status.HIT_TP));
    }

    function test_ExecutorForceSettleRevertsWithoutRole() public {
        uint256 tradeId = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, registry.EXECUTOR_ROLE()
            )
        );
        vm.prank(bob);
        registry.executorForceSettle(tradeId, 2_150e8);
    }

    function test_AdminCanUpgradeUUPSProxy() public {
        OneStrokeTradeRegistryV2 newImplementation = new OneStrokeTradeRegistryV2();
        registry.upgradeToAndCall(address(newImplementation), "");

        assertEq(OneStrokeTradeRegistryV2(address(registry)).version(), 2);
        assertEq(registry.getTreasuryBalance(), SEEDED_TREASURY);
    }

    function test_NonAdminCannotUpgradeUUPSProxy() public {
        OneStrokeTradeRegistryV2 newImplementation = new OneStrokeTradeRegistryV2();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(bob);
        registry.upgradeToAndCall(address(newImplementation), "");
    }

    function test_PriceNormalizationAcrossExponents() public {
        registry.setPriceFeed("ETH6", ETH6_FEED_ID);
        registry.setPriceFeed("ETH18", ETH18_FEED_ID);
        _setPrice(ETH6_FEED_ID, 2_000_000_000, -6, block.timestamp);
        _setPrice(ETH18_FEED_ID, 2_000_000_000_000_000, -12, block.timestamp);

        (uint256 normalized6,) = registry.peekPrice("ETH6");
        (uint256 normalized18,) = registry.peekPrice("ETH18");

        assertEq(normalized6, 2_000e8);
        assertEq(normalized18, 2_000e8);
    }

    function test_GetUserStatsAggregatesWinsAndLosses() public {
        uint256 trade1 = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        uint256 trade2 = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);

        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);
        registry.settleTrade(trade1, _emptyUpdates());

        _setPrice(BTC_FEED_ID, 31_500e8, -8, block.timestamp);
        registry.settleTrade(trade2, _emptyUpdates());

        (uint256 wins, uint256 losses, uint256 settled, int256 netPnl) = registry.getUserStats(alice);
        assertEq(wins, 1);
        assertEq(losses, 1);
        assertEq(settled, 2);
        assertEq(netPnl, -int256(400e6));
    }

    function test_GetTradesByUserReturnsFullList() public {
        _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);
        _createLongTrade(alice, "MON", 100e8, 80e8, 90e8, 120e8, 130e8, STAKE, 1 hours);

        uint256[] memory tradeIds = registry.getTradesByUser(alice);
        assertEq(tradeIds.length, 3);
        assertEq(tradeIds[0], 1);
        assertEq(tradeIds[1], 2);
        assertEq(tradeIds[2], 3);
    }

    function test_TotalTradesCorrectAfterMixedActivity() public {
        uint256 trade1 = _createLongTrade(alice, "ETH", ENTRY, 1_800e8, 1_900e8, 2_100e8, 2_200e8, STAKE, 1 hours);
        uint256 trade2 = _createShortTrade(alice, "BTC", 30_000e8, 31_000e8, 32_000e8, 28_000e8, 29_000e8, STAKE, 1 hours);
        _createLongTrade(alice, "MON", 100e8, 80e8, 90e8, 120e8, 130e8, STAKE, 1 hours);

        _setPrice(ETH_FEED_ID, 2_150e8, -8, block.timestamp);
        registry.settleTrade(trade1, _emptyUpdates());

        vm.prank(alice);
        registry.cancelTrade(trade2);

        assertEq(registry.totalTrades(), 3);
    }

    function _createLongTrade(
        address user,
        string memory asset,
        uint256 entryPrice,
        uint256 stopLossLower,
        uint256 stopLossUpper,
        uint256 takeProfitLower,
        uint256 takeProfitUpper,
        uint256 stakeAmount,
        uint256 duration
    ) internal returns (uint256) {
        vm.prank(user);
        return registry.createTrade(
            asset,
            OneStrokeTradeRegistry.Direction.LONG,
            entryPrice,
            stopLossLower,
            stopLossUpper,
            takeProfitLower,
            takeProfitUpper,
            block.timestamp + duration,
            stakeAmount
        );
    }

    function _createShortTrade(
        address user,
        string memory asset,
        uint256 entryPrice,
        uint256 stopLossLower,
        uint256 stopLossUpper,
        uint256 takeProfitLower,
        uint256 takeProfitUpper,
        uint256 stakeAmount,
        uint256 duration
    ) internal returns (uint256) {
        vm.prank(user);
        return registry.createTrade(
            asset,
            OneStrokeTradeRegistry.Direction.SHORT,
            entryPrice,
            stopLossLower,
            stopLossUpper,
            takeProfitLower,
            takeProfitUpper,
            block.timestamp + duration,
            stakeAmount
        );
    }

    function _setPrice(bytes32 feedId, int64 price, int32 expo, uint256 publishTime) internal {
        pyth.setPrice(feedId, price, expo, publishTime);
    }

    function _emptyUpdates() internal pure returns (bytes[] memory updates) {
        updates = new bytes[](0);
    }
}
