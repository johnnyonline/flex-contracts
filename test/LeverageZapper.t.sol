// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MockRouter} from "./mocks/MockRouter.sol";

import "./Base.sol";

contract LeverageZapperTests is Base {

    MockRouter public mockRouter;

    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    uint256 constant SLIPPAGE_BPS = 50; // 0.5%
    uint256 constant BPS = 10_000;

    uint256 public maxCollateralFuzzAmount;
    uint256 public minCollateralFuzzAmount;
    uint256 public maxLeverage;

    function setUp() public override {
        // isLatestBlock = true;
        Base.setUp();

        // Deploy mock router
        mockRouter = new MockRouter(priceOracle, address(collateralToken), address(borrowToken), CRVUSD, SLIPPAGE_BPS);
        vm.label(address(mockRouter), "MockRouter");

        // Set fuzz bounds
        maxCollateralFuzzAmount = 100 * COLLATERAL_TOKEN_PRECISION;
        minCollateralFuzzAmount = minimumDebt * BORROW_TOKEN_PRECISION * ORACLE_PRICE_SCALE / priceOracle.get_price() * 2;
        maxLeverage = (minimumCollateralRatio / (minimumCollateralRatio - 100)) * 90 / 100;
    }

    function test_openLeveragedTrove(
        uint256 _userCollateral,
        uint256 _leverage
    ) public returns (uint256) {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        airdrop(address(collateralToken), userBorrower, _userCollateral);

        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 baseDebt = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = baseDebt * WAD / BORROW_TOKEN_PRECISION;

        // Buffer debt to account for slippage on the debt swap (2x slippage to ensure surplus after rounding)
        uint256 debtAmount = baseDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender
        mintAndDepositIntoLender(userLender, debtAmount);

        uint256 ownerIndex = block.timestamp;

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Open leveraged trove
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: ownerIndex,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(CRVUSD, address(collateralToken))}),
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), CRVUSD)})
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

        // Verify leverage: trove.collateral should be approximately _leverage * userCollateral
        assertApproxEqRel(trove.collateral, _userCollateral * _leverage, 1e16, "E3"); // 1% tolerance

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E5");
        assertEq(IERC20(CRVUSD).balanceOf(address(leverageZapper)), 0, "E6");

        // Verify swept leftovers to borrower
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E7");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E8");
        assertGt(IERC20(CRVUSD).balanceOf(userBorrower), 0, "E9");

        return troveId;
    }

    function test_closeLeveragedTrove(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        // Get trove debt
        uint256 troveDebt = troveManager.get_trove_debt_after_interest(troveId);

        // Flash loan crvUSD to cover the debt (2x slippage buffer to ensure surplus after rounding)
        uint256 closeFlashLoanAmount = troveDebt * WAD / BORROW_TOKEN_PRECISION * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Transfer trove ownership to zapper
        vm.prank(userBorrower);
        troveManager.transfer_ownership(troveId, address(leverageZapper));

        // Close leveraged trove
        vm.prank(userBorrower);
        leverageZapper.close_leveraged_trove(
            ILeverageZapper.CloseLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                trove_id: troveId,
                flash_loan_amount: closeFlashLoanAmount,
                collateral_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(collateralToken), CRVUSD)}),
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(CRVUSD, address(borrowToken))})
            })
        );

        // Verify trove is closed
        ITroveManager.Trove memory closedTrove = troveManager.troves(troveId);
        assertEq(uint256(closedTrove.status), uint256(ITroveManager.Status.closed), "E0");
        assertEq(closedTrove.debt, 0, "E1");
        assertEq(closedTrove.collateral, 0, "E2");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E3");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(IERC20(CRVUSD).balanceOf(address(leverageZapper)), 0, "E5");

        // Verify user received value back (leftovers from slippage buffer)
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E6");
        assertGt(borrowToken.balanceOf(userBorrower), 0, "E7");
        assertGt(IERC20(CRVUSD).balanceOf(userBorrower), 0, "E8");
    }

    function test_leverUpTrove(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 2);

        // Open trove at 2x leverage
        uint256 troveId = test_openLeveragedTrove(_userCollateral, 2);

        // Record state before lever up
        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 crvusdBalanceBefore = IERC20(CRVUSD).balanceOf(userBorrower);

        // Compute flash loan for additional leverage
        uint256 additionalDebtBase = _userCollateral * _additionalLeverage * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = additionalDebtBase * WAD / BORROW_TOKEN_PRECISION;

        // Buffer debt to account for slippage on the debt swap
        uint256 debtAmount = additionalDebtBase * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender with additional debt
        mintAndDepositIntoLender(userLender, debtAmount);

        // Transfer trove ownership to zapper
        vm.prank(userBorrower);
        troveManager.transfer_ownership(troveId, address(leverageZapper));

        // Lever up
        vm.prank(userBorrower);
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(CRVUSD, address(collateralToken))}),
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), CRVUSD)})
            })
        );

        // Accept ownership back
        vm.prank(userBorrower);
        troveManager.accept_ownership(troveId);

        // Verify trove state
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.owner, userBorrower, "E0");
        assertApproxEqRel(troveAfter.collateral, _userCollateral * (2 + _additionalLeverage), 2e16, "E1"); // 2% tolerance
        assertGt(troveAfter.debt, troveBefore.debt, "E2");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E3");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(IERC20(CRVUSD).balanceOf(address(leverageZapper)), 0, "E5");

        // Verify user received crvUSD leftovers from slippage buffer
        assertGt(IERC20(CRVUSD).balanceOf(userBorrower), crvusdBalanceBefore, "E6");
    }

    function test_leverDownTrove(
        uint256 _userCollateral,
        uint256 _leverageReduction
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverageReduction = bound(_leverageReduction, 1, maxLeverage - 2);

        // Open trove at max leverage
        uint256 troveId = test_openLeveragedTrove(_userCollateral, maxLeverage);

        // Record state before lever down
        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 crvusdBalanceBefore = IERC20(CRVUSD).balanceOf(userBorrower);

        // Compute amounts for lever down
        uint256 collateralToRemove = _userCollateral * _leverageReduction;

        // Flash loan sized so that collateral sale covers it (with slippage buffer)
        uint256 flashLoanAmount =
            collateralToRemove * priceOracle.get_price() * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION) * (BPS - 2 * SLIPPAGE_BPS) / BPS;

        // Transfer trove ownership to zapper
        vm.prank(userBorrower);
        troveManager.transfer_ownership(troveId, address(leverageZapper));

        // Lever down
        vm.prank(userBorrower);
        leverageZapper.lever_down_trove(
            ILeverageZapper.LeverDownData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_to_remove: collateralToRemove,
                collateral_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(collateralToken), CRVUSD)}),
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(CRVUSD, address(borrowToken))})
            })
        );

        // Accept ownership back
        vm.prank(userBorrower);
        troveManager.accept_ownership(troveId);

        // Verify trove state
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.owner, userBorrower, "E0");
        assertEq(troveAfter.collateral, troveBefore.collateral - collateralToRemove, "E1");
        assertApproxEqRel(troveAfter.collateral, _userCollateral * (maxLeverage - _leverageReduction), 3e16, "E2"); // 3% tolerance
        assertLt(troveAfter.debt, troveBefore.debt, "E3");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E5");
        assertEq(IERC20(CRVUSD).balanceOf(address(leverageZapper)), 0, "E6");

        // Verify user received leftovers from slippage buffer
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E7");
        assertGe(borrowToken.balanceOf(userBorrower), 0, "E8");
        assertGt(IERC20(CRVUSD).balanceOf(userBorrower), crvusdBalanceBefore, "E9");
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

}
