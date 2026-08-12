// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./Base.sol";

interface IYsyboldOracle {

    function get_price() external view returns (uint256);
    function get_price(
        bool scaled
    ) external view returns (uint256);
    function price() external view returns (uint256);
    function set_depeg_mode(
        bool depeg_mode
    ) external;
    function depeg_mode() external view returns (bool);
    function DADDY() external view returns (address);

}

interface ICurveStableSwapNG {

    function price_oracle(
        uint256 i
    ) external view returns (uint256);

}

contract YsyboldOracleTests is Base {

    address public constant YSYBOLD = 0x23346B04a7f55b8760E5860AA5A77383D63491cD;
    address public constant YBOLD = 0x9F4330700a36B29952869fac9b33f45EEdd8A3d8;
    address public constant CURVE_POOL = 0xEFc6516323FbD28e80B85A497B65A86243a54B3E;

    IYsyboldOracle public ysyboldOracle;

    function setUp() public override {
        Base.setUp();

        ysyboldOracle = IYsyboldOracle(deployCode("ysybold_to_usdc_oracle"));
    }

    function test_ysyboldOracle() public {
        uint256 _boldPrice = 1e36 / ICurveStableSwapNG(CURVE_POOL).price_oracle(0);
        console2.log("BOLD/USDC price:", _boldPrice);
        console2.log("ysyBOLD/USDC price:", ysyboldOracle.get_price(false));

        assertEq(ysyboldOracle.DADDY(), address(DADDY), "E0");
        assertFalse(ysyboldOracle.depeg_mode(), "E1");
        assertEq(ysyboldOracle.get_price(false), _expectedPrice(), "E2");
        assertEq(ysyboldOracle.get_price(), _expectedPrice() * 1e6, "E3");
        assertEq(ysyboldOracle.price(), ysyboldOracle.get_price(), "E4");
    }

    function test_ysyboldOracle_capped() public {
        // An EMA implying BOLD above 1.01 USDC is capped
        vm.mockCall(CURVE_POOL, abi.encodeWithSignature("price_oracle(uint256)", 0), abi.encode(0.98e18));
        assertEq(ysyboldOracle.get_price(false), _boldPerShare() * 1.01e18 / 1e18, "E0");
    }

    function test_ysyboldOracle_flooredUnlessDepegMode() public {
        // An EMA implying BOLD below 0.99 USDC is floored
        uint256 _ema = 1.02e18;
        vm.mockCall(CURVE_POOL, abi.encodeWithSignature("price_oracle(uint256)", 0), abi.encode(_ema));
        assertEq(ysyboldOracle.get_price(false), _boldPerShare() * 0.99e18 / 1e18, "E0");

        // Daddy lifts the floor and the raw price flows through
        vm.prank(address(DADDY));
        ysyboldOracle.set_depeg_mode(true);
        assertTrue(ysyboldOracle.depeg_mode(), "E1");
        assertEq(ysyboldOracle.get_price(false), _boldPerShare() * (1e36 / _ema) / 1e18, "E2");

        // And can restore it
        vm.prank(address(DADDY));
        ysyboldOracle.set_depeg_mode(false);
        assertEq(ysyboldOracle.get_price(false), _boldPerShare() * 0.99e18 / 1e18, "E3");
    }

    function test_ysyboldOracle_setDepegMode_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != address(DADDY));
        vm.prank(_wrongCaller);
        vm.expectRevert("!daddy");
        ysyboldOracle.set_depeg_mode(true);
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev BOLD value of one ysyBOLD share
    function _boldPerShare() internal view returns (uint256) {
        return IERC4626(YBOLD).convertToAssets(IERC4626(YSYBOLD).convertToAssets(1e18));
    }

    /// @dev Mirror the oracle's math against the live pool state
    function _expectedPrice() internal view returns (uint256) {
        uint256 _boldPrice = 1e36 / ICurveStableSwapNG(CURVE_POOL).price_oracle(0);
        if (_boldPrice > 1.01e18) _boldPrice = 1.01e18;
        if (_boldPrice < 0.99e18) _boldPrice = 0.99e18;
        return _boldPerShare() * _boldPrice / 1e18;
    }

}
