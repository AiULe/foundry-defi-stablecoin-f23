// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

/**
    @title OracleLib
    @author Xuan
    @notice This libary is used to check the ChainLink Oracle for state data.
    if a price is stale, the function will revert, and render the DSCEngine unusable - this is by design
    如果价格源过期就停止。
    We want the DSCEngine to freeze if prices become stale.
    So if the Chainlink network explodes and you have a lot of money locked in the protocol... too bad.

 */

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLastestRoundData(
        AggregatorV3Interface priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
