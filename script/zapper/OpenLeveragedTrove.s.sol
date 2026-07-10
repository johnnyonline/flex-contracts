// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILeverageZapper} from "../interfaces/ILeverageZapper.sol";

import {ISortedTroves} from "../../test/interfaces/ISortedTroves.sol";
import {ITroveManager} from "../../test/interfaces/ITroveManager.sol";

import {BaseZapperScript} from "./BaseZapperScript.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// open a leveraged trove via Enso:
// forge script script/zapper/OpenLeveragedTrove.s.sol:OpenLeveragedTrove --slow --rpc-url $RPC_URL --ffi --broadcast

contract OpenLeveragedTrove is BaseZapperScript {

    // ============================================================================================
    // Parameters - tweak before running
    // ============================================================================================

    uint256 public constant TARGET_LEVERAGE = 5; // e.g. 10x
    uint256 public constant USER_COLLATERAL = 500e6; // raw amount in collateral decimals
    uint256 public constant ANNUAL_INTEREST_RATE = 1e3; // 0.1% on USDC (= `min_annual_interest_rate` = `one_pct / 10`)

    // ============================================================================================
    // Storage (hoisted out of `run()` to relieve stack pressure)
    // ============================================================================================

    uint256 internal _additionalCollateral;
    uint256 internal _totalCollateral;
    uint256 internal _baseDebt;
    uint256 internal _debtAmount;
    uint256 internal _maxUpfrontFee;
    uint256 internal _minBorrowOut;
    uint256 internal _minCollateralOut;
    uint256 internal _lenderIdle;
    uint256 internal _atomicDelivery;
    uint256 internal _redemptionAmount;
    uint256 internal _expectedRedeemedColl;
    uint256 internal _rateBps;
    uint256 internal _prevId;
    uint256 internal _nextId;
    uint256 internal _ownerIndex;
    uint256 internal _troveId;
    uint256 internal _achievedLeverageBps;
    uint256 internal _collValue;
    uint256 internal _ltvBps;

    // ============================================================================================
    // Run
    // ============================================================================================

    function run() public {
        uint256 _pk = _loadUser();

        require(TARGET_LEVERAGE >= 2, "leverage must be >= 2");

        _loadMarket();

        // Compute amounts. The additional collateral is sourced inside the trove callback: the
        // redemption-driven portion arrives in kind from the kicked auction (the zapper is both
        // taker and kick receiver, so the take nets out), and the idle-liquidity portion is
        // swapped borrow -> collateral via Enso.
        _additionalCollateral = USER_COLLATERAL * (TARGET_LEVERAGE - 1);
        _totalCollateral = USER_COLLATERAL * TARGET_LEVERAGE;
        _baseDebt = _additionalCollateral * _price / ORACLE_PRICE_SCALE;
        // Buffer the debt to cover swap slippage (lever zapper sweeps excess back to user)
        _debtAmount = _baseDebt * BPS / (BPS - SLIPPAGE_BPS);

        // Snapshot how much of `_debtAmount` the Lender can cover from idle vs. how much will go
        // through the redemption path (auction taken atomically in the trove callback).
        _lenderIdle = IERC20(_borrowToken).balanceOf(TROVE_MANAGER.lender());
        _atomicDelivery = _debtAmount > _lenderIdle ? _lenderIdle : _debtAmount;
        _redemptionAmount = _debtAmount - _atomicDelivery;
        _expectedRedeemedColl = _redemptionAmount * ORACLE_PRICE_SCALE / _price;

        // Slippage / sandwich-protection floors and ceilings
        // - max upfront fee: quote + a small tolerance for avg-rate movement
        // - min borrow out: require the Lender to still have at least its snapshotted idle balance
        //   (anyone draining it between quote and execution makes the tx revert)
        // - min collateral out: allow up to SLIPPAGE_BPS slippage on the redemption-driven auction
        // - the declared `collateral_amount` is itself the overall floor: if the callback sources
        //   less than `_totalCollateral`, the Trove Manager's collateral pull reverts
        _maxUpfrontFee = TROVE_MANAGER.get_upfront_fee(_debtAmount, ANNUAL_INTEREST_RATE) * (BPS + SLIPPAGE_BPS) / BPS;
        _minBorrowOut = _atomicDelivery;
        _minCollateralOut = _expectedRedeemedColl * (BPS - SLIPPAGE_BPS) / BPS;

        // Sanity checks before any state changes
        require(_debtAmount > TROVE_MANAGER.min_debt(), "!min_debt");
        require(IERC20(_collateralToken).balanceOf(_user) >= USER_COLLATERAL, "!USER_COLLATERAL");

        // Annual interest rate in bps for display
        _rateBps = ANNUAL_INTEREST_RATE * 100 / TROVE_MANAGER.one_pct();
        // Compute SortedTroves insertion hints off-chain (passing (0, 0) walks the list from ROOT)
        (_prevId, _nextId) = ISortedTroves(TROVE_MANAGER.sorted_troves()).find_insert_position(ANNUAL_INTEREST_RATE, 0, 0);

        // Print plan
        console.log("---------------------------------");
        console.log("Trove Manager:        %s", address(TROVE_MANAGER));
        console.log("Collateral token:     %s (%s)", _collSym, _collateralToken);
        console.log("Borrow token:         %s (%s)", _borrowSym, _borrowToken);
        console.log("Price:                1 %s = %s", _collSym, _format(_borrowPerColl, _borrowDec, _borrowSym));
        console.log("Target leverage:      %sx", TARGET_LEVERAGE);
        console.log("User collateral:      %s", _format(USER_COLLATERAL, _collDec, _collSym));
        console.log("Additional coll:      %s", _format(_additionalCollateral, _collDec, _collSym));
        console.log("Total trove coll:     %s", _format(_totalCollateral, _collDec, _collSym));
        console.log("Base debt:            %s", _format(_baseDebt, _borrowDec, _borrowSym));
        console.log("Buffered debt:        %s", _format(_debtAmount, _borrowDec, _borrowSym));
        console.log("Annual interest rate: %s bps", _rateBps);
        console.log("Max upfront fee:      %s", _format(_maxUpfrontFee, _borrowDec, _borrowSym));
        console.log("Lender idle:          %s", _format(_lenderIdle, _borrowDec, _borrowSym));
        console.log("Atomic delivery:      %s", _format(_atomicDelivery, _borrowDec, _borrowSym));
        console.log("Redeemed debt:        %s", _format(_redemptionAmount, _borrowDec, _borrowSym));
        console.log("Redeemed collateral:  %s", _format(_expectedRedeemedColl, _collDec, _collSym));
        console.log("Min borrow out:       %s", _format(_minBorrowOut, _borrowDec, _borrowSym));
        console.log("Min collateral out:   %s", _format(_minCollateralOut, _collDec, _collSym));
        console.log("---------------------------------");

        // Get the enso swap calldata (borrow_token -> collateral_token) for the idle-liquidity
        // portion only; the redemption portion arrives in kind from the auction.
        // IMPORTANT: pass the SwapExecutor as the Enso `fromAddress` so the route writes the output
        // back to the executor (which sweeps it to the LeverageZapper). If we pass the user instead,
        // Enso bakes the user's address into the deposit receiver and the zapper sees zero output.
        if (_atomicDelivery > 0) {
            (_swapRouter, _swapData) =
                _getEnsoSwapData(block.chainid, _borrowToken, _collateralToken, _atomicDelivery, LEVERAGE_ZAPPER.SWAP_EXECUTOR());
            console.log("Swap router:          %s", _swapRouter);
            console.log("Swap calldata bytes:  %s", _swapData.length);

            // Make sure the router is whitelisted on the zapper
            require(LEVERAGE_ZAPPER.routers(_swapRouter), "swap router not whitelisted on LeverageZapper");
        }

        _ownerIndex = block.timestamp;

        vm.startBroadcast(_pk);

        // Approve zapper to pull the user's collateral
        IERC20(_collateralToken).approve(address(LEVERAGE_ZAPPER), USER_COLLATERAL);

        // Approve zapper as a Trove Manager operator (needed for future lever_up / lever_down / close_leveraged_trove on this trove)
        _ensureZapperApproved();

        // Open the leveraged trove
        _troveId = LEVERAGE_ZAPPER.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: _user,
                trove_manager: address(TROVE_MANAGER),
                owner_index: _ownerIndex,
                initial_collateral: USER_COLLATERAL,
                collateral_amount: _totalCollateral,
                debt_amount: _debtAmount,
                prev_id: _prevId,
                next_id: _nextId,
                annual_interest_rate: ANNUAL_INTEREST_RATE,
                max_upfront_fee: _maxUpfrontFee,
                min_borrow_out: _minBorrowOut,
                min_collateral_out: _minCollateralOut,
                debt_swap: ILeverageZapper.SwapData({router: _swapRouter, data: _swapData})
            })
        );

        vm.stopBroadcast();

        // Verify
        _trove = TROVE_MANAGER.troves(_troveId);
        require(_trove.owner == _user, "trove owner mismatch");
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");
        require(_trove.collateral > 0, "trove has no collateral");
        require(_trove.debt > 0, "trove has no debt");

        // Achieved leverage = trove.collateral / user_collateral
        _achievedLeverageBps = _trove.collateral * BPS / USER_COLLATERAL;

        // LTV = debt / collateral_value_in_borrow (bps).
        _collValue = _trove.collateral * _price / ORACLE_PRICE_SCALE;
        _ltvBps = _trove.debt * BPS / _collValue;

        console.log("---------------------------------");
        console.log("Trove ID:             %s", _troveId);
        console.log("Trove collateral:     %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Trove debt:           %s", _format(_trove.debt, _borrowDec, _borrowSym));
        console.log("Achieved leverage:    %s.%s%sx", _achievedLeverageBps / BPS, (_achievedLeverageBps / 100) % 100, _achievedLeverageBps % 100);
        console.log("LTV:                  %s (max %s)", _fmtPct(_ltvBps), _fmtPct(_maxLtvBps));
        console.log("---------------------------------");
    }

}
