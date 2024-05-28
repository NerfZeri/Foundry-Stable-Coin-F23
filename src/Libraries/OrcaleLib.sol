//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
* @title OracleLib
* @dev NerfZeri
* @notice This library is used to check the Chainlink Orcale for stale data.
* If a price is stale, the function will revert, and render the DSCEngine unusable,
* This is critical to the design of the protocol, as the protocol relies on accurate price feeds.
*/
library OracleLib{
    
    uint256 private constant TIMEOUT = 3 hours;
    error OracleLib__StalePrice();

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed) public view returns (uint80, int256, uint256, uint256, uint80) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        
            if(updatedAt == 0 || answeredInRound < roundId) {
                revert OracleLib__StalePrice();
        }
        
        uint256 secondsSince = block.timestamp - updatedAt;
            if(secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        
            return (roundId, answer, startedAt, updatedAt, answeredInRound); 
    }

    function getTimeout(AggregatorV3Interface) public pure returns (uint256) {
        return TIMEOUT;
    }
}
