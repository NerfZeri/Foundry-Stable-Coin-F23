//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* 
* @title DecentralisedStableCoin
* @author NerfZeri
* collateral: exogenous (ETH and BTC)
* Stability: pegged to USD
*
* @notice 
*/

contract Dsc is ERC20Burnable, Ownable {
    /**
     * Errors
     */
    error DSC__MustBeMoreThanZero();
    error DSC__BurnExceedsBalance();
    error DSC_NotZeroAddress();

    /**
     * Constructor
     */
    constructor() ERC20("Decentralised Stable Coin", "DSC") Ownable(msg.sender) {}

    /**
     * Functions
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DSC__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DSC__BurnExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DSC_NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DSC__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
