// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal prices;
    uint256 public updateFee;
    string public constant version = "mock-pyth";

    error StalePrice();
    error PriceFeedNotFound();
    error InsufficientFee();

    function setPrice(bytes32 feedId, int64 price, int32 expo, uint256 publishTime) external {
        prices[feedId] = PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    function setUpdateFee(uint256 newFee) external {
        updateFee = newFee;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory price) {
        price = prices[id];
        if (price.publishTime == 0) revert PriceFeedNotFound();
        if (block.timestamp - price.publishTime > age) revert StalePrice();
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256 feeAmount) {
        return updateFee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        if (msg.value < updateFee) revert InsufficientFee();
    }
}
