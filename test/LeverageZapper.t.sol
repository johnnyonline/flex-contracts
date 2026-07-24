// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MockRouter} from "./mocks/MockRouter.sol";

import "./Base.sol";

contract LeverageZapperTests is Base {

    MockRouter public mockRouter;

    uint256 constant SLIPPAGE_BPS = 50; // 0.5%

    uint256 public maxCollateralFuzzAmount;
    uint256 public minCollateralFuzzAmount;
    uint256 public maxLeverage;

    function setUp() public override {
        // isLatestBlock = true;

        // The netted self-take requires a market with no starting price buffer
        startingPriceBufferPercentage = 1e18;

        Base.setUp();

        // Deploy mock router
        mockRouter = new MockRouter(priceOracle, address(collateralToken), address(borrowToken), address(borrowToken), SLIPPAGE_BPS);
        vm.label(address(mockRouter), "MockRouter");

        // Endorse market in registry
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        // Whitelist mock router
        vm.prank(deployerAddress);
        daddy.execute(address(leverageZapper), abi.encodeWithSelector(ILeverageZapper.set_router.selector, address(mockRouter), true), 0, true);

        // Set fuzz bounds
        maxCollateralFuzzAmount = 100 * COLLATERAL_TOKEN_PRECISION;
        minCollateralFuzzAmount = minimumDebt * BORROW_TOKEN_PRECISION * ORACLE_PRICE_SCALE / priceOracle.get_price() * 2;
        maxLeverage = (minimumCollateralRatio / (minimumCollateralRatio - 100)) * 90 / 100;
    }

    /// @dev Push all of the Lender's idle liquidity into a redeemable trove owned by `anotherUserBorrower`
    function _exhaustIdleLiquidity() internal returns (uint256) {
        uint256 idle = borrowToken.balanceOf(address(lender));
        uint256 collateral = (idle * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 troveId = mintAndOpenTrove(anotherUserBorrower, collateral, idle, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(borrowToken.balanceOf(address(lender)), 0, "lender should have no idle liquidity");
        return troveId;
    }

    /// @dev Replicates the MockRouter's borrow -> collateral output for exact assertions
    function _swapOut(
        uint256 _amountIn
    ) internal view returns (uint256) {
        uint256 exactOut = _amountIn * ORACLE_PRICE_SCALE / priceOracle.get_price();
        return exactOut * (BPS - SLIPPAGE_BPS) / BPS;
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

        // Buffer debt to account for slippage on the debt swap
        uint256 debtAmount = baseDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender so the whole loan is delivered from idle liquidity
        mintAndDepositIntoLender(userLender, debtAmount * 10);

        uint256 ownerIndex = block.timestamp;

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Open leveraged trove. The callback swaps the delivered loan into collateral
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: ownerIndex,
                initial_collateral: _userCollateral,
                collateral_amount: _userCollateral * _leverage,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))})
            })
        );

        // Verify trove
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertGt(trove.debt, 0, "E2");

        // Verify leverage: the trove is opened with exactly the declared collateral
        assertEq(trove.collateral, _userCollateral * _leverage, "E3");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E5");

        // Verify swept leftovers to borrower (the slippage buffer comes back as collateral)
        assertGt(collateralToken.balanceOf(userBorrower), 0, "E6");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E7");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E8");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E9");

        return troveId;
    }

    function test_closeLeveragedTrove(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        // Get trove debt
        uint256 troveDebt = troveManager.get_trove_debt_after_interest(troveId);

        // Flash loan borrow token to cover the debt (with slippage buffer for collateral swap)
        uint256 closeFlashLoanAmount = troveDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Skip time so we dont revert on same block close
        skip(1);

        // Record state before close
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        // Close leveraged trove
        vm.prank(userBorrower);
        leverageZapper.close_leveraged_trove(
            ILeverageZapper.CloseLeveragedData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: closeFlashLoanAmount,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
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

        // Verify user received value back
        assertGt(borrowToken.balanceOf(userBorrower), borrowBalanceBefore, "E5");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E6");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E7");
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
        uint256 collateralBalanceBefore = collateralToken.balanceOf(userBorrower);

        // Compute the additional debt for the additional leverage
        uint256 additionalCollateral = _userCollateral * _additionalLeverage;
        uint256 additionalDebtBase = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Buffer debt to account for slippage on the debt swap
        uint256 debtAmount = additionalDebtBase * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender with additional debt
        mintAndDepositIntoLender(userLender, debtAmount);

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        // Lever up
        vm.prank(userBorrower);
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                trove_id: troveId,
                initial_collateral: 0,
                collateral_amount: additionalCollateral,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))})
            })
        );

        // Verify trove state: collateral grows by exactly the declared amount
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.owner, userBorrower, "E0");
        assertEq(troveAfter.collateral, troveBefore.collateral + additionalCollateral, "E1");
        assertGt(troveAfter.debt, troveBefore.debt, "E2");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E3");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E4");

        // Verify user received collateral leftovers from the slippage buffer
        assertGt(collateralToken.balanceOf(userBorrower), collateralBalanceBefore, "E5");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E6");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E7");
    }

    function test_leverDownTrove(
        uint256 _userCollateral,
        uint256 _leverageReduction
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverageReduction = bound(_leverageReduction, 1, maxLeverage - 2);

        // Open trove at max leverage
        uint256 troveId = test_openLeveragedTrove(_userCollateral, maxLeverage);

        // Skip past the open's block so the lever-down repay isn't blocked by the same-block guard
        skip(1);

        // Record state before lever down
        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Compute amounts for lever down
        uint256 collateralToRemove = _userCollateral * _leverageReduction;

        // Flash loan sized so that collateral sale covers it (with slippage buffer)
        uint256 flashLoanAmount = collateralToRemove * priceOracle.get_price() / ORACLE_PRICE_SCALE * (BPS - 2 * SLIPPAGE_BPS) / BPS;

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        // Lever down
        vm.prank(userBorrower);
        leverageZapper.lever_down_trove(
            ILeverageZapper.LeverDownData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_to_remove: collateralToRemove,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Verify trove state
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.owner, userBorrower, "E0");
        assertEq(troveAfter.collateral, troveBefore.collateral - collateralToRemove, "E1");
        assertApproxEqRel(troveAfter.collateral, _userCollateral * (maxLeverage - _leverageReduction), 3e16, "E2"); // 3% tolerance
        assertLt(troveAfter.debt, troveBefore.debt, "E3");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E5");

        // Verify user received leftovers from slippage buffer
        assertGt(borrowToken.balanceOf(userBorrower), borrowBalanceBefore, "E6");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E7");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E8");
    }

    // The entire loan is sourced via redemption: the kicked auction is taken netted, the redeemed
    // collateral is kept in kind, and no borrow token ever moves - a loss-free loop with no swap
    function test_openLeveragedTrove_fullRedemption(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        airdrop(address(collateralToken), userBorrower, _userCollateral);

        // No swap and no buffer: the debt does not need any slippage allowance
        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 debtAmount = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Fund the lender, then push all of its idle liquidity into a redeemable trove
        mintAndDepositIntoLender(userLender, debtAmount);
        uint256 redeemableTroveId = _exhaustIdleLiquidity();
        ITroveManager.Trove memory redeemableBefore = troveManager.troves(redeemableTroveId);

        // The redemption gives collateral worth exactly the redeemed debt at the oracle price
        uint256 expectedRedeemedColl = debtAmount * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 declaredCollateral = _userCollateral + expectedRedeemedColl;

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Open the leveraged trove with no swap data: the whole loop settles through the auction
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: _userCollateral,
                collateral_amount: declaredCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2, // higher rate so we can redeem the first trove
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: expectedRedeemedColl,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Verify trove: opened with exactly the declared collateral
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertEq(trove.collateral, declaredCollateral, "E2");
        assertGe(trove.debt, debtAmount, "E3");
        assertApproxEqRel(trove.collateral, _userCollateral * _leverage, 1e15, "E4"); // 0.1% tolerance

        // Verify the redeemed trove shrank by exactly the redeemed amounts
        ITroveManager.Trove memory redeemableAfter = troveManager.troves(redeemableTroveId);
        assertEq(redeemableAfter.collateral, redeemableBefore.collateral - expectedRedeemedColl, "E5");
        assertEq(redeemableAfter.debt, redeemableBefore.debt - debtAmount, "E6");

        // Verify the netting: no borrow tokens moved anywhere
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E7");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E8");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E9");

        // Verify the auction was fully taken and nothing is left anywhere
        address auction = IDutchDesk(troveManager.dutch_desk()).auction();
        assertEq(collateralToken.balanceOf(auction), 0, "E10");
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E11");
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E12");
    }

    // The loan is sourced partly from idle liquidity (swapped via the router) and partly via
    // redemption (netted take), in a single open
    function test_openLeveragedTrove_partialRedemption(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        airdrop(address(collateralToken), userBorrower, _userCollateral);

        // Buffer the debt so the swap leg's slippage is covered
        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 baseDebt = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 debtAmount = baseDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender, then drain all but half the debt into a redeemable trove
        uint256 idleTarget = debtAmount / 2;
        mintAndDepositIntoLender(userLender, debtAmount);
        uint256 firstCollateral =
            ((debtAmount - idleTarget) * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(anotherUserBorrower, firstCollateral, debtAmount - idleTarget, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(borrowToken.balanceOf(address(lender)), idleTarget, "lender idle mismatch");

        // Expected collateral: the redemption leg at the oracle price plus the swap leg's output
        uint256 expectedRedeemedColl = (debtAmount - idleTarget) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 declaredCollateral = _userCollateral + expectedRedeemedColl + _swapOut(idleTarget);

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Open the leveraged trove: the callback takes the auction, then swaps the idle portion
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: _userCollateral,
                collateral_amount: declaredCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2, // higher rate so we can redeem the first trove
                max_upfront_fee: type(uint256).max,
                min_borrow_out: idleTarget,
                min_collateral_out: expectedRedeemedColl,
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))})
            })
        );

        // Verify trove: opened with exactly the declared collateral
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(trove.collateral, declaredCollateral, "E1");
        assertGe(trove.collateral, _userCollateral * _leverage, "E2"); // the buffered debt over-sources slightly

        // Verify no leftovers anywhere
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E3");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E4");
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E5");
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E6");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E7");
    }

    // Levering up an existing trove sources the added collateral via redemption, netted, with no swap
    function test_leverUpTrove_fullRedemption(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 2);

        // Open a plain trove for the user at a rate high enough to redeem the other trove later.
        // Sized like a 2x leveraged position: collateral C, debt worth C/2
        uint256 userDebt = _userCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE / 2;
        uint256 additionalCollateral = _userCollateral * _additionalLeverage / 2;
        uint256 debtAmount = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Fund the lender for both the user's plain open and the lever up
        mintAndDepositIntoLender(userLender, userDebt + debtAmount);
        uint256 troveId = mintAndOpenTrove(userBorrower, _userCollateral, userDebt, DEFAULT_ANNUAL_INTEREST_RATE * 2);

        // Push the remaining idle liquidity into a redeemable trove at a lower rate
        uint256 redeemableTroveId = _exhaustIdleLiquidity();
        ITroveManager.Trove memory redeemableBefore = troveManager.troves(redeemableTroveId);

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);

        // The redemption gives collateral worth exactly the redeemed debt at the oracle price
        uint256 expectedRedeemedColl = debtAmount * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        // Lever up with no swap data: the whole loop settles through the auction
        vm.prank(userBorrower);
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                trove_id: troveId,
                initial_collateral: 0,
                collateral_amount: expectedRedeemedColl,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: expectedRedeemedColl,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Verify trove: collateral grows by exactly the redeemed amount
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.collateral, troveBefore.collateral + expectedRedeemedColl, "E0");
        assertGt(troveAfter.debt, troveBefore.debt, "E1");

        // Verify the redeemed trove shrank by exactly the redeemed amounts
        ITroveManager.Trove memory redeemableAfter = troveManager.troves(redeemableTroveId);
        assertEq(redeemableAfter.collateral, redeemableBefore.collateral - expectedRedeemedColl, "E2");
        assertEq(redeemableAfter.debt, redeemableBefore.debt - debtAmount, "E3");

        // Verify the netting: no borrow tokens moved anywhere
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E5");
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E6");
    }

    // Levering up with the loan sourced partly from idle liquidity (swapped) and partly via redemption
    function test_leverUpTrove_partialRedemption(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        // Larger floor so the redeemable half of the debt clears `min_debt`
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount * 2, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 2);

        // Open a plain trove for the user at a rate high enough to redeem the other trove later.
        // Sized like a 2x leveraged position: collateral C, debt worth C/2
        uint256 userDebt = _userCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE / 2;
        uint256 additionalCollateral = _userCollateral * _additionalLeverage / 2;
        uint256 baseDebt = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Buffer the debt so the swap leg's slippage is covered
        uint256 debtAmount = baseDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);
        uint256 idleTarget = debtAmount / 2;

        // Fund the lender, open the user's trove, then drain all but `idleTarget` into a redeemable trove
        mintAndDepositIntoLender(userLender, userDebt + debtAmount);
        uint256 troveId = mintAndOpenTrove(userBorrower, _userCollateral, userDebt, DEFAULT_ANNUAL_INTEREST_RATE * 2);
        uint256 firstCollateral =
            ((debtAmount - idleTarget) * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(anotherUserBorrower, firstCollateral, debtAmount - idleTarget, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(borrowToken.balanceOf(address(lender)), idleTarget, "lender idle mismatch");

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);

        // Expected collateral: the redemption leg at the oracle price plus the swap leg's output
        uint256 expectedRedeemedColl = (debtAmount - idleTarget) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 collateralAmount = expectedRedeemedColl + _swapOut(idleTarget);

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        // Lever up: the callback takes the auction, then swaps the idle portion
        vm.prank(userBorrower);
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                trove_id: troveId,
                initial_collateral: 0,
                collateral_amount: collateralAmount,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: idleTarget,
                min_collateral_out: expectedRedeemedColl,
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))})
            })
        );

        // Verify trove: collateral grows by exactly the declared amount
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.collateral, troveBefore.collateral + collateralAmount, "E0");
        assertGt(troveAfter.debt, troveBefore.debt, "E1");

        // Verify no leftovers anywhere
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E2");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E3");
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E5");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E6");
    }

    // Declaring more collateral than the callback can source makes the whole open revert
    function test_openLeveragedTrove_collateralShortfall_reverts() public {
        uint256 _userCollateral = minCollateralFuzzAmount;
        airdrop(address(collateralToken), userBorrower, _userCollateral);

        uint256 debtAmount = _userCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Fund the lender, then push all of its idle liquidity into a redeemable trove
        mintAndDepositIntoLender(userLender, debtAmount);
        _exhaustIdleLiquidity();

        uint256 expectedRedeemedColl = debtAmount * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Declare one wei more than the callback can source: the Trove Manager's pull must revert
        vm.prank(userBorrower);
        vm.expectRevert();
        leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: _userCollateral,
                collateral_amount: _userCollateral + expectedRedeemedColl + 1,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

    // A market with a starting price buffer cannot settle the netted take: the callback must revert
    function test_openLeveragedTrove_bufferedMarket_reverts() public {
        uint256 _userCollateral = minCollateralFuzzAmount;
        airdrop(address(collateralToken), userBorrower, _userCollateral);

        uint256 debtAmount = _userCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Fund the lender, then push all of its idle liquidity into a redeemable trove
        mintAndDepositIntoLender(userLender, debtAmount);
        _exhaustIdleLiquidity();

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Simulate a market with a starting price buffer
        address dutchDesk = troveManager.dutch_desk();
        vm.mockCall(dutchDesk, abi.encodeWithSelector(IDutchDesk.starting_price_buffer_percentage.selector), abi.encode(uint256(1e18 + 1)));

        vm.prank(userBorrower);
        vm.expectRevert("!buffer");
        leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: _userCollateral,
                collateral_amount: _userCollateral * 2,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

    function test_troveCallback_directCall_reverts(
        address _caller
    ) public {
        vm.assume(_caller != address(0));
        vm.prank(_caller);
        vm.expectRevert("!caller");
        leverageZapper.troveCallback(0, abi.encode(uint256(0), ILeverageZapper.SwapData({router: address(0), data: ""})));
    }

    function test_onMorphoFlashLoan_directCall_reverts(
        address _caller,
        bytes memory _data
    ) public {
        address _morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        vm.assume(_caller != _morpho);
        vm.prank(_caller);
        vm.expectRevert("!caller");
        leverageZapper.onMorphoFlashLoan(0, _data);
    }

    function test_onMorphoFlashLoan_noPendingCommitment_reverts(
        bytes memory _data
    ) public {
        // Even Morpho itself cannot invoke the callback without a payload committed by an outer call
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
        vm.expectRevert("!pending");
        leverageZapper.onMorphoFlashLoan(0, _data);
    }

    function test_closeLeveragedTrove_unapproved_reverts(
        uint256 _userCollateral,
        uint256 _leverage,
        address _caller
    ) public {
        vm.assume(_caller != userBorrower);
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        vm.prank(_caller);
        vm.expectRevert("!owner");
        leverageZapper.close_leveraged_trove(
            ILeverageZapper.CloseLeveragedData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(0), data: ""}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

    function test_leverUpTrove_unapproved_reverts(
        uint256 _userCollateral,
        uint256 _leverage,
        address _caller
    ) public {
        vm.assume(_caller != userBorrower);
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        vm.prank(_caller);
        vm.expectRevert("!owner");
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                trove_id: troveId,
                initial_collateral: 0,
                collateral_amount: 0,
                debt_amount: 0,
                max_upfront_fee: 0,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

    function test_leverDownTrove_unapproved_reverts(
        uint256 _userCollateral,
        uint256 _leverage,
        address _caller
    ) public {
        vm.assume(_caller != userBorrower);
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        vm.prank(_caller);
        vm.expectRevert("!owner");
        leverageZapper.lever_down_trove(
            ILeverageZapper.LeverDownData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: 0,
                collateral_to_remove: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(0), data: ""}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

    function test_openLeveragedTrove_zeroOwner_reverts() public {
        mintAndDepositIntoLender(userLender, troveManager.min_debt());

        uint256 _collateral =
            (troveManager.min_debt() * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        airdrop(address(collateralToken), userBorrower, _collateral);
        uint256 _debtAmount = troveManager.min_debt();

        vm.startPrank(userBorrower);
        collateralToken.approve(address(leverageZapper), _collateral);
        vm.expectRevert("!owner");
        leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: address(0),
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: _collateral,
                collateral_amount: _collateral,
                debt_amount: _debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
        vm.stopPrank();
    }

    function test_openLeveragedTrove_troveManagerAsOwner_reverts() public {
        mintAndDepositIntoLender(userLender, troveManager.min_debt());

        uint256 _collateral =
            (troveManager.min_debt() * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        airdrop(address(collateralToken), userBorrower, _collateral);
        uint256 _debtAmount = troveManager.min_debt();

        vm.startPrank(userBorrower);
        collateralToken.approve(address(leverageZapper), _collateral);
        vm.expectRevert("!owner");
        leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: address(troveManager),
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: _collateral,
                collateral_amount: _collateral,
                debt_amount: _debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
        vm.stopPrank();
    }

    function test_closeLeveragedTrove_approvedOperator(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        uint256 troveDebt = troveManager.get_trove_debt_after_interest(troveId);
        uint256 closeFlashLoanAmount = troveDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Owner approves both the operator and the zapper
        vm.startPrank(userBorrower);
        troveManager.approve(operator, true);
        troveManager.approve(address(leverageZapper), true);
        vm.stopPrank();

        // Skip time so we dont revert on same block close
        skip(1);

        // Operator closes the trove on behalf of the owner
        vm.prank(operator);
        leverageZapper.close_leveraged_trove(
            ILeverageZapper.CloseLeveragedData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: closeFlashLoanAmount,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        assertEq(uint256(troveManager.troves(troveId).status), uint256(ITroveManager.Status.closed), "E0");
    }

    function test_leverUpTrove_approvedOperator(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 2);

        uint256 troveId = test_openLeveragedTrove(_userCollateral, 2);

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);

        uint256 additionalCollateral = _userCollateral * _additionalLeverage;
        uint256 additionalDebtBase = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 debtAmount = additionalDebtBase * BPS / (BPS - 2 * SLIPPAGE_BPS);

        mintAndDepositIntoLender(userLender, debtAmount);

        // Owner approves both the operator and the zapper
        vm.startPrank(userBorrower);
        troveManager.approve(operator, true);
        troveManager.approve(address(leverageZapper), true);
        vm.stopPrank();

        // Operator levers up on behalf of the owner
        vm.prank(operator);
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                trove_id: troveId,
                initial_collateral: 0,
                collateral_amount: additionalCollateral,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))})
            })
        );

        assertGt(troveManager.troves(troveId).collateral, troveBefore.collateral, "E0");
        assertGt(troveManager.troves(troveId).debt, troveBefore.debt, "E1");
    }

    function test_leverDownTrove_approvedOperator(
        uint256 _userCollateral,
        uint256 _leverageReduction
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverageReduction = bound(_leverageReduction, 1, maxLeverage - 2);

        uint256 troveId = test_openLeveragedTrove(_userCollateral, maxLeverage);

        // Skip past the open's block so the lever-down repay isn't blocked by the same-block guard
        skip(1);

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);

        uint256 collateralToRemove = _userCollateral * _leverageReduction;
        uint256 flashLoanAmount = collateralToRemove * priceOracle.get_price() / ORACLE_PRICE_SCALE * (BPS - 2 * SLIPPAGE_BPS) / BPS;

        // Owner approves both the operator and the zapper
        vm.startPrank(userBorrower);
        troveManager.approve(operator, true);
        troveManager.approve(address(leverageZapper), true);
        vm.stopPrank();

        // Operator levers down on behalf of the owner
        vm.prank(operator);
        leverageZapper.lever_down_trove(
            ILeverageZapper.LeverDownData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_to_remove: collateralToRemove,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        assertLt(troveManager.troves(troveId).collateral, troveBefore.collateral, "E0");
        assertLt(troveManager.troves(troveId).debt, troveBefore.debt, "E1");
    }

    function test_setRouter(
        address _router
    ) public {
        vm.assume(_router != address(0));
        assertFalse(leverageZapper.routers(_router), "E0");

        vm.prank(deployerAddress);
        daddy.execute(address(leverageZapper), abi.encodeWithSelector(ILeverageZapper.set_router.selector, _router, true), 0, true);
        assertTrue(leverageZapper.routers(_router), "E1");

        vm.prank(deployerAddress);
        daddy.execute(address(leverageZapper), abi.encodeWithSelector(ILeverageZapper.set_router.selector, _router, false), 0, true);
        assertFalse(leverageZapper.routers(_router), "E2");
    }

    function test_setRouter_notDaddy_reverts(
        address _caller
    ) public {
        vm.assume(_caller != deployerAddress);
        vm.prank(_caller);
        vm.expectRevert();
        leverageZapper.set_router(address(1), true);
    }

    function test_openLeveragedTrove_unendorsedMarket_reverts() public {
        // Deploy a new trove manager that is NOT endorsed
        (, address _tm,,,) = catFactory.deploy(
            ICatFactory.DeployParams({
                borrow_token: address(borrowToken),
                collateral_token: address(collateralToken),
                price_oracle: address(priceOracle),
                minimum_debt: minimumDebt * BORROW_TOKEN_PRECISION,
                safe_collateral_ratio: safeCollateralRatio,
                minimum_collateral_ratio: minimumCollateralRatio,
                max_penalty_collateral_ratio: maxPenaltyCollateralRatio,
                min_liquidation_fee: minLiquidationFee,
                max_liquidation_fee: maxLiquidationFee,
                upfront_interest_period: upfrontInterestPeriod,
                interest_rate_adj_cooldown: interestRateAdjCooldown,
                repay_cooldown: repayCooldown,
                minimum_price_buffer_percentage: minimumPriceBufferPercentage,
                starting_price_buffer_percentage: startingPriceBufferPercentage,
                re_kick_starting_price_buffer_percentage: reKickStartingPriceBufferPercentage,
                step_duration: stepDuration,
                step_decay_rate: stepDecayRate,
                auction_length: auctionLength,
                salt: bytes32(uint256(999))
            })
        );

        vm.prank(userBorrower);
        vm.expectRevert("!endorsed");
        leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: _tm,
                owner_index: block.timestamp,
                initial_collateral: 0,
                collateral_amount: 0,
                debt_amount: 0,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: 0,
                max_upfront_fee: 0,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(mockRouter), data: ""})
            })
        );
    }

    function test_openLeveragedTrove_unwhitelistedRouter_reverts() public {
        address _badRouter = address(12345);

        vm.prank(userBorrower);
        vm.expectRevert("!debt_swap_router");
        leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                owner_index: block.timestamp,
                initial_collateral: 0,
                collateral_amount: 0,
                debt_amount: 0,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: 0,
                max_upfront_fee: 0,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: _badRouter, data: "0x"})
            })
        );
    }

    function test_closeLeveragedTrove_unwhitelistedRouter_reverts(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        vm.prank(userBorrower);
        vm.expectRevert("!collateral_swap_router");
        leverageZapper.close_leveraged_trove(
            ILeverageZapper.CloseLeveragedData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(12345), data: "0x"}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

    function test_leverUpTrove_unwhitelistedRouter_reverts(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        vm.prank(userBorrower);
        vm.expectRevert("!debt_swap_router");
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                trove_id: troveId,
                initial_collateral: 0,
                collateral_amount: 0,
                debt_amount: 0,
                max_upfront_fee: 0,
                min_borrow_out: 0,
                min_collateral_out: 0,
                debt_swap: ILeverageZapper.SwapData({router: address(12345), data: "0x"})
            })
        );
    }

    function test_leverDownTrove_unwhitelistedRouter_reverts(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        uint256 troveId = test_openLeveragedTrove(_userCollateral, _leverage);

        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        vm.prank(userBorrower);
        vm.expectRevert("!collateral_swap_router");
        leverageZapper.lever_down_trove(
            ILeverageZapper.LeverDownData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                trove_id: troveId,
                flash_loan_amount: 0,
                collateral_to_remove: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(12345), data: "0x"}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );
    }

}
