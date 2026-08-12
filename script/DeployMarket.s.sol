// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {ICatFactory} from "./interfaces/ICatFactory.sol";
import {IDaddy} from "./interfaces/IDaddy.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// forge script script/DeployMarket.s.sol:DeployMarket --verify --slow -g 250 --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployMarket is Script {

    // Parameters
    address public constant BORROW_TOKEN = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address public constant COLLATERAL_TOKEN = address(0x23346B04a7f55b8760E5860AA5A77383D63491cD); // ysyBOLD

    // Deployed contracts
    ICatFactory public constant FACTORY = ICatFactory(0xfFc787AD990dA8f73dDA2B971Dce31C0D9d2501F);
    IDaddy public constant DADDY = IDaddy(0x4e8341C77c94cCE982AB96d92BB28D69f4638290);
    IRegistry public constant REGISTRY = IRegistry(0x9117440a7D03238905d1C8908157Bd7a547c77c8);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);
        require(_deployer == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
        console.log("Deployer address: %s", _deployer);

        vm.startBroadcast(_pk);

        // Deploy the ysyBOLD/USDC price oracle
        address _priceOracle = deployCode("ysybold_to_usdc_oracle");

        // Deploy market
        (address _troveManager, address _sortedTroves, address _dutchDesk, address _auction, address _lender) = FACTORY.deploy(
            ICatFactory.DeployParams({
                borrow_token: BORROW_TOKEN,
                collateral_token: COLLATERAL_TOKEN,
                price_oracle: _priceOracle,
                minimum_debt: 500 * 10 ** IERC20Metadata(BORROW_TOKEN).decimals(), // 500 tokens
                safe_collateral_ratio: 120, // 120%
                minimum_collateral_ratio: 110, // 110%
                max_penalty_collateral_ratio: 105, // 105%
                min_liquidation_fee: 50, // 0.5%
                max_liquidation_fee: 500, // 5%
                upfront_interest_period: 1 days,
                interest_rate_adj_cooldown: 7 days,
                repay_cooldown: 1 hours, // the max, so it's hard to arb the oracle price via redemptions
                minimum_price_buffer_percentage: 1e18 - 1e16, // 99%
                starting_price_buffer_percentage: 1e18, // 100%
                re_kick_starting_price_buffer_percentage: 1e18 + 1e15, // 100.1%
                step_duration: 60, // 1 minute
                step_decay_rate: 1, // 0.01%
                auction_length: 1 days,
                salt: bytes32(uint256(420))
            })
        );

        // // Accept Lender management
        // DADDY.execute(address(_lender), abi.encodeWithSelector(ITokenizedStrategy.acceptManagement.selector), 0, true);

        // // Endorse market
        // DADDY.execute(address(REGISTRY), abi.encodeWithSelector(IRegistry.endorse.selector, _troveManager), 0, true);

        console2.log("---------------------------------");
        console2.log("Price Oracle: ", _priceOracle);
        console2.log("Trove Manager: ", _troveManager);
        console2.log("Sorted Troves: ", _sortedTroves);
        console2.log("Dutch Desk: ", _dutchDesk);
        console2.log("Auction: ", _auction);
        console2.log("Lender: ", _lender);
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

}

// Price Oracle:  0x405568114Ee8058d0ca1Bbe95DA1f929279BaE65
// Trove Manager:  0xADf4E0226d59aac20272023c04B4DcF5Ade7Fc6E
// Sorted Troves:  0x268C2F12A22C0Ec8f8A4e4d3D8527Eb0cFc4C17b
// Dutch Desk:  0x8e5C69f8981C014fc5a438eA0D916F79c7B52A6D
// Auction:  0x068C6c7E1cb47df3852159F8cAb1Bb4000211e73
// Lender:  0xf4996Ca4190A1a3e7CF19AbE2F6eb712abd4a03C