//SPDX-License-Identifier: MIT

// 1. Total supply of DSC must be less then total value of collateral
// 2. Getter view fuctions should never revert

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DscDeploy} from "../../../script/DscDeploy.s.sol";
import {DscEngine} from "../../../src/DscEngine.sol";
import {Dsc} from "../../../src/Dsc.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DscDeploy deploy;
    DscEngine engine;
    Dsc dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deploy = new DscDeploy();
        (dsc,engine, config) = deploy.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalSupply);
        console.log("times mint called", handler.timesMintCalled());
    }

    function invariant_gettersShouldNotRevert() public view {
        engine.getAdditionalFeedPrecision();
        engine.getPrecision();
        engine.getLiquidationBonus();
        engine.getFeedPrecision();
        engine.getLiquidationThreshold();
        engine.getMinHealthFactor();
        engine.getLiquidationPrecision();
        engine.getCollateralTokens();
        engine.getDsc();
    }
}