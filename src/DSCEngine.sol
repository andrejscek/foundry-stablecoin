// SPDX-License-Identifier: MIT

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

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Andrej Scek
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be overcollateralized. At no point should the value of all the collateral <= the $ backing the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    ////////////
    // Errors //
    ////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLenght();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__HealthFactorIsOK();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__MintFailed();

    ///////////
    // Type //
    ///////////

    using OracleLib for AggregatorV3Interface;

    //////////////////////
    // State Variables //
    /////////////////////

    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATOR_BONUS = 10; // 10% bonus for liquidators
    // we are only safe between 200% and 110%, if the price of assets securing the system plummets too fast, it breaks the entire system

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToCollateralofTokenDeposited
    mapping(address user => uint256) private s_DSCMinted; // userToDscMinted
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);
    ///////////////
    // Modifiers //
    ///////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToke(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLenght();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /*
     * @param tokenCollAdrs The address of the collateral token
     * @param amountColl The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice depositCollateral and mintDsc in one function
     */
    function depositCollateralAndMintDsc(address tokenCollAdrs, uint256 amountColl, uint256 amountDscToMint) external {
        depositCollateral(tokenCollAdrs, amountColl);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToke(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * @param tokenCollAdrs The address of the collateral token
    * @param amountColl The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * @notice redeemCollateral and burnDsc in one function
    */
    function redeemCollateralForDsc(address tokenCollAdrs, uint256 ammountColl, uint256 amountDscToBurn)
        external
        moreThanZero(ammountColl)
    {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _reedemCollateral(msg.sender, msg.sender, tokenCollAdrs, ammountColl);
        revertIfHelthFactorIsBroken(msg.sender);
        // redeemCollateral(tokenCollAdrs, ammountColl);
        // burnDsc(amountDscToBurn);
        // redeemCollateral alread checks health factor
    }

    // health after pull should be > 1
    function redeemCollateral(address tokenCollateralAdrs, uint256 amountColl)
        public
        moreThanZero(amountColl)
        nonReentrant
    {
        _reedemCollateral(msg.sender, msg.sender, tokenCollateralAdrs, amountColl);
        revertIfHelthFactorIsBroken(msg.sender);
    }

    /* @notice follows CEI pattern
     * @param ammountDscToMin The ammount of dsc to mint
     * @notice they must have more collateral value than the min treshold
     */
    function mintDsc(uint256 ammountDscToMin) public moreThanZero(ammountDscToMin) nonReentrant {
        s_DSCMinted[msg.sender] += ammountDscToMin;
        // check if minted too much
        revertIfHelthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, ammountDscToMin);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        revertIfHelthFactorIsBroken(msg.sender); // TODO needed? removing debth can not break health factor
    }

    // if someone has a health factor bellow 1, we will pay you to liquidate someone
    // under $75 backing $50 DSC > pay someone $25 to repay debt
    /*
    * @param collateral The address of the collateral token
    * @param user The address of the user
    * @param debtToCover The amount of debt to cover
    * @notice you can partialy liquidate a user, as long you improve the health factor to abouve 1
    * @notice you will get a reward for liquidating someone
    * @notice A known bug would be if the protocol were were 100% or less collateralized, then we woudn't be able to incentive the liquidators
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingHF = _helthFactor(user);
        if (startingHF > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOK();
        }
        // burn DSC debt and take there collateral
        // bad user: $140 ETH, $100 DSC > debthToCover = $100
        // $100 of DSC = ? ETH
        uint256 tokenAmountFromDebthCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // give them a 10% bonus > give $110 of WETH for $100 of DSC
        // implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a tresury
        uint256 bonusCollateral = (tokenAmountFromDebthCovered * LIQUIDATOR_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollToRedeem = tokenAmountFromDebthCovered + bonusCollateral;
        _reedemCollateral(user, msg.sender, collateral, totalCollToRedeem);
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHF = _helthFactor(user);
        if (endingUserHF < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        revertIfHelthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // Private & Internal View Functions //
    //////////////////////////////////////

    /*
    * Returns how close to liquidation the user is, bellow 1 means the user can be liquidated
    * @param user The address of the user
    * @return The health factor of the user
    */
    function _getAccountInfo(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralInUSD)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralInUSD = getAccountCollateralValue(user);
    }

    function _helthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralInUSD) = _getAccountInfo(user);

        return _calculateHealthFactor(totalDscMinted, totalCollateralInUSD);
    }

    function revertIfHelthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _helthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    function _reedemCollateral(address from, address to, address tokenCollAdrs, uint256 amountColl) private {
        s_collateralDeposited[from][tokenCollAdrs] -= amountColl;
        emit CollateralRedeemed(from, to, tokenCollAdrs, amountColl);

        bool success = IERC20(tokenCollAdrs).transfer(to, amountColl);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /* @dev low-level internal function, do not call unless the caller is checking for health factors beiing broken
    */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // backup check, unreachable since transferFrom would fail
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collAdjustedForTreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collAdjustedForTreshold * PRECISION) / totalDscMinted;
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        uint8 decimals = priceFeed.decimals();
        uint256 afp = PRECISION / uint256(10 ** decimals);

        return ((uint256(price) * afp) * amount) / PRECISION;
    }
    ///////////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 amountUsdInWei) public view returns (uint256) {
        // $/ETH ETH? > $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        uint8 decimals = priceFeed.decimals();
        uint256 feed_precision = PRECISION / uint256(10 ** decimals); // standardize precision to multiply price to 18 decimals

        return (amountUsdInWei * PRECISION) / (uint256(price) * feed_precision);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralInUSD) {
        // loop through all the collateral tokens and get the price of each one in USD

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUSD += _getUsdValue(token, amount);
        }
        return totalCollateralInUSD;
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getAccountInfo(address user) external view returns (uint256 totalDscMinted, uint256 collateralInUSD) {
        (totalDscMinted, collateralInUSD) = _getAccountInfo(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralInUSD) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralInUSD);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _helthFactor(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATOR_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
