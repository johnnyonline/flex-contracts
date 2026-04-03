// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {AuctionTakerMock} from "./mocks/AuctionTakerMock.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

import "./Base.sol";

contract LeverageZapperTests is Base {

    MockRouter public mockRouter;

    uint256 constant SLIPPAGE_BPS = 50; // 0.5%
    uint256 constant BPS = 10_000;

    uint256 public maxCollateralFuzzAmount;
    uint256 public minCollateralFuzzAmount;
    uint256 public maxLeverage;

    function setUp() public override {
        // isLatestBlock = true;
        Base.setUp();

        // Deploy mock router
        mockRouter = new MockRouter(priceOracle, address(collateralToken), address(borrowToken), address(borrowToken), SLIPPAGE_BPS);
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
        uint256 flashLoanAmount = baseDebt;

        // Buffer debt to account for slippage on the collateral swap
        uint256 debtAmount = baseDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender
        mintAndDepositIntoLender(userLender, debtAmount * 10);

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
                flash_loan_token: address(borrowToken),
                auction_taker: address(0),
                owner_index: ownerIndex,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

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

        // Verify swept leftovers to borrower
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E6");
        assertGt(borrowToken.balanceOf(userBorrower), 0, "E7");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E8");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E9");

        return troveId;
    }

    function test_openLeveragedTroveWithCallback(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        // Deploy auction taker mock
        AuctionTakerMock auctionTaker = new AuctionTakerMock();
        vm.label(address(auctionTaker), "AuctionTakerMock");

        airdrop(address(collateralToken), userBorrower, _userCollateral);

        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 baseDebt = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = baseDebt;

        // Buffer debt to account for slippage on the collateral swap
        uint256 debtAmount = baseDebt * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Fund the lender with enough for both troves
        mintAndDepositIntoLender(userLender, debtAmount);

        // Exhaust lender liquidity by opening a trove from another user
        uint256 firstCollateral =
            (debtAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(anotherUserBorrower, firstCollateral, debtAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Open leveraged trove with auction taker to take the kicked auction
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: address(auctionTaker),
                owner_index: block.timestamp,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2, // higher rate so we can redeem the first trove
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

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

        // Verify swept leftovers to borrower
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E6");
        assertGt(borrowToken.balanceOf(userBorrower), 0, "E7");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E8");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E9");
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
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E5");
        assertGt(borrowToken.balanceOf(userBorrower), 0, "E6");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E7");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E8");
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
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Compute flash loan for additional leverage
        uint256 additionalDebtBase = _userCollateral * _additionalLeverage * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = additionalDebtBase;

        // Buffer debt to account for slippage on the collateral swap
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
                flash_loan_token: address(borrowToken),
                auction_taker: address(0),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Verify trove state
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.owner, userBorrower, "E0");
        assertApproxEqRel(troveAfter.collateral, _userCollateral * (2 + _additionalLeverage), 2e16, "E1"); // 2% tolerance
        assertGt(troveAfter.debt, troveBefore.debt, "E2");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E3");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E4");

        // Verify user received borrow token leftovers from slippage buffer
        assertGt(borrowToken.balanceOf(userBorrower), borrowBalanceBefore, "E5");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E6");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E7");
    }

    function test_leverUpTroveWithCallback(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 2);

        // Deploy auction taker mock
        AuctionTakerMock auctionTaker = new AuctionTakerMock();
        vm.label(address(auctionTaker), "AuctionTakerMock");

        // Open trove at 2x leverage
        uint256 troveId = test_openLeveragedTrove(_userCollateral, 2);

        // Record state before lever up
        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Compute flash loan for additional leverage
        uint256 additionalDebtBase = _userCollateral * _additionalLeverage * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = additionalDebtBase;

        // Buffer debt to account for slippage on the collateral swap
        uint256 debtAmount = additionalDebtBase * BPS / (BPS - 2 * SLIPPAGE_BPS);

        // Exhaust lender liquidity by opening a trove from another user
        uint256 idle = borrowToken.balanceOf(address(lender));
        if (idle > 0) {
            uint256 extraCollateral = (idle * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
            mintAndOpenTrove(anotherUserBorrower, extraCollateral, idle, DEFAULT_ANNUAL_INTEREST_RATE);
        }
        assertEq(borrowToken.balanceOf(address(lender)), 0, "lender should have no idle liquidity");

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(leverageZapper), true);

        // Lever up with auction taker to take the kicked auction
        vm.prank(userBorrower);
        leverageZapper.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: address(auctionTaker),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Verify trove state
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertEq(troveAfter.owner, userBorrower, "E0");
        assertApproxEqRel(troveAfter.collateral, _userCollateral * (2 + _additionalLeverage), 2e16, "E1"); // 2% tolerance
        assertGt(troveAfter.debt, troveBefore.debt, "E2");

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E3");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E4");

        // Verify user received borrow token leftovers from slippage buffer
        assertGt(borrowToken.balanceOf(userBorrower), borrowBalanceBefore, "E5");

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
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E6");
        assertGt(borrowToken.balanceOf(userBorrower), borrowBalanceBefore, "E7");

        // Verify swap executor has no leftover tokens
        assertEq(collateralToken.balanceOf(address(swapExecutor)), 0, "E8");
        assertEq(borrowToken.balanceOf(address(swapExecutor)), 0, "E9");
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
                flash_loan_token: address(borrowToken),
                auction_taker: address(0),
                trove_id: troveId,
                flash_loan_amount: 0,
                collateral_amount: 0,
                debt_amount: 0,
                max_upfront_fee: 0,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({router: address(0), data: ""}),
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
                flash_loan_token: address(borrowToken),
                auction_taker: address(0),
                owner_index: block.timestamp,
                flash_loan_amount: _debtAmount,
                collateral_amount: _collateral,
                debt_amount: _debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
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
                flash_loan_token: address(borrowToken),
                auction_taker: address(0),
                owner_index: block.timestamp,
                flash_loan_amount: _debtAmount,
                collateral_amount: _collateral,
                debt_amount: _debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
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

        uint256 additionalDebtBase = _userCollateral * _additionalLeverage * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = additionalDebtBase;
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
                flash_loan_token: address(borrowToken),
                auction_taker: address(0),
                trove_id: troveId,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
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

}
