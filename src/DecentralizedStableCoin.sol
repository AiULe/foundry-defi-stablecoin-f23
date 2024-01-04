// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

/**
    @title DecentrailizedStableCoin
    @author Xaun
    @notice 
    Collateral: Exogenous (ETH & BTC)
    Minting: Algorithmic
    Relative Stability: Pagged to USD
    This is the contract meant to be governed by DSCEngine. This contract is just ERC20
    implementation of our stablecoin system. 
 */

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentrailizedStableCoin__MustBeMoreThanZero();
    error DecentrailizedStableCoin__BurnAmountExceedsBalance();
    error DecentrailizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentrailizedStableCoin", "DSC") Ownable() {}

    function burn(uint256 _amount) public override onlyOwner {
        //onlyOwner只有所有者才能使用这个函数
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentrailizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentrailizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //使用父类的burn函数
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentrailizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentrailizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
