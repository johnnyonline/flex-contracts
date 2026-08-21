// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./Base.sol";

interface IYvcrvusdOracle {

    function get_price() external view returns (uint256);
    function get_price(
        bool scaled
    ) external view returns (uint256);

}

interface ICurveStableSwap {

    function price_oracle() external view returns (uint256);

}

contract YvcrvusdOracleTests is Base {

    address public constant YVCRVUSD = 0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F;
    address public constant CURVE_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    IYvcrvusdOracle public yvcrvusdOracle;

    function setUp() public override {
        Base.setUp();

        yvcrvusdOracle = IYvcrvusdOracle(deployCode("yvcrvusd_to_usdc_oracle"));
    }

    function test_yvcrvusdOracle() public {
        uint256 _crvusdPrice = ICurveStableSwap(CURVE_POOL).price_oracle();
        console2.log("crvUSD/USDC price:", _crvusdPrice);
        console2.log("yvcrvUSD/USDC price:", yvcrvusdOracle.get_price(false));

        assertEq(yvcrvusdOracle.get_price(false), _expectedPrice(), "E0");
        assertEq(yvcrvusdOracle.get_price(), _expectedPrice() * 1e6, "E1");
    }

    function test_yvcrvusdOracle_capped() public {
        // An EMA implying crvUSD above 1.01 USDC is capped
        vm.mockCall(CURVE_POOL, abi.encodeWithSignature("price_oracle()"), abi.encode(1.02e18));
        assertEq(yvcrvusdOracle.get_price(false), _crvusdPerShare() * 1.01e18 / 1e18, "E0");
    }

    function test_yvcrvusdOracle_noFloor() public {
        // A depegged EMA flows through, there is no floor
        uint256 _ema = 0.9e18;
        vm.mockCall(CURVE_POOL, abi.encodeWithSignature("price_oracle()"), abi.encode(_ema));
        assertEq(yvcrvusdOracle.get_price(false), _crvusdPerShare() * _ema / 1e18, "E0");
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev crvUSD value of one yvcrvUSD share
    function _crvusdPerShare() internal view returns (uint256) {
        return IERC4626(YVCRVUSD).convertToAssets(1e18);
    }

    /// @dev Mirror the oracle's math against the live pool state
    function _expectedPrice() internal view returns (uint256) {
        uint256 _crvusdPrice = ICurveStableSwap(CURVE_POOL).price_oracle();
        if (_crvusdPrice > 1.01e18) _crvusdPrice = 1.01e18;
        return _crvusdPerShare() * _crvusdPrice / 1e18;
    }

}
