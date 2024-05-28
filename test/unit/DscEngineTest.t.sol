//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {DscDeploy} from "../../script/DscDeploy.s.sol";
import {Dsc} from "../../src/Dsc.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggreagator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDsc.sol";

contract DscEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address redeemedTo, address indexed token, uint256 amount);

    DscDeploy deployer;
    Dsc dsc;
    DscEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public COLLATERAL_TO_COVER = 20 ether;
    
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DSC_TO_MINT = 100 ether;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    
    function setUp() public {
        deployer = new DscDeploy();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////
    //// Constructor Tests ////
    ///////////////////////////

     function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DscEngine.DSCEngine__TokenAddressNotValid.selector);
        new DscEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    
    function testConstructorWorks() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        new DscEngine(tokenAddresses, priceFeedAddresses, address(dsc));       
    }

    ////////////////////
    /// Price Tests ////
    ////////////////////
    
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsdValue = 3e38;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsdValue);
    }

    function testGetTokenAmountFromUsd() public view{
        uint256 expectedTokenAmount = 5;
        uint256 actualTokenAmount = engine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(actualTokenAmount, expectedTokenAmount);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 expectedCollateralValue = engine.getUsdValue(weth, 10 ether);
        uint256 actualCollateralValue = engine.getAccountCollateralValue(USER);
        assertEq(actualCollateralValue, expectedCollateralValue);
    }

    ///////////////////////////////////
    //// Deposiot Collateral Tests ////
    ///////////////////////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }
    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testRevertsIfCollateralZero() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }


    function testRevertsWithWrongCollateral() public{
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DSCEngine__TokenNotAllowed.selector, address(ranToken)));
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral{
        (uint256 totalDscminted, uint256 collateralValueInUsd) = engine.getAccountInfo(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscminted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testRevertsIfTransferFromFails() public {
  
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DscEngine mockDsce = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
    
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        
        vm.expectRevert(DscEngine.DSCEngine__TokenTransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////////////////
    //// Redeem Collateral Tests ////
    /////////////////////////////////

    function testRedeemRevertsIfCollateralZero() public{
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
    }

    function testRedeemRevertsIfBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        engine.mintDsc(100);
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    function testReedemCollateral() public depositedCollateral{
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitsEvent() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfTransferFails() public {
        
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DscEngine mockDsce = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
       
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DSCEngine__TokenTransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }


    //////////////////////////////////
    //// Deposit & Mint DSC Tests ////
    //////////////////////////////////

    modifier depositedAndMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositAndMint(weth, AMOUNT_COLLATERAL, DSC_TO_MINT);
        vm.stopPrank();
        _;
    }
    
    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint = (AMOUNT_COLLATERAL *(uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositAndMint(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank(); 
    }

    function testCanDepositAndMint() public depositedAndMinted {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, DSC_TO_MINT);
    }

    /////////////////////////
    ///   MintDsc Tests  ////
    /////////////////////////


    function testRevertsIfMintedAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral{
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint = (AMOUNT_COLLATERAL *(uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        
        uint256 expectedHealthFactor = engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        engine.mintDsc(DSC_TO_MINT);
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, DSC_TO_MINT);
    }

    /////////////////////////////
    ////    Burn Dsc Tests   ////
    /////////////////////////////

    function testRevertsIfBurnAmountIsZero() public depositedCollateral{
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.burnDsc(0);
    }

    function testCantBurnMoreThanBalance() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedAndMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), DSC_TO_MINT);
        engine.burnDsc(DSC_TO_MINT);
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }


    /////////////////////////////////////////
    //// Redeem Collateral For DSC Tests ////
    /////////////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedAndMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), DSC_TO_MINT);
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth, 0, DSC_TO_MINT);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositAndMint(weth, AMOUNT_COLLATERAL, DSC_TO_MINT);
        dsc.approve(address(engine), DSC_TO_MINT);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, DSC_TO_MINT);
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /////////////////////////////////
    ////   Health Factor Tests   ////
    /////////////////////////////////

    function testProperlyReportsHealthFactor() public depositedAndMinted {
        uint256 expectedHealthFactor = 100 ether;
        uint256 actualHealthFactor = engine.getHealthFactor(USER);
        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedAndMinted{
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor == 0.9 ether);
    }

    /////////////////////////////
    ////   Liquidate Tests   ////
    /////////////////////////////

    function testMustImproveHelathFactorOnLiquidate() public {
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(address(ethUsdPriceFeed));
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DscEngine mockDsce = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositAndMint(weth, AMOUNT_COLLATERAL, DSC_TO_MINT);
        vm.stopPrank();

        COLLATERAL_TO_COVER = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockDsce), COLLATERAL_TO_COVER);
        uint256 debtToCover = 10 ether;
        mockDsce.depositAndMint(weth, COLLATERAL_TO_COVER, DSC_TO_MINT);
        mockDsc.approve(address(mockDsce), debtToCover);

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.expectRevert(DscEngine.DSCENGINE__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedAndMinted {
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositAndMint(weth, COLLATERAL_TO_COVER, DSC_TO_MINT);
        ERC20Mock(weth).approve(address(engine), DSC_TO_MINT);

        vm.expectRevert(DscEngine.DSCEngine__HealthFactorOkay.selector);
        engine.liquidate(weth, USER, DSC_TO_MINT);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositAndMint(weth, AMOUNT_COLLATERAL, DSC_TO_MINT);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 healthFactor = engine.getHealthFactor(USER);
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositAndMint(weth, COLLATERAL_TO_COVER, DSC_TO_MINT);
        dsc.approve(address(engine), DSC_TO_MINT);
        engine.liquidate(weth, USER, DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated{
        uint256 liquidatorBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, DSC_TO_MINT) + (engine.getTokenAmountFromUsd(weth, DSC_TO_MINT) / engine.getLiquidationBonus());
        assertEq(liquidatorBalance, expectedWeth);
    }

    function testUserStillHasEthAfterLiquidation() public liquidated {
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, DSC_TO_MINT) + (engine.getTokenAmountFromUsd(weth, DSC_TO_MINT) / engine.getLiquidationBonus());
        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserBalance = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);
        (, uint256 userCollateralValueInUsd) = engine.getAccountInfo(USER);
        assertEq(userCollateralValueInUsd, expectedUserBalance);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInfo(LIQUIDATOR);
        assertEq(liquidatorDscMinted, DSC_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInfo(USER);
        assertEq(userDscMinted, 0);
    }


    //////////////////////////////////////
    //// View & Pure Function Tests   ////
    //////////////////////////////////////

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 userCollateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(userCollateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountInfo() public depositedAndMinted {
        (uint256 dscMinted, uint256 collateralValue) = engine.getAccountInfo(USER);
        uint256 expectedCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(dscMinted, DSC_TO_MINT);
        assertEq(collateralValue, expectedCollateralValueInUsd);
    }


    function testGetHealthFactor() public depositedAndMinted {
        uint256 healthFactor = engine.getHealthFactor(USER);
        uint256 expectedHelathFactor = engine.calculateHealthFactor(DSC_TO_MINT, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        assertEq(healthFactor, expectedHelathFactor);
    }

    function testGetAdditionalPriceFeedPrecision() public view {
        uint256 additionalPrecision = engine.getAdditionalFeedPrecision();
        assertEq(additionalPrecision, 1e10);
    }

    function testGetPrecision() public view {
        uint256 precision = engine.getPrecision();
        assertEq(precision, 100);
    }

    function testGetLiquidationBonus() public view {
        uint256 liquidationBonus = engine.getLiquidationBonus();
        assertEq(liquidationBonus, 10);
    }

    function testGetFeedPrecision() public view {
        uint256 feedPrecision = engine.getFeedPrecision();
        assertEq(feedPrecision, 1e8);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, 50);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }

    function testGetLiquidationPrecision() public view {
        uint256 liquidationPrecision = engine.getLiquidationPrecision();
        assertEq(liquidationPrecision, 100);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testGetCollateralPriceFeeds() public view {
        address priceFeeds = engine.getCollateralPriceFeeds(weth);
        assertEq(priceFeeds, ethUsdPriceFeed);
    }

}