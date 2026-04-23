// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

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
    address public constant COLLATERAL_TOKEN = address(0x696d02Db93291651ED510704c9b286841d506987); // yvUSD

    // Deployed contracts
    ICatFactory public constant FACTORY = ICatFactory(0x609CbB93c1F02552967A5C457047a13e6b70B6d5);
    IDaddy public constant DADDY = IDaddy(0x4e8341C77c94cCE982AB96d92BB28D69f4638290);
    IRegistry public constant REGISTRY = IRegistry(0xA6D5efF88aB2D192db11A32912c346c8c0AFe125);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);
        require(_deployer == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
        console.log("Deployer address: %s", _deployer);

        vm.startBroadcast(_pk);

        // Deploy price oracle
        address _priceOracle = deployCode("yvusd_to_usdc_oracle");

        // Deploy market
        (address _troveManager, address _sortedTroves, address _dutchDesk, address _auction, address _lender) = FACTORY.deploy(
            ICatFactory.DeployParams({
                borrow_token: BORROW_TOKEN,
                collateral_token: COLLATERAL_TOKEN,
                price_oracle: _priceOracle,
                minimum_debt: 500,
                safe_collateral_ratio: 120, // 120%
                minimum_collateral_ratio: 110, // 110%
                max_penalty_collateral_ratio: 105, // 105%
                min_liquidation_fee: 50, // 0.5%
                max_liquidation_fee: 500, // 5%
                upfront_interest_period: 7 days,
                interest_rate_adj_cooldown: 7 days,
                minimum_price_buffer_percentage: 1e18 - 1e16, // 99%
                starting_price_buffer_percentage: 1e18, // 100%
                re_kick_starting_price_buffer_percentage: 1e18 + 1e15, // 100.1%
                step_duration: 60, // 1 minute
                step_decay_rate: 1, // 0.01%
                auction_length: 1 days,
                salt: bytes32(uint256(420))
            })
        );

        // Accept Lender management
        DADDY.execute(address(_lender), abi.encodeWithSelector(ITokenizedStrategy.acceptManagement.selector), 0, true);

        // Endorse market
        DADDY.execute(address(REGISTRY), abi.encodeWithSelector(IRegistry.endorse.selector, _troveManager), 0, true);

        console2.log("---------------------------------");
        console2.log("Trove Manager: ", _troveManager);
        console2.log("Sorted Troves: ", _sortedTroves);
        console2.log("Dutch Desk: ", _dutchDesk);
        console2.log("Auction: ", _auction);
        console2.log("Lender: ", _lender);
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

}
