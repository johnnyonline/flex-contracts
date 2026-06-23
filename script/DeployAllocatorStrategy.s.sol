// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IStrategy} from "../src/allocator/interfaces/IStrategy.sol";
import {ICentralAPROracle} from "./interfaces/ICentralAPROracle.sol";
import {ICommonReportTrigger} from "./interfaces/ICommonReportTrigger.sol";

import {StrategyFactory} from "../src/allocator/StrategyFactory.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployAllocatorStrategy.s.sol:DeployAllocatorStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployAllocatorStrategy is Script {

    // Market params
    string public constant NAME = "Flex siUSD/USDC Lender";
    address public constant ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address public constant LENDER = 0x9a28d962aF18B304cA2bA16bf998D1EaF8452456; // Flex siUSD/USDC Lender

    // Yearn addresses
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // sms mainnet
    address public constant VAULT = 0x863687e4E9751b57F38b4B0ebA04744C72d0f7B8; // yvFlexUSDC mainnet
    address public constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHaaS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // accountant mainnet

    // Deployed contracts
    address public constant FIXED_REPORT_TRIGGER = 0xb9F57B62Cbe9463da16E5b75e3B809321a0eA871;
    address public constant STRATEGY_APR_ORACLE = 0xfd6117E7dC92Dd284412a0eE9FC2C9bDb945B9d1;
    ICentralAPROracle public constant CENTRAL_APR_ORACLE = ICentralAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);
    ICommonReportTrigger public constant COMMON_REPORT_TRIGGER = ICommonReportTrigger(0xf8dF17a35c88AbB25e83C92f9D293B4368b9D52D);
    StrategyFactory public constant FACTORY = StrategyFactory(0x7A3B96E84156d22Cdb53CbfC0B035Ddd61805266);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        address _deployerAddress = vm.addr(_pk);

        require(_deployerAddress == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
        console.log("Deployer address: %s", _deployerAddress);

        vm.startBroadcast(_pk);

        // Deploy the Strategy
        IStrategy _strategy = IStrategy(FACTORY.deploy(ASSET, LENDER, _deployerAddress, KEEPER, ACCOUNTANT, NAME));

        // Set up the Strategy
        _strategy.acceptManagement();
        _strategy.setProfitMaxUnlockTime(0 days);
        _strategy.setAllowed(VAULT, true);
        _strategy.setPerformanceFee(0);
        _strategy.setPendingManagement(SMS);

        // Set APR oracle for the strategy
        CENTRAL_APR_ORACLE.setOracle(address(_strategy), STRATEGY_APR_ORACLE);

        // Set report trigger for the strategy
        COMMON_REPORT_TRIGGER.setCustomStrategyTrigger(address(_strategy), FIXED_REPORT_TRIGGER);

        console2.log("---------------------------------");
        console2.log("Strategy: ", address(_strategy));
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

}
