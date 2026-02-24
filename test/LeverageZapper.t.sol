// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ILeverageZapper} from "./interfaces/ILeverageZapper.sol";

import "./Base.sol";

contract LeverageZapperTests is Base {

    ILeverageZapper public leverageZapper;

    address constant ODOS_ROUTER = 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05;
    address constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    function setUp() public override {
        isLatestBlock = true;
        Base.setUp();

        // Deploy leverage zapper
        leverageZapper = ILeverageZapper(deployCode("leverage_zapper"));
        vm.label(address(leverageZapper), "LeverageZapper");
    }

    // ============================================================================================
    // Open leveraged trove
    // ============================================================================================

    function test_open_leveraged_trove() public {
        // Airdrop collateral to borrower
        uint256 userCollateral = 10 ether;
        airdrop(address(collateralToken), userBorrower, userCollateral);

        // Target 2x leverage
        uint256 targetLeverage = 2;
        uint256 additionalCollateral = userCollateral * (targetLeverage - 1);
        uint256 debtAmount = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = debtAmount * WAD / BORROW_TOKEN_PRECISION; // scale to crvUSD (18 decimals)

        // Add slippage buffer to debt
        debtAmount = debtAmount * 105 / 100;

        // Fund the lender
        mintAndDepositIntoLender(userLender, debtAmount);

        uint256 ownerIndex = block.timestamp;

        // Get swap data (skip if token is crvUSD)
        bool collateralIsCrvUSD = address(collateralToken) == CRVUSD;
        bool borrowIsCrvUSD = address(borrowToken) == CRVUSD;

        bytes memory collateralSwapData;
        if (!collateralIsCrvUSD) {
            collateralSwapData = _getEnsoSwapData(1, CRVUSD, address(collateralToken), flashLoanAmount, address(leverageZapper));
        }

        bytes memory debtSwapData;
        if (!borrowIsCrvUSD) {
            debtSwapData = _getEnsoSwapData(1, address(borrowToken), CRVUSD, debtAmount, address(leverageZapper));
        }

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), userCollateral);

        // Open leveraged trove
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: ownerIndex,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: collateralIsCrvUSD
                    ? ILeverageZapper.SwapData({router: address(0), data: ""})
                    : ILeverageZapper.SwapData({router: ENSO_ROUTER, data: collateralSwapData}),
                debt_swap: borrowIsCrvUSD
                    ? ILeverageZapper.SwapData({router: address(0), data: ""})
                    : ILeverageZapper.SwapData({router: ENSO_ROUTER, data: debtSwapData}),
                take_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Accept ownership
        vm.prank(userBorrower);
        troveManager.accept_ownership(troveId);

        // Verify trove
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertGt(trove.debt, 0, "E2");

        // Verify leverage: trove.collateral should be approximately targetLeverage * userCollateral
        uint256 expectedCollateral = userCollateral * targetLeverage;
        assertApproxEqRel(trove.collateral, expectedCollateral, 10e16, "E3"); // 10% tolerance

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E5");
        assertEq(IERC20(CRVUSD).balanceOf(address(leverageZapper)), 0, "E6");

        // Verify swept balances to borrower are dust
        assertLt(collateralToken.balanceOf(userBorrower), COLLATERAL_TOKEN_PRECISION / 100, "E7");
        assertLt(borrowToken.balanceOf(userBorrower), BORROW_TOKEN_PRECISION / 100, "E8");
        assertLt(IERC20(CRVUSD).balanceOf(userBorrower), 1e16, "E9");
    }

    // ============================================================================================
    // Enso sanity
    // ============================================================================================

    function test_enso_swap() public {
        address sender = address(this);
        address crvusd = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
        address wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        uint256 crvusdAmount = 5_000e18;

        bytes memory swapData = _getEnsoSwapData(1, crvusd, wsteth, crvusdAmount, sender);

        airdrop(crvusd, sender, crvusdAmount);
        IERC20(crvusd).approve(ENSO_ROUTER, crvusdAmount);
        (bool success,) = ENSO_ROUTER.call(swapData);
        assertTrue(success, "E0");
        assertGt(IERC20(wsteth).balanceOf(sender), 0, "E1");
    }

    // ============================================================================================
    // Odos sanity
    // ============================================================================================

    function test_odos_swap() public {
        address sender = address(this);
        address crvusd = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
        address wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        uint256 crvusdAmount = 5_000e18;

        bytes memory swapData = _getOdosSwapData(1, crvusd, wsteth, crvusdAmount, sender);

        airdrop(crvusd, sender, crvusdAmount);
        IERC20(crvusd).approve(ODOS_ROUTER, crvusdAmount);
        (bool success,) = ODOS_ROUTER.call(swapData);
        assertTrue(success, "E0");
        assertGt(IERC20(wsteth).balanceOf(sender), 0, "E1");
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    function _getEnsoSwapData(
        uint256 chainId,
        address inputToken,
        address outputToken,
        uint256 amount,
        address sender
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](7);
        cmd[0] = "bash";
        cmd[1] = "script/get_enso_swap.sh";
        cmd[2] = vm.toString(chainId);
        cmd[3] = vm.toString(inputToken);
        cmd[4] = vm.toString(outputToken);
        cmd[5] = vm.toString(amount);
        cmd[6] = vm.toString(sender);
        return vm.ffi(cmd);
    }

    function _getOdosSwapData(
        uint256 chainId,
        address inputToken,
        address outputToken,
        uint256 amount,
        address sender
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](7);
        cmd[0] = "bash";
        cmd[1] = "script/get_odos_swap.sh";
        cmd[2] = vm.toString(chainId);
        cmd[3] = vm.toString(inputToken);
        cmd[4] = vm.toString(outputToken);
        cmd[5] = vm.toString(amount);
        cmd[6] = vm.toString(sender);
        return vm.ffi(cmd);
    }
}
