// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILeverageZapper} from "../interfaces/ILeverageZapper.sol";

import {ITroveManager} from "../../test/interfaces/ITroveManager.sol";

import {BaseZapperScript} from "./BaseZapperScript.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// lever up a leveraged trove via Enso:
// forge script script/zapper/LeverUpTrove.s.sol:LeverUpTrove --slow --rpc-url $RPC_URL --ffi --broadcast

contract LeverUpTrove is BaseZapperScript {

    // ============================================================================================
    // Parameters - tweak before running
    // ============================================================================================

    // Position - set the trove id and how much MORE collateral to acquire via the new debt
    uint256 public constant TROVE_ID = 55747671586403220826287365044824856006422462050911439375647723028660622133195;
    uint256 public constant ADDITIONAL_COLLATERAL = 400e6; // raw collateral amount to acquire via the new debt

    // Optional additional collateral pulled from the caller's wallet (defaults to 0)
    uint256 public constant USER_EXTRA_COLLATERAL = 50e6;

    // ============================================================================================
    // Storage (hoisted out of `run()` to relieve stack pressure)
    // ============================================================================================

    uint256 internal _baseDebt;
    uint256 internal _debtAmount;
    uint256 internal _collateralAmount;
    uint256 internal _maxUpfrontFee;
    uint256 internal _minBorrowOut;
    uint256 internal _minCollateralOut;
    uint256 internal _lenderIdle;
    uint256 internal _atomicDelivery;
    uint256 internal _redemptionAmount;
    uint256 internal _expectedRedeemedColl;
    uint256 internal _newCollateral;
    uint256 internal _newDebtPreview;
    uint256 internal _newLtvBps;

    // ============================================================================================
    // Run
    // ============================================================================================

    function run() public {
        uint256 _pk = _loadUser();

        require(TROVE_ID != 0, "TROVE_ID not set");
        require(ADDITIONAL_COLLATERAL > 0, "ADDITIONAL_COLLATERAL not set");

        // Read trove state
        _trove = TROVE_MANAGER.troves(TROVE_ID);
        require(_trove.owner == _user, "trove owner mismatch");
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");

        _loadMarket();

        // Compute amounts. `ADDITIONAL_COLLATERAL` is sourced inside the trove callback (auction
        // take for the redemption portion, Enso swap for the idle portion); `USER_EXTRA_COLLATERAL`
        // is anything the user contributes directly. Total trove delta = both.
        _baseDebt = ADDITIONAL_COLLATERAL * _price / ORACLE_PRICE_SCALE;
        // Buffer the debt to cover swap slippage (lever zapper sweeps excess back to user)
        _debtAmount = _baseDebt * BPS / (BPS - SLIPPAGE_BPS);
        _collateralAmount = ADDITIONAL_COLLATERAL + USER_EXTRA_COLLATERAL;

        // Snapshot how much of `_debtAmount` the Lender can cover from idle vs. how much will go
        // through the redemption path (auction taken atomically in the trove callback).
        _lenderIdle = IERC20(_borrowToken).balanceOf(TROVE_MANAGER.lender());
        _atomicDelivery = _debtAmount > _lenderIdle ? _lenderIdle : _debtAmount;
        _redemptionAmount = _debtAmount - _atomicDelivery;
        _expectedRedeemedColl = _redemptionAmount * ORACLE_PRICE_SCALE / _price;

        // Slippage / sandwich-protection floors and ceilings.
        // `borrow()` uses the trove's existing rate to compute the upfront fee, so quote it with that.
        // The declared `collateral_amount` is itself the overall floor: if the callback sources less,
        // the Trove Manager's collateral pull reverts.
        _maxUpfrontFee = TROVE_MANAGER.get_upfront_fee(_debtAmount, _trove.annual_interest_rate) * (BPS + SLIPPAGE_BPS) / BPS;
        _minBorrowOut = _atomicDelivery;
        _minCollateralOut = _expectedRedeemedColl * (BPS - SLIPPAGE_BPS) / BPS;

        // Sanity checks before any state changes
        require(_debtAmount > 0, "!debt_amount");
        if (USER_EXTRA_COLLATERAL > 0) require(IERC20(_collateralToken).balanceOf(_user) >= USER_EXTRA_COLLATERAL, "!USER_EXTRA_COLLATERAL");

        // Preview the post-lever state for the print plan (debt grows by debt_amount + upfront_fee)
        _newCollateral = _trove.collateral + _collateralAmount;
        _newDebtPreview = _trove.debt + _debtAmount + (_maxUpfrontFee * BPS / (BPS + SLIPPAGE_BPS));

        // LTV after the lever-up (in bps)
        _newLtvBps = _newDebtPreview * BPS * ORACLE_PRICE_SCALE / (_newCollateral * _price);

        // Get the enso swap calldata (borrow_token -> collateral_token) for the idle-liquidity
        // portion only; the redemption portion arrives in kind from the auction.
        // IMPORTANT: pass the SwapExecutor as the Enso `fromAddress` so the route writes the output
        // back to the executor (which sweeps it to the LeverageZapper). If we pass the user instead,
        // Enso bakes the user's address into the deposit receiver and the zapper sees zero output.
        if (_atomicDelivery > 0) {
            (_swapRouter, _swapData) =
                _getEnsoSwapData(block.chainid, _borrowToken, _collateralToken, _atomicDelivery, LEVERAGE_ZAPPER.SWAP_EXECUTOR());

            // Make sure the router is whitelisted on the zapper
            require(LEVERAGE_ZAPPER.routers(_swapRouter), "swap router not whitelisted on LeverageZapper");
        }

        // Print plan
        console.log("---------------------------------");
        console.log("Trove Manager:        %s", address(TROVE_MANAGER));
        console.log("Trove ID:             %s", TROVE_ID);
        console.log("Collateral token:     %s (%s)", _collSym, _collateralToken);
        console.log("Borrow token:         %s (%s)", _borrowSym, _borrowToken);
        console.log("Price:                1 %s = %s", _collSym, _format(_borrowPerColl, _borrowDec, _borrowSym));
        console.log("--- Trove before ---");
        console.log("Collateral:           %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Debt:                 %s", _format(_trove.debt, _borrowDec, _borrowSym));
        console.log("--- Lever up ---");
        console.log("Additional coll:      %s (via the trove callback)", _format(ADDITIONAL_COLLATERAL, _collDec, _collSym));
        console.log("User extra coll:      %s", _format(USER_EXTRA_COLLATERAL, _collDec, _collSym));
        console.log("Base debt:            %s", _format(_baseDebt, _borrowDec, _borrowSym));
        console.log("Buffered debt:        %s", _format(_debtAmount, _borrowDec, _borrowSym));
        console.log("Max upfront fee:      %s", _format(_maxUpfrontFee, _borrowDec, _borrowSym));
        console.log("Lender idle:          %s", _format(_lenderIdle, _borrowDec, _borrowSym));
        console.log("Atomic delivery:      %s", _format(_atomicDelivery, _borrowDec, _borrowSym));
        console.log("Redeemed debt:        %s", _format(_redemptionAmount, _borrowDec, _borrowSym));
        console.log("Redeemed collateral:  %s", _format(_expectedRedeemedColl, _collDec, _collSym));
        console.log("Min borrow out:       %s", _format(_minBorrowOut, _borrowDec, _borrowSym));
        console.log("Min collateral out:   %s", _format(_minCollateralOut, _collDec, _collSym));
        console.log("--- Trove after (preview) ---");
        console.log("Collateral:           %s", _format(_newCollateral, _collDec, _collSym));
        console.log("Debt:                 %s", _format(_newDebtPreview, _borrowDec, _borrowSym));
        console.log("LTV:                  %s (max %s)", _fmtPct(_newLtvBps), _fmtPct(_maxLtvBps));
        console.log("---");
        console.log("Swap router:          %s", _swapRouter);
        console.log("Swap calldata bytes:  %s", _swapData.length);
        console.log("---------------------------------");

        vm.startBroadcast(_pk);

        // If the user is contributing extra collateral, the zapper needs an ERC20 allowance
        if (USER_EXTRA_COLLATERAL > 0) IERC20(_collateralToken).approve(address(LEVERAGE_ZAPPER), USER_EXTRA_COLLATERAL);

        // Make sure the zapper is approved to operate on the trove
        _ensureZapperApproved();

        // Lever up
        LEVERAGE_ZAPPER.lever_up_trove(
            ILeverageZapper.LeverUpData({
                trove_manager: address(TROVE_MANAGER),
                trove_id: TROVE_ID,
                initial_collateral: USER_EXTRA_COLLATERAL,
                collateral_amount: _collateralAmount,
                debt_amount: _debtAmount,
                max_upfront_fee: _maxUpfrontFee,
                min_borrow_out: _minBorrowOut,
                min_collateral_out: _minCollateralOut,
                debt_swap: ILeverageZapper.SwapData({router: _swapRouter, data: _swapData})
            })
        );

        vm.stopBroadcast();

        // Verify
        _trove = TROVE_MANAGER.troves(TROVE_ID);
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");

        // Final LTV (using the trove's stored debt, which already includes the upfront fee)
        uint256 _ltvBps = _trove.debt * BPS * ORACLE_PRICE_SCALE / (_trove.collateral * _price);

        console.log("---------------------------------");
        console.log("Trove collateral:     %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Trove debt:           %s", _format(_trove.debt, _borrowDec, _borrowSym));
        console.log("LTV:                  %s (max %s)", _fmtPct(_ltvBps), _fmtPct(_maxLtvBps));
        console.log("---------------------------------");
    }

}
