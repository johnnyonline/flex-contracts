// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./Base.sol";

interface ILockedYvusdOracle {

    function get_price() external view returns (uint256);
    function get_price(
        bool scaled
    ) external view returns (uint256);

}

contract LockedYvusdOracleTests is Base {

    address public constant YVUSD = 0x696d02Db93291651ED510704c9b286841d506987;
    address public constant LOCKED_YVUSD = 0xAaaFEa48472f77563961Cdb53291DEDfB46F9040;

    ILockedYvusdOracle public lockedYvusdOracle;

    function setUp() public override {
        Base.setUp();

        lockedYvusdOracle = ILockedYvusdOracle(deployCode("locked_yvusd_to_usdc_oracle"));
    }

    function test_lockedYvusdOracle() public {
        console2.log("yvUSD/USDC price:", IERC4626(YVUSD).convertToAssets(1e6));
        console2.log("Locked yvUSD/USDC price:", lockedYvusdOracle.get_price(false));

        assertEq(lockedYvusdOracle.get_price(false), _expectedPrice(), "E0");
        assertEq(lockedYvusdOracle.get_price(), _expectedPrice() * 1e18, "E1");
    }

    function test_lockedYvusdOracle_followsExchangeRates() public {
        // A move in the Locked yvUSD exchange rate flows through both hops, there are no bounds
        vm.mockCall(LOCKED_YVUSD, abi.encodeWithSelector(IERC4626.convertToAssets.selector, 1e6), abi.encode(2e6));
        assertEq(lockedYvusdOracle.get_price(false), _expectedPrice(), "E0");
        assertEq(lockedYvusdOracle.get_price(false), IERC4626(YVUSD).convertToAssets(2e6) * 1e12, "E1");
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Mirror the oracle's math against the live vault state
    function _expectedPrice() internal view returns (uint256) {
        return IERC4626(YVUSD).convertToAssets(IERC4626(LOCKED_YVUSD).convertToAssets(1e6)) * 1e12;
    }

}
