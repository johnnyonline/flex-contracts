// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

import "forge-std/Test.sol";

interface IChainlinkFeed {

    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);

}

interface IERC4626Like {

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256);
    function decimals() external view returns (uint8);
    function asset() external view returns (address);

}

contract PriceOracleTests is Test {

    // ---- Mainnet addresses (must match sfrxusd_to_usdc_oracle.vy) ----
    address public constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6; // collateral
    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29; // sfrxUSD underlying
    address public constant FRXUSD_USD_FEED = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;
    address public constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    uint256 public constant WAD = 1e18;
    // USDC borrow (6 dec), sfrxUSD collateral (18 dec) => 10^(36 + 6 - 18) = 10^24
    uint256 public constant ORACLE_SCALE_FACTOR = 1e24;
    // Chainlink USD feeds report 8 decimals; $1.00 == 1e8
    uint256 public constant FEED_PEG = 1e8;

    // Pinned to the same block Base.sol caches so the fork is reused
    uint256 public constant FORK_BLOCK = 24_541_660;

    IPriceOracle public priceOracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        priceOracle = IPriceOracle(deployCode("sfrxusd_to_usdc_oracle"));
    }

    // ---- Independent recomputation of the oracle math (written from spec, not copied) ----

    function _pps() internal view returns (uint256) {
        // frxUSD redeemable for one whole sfrxUSD share, in frxUSD (18) decimals
        return IERC4626Like(SFRXUSD).convertToAssets(10 ** IERC4626Like(SFRXUSD).decimals());
    }

    function _expectedUnscaledPriceWith(
        uint256 _frxusdUsd,
        uint256 _usdcUsd
    ) internal view returns (uint256) {
        return _frxusdUsd * WAD / _usdcUsd * _pps() / WAD;
    }

    function _expectedUnscaledPrice() internal view returns (uint256) {
        uint256 _frxusdUsd = uint256(IChainlinkFeed(FRXUSD_USD_FEED).latestAnswer());
        uint256 _usdcUsd = uint256(IChainlinkFeed(USDC_USD_FEED).latestAnswer());
        return _expectedUnscaledPriceWith(_frxusdUsd, _usdcUsd);
    }

    function _liveAnswer(
        address _feed
    ) internal view returns (uint256) {
        return uint256(IChainlinkFeed(_feed).latestAnswer());
    }

    function _mockAnswer(
        address _feed,
        uint256 _answer
    ) internal {
        vm.mockCall(_feed, abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector), abi.encode(int256(_answer)));
    }

    // ============================================================================================
    // Baseline
    // ============================================================================================

    function test_sanity_onchainFacts() public {
        // sfrxUSD is an 18-decimal ERC4626 whose underlying is frxUSD
        assertEq(IERC4626Like(SFRXUSD).decimals(), 18, "!sfrxUSD decimals");
        assertEq(IERC4626Like(SFRXUSD).asset(), FRXUSD, "!sfrxUSD asset");
        // Both feeds report 8 decimals (asserted in the oracle constructor too)
        assertEq(IChainlinkFeed(FRXUSD_USD_FEED).decimals(), 8, "!frxUSD feed decimals");
        assertEq(IChainlinkFeed(USDC_USD_FEED).decimals(), 8, "!usdc feed decimals");
    }

    function test_priceOracle_unscaled() public {
        uint256 _price = priceOracle.get_price(false);
        console2.log("unscaled price:", _price);

        // Matches an independently computed value
        assertEq(_price, _expectedUnscaledPrice(), "!unscaled");

        // Sanity: 1 sfrxUSD ~ 1.18 USDC at the pinned block; bound it loosely
        assertGt(_price, 1.05e18, "price too low");
        assertLt(_price, 1.4e18, "price too high");
    }

    function test_priceOracle_scaled() public {
        uint256 _price = priceOracle.get_price(true);
        console2.log("scaled price:  ", _price);

        uint256 _expected = _expectedUnscaledPrice() * ORACLE_SCALE_FACTOR / WAD;
        assertEq(_price, _expected, "!scaled");

        // scaled == unscaled * 1e6 (10^(36+6-18) / 10^18)
        assertEq(_price, priceOracle.get_price(false) * 1e6, "!scale relationship");
    }

    function test_priceOracle_defaultIsScaled() public {
        // Vyper default arg is `scaled = True`
        assertEq(priceOracle.get_price(), priceOracle.get_price(true), "!default scaled");
    }

    // ============================================================================================
    // Depegs - USDC (the borrow/quote token)
    // ============================================================================================

    // USDC cheaper than $1 => each sfrxUSD buys MORE USDC => oracle price goes UP
    function test_priceOracle_usdcDepegDown() public {
        uint256 _baseline = priceOracle.get_price(false);
        uint256 _frxusd = _liveAnswer(FRXUSD_USD_FEED);
        uint256 _usdcDepegged = (FEED_PEG * 95) / 100; // $0.95

        _mockAnswer(USDC_USD_FEED, _usdcDepegged);

        uint256 _price = priceOracle.get_price(false);
        console2.log("price with usdc depeg down: ", _price);
        assertEq(_price, _expectedUnscaledPriceWith(_frxusd, _usdcDepegged), "!usdc depeg down math");
        assertGt(_price, _baseline, "usdc depeg down should raise price");
    }

    // USDC above $1 => each sfrxUSD buys FEWER USDC => oracle price goes DOWN
    function test_priceOracle_usdcDepegUp() public {
        uint256 _baseline = priceOracle.get_price(false);
        uint256 _frxusd = _liveAnswer(FRXUSD_USD_FEED);
        uint256 _usdcDepegged = (FEED_PEG * 105) / 100; // $1.05

        _mockAnswer(USDC_USD_FEED, _usdcDepegged);

        uint256 _price = priceOracle.get_price(false);
        console2.log("price with usdc depeg up:   ", _price);
        assertEq(_price, _expectedUnscaledPriceWith(_frxusd, _usdcDepegged), "!usdc depeg up math");
        assertLt(_price, _baseline, "usdc depeg up should lower price");
    }

    // ============================================================================================
    // Depegs - frxUSD (the sfrxUSD underlying)
    // ============================================================================================

    // frxUSD below $1 => collateral worth less => oracle price goes DOWN
    function test_priceOracle_frxusdDepegDown() public {
        uint256 _baseline = priceOracle.get_price(false);
        uint256 _usdc = _liveAnswer(USDC_USD_FEED);
        uint256 _frxusdDepegged = (FEED_PEG * 90) / 100; // $0.90

        _mockAnswer(FRXUSD_USD_FEED, _frxusdDepegged);

        uint256 _price = priceOracle.get_price(false);
        console2.log("price with frxusd depeg down: ", _price);
        assertEq(_price, _expectedUnscaledPriceWith(_frxusdDepegged, _usdc), "!frxusd depeg down math");
        assertLt(_price, _baseline, "frxusd depeg down should lower price");
    }

    // frxUSD above $1 => collateral worth more => oracle price goes UP
    function test_priceOracle_frxusdDepegUp() public {
        uint256 _baseline = priceOracle.get_price(false);
        uint256 _usdc = _liveAnswer(USDC_USD_FEED);
        uint256 _frxusdDepegged = (FEED_PEG * 110) / 100; // $1.10

        _mockAnswer(FRXUSD_USD_FEED, _frxusdDepegged);

        uint256 _price = priceOracle.get_price(false);
        console2.log("price with frxusd depeg up:   ", _price);
        assertEq(_price, _expectedUnscaledPriceWith(_frxusdDepegged, _usdc), "!frxusd depeg up math");
        assertGt(_price, _baseline, "frxusd depeg up should raise price");
    }

}
