// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPyth, PythStructs} from "./interfaces/IPyth.sol";

contract OneStrokeTradeRegistry is Initializable, AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    enum Direction {
        LONG,
        SHORT
    }

    enum Status {
        OPEN,
        HIT_TP,
        HIT_SL,
        EXPIRED,
        CANCELLED
    }

    struct Trade {
        uint256 tradeId;
        address creator;
        string asset;
        Direction direction;
        uint256 entryPrice;
        uint256 stopLossLower;
        uint256 stopLossUpper;
        uint256 takeProfitLower;
        uint256 takeProfitUpper;
        uint256 createdAt;
        uint256 expiry;
        uint256 stakeAmount;
        Status status;
        uint256 settlementPrice;
    }

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant MAX_PRICE_AGE = 3600;
    uint256 public constant MIN_DURATION = 60;
    uint256 public constant MAX_DURATION = 24 hours;
    uint256 public constant TP_BONUS_BPS = 1000;
    uint256 public constant SL_PENALTY_BPS = 5000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(string => bytes32) public priceFeedIds;
    mapping(uint256 => Trade) public trades;
    mapping(address => uint256[]) public userTradeIds;
    mapping(address => uint256) public userWins;
    mapping(address => uint256) public userLosses;
    mapping(address => uint256) public userSettledCount;
    mapping(address => int256) public userNetPnl;
    mapping(address => uint256) public userBalances;

    IERC20 public usdc;
    IPyth public pyth;
    uint256 public nextTradeId;
    uint256 public treasuryBalance;
    uint256 public totalUserBalances;

    error InvalidAsset();
    error InvalidEntryPrice();
    error InvalidExpiry();
    error InvalidStakeAmount();
    error InvalidZone();
    error InvalidDirectionZones();
    error TradeNotFound();
    error NotTradeCreator();
    error InvalidStatus();
    error NoSettlementConditionMet();
    error InsufficientTreasury();
    error StalePrice();
    error InvalidPrice();
    error ZeroAddress();
    error TransferFailed();
    error InsufficientUserBalance();
    error InsufficientOracleFee();

    event TradeCreated(
        uint256 indexed tradeId,
        address indexed creator,
        string asset,
        Direction direction,
        uint256 entryPrice,
        uint256 stopLossLower,
        uint256 stopLossUpper,
        uint256 takeProfitLower,
        uint256 takeProfitUpper,
        uint256 stakeAmount,
        uint256 createdAt,
        uint256 expiry
    );
    event TradeCancelled(uint256 indexed tradeId, address indexed creator, uint256 refundedStake);
    event TradeSettled(
        uint256 indexed tradeId,
        address indexed creator,
        Status status,
        uint256 marketPrice,
        uint256 payoutAmount,
        int256 pnl
    );
    event BatchSettleResult(uint256 indexed tradeId, bool settled, Status status);
    event BatchSettled(uint256 totalAttempted, uint256 successCount);
    event ExecutorForceSettled(uint256 indexed tradeId, Status status, uint256 marketPrice);
    event TreasurySeeded(uint256 amount, uint256 newBalance);
    event TreasuryWithdrawn(uint256 amount, uint256 newBalance);
    event PriceFeedSet(string asset, bytes32 feedId);
    event PythContractSet(address pythContract);
    event UserDeposited(address indexed user, uint256 amount, uint256 newBalance);
    event UserWithdrawn(address indexed user, uint256 amount, uint256 newBalance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable OneStroke registry proxy.
    function initialize(address admin, address usdc_, address pyth_) external initializer {
        if (admin == address(0) || usdc_ == address(0) || pyth_ == address(0)) revert ZeroAddress();

        __AccessControl_init();

        usdc = IERC20(usdc_);
        pyth = IPyth(pyth_);
        nextTradeId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Sets the Pyth contract used to fetch price data.
    function setPythContract(address pythContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pythContract == address(0)) revert ZeroAddress();
        pyth = IPyth(pythContract);
        emit PythContractSet(pythContract);
    }

    /// @notice Registers or updates a Pyth feed id for an asset symbol.
    function setPriceFeed(string calldata asset, bytes32 feedId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(asset).length == 0 || feedId == bytes32(0)) revert InvalidAsset();

        priceFeedIds[asset] = feedId;
        emit PriceFeedSet(asset, feedId);
    }

    /// @notice Seeds treasury liquidity used to pay take-profit bonuses.
    function seedTreasury(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert InvalidStakeAmount();
        _pullTokens(msg.sender, amount);
        treasuryBalance += amount;
        emit TreasurySeeded(amount, treasuryBalance);
    }

    /// @notice Withdraws available treasury funds without touching user escrow.
    function withdrawTreasury(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert InvalidStakeAmount();
        if (amount > treasuryBalance) revert InsufficientTreasury();

        treasuryBalance -= amount;
        _pushTokens(msg.sender, amount);
        emit TreasuryWithdrawn(amount, treasuryBalance);
    }

    /// @notice Deposits USDC into the caller's internal trading balance.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidStakeAmount();

        _pullTokens(msg.sender, amount);
        userBalances[msg.sender] += amount;
        totalUserBalances += amount;

        emit UserDeposited(msg.sender, amount, userBalances[msg.sender]);
    }

    /// @notice Withdraws USDC from the caller's internal trading balance.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidStakeAmount();
        if (amount > userBalances[msg.sender]) revert InsufficientUserBalance();

        userBalances[msg.sender] -= amount;
        totalUserBalances -= amount;

        _pushTokens(msg.sender, amount);
        emit UserWithdrawn(msg.sender, amount, userBalances[msg.sender]);
    }

    /// @notice Creates a new OneStroke trade thesis and locks stake from the caller's internal balance.
    function createTrade(
        string calldata asset,
        Direction direction,
        uint256 entryPrice,
        uint256 stopLossLower,
        uint256 stopLossUpper,
        uint256 takeProfitLower,
        uint256 takeProfitUpper,
        uint256 expiry,
        uint256 stakeAmount
    ) external nonReentrant returns (uint256 tradeId) {
        _validateCreateTrade(
            asset,
            direction,
            entryPrice,
            stopLossLower,
            stopLossUpper,
            takeProfitLower,
            takeProfitUpper,
            expiry,
            stakeAmount
        );

        if (stakeAmount > userBalances[msg.sender]) revert InsufficientUserBalance();
        userBalances[msg.sender] -= stakeAmount;
        totalUserBalances -= stakeAmount;

        tradeId = nextTradeId++;
        Trade memory trade = Trade({
            tradeId: tradeId,
            creator: msg.sender,
            asset: asset,
            direction: direction,
            entryPrice: entryPrice,
            stopLossLower: stopLossLower,
            stopLossUpper: stopLossUpper,
            takeProfitLower: takeProfitLower,
            takeProfitUpper: takeProfitUpper,
            createdAt: block.timestamp,
            expiry: expiry,
            stakeAmount: stakeAmount,
            status: Status.OPEN,
            settlementPrice: 0
        });

        trades[tradeId] = trade;
        userTradeIds[msg.sender].push(tradeId);
        _emitTradeCreated(trade);
    }

    /// @notice Cancels an open trade before settlement and refunds the full stake to the caller's internal balance.
    function cancelTrade(uint256 tradeId) external nonReentrant {
        Trade storage trade = _requireTrade(tradeId);
        if (trade.creator != msg.sender) revert NotTradeCreator();
        if (trade.status != Status.OPEN) revert InvalidStatus();

        uint256 refundAmount = trade.stakeAmount;
        trade.status = Status.CANCELLED;
        trade.settlementPrice = 0;

        userBalances[trade.creator] += refundAmount;
        totalUserBalances += refundAmount;

        emit TradeCancelled(tradeId, trade.creator, refundAmount);
    }

    /// @notice Settles a trade using the configured Pyth feed, optionally updating prices first.
    function settleTrade(uint256 tradeId, bytes[] calldata priceUpdateData) external payable nonReentrant {
        uint256 oracleFee = _updatePythIfNeeded(priceUpdateData);
        (bool settled,,) = _settleTrade(tradeId, false, 0, true);
        if (!settled) revert NoSettlementConditionMet();
        _refundExcessValue(oracleFee);
    }

    /// @notice Attempts to settle many trades and skips trades that are not currently settleable.
    function settleBatch(uint256[] calldata tradeIds, bytes[] calldata priceUpdateData) external payable nonReentrant {
        uint256 oracleFee = _updatePythIfNeeded(priceUpdateData);
        uint256 successCount;

        for (uint256 i = 0; i < tradeIds.length; ++i) {
            (bool settled, Status status,) = _settleTrade(tradeIds[i], false, 0, false);
            if (settled) {
                successCount++;
            }
            emit BatchSettleResult(tradeIds[i], settled, status);
        }

        emit BatchSettled(tradeIds.length, successCount);
        _refundExcessValue(oracleFee);
    }

    /// @notice Settles a trade with an executor-supplied market price as a demo fallback.
    function executorForceSettle(uint256 tradeId, uint256 marketPrice)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        if (marketPrice == 0) revert InvalidPrice();
        (bool settled, Status status,) = _settleTrade(tradeId, true, marketPrice, true);
        if (!settled) revert NoSettlementConditionMet();
        emit ExecutorForceSettled(tradeId, status, marketPrice);
    }

    /// @notice Returns a trade by id.
    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return _requireTradeView(tradeId);
    }

    /// @notice Returns the list of trade ids created by a user.
    function getTradesByUser(address user) external view returns (uint256[] memory) {
        return userTradeIds[user];
    }

    /// @notice Returns the total number of created trades.
    function totalTrades() external view returns (uint256) {
        return nextTradeId - 1;
    }

    /// @notice Returns cached leaderboard statistics for a user.
    function getUserStats(address user)
        external
        view
        returns (uint256 wins, uint256 losses, uint256 settled, int256 netPnl)
    {
        return (userWins[user], userLosses[user], userSettledCount[user], userNetPnl[user]);
    }

    /// @notice Returns the treasury balance tracked by the registry.
    function getTreasuryBalance() external view returns (uint256) {
        return treasuryBalance;
    }

    /// @notice Returns the internal balance available for trading or withdrawal.
    function getUserBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }

    /// @notice Returns the configured Pyth feed id for an asset symbol.
    function getPriceFeed(string calldata asset) external view returns (bytes32) {
        return priceFeedIds[asset];
    }

    /// @notice Returns the current normalized price and publish timestamp for an asset.
    function peekPrice(string calldata asset) external view returns (uint256 price1e8, uint256 publishTime) {
        return _getPrice(asset);
    }

    /// @notice Quotes the native token fee required for a given Pyth price update payload.
    function quoteUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 feeAmount) {
        if (priceUpdateData.length == 0) return 0;
        return pyth.getUpdateFee(priceUpdateData);
    }

    /// @notice Returns whether a trade can currently be settled using the latest onchain Pyth price.
    function canSettleTrade(uint256 tradeId) external view returns (bool settleable, Status expectedStatus) {
        (settleable, expectedStatus,,,,) = _previewSettlement(tradeId);
    }

    /// @notice Previews settlement outcome so relayers can decide whether to settle with or without Pyth updates.
    function previewSettlement(uint256 tradeId)
        external
        view
        returns (
            bool settleable,
            Status expectedStatus,
            uint256 marketPrice,
            uint256 payoutAmount,
            int256 pnl,
            bool priceFresh
        )
    {
        return _previewSettlement(tradeId);
    }

    function _validateCreateTrade(
        string calldata asset,
        Direction direction,
        uint256 entryPrice,
        uint256 stopLossLower,
        uint256 stopLossUpper,
        uint256 takeProfitLower,
        uint256 takeProfitUpper,
        uint256 expiry,
        uint256 stakeAmount
    ) internal view {
        if (bytes(asset).length == 0 || priceFeedIds[asset] == bytes32(0)) revert InvalidAsset();
        if (entryPrice == 0) revert InvalidEntryPrice();
        if (stakeAmount == 0) revert InvalidStakeAmount();
        if (expiry < block.timestamp + MIN_DURATION || expiry > block.timestamp + MAX_DURATION) revert InvalidExpiry();
        if (stopLossLower > stopLossUpper || takeProfitLower > takeProfitUpper) revert InvalidZone();

        if (direction == Direction.LONG) {
            if (
                takeProfitLower <= entryPrice || takeProfitUpper <= entryPrice || stopLossLower >= entryPrice
                    || stopLossUpper >= entryPrice
            ) revert InvalidDirectionZones();
        } else {
            if (
                takeProfitLower >= entryPrice || takeProfitUpper >= entryPrice || stopLossLower <= entryPrice
                    || stopLossUpper <= entryPrice
            ) revert InvalidDirectionZones();
        }
    }

    function _previewSettlement(uint256 tradeId)
        internal
        view
        returns (
            bool settleable,
            Status expectedStatus,
            uint256 marketPrice,
            uint256 payoutAmount,
            int256 pnl,
            bool priceFresh
        )
    {
        Trade memory trade = _requireTradeView(tradeId);
        if (trade.status != Status.OPEN) {
            return (false, trade.status, trade.settlementPrice, 0, 0, false);
        }

        (bool hasPrice, uint256 fetchedPrice) = _tryGetPrice(trade.asset);
        priceFresh = hasPrice;
        marketPrice = fetchedPrice;

        if (block.timestamp >= trade.expiry) {
            return (true, Status.EXPIRED, marketPrice, trade.stakeAmount, 0, priceFresh);
        }

        if (!priceFresh) {
            return (false, Status.OPEN, 0, 0, 0, false);
        }

        (bool hasCondition, Status computedStatus) = _computeStatusView(trade, marketPrice);
        if (!hasCondition) {
            return (false, Status.OPEN, marketPrice, 0, 0, true);
        }

        expectedStatus = computedStatus;
        (payoutAmount, pnl) = _computePreviewPayout(trade.stakeAmount, expectedStatus);
        settleable = true;
    }

    function _settleTrade(uint256 tradeId, bool useManualPrice, uint256 manualPrice, bool revertOnFailure)
        internal
        returns (bool settled, Status status, uint256 payoutAmount)
    {
        Trade storage trade = trades[tradeId];
        if (trade.creator == address(0)) {
            if (revertOnFailure) revert TradeNotFound();
            return (false, Status.OPEN, 0);
        }
        if (trade.status != Status.OPEN) {
            if (revertOnFailure) revert InvalidStatus();
            return (false, trade.status, 0);
        }

        uint256 marketPrice;
        if (useManualPrice) {
            marketPrice = manualPrice;
        } else if (revertOnFailure) {
            (marketPrice,) = _getPrice(trade.asset);
        } else {
            (bool ok, uint256 fetchedPrice) = _tryGetPrice(trade.asset);
            if (!ok) {
                return (false, trade.status, 0);
            }
            marketPrice = fetchedPrice;
        }

        Status finalStatus;
        int256 pnl;

        if (block.timestamp >= trade.expiry) {
            finalStatus = Status.EXPIRED;
            payoutAmount = trade.stakeAmount;
        } else {
            (bool hasCondition, Status computedStatus) = _computeStatus(trade, marketPrice);
            if (!hasCondition) {
                if (revertOnFailure) revert NoSettlementConditionMet();
                return (false, trade.status, 0);
            }
            finalStatus = computedStatus;
            (payoutAmount, pnl) = _computePayout(trade, finalStatus);
            _updateLeaderboard(trade.creator, finalStatus, pnl);
        }

        trade.status = finalStatus;
        trade.settlementPrice = marketPrice;
        userBalances[trade.creator] += payoutAmount;
        totalUserBalances += payoutAmount;

        emit TradeSettled(tradeId, trade.creator, finalStatus, marketPrice, payoutAmount, pnl);
        return (true, finalStatus, payoutAmount);
    }

    function _computeStatusView(Trade memory trade, uint256 marketPrice) internal pure returns (bool, Status) {
        if (trade.direction == Direction.LONG) {
            if (marketPrice >= trade.takeProfitLower) return (true, Status.HIT_TP);
            if (marketPrice <= trade.stopLossUpper) return (true, Status.HIT_SL);
        } else {
            if (marketPrice <= trade.takeProfitUpper) return (true, Status.HIT_TP);
            if (marketPrice >= trade.stopLossLower) return (true, Status.HIT_SL);
        }

        return (false, Status.OPEN);
    }

    function _computeStatus(Trade storage trade, uint256 marketPrice) internal view returns (bool, Status) {
        if (trade.direction == Direction.LONG) {
            if (marketPrice >= trade.takeProfitLower) return (true, Status.HIT_TP);
            if (marketPrice <= trade.stopLossUpper) return (true, Status.HIT_SL);
        } else {
            if (marketPrice <= trade.takeProfitUpper) return (true, Status.HIT_TP);
            if (marketPrice >= trade.stopLossLower) return (true, Status.HIT_SL);
        }

        return (false, Status.OPEN);
    }

    function _computePreviewPayout(uint256 stakeAmount, Status finalStatus)
        internal
        view
        returns (uint256 payoutAmount, int256 pnl)
    {
        if (finalStatus == Status.HIT_TP) {
            uint256 bonus = (stakeAmount * TP_BONUS_BPS) / BPS_DENOMINATOR;
            if (bonus > treasuryBalance) revert InsufficientTreasury();
            payoutAmount = stakeAmount + bonus;
            pnl = int256(bonus);
        } else if (finalStatus == Status.HIT_SL) {
            uint256 penalty = (stakeAmount * SL_PENALTY_BPS) / BPS_DENOMINATOR;
            payoutAmount = stakeAmount - penalty;
            pnl = -int256(penalty);
        } else {
            payoutAmount = stakeAmount;
            pnl = 0;
        }
    }

    function _computePayout(Trade storage trade, Status finalStatus) internal returns (uint256 payoutAmount, int256 pnl) {
        uint256 stakeAmount = trade.stakeAmount;

        if (finalStatus == Status.HIT_TP) {
            uint256 bonus = (stakeAmount * TP_BONUS_BPS) / BPS_DENOMINATOR;
            if (bonus > treasuryBalance) revert InsufficientTreasury();
            treasuryBalance -= bonus;
            payoutAmount = stakeAmount + bonus;
            pnl = int256(bonus);
        } else if (finalStatus == Status.HIT_SL) {
            uint256 penalty = (stakeAmount * SL_PENALTY_BPS) / BPS_DENOMINATOR;
            treasuryBalance += penalty;
            payoutAmount = stakeAmount - penalty;
            pnl = -int256(penalty);
        } else {
            payoutAmount = stakeAmount;
            pnl = 0;
        }
    }

    function _updateLeaderboard(address user, Status finalStatus, int256 pnl) internal {
        if (finalStatus == Status.HIT_TP) {
            userWins[user] += 1;
            userSettledCount[user] += 1;
            userNetPnl[user] += pnl;
        } else if (finalStatus == Status.HIT_SL) {
            userLosses[user] += 1;
            userSettledCount[user] += 1;
            userNetPnl[user] += pnl;
        }
    }

    function _getPrice(string memory asset) internal view returns (uint256 price1e8, uint256 publishTime) {
        bytes32 feedId = priceFeedIds[asset];
        if (feedId == bytes32(0) || address(pyth) == address(0)) revert InvalidAsset();

        PythStructs.Price memory price = pyth.getPriceNoOlderThan(feedId, MAX_PRICE_AGE);
        if (price.price <= 0) revert InvalidPrice();
        if (price.publishTime == 0 || block.timestamp - price.publishTime > MAX_PRICE_AGE) revert StalePrice();

        price1e8 = _normalizePythPrice(price.price, price.expo);
        publishTime = price.publishTime;
    }

    function _tryGetPrice(string memory asset) internal view returns (bool ok, uint256 price1e8) {
        try this.peekPrice(asset) returns (uint256 normalizedPrice, uint256) {
            return (true, normalizedPrice);
        } catch {
            return (false, 0);
        }
    }

    function _normalizePythPrice(int64 rawPrice, int32 expo) internal pure returns (uint256 price1e8) {
        if (rawPrice <= 0) revert InvalidPrice();

        uint256 unsignedPrice = uint64(rawPrice);
        int256 scale = int256(expo) + 8;

        if (scale == 0) {
            return unsignedPrice;
        }
        if (scale > 0) {
            return unsignedPrice * (10 ** uint256(scale));
        }

        return unsignedPrice / (10 ** uint256(-scale));
    }

    function _updatePythIfNeeded(bytes[] calldata priceUpdateData) internal returns (uint256 oracleFee) {
        if (priceUpdateData.length == 0) {
            if (msg.value != 0) revert InsufficientOracleFee();
            return 0;
        }

        oracleFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value < oracleFee) revert InsufficientOracleFee();
        pyth.updatePriceFeeds{value: oracleFee}(priceUpdateData);
    }

    function _refundExcessValue(uint256 oracleFee) internal {
        uint256 excess = msg.value - oracleFee;
        if (excess == 0) return;

        (bool success,) = payable(msg.sender).call{value: excess}("");
        if (!success) revert TransferFailed();
    }

    function _pullTokens(address from, uint256 amount) internal {
        bool success = usdc.transferFrom(from, address(this), amount);
        if (!success) revert TransferFailed();
    }

    function _emitTradeCreated(Trade memory trade) internal {
        emit TradeCreated(
            trade.tradeId,
            trade.creator,
            trade.asset,
            trade.direction,
            trade.entryPrice,
            trade.stopLossLower,
            trade.stopLossUpper,
            trade.takeProfitLower,
            trade.takeProfitUpper,
            trade.stakeAmount,
            trade.createdAt,
            trade.expiry
        );
    }

    function _pushTokens(address to, uint256 amount) internal {
        bool success = usdc.transfer(to, amount);
        if (!success) revert TransferFailed();
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }

    function _requireTrade(uint256 tradeId) internal view returns (Trade storage trade) {
        trade = trades[tradeId];
        if (trade.creator == address(0)) revert TradeNotFound();
    }

    function _requireTradeView(uint256 tradeId) internal view returns (Trade memory trade) {
        trade = trades[tradeId];
        if (trade.creator == address(0)) revert TradeNotFound();
    }
}
