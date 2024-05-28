//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {Dsc} from "../src/Dsc.sol";
import {DscEngine} from "../src/DscEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DscDeploy is Script {
    Dsc dsc;
    DscEngine dscEngine;
    HelperConfig config;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (Dsc, DscEngine, HelperConfig) {
        config = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = config.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        
        vm.startBroadcast(deployerKey);
        dsc = new Dsc();
        dscEngine = new DscEngine(tokenAddresses ,priceFeedAddresses ,address(dsc));
        dsc.transferOwnership(address(dscEngine));
        vm.stopBroadcast();
        return (dsc, dscEngine, config);
    }
}
