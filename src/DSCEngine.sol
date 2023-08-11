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
    error DSCEngine__DepositTransferFailed();
    error DSCEngine__MintTransferFailed();
    error DSCEngine__BreakesHelthFactor(uint256 healthFactor);

    //////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // 200% collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToCollateralofTokenDeposited
    mapping(address user => uint256) private s_DSCMinted; // userToDscMinted
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

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
    function depositCollateralAndMintDsc() external {}

    /*
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToke(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__DepositTransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /* @notice follows CEI pattern
     * @param ammountDscToMin The ammount of dsc to mint
     * @notice they must have more collateral value than the min treshold
     */
    function mintDsc(uint256 ammountDscToMin) external moreThanZero(ammountDscToMin) nonReentrant {
        s_DSCMinted[msg.sender] += ammountDscToMin;
        // check if minted too much
        _revertIfHelthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, ammountDscToMin);
        if (!minted) {
            revert DSCEngine__MintTransferFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

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
        totalCollateralInUSD = getAccountCollaterValue(user);
    }

    function _helthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralInUSD) = _getAccountInfo(user);

        uint256 collateralAdjustedForTreshold = (totalCollateralInUSD * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForTreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHelthFactorIsBroken(address user) private view {
        uint256 healthFactor = _helthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakesHelthFactor(healthFactor);
        }
    }

    ///////////////////////////////////////
    // Private & Internal View Functions //
    //////////////////////////////////////

    function getAccountCollaterValue(address user) public view returns (uint256 totalCollateralInUSD) {
        // loop through all the collateral tokens and get the price of each one in USD

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUSD += getUsdValue(token, amount);
        }
        return totalCollateralInUSD;
    }

    function getUsdValue(address token, uint256 ammount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        uint8 decimals = priceFeed.decimals();
        uint256 feed_precision = PRECISION / uint256(10 ** decimals); // standardize precision to multiply price to 18 decimals
        return ((uint256(price) * feed_precision * ammount) / PRECISION);
    }
}
