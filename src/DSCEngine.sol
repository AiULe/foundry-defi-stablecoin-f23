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

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
    @title DSCEngine
    @author Xuan
    The system is desigined to be as minimal as possible, and bave the maintain a 1 token == $1 peg.
    This stablecoin has the properties:
        - Exogenous Collateral
        - Dollar Pegged
        - Algoritmically Stable
    It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.

    Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.

    @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as deposition & withdrawing collateral
    @notice This contract is VERY loossely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    ///Errors       ///
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////////////
    ///Type                  ///
    ////////////////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////////////////
    ///State Variables       ///
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; //精度
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_Dsc;

    ////////////////////////////
    ///Events                ///
    ////////////////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    ///////////////////
    ///Modifiers    ///
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        //传入的代币地址在s_priceFeeds中有对应的价格源，就说明允许使用，否则不允许使用。
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////
    ///Functions    ///
    ///////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH / USD , BTC / USD , MKR / USD ,etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_Dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    ///External Function    ///
    ///////////////////////////
    /**
        用户存入以太坊或比特币，然后铸造DSC稳定币（我们自己写的合约）
     */
    /*
        @param tokenCollateralAddress the address of the token to deposit as collateral
        @param amountCollateral The amount of collateral to deposit
        @param amountDscToMint The amount of decentralized stablecoin to mint.
        @notice this function will deposit your collateral and mint DSC in one transcation.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
        @param tokenCollateralAddress The collateral address to redeem
        @Param amountCollateral The amount of collateral to redeem
        @param amountDscToBurn The amount of DSC to burn
        This function burns DSC and redeems underlying collateral in one transaction
    */
    /**
        用户可以将稳定币兑换回原始使用的抵押品
    */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        //先销毁DSC
        burnDsc(amountDscToBurn);
        //赎回抵押品
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
        @notice follows CEI
        @param tokenCollateralAddress The address of the token to deposit as collateral
        @param amountCollateral The amount of collateral to deposit.
        @notice 存入抵押品
     */
    //nonReentrant:不可重入修饰符
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    //赎回抵押品函数
    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    // CEI:Check, Effects, Interactions
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 1.check if the collateral value > DSC amount
    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
       @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they minted too much ($150 DSC , 100ETH)
        //铸造这些DSC会破坏HealthFactor ,就回滚 ，因为这个用户自己的抵押品价值低于DSC，不能让他铸造DSC，以免破坏合约。
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_Dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
        销毁DSC，更快换取原始抵押品
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
        清算
        100 ETH -> 50 DSC
        40 ETH -> 意思就是用ETH抵押的用户，就会被清算，不能允许在系统中占有一席之地
        清除头寸
     */
    /*
        $75 backing $50 DSC
        Liquidator take $75 backing and burns off the $50 DSC
        if someone is almost undercollateralized, we will pay you to liquidate them!
      */
    /*
        @param collateral The erc20 collateral address to liquidate from the user
        @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
        @param debtToCover The amount of DSC you want to burn to improve the users health factor
        @notice You Can partially liquidate a user.
        @notice You will get a liqudation bonus for taking the users funds.
        @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
        For example, if the price of the collateral plummeted before anyone could liquidated.

        Follows CEI: Checks, Effects, Interactions
     */
    /*
        1.首先他们（清算者）能够选择清算的用户和抵押品，并选择要偿还的债务
        他们（清算者），他们将能够通过监听这些来追踪用户和他们的头寸。
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC "debt";
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100    偿还100$的债务
        // $100 of DSC == ??? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100DSC  初步猜测，感觉是有10%奖励（（（110-100）/100） = 0.1）
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        //激励 鼓励人们进行清算，以便我们的协议永远不会资不抵债
        //抵押品的价值应该永远大于已发行的DSC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        //user: 被清算的用户
        //msg.sender: 清算者
        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        /*
            debtToCover: 用于偿还债务的数量
            user：用户
            msg.sender:支付款项的人
         */
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /////////////////////////////////
    // Private & Internal view Function //
    /////////////////////////////////

    /*
        @dev Low-Level internal function, do nor call unless the function calling it is checking for health factors being broken.
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_Dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        //This conditional is hypothically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_Dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        //to 清算者地址，将清算奖励发送给清算者
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
        Returns how close to liquidation a user is
        If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50000 / 100 = 500
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // return (collateralValueInUsd / totalDscMinted);

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collaterValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collaterValueInUsd = getAccountCollateralValueInUsd(user); //抵押品总价值（单位：美元）
    }

    // 1. Check health factor (do they have enough collateral ?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////////////
    // Public & External view Function //
    /////////////////////////////////

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        //通过美元算出相应的以太坊数量
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLastestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUsd(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLastestRoundData();
        //price decimal is 8
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }
}
