// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20Like, IMapleGlobalsLike, IOracleLike, IUniswapRouterLike, ILiquidatorLike } from "../../interfaces/Interfaces.sol";

import { TestUtils } from "../../../modules/contract-test-utils/contracts/test.sol";

contract AuctioneerMock {

    address public owner;
    address public globals;
    address public fundsAsset;

    mapping(address => uint256) public allowedSlippageFor;
    mapping(address => uint256) public minRatioFor;

    constructor(address globals_, address fundsAsset_) {
        owner      = msg.sender;
        globals    = globals_;
        fundsAsset = fundsAsset_;
    }

    function __setValuesFor(address collateralAsset_, uint256 allowedSlippage_, uint256 minRatio_) external {
        allowedSlippageFor[collateralAsset_] = allowedSlippage_;
        minRatioFor[collateralAsset_]        = minRatio_;
    }

    function getExpectedAmount(address collateralAsset_, uint256 swapAmount_) public view returns (uint256 returnAmount_) {
        uint256 oracleAmount =
            swapAmount_
                * IMapleGlobalsLike(globals).getLatestPrice(collateralAsset_)  // Convert from `fromAsset` value.
                * 10 ** IERC20Like(fundsAsset).decimals()                      // Convert to `toAsset` decimal precision.
                * (10_000 - allowedSlippageFor[collateralAsset_])              // Multiply by allowed slippage basis points.
                / IMapleGlobalsLike(globals).getLatestPrice(fundsAsset)        // Convert to `toAsset` value.
                / 10 ** IERC20Like(collateralAsset_).decimals()                // Convert from `fromAsset` decimal precision.
                / 10_000;                                                      // Divide basis points for slippage.

        uint256 minRatioAmount = (swapAmount_ * minRatioFor[collateralAsset_]) / (10 ** IERC20Like(collateralAsset_).decimals());

        return oracleAmount > minRatioAmount ? oracleAmount : minRatioAmount;
    }

}

contract EmptyContract {}

contract MapleGlobalsMock {

    bool public protocolPaused;

    mapping(address => address) public oracleFor;

    function getLatestPrice(address asset_) external view returns (uint256 price_) {
        ( , int256 price, , , ) = IOracleLike(oracleFor[asset_]).latestRoundData();
        return uint256(price);
    }

    function setPriceOracle(address asset_, address oracle_) external {
        oracleFor[asset_] = oracle_;
    }

    function setProtocolPaused(bool paused_) external {
        protocolPaused = paused_;
    }

}

// Contract to perform fake arbitrage transactions to prop price back up.
contract Rebalancer is TestUtils {

    function swap(
        address router_,
        uint256 amountOut_,
        uint256 amountInMax_,
        address fromAsset_,
        address middleAsset_,
        address toAsset_
    )
        external
    {
        IERC20Like(fromAsset_).approve(router_, amountInMax_);

        bool hasMiddleAsset = middleAsset_ != toAsset_ && middleAsset_ != address(0);

        address[] memory path = new address[](hasMiddleAsset ? 3 : 2);

        path[0] = address(fromAsset_);
        path[1] = hasMiddleAsset ? middleAsset_ : toAsset_;

        if (hasMiddleAsset) {
            path[2] = toAsset_;
        }

        IUniswapRouterLike(router_).swapTokensForExactTokens(
            amountOut_,
            amountInMax_,
            path,
            address(this),
            block.timestamp
        );
    }

}

contract ReentrantLiquidator {

    address lender;
    uint256 swapAmount;

    function flashBorrowLiquidation(
        address lender_,
        uint256 swapAmount_
    )
        external
    {
        lender     = lender_;
        swapAmount = swapAmount_;

        ILiquidatorLike(lender_).liquidatePortion(
            swapAmount_,
            type(uint256).max,
            abi.encodeWithSelector(
                this.reenter.selector
            )
        );
    }

    function reenter() external {
        ILiquidatorLike(lender).liquidatePortion(swapAmount, type(uint256).max, new bytes(0));
    }

}
