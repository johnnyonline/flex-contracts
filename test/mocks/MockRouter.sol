// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

import "forge-std/Test.sol";

contract MockRouter is Test {

    IPriceOracle immutable oracle;
    address immutable collateral;
    address immutable borrow;
    address immutable crvusd;

    uint256 immutable collateralPrecision;
    uint256 immutable borrowPrecision;
    uint256 immutable crvusdPrecision;

    uint256 immutable slippageBps;

    uint256 constant ORACLE_PRICE_SCALE = 1e36;
    uint256 constant BPS = 10_000;

    constructor(
        IPriceOracle _oracle,
        address _collateral,
        address _borrow,
        address _crvusd,
        uint256 _slippageBps
    ) {
        oracle = _oracle;
        collateral = _collateral;
        borrow = _borrow;
        crvusd = _crvusd;
        collateralPrecision = 10 ** IERC20Metadata(_collateral).decimals();
        borrowPrecision = 10 ** IERC20Metadata(_borrow).decimals();
        crvusdPrecision = 10 ** IERC20Metadata(_crvusd).decimals();
        slippageBps = _slippageBps;
    }

    fallback() external {
        (address tokenIn, address tokenOut) = abi.decode(msg.data, (address, address));

        // Pull input tokens via allowance
        uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate output amount from oracle price
        uint256 amountOut = _getAmountOut(tokenIn, tokenOut, amountIn);

        // Mint output tokens and send to caller
        deal(tokenOut, address(this), IERC20(tokenOut).balanceOf(address(this)) + amountOut);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    function _getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256) {
        uint256 price = oracle.get_price();
        uint256 exactOut;

        if (tokenIn == crvusd && tokenOut == collateral) {
            // crvUSD -> collateral
            exactOut = amountIn * borrowPrecision * ORACLE_PRICE_SCALE / (crvusdPrecision * price);
        } else if (tokenIn == collateral && tokenOut == crvusd) {
            // collateral -> crvUSD
            exactOut = amountIn * price * crvusdPrecision / (ORACLE_PRICE_SCALE * borrowPrecision);
        } else if (tokenIn == borrow && tokenOut == crvusd) {
            // borrow -> crvUSD (1:1 peg, adjust decimals)
            exactOut = amountIn * crvusdPrecision / borrowPrecision;
        } else if (tokenIn == crvusd && tokenOut == borrow) {
            // crvUSD -> borrow (1:1 peg, adjust decimals)
            exactOut = amountIn * borrowPrecision / crvusdPrecision;
        } else {
            revert("MockRouter: unsupported pair");
        }

        // Apply slippage
        return exactOut * (BPS - slippageBps) / BPS;
    }

}
