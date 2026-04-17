// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OneStrokeTradeRegistry} from "../../src/OneStrokeTradeRegistry.sol";

contract OneStrokeTradeRegistryV2 is OneStrokeTradeRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}
