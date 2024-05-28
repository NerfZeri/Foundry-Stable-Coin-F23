//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Dsc} from "./Dsc.sol";
import{ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./Libraries/OrcaleLib.sol";


/**
 * @title DecentralisedEngine
 * @author NerfZeri
 * This system is designed to be as minmimal as possible, and have the tokens maintain its value to the pegged currency.
 * 
 * This Stablecoin has the following properties:
 *  - Exogenous Collateral (ETH and BTC)
 *  - Stability: pegged to USD
 *  - Algorithmically Stable
 * 
 * Our DSC system should always be OVERCOLLATERALISED. This means that the value of the collateral should always be greater than the value of the DSC.
 * 
 *  @notice This contract is loosely based on the MakerDAO DSS (DAI) system.
 *  @notice Props to Patrick Collins for creating this course and all the projects to learn from along the way.
*/
contract DscEngine is ReentrancyGuard{
    ///////////////////// 
    ////    Errors   ////
    /////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressNotValid();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TokenTransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCENGINE__HealthFactorNotImproved();


    ///////////////////// 
    ////    Types    ////
    /////////////////////
    using OracleLib for AggregatorV3Interface;

    //////////////////////////////  
    ////    State Variables   ////
    //////////////////////////////
    Dsc private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant PRECISION = 100;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    ///////////////////// 
    ////  Mappings   ////
    /////////////////////

    mapping(address token => address priceFeed) private s_priceFeeds;                                 //used to retrieve the price feeds of the selected token
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;  //A mapping of a users address which points to a mapping of the ammount of collateral deposited
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;                             //used to show the amount of minted DSC for a particular user
    address[] private s_collateralTokens;

    ///////////////////// 
    ////   Events   /////
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address redeemedTo, address indexed token, uint256 amount);

    //////////////////////// 
    ////    Modifiers   ////
    ////////////////////////
    modifier moreThanZero(uint256 amount) {
        if(amount == 0){                                   // Reverts the function if a zero amount is entered
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);           //Reverts the function if the token is not approved, i.e. not Eth or BTC.
        }
        _;
    }

    //////////////////////// 
    ////  Constructor   ////
    ////////////////////////
    
    /*
     * @notice The Constructor is used to set the Price Feeds for Eth and Btc
     * it then maps the tokens to an array of Token Addresses
     * @notice the Constructor will revert if the length of the tokenAddresses and priceFeedAddresses are not equal i.e. not Btc or Eth. 
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if(tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressNotValid();
        }
        for(uint i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = Dsc(dscAddress); 
    }

    ///////////////////////////////
    ////  Extrernal Functions  ////
    ///////////////////////////////
    
    /*
     * 
     * @param tokenCollateralAddress - the address of the collateral token
     * @param collateral - the amount of collateral to deposit
     * @param amountDscToMint - the amount of DSC to mint
     * 
     * @notice This function is used to deposit collateral and mint DSC
    */
    function depositAndMint(address tokenCollateralAddress, uint256 collateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, collateral);
        mintDsc(amountDscToMint);
    }

    /*
     * 
     * @param tokenCollaterAddress - the address of the collateral token
     * @param amountCollateral - the amount of collateral to redeem
     * @param amountDscToBurn - the amount of DSC to burn
     * 
     * @notice This function is used to redeem collateral and burn DSC
    */
    function redeemCollateralForDsc(address tokenCollaterAddress, uint256 amountCollateral, uint256 amountDscToBurn) external moreThanZero(amountCollateral) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollaterAddress, amountCollateral);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress - the address of the collateral token
     * @param amountCollateral - the amount of collateral to redeem
     * 
     * @notice This function is used to redeem collateral
    */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) external moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param amount - the amount of DSC to burn
     *
     * @notice This function is used to burn DSC
     */
    function burnDsc(uint256 amount) external moreThanZero(amount){
        _burnDsc(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender); //possibly dont need this
    }

    /*
     * @param collateral - the address of the collateral token
     * @param user - the address of the user
     * @param debtToCover - the amount of debt to cover
     * 
     * @notice This function is used to liquidate a user
     * @notice The liquidation bonus is 10% of the debt to cover
     * @notice The total collateral to redeem is the debt to cover plus the bonus collateral
     * @notice The collateral is redeemed from the user and sent to the liquidator
     * @notice The DSC is burned from the user
     * @notice The health factor is recalculated
     * @notice The Function will revert if the health factor is not improved
     * @notice The Function will revert if the health factor of the User is initially okay
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
        uint256 startingHealthFactor = _healthFactor(user);
            if(startingHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOkay();        
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        
        uint256 endingHealthFactor = _healthFactor(user);
            if(endingHealthFactor <= MIN_HEALTH_FACTOR){
            revert DSCENGINE__HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    ////////////////////////////
    ////  Public Functions  ////
    ////////////////////////////
    
    /*
     * @param amountDscToMint - the amount of DSC to mint
     *
     * @notice This function is used to mint DSC
     * @notice The function will revert if the health factor is broken in the process of minting
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
        s_dscMinted[msg.sender] += amountDscToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
            if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }


    /*
    * @param tokenCollateralAddress - the address of the collateral token
    * @param amountCollateral - the amount of collateral to deposit
    *
    * @notice This function is used to deposit collateral
    * @notice The function will only accept approved tokens
    * 
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
            if (!success) {
            revert DSCEngine__TokenTransferFailed();
        }
    }

    /////////////////////////////
    ////  Private Functions  ////
    ///////////////////////////// 
  
    /*
     * @param from - the address of the user
     * @param to - the address of the user
     * @param tokenCollateralAddress - the address of the collateral token
     * @param amountCollateral - the amount of collateral to redeem
     * 
     * @notice This function is used internally in the contract to redeem collateral.
     * This is incorporated so that the redeem process can be called in functions that incorporate multiple steps.
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
            if (!success) {
            revert DSCEngine__TokenTransferFailed();
        }
    }


    /*
     * @param amountDscToBurn - the amount of DSC to burn
     * @param onBehalfOf - the address of the user
     * @param dscFrom - the address of the user
     * 
     * @notice This function is used internally in the contract to burn DSC.
     * This is incorporated so that the burn process can be called in functions that incorporate multiple steps.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
            if(!success) {
            revert DSCEngine__TokenTransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }    
    
    ////////////////////////////////////////////////
    ////  Private and Internal View Functions   ////
    //////////////////////////////////////////////// 

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValue){
        totalDscMinted = s_dscMinted[user];
        collateralValue = getAccountCollateralValue(user);
    }
    
    function _healthFactor(address user) private view returns(uint256){
        (uint256 totalDscMinted, uint256 collateralValue) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValue);
    }

    function _getUsdValue(address token, uint256 amount) private view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }   

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns(uint256){
        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    
    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if(healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    ///////////////////////////////////////////////
    ////  Public and External View Functions   ////
    ///////////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns(uint256){
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256){
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValue){
        for(uint256 i=0; i< s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += getUsdValue(token, amount);
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        return _getUsdValue(token, amount);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInfo(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns(uint256) {
        return _healthFactor(user);
    }

    function getAdditionalFeedPrecision() external pure returns(uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns(uint256) {
        return PRECISION;
    }

    function getLiquidationBonus() external pure returns(uint256) {
        return LIQUIDATION_BONUS;
    }

    function getFeedPrecision() external pure returns(uint256) {
        return FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns(uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getMinHealthFactor() external pure returns(uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationPrecision() external pure returns(uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns(address) {
        return address(i_dsc);
    }

    function getCollateralPriceFeeds(address token) external view returns(address) {
        return s_priceFeeds[token];
    }

}