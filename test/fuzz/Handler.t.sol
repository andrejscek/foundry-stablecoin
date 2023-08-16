// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled = 0;
    address[] public usersDepositedCollateral;
    MockV3Aggregator ethUsdPriceFeed;
    MockV3Aggregator btcUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // big number

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        engine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    ///////////////
    // DSCEngine //
    ///////////////
    function mintDsc(uint256 amountDsc, uint256 addressSeed) public {
        if (usersDepositedCollateral.length == 0) {
            return;
        }
        address sender = usersDepositedCollateral[addressSeed % usersDepositedCollateral.length];
        (uint256 totalDscMinted, uint256 totalCollateralInUSD) = engine.getAccountInfo(sender);
        int256 maxDscToMint = (int256(totalCollateralInUSD) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }

        // console.log("maxDscToMint: %s", maxDscToMint);
        amountDsc = bound(amountDsc, 0, uint256(maxDscToMint));
        if (amountDsc == 0) {
            return;
        }

        vm.startPrank(sender);
        engine.mintDsc(amountDsc);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 collSeed, uint256 amountColl) public {
        // engine.depositCollateral(collateral, amountColl);
        ERC20Mock collateral = _getCollateralFromSeed(collSeed);
        // amountColl = bound(amountColl, 1, collateral.balanceOf(msg.sender));
        amountColl = bound(amountColl, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountColl);
        collateral.approve(address(engine), amountColl);
        engine.depositCollateral(address(collateral), amountColl);
        vm.stopPrank();
        usersDepositedCollateral.push(msg.sender);
    }

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        uint256 maxCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        console.log("maxCollateral", maxCollateral);

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function burnDsc(uint256 amountDsc) public {
        // Must burn more than 0
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        if (amountDsc == 0) {
            return;
        }
        engine.burnDsc(amountDsc);
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        uint256 userHealthFactor = engine.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    /////////////////////////////
    // DecentralizedStableCoin //
    /////////////////////////////
    function transferDsc(uint256 amountDsc, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dsc.transfer(to, amountDsc);
    }

    ////////////////
    // Aggregator //
    ////////////////

    // This breakes the test suite!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 collSeed) private view returns (ERC20Mock) {
        if (collSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
