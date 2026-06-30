// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILender} from "../src/lender/interfaces/ILender.sol";

import {ICatFactory} from "../script/interfaces/ICatFactory.sol";
import {IDaddy} from "../script/interfaces/IDaddy.sol";
import {ILeverageZapperNG} from "../script/interfaces/ILeverageZapperNG.sol";
import {IRegistry} from "../script/interfaces/IRegistry.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import {MockRouter} from "./mocks/MockRouter.sol";

import "forge-std/Test.sol";

contract LeverageZapperNGLossyConversionTests is Test {

    // Tokens
    IERC20 public borrowToken = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
    IERC20 public collateralToken = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0); // wstETH

    // Morpho oracle for the collateral/borrow pair (wstETH/WETH)
    address public constant MORPHO_ORACLE = 0xbD60A6770b27E084E8617335ddE769241B0e71D8;

    // Prod core (already deployed at the fork block)
    ICatFactory public constant CAT_FACTORY = ICatFactory(0xe2c4a5C2AB1ed5745D206B33cc0abf0A5D34753d);
    IDaddy public constant DADDY = IDaddy(0x4e8341C77c94cCE982AB96d92BB28D69f4638290);
    IRegistry public constant REGISTRY = IRegistry(0x9117440a7D03238905d1C8908157Bd7a547c77c8);

    uint256 public constant BPS = 10_000;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant SLIPPAGE_BPS = 15; // simulated lossy collateral<->borrow swap via MockRouter (wstETH/WETH is ~1:1 in reality)
    uint256 public constant MINIMUM_COLLATERAL_RATIO = 110; // 110%

    // Contracts
    address public lender;
    address public swapExecutor;
    address public auctionTaker;
    IPriceOracle public priceOracle;
    ITroveManager public troveManager;
    ILeverageZapperNG public zapper;
    MockRouter public mockRouter;

    // Roles
    address public daddyOwner;
    address public userLender = address(420);
    address public userBorrower = address(69);
    address public anotherUserBorrower = address(555);

    // "constants" for tests
    uint256 public BORROW_TOKEN_PRECISION;
    uint256 public COLLATERAL_TOKEN_PRECISION;
    uint256 public MIN_RATE;
    uint256 public LENDER_FUNDS;
    uint256 public DUST; // deliberate over-borrow margin == max borrow the user can be swept back

    // Fuzz bounds
    uint256 public minCollateralFuzzAmount;
    uint256 public maxCollateralFuzzAmount;
    uint256 public maxLeverage;

    uint256 internal _ownerIndex;

    function setUp() public {
        // Create fork
        uint256 _blockNumber = 25_317_111; // cache state for faster tests (Morpho oracle + prod core exist)
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        daddyOwner = DADDY.owner();

        // Deploy the generic Morpho oracle for the collateral/borrow pair
        priceOracle = IPriceOracle(deployCode("morpho_oracle", abi.encode(MORPHO_ORACLE, address(borrowToken), address(collateralToken))));

        // Deploy the market via the prod factory (permissionless, salted by msg.sender)
        (address _troveManager,,,, address _lender) = CAT_FACTORY.deploy(
            ICatFactory.DeployParams({
                borrow_token: address(borrowToken),
                collateral_token: address(collateralToken),
                price_oracle: address(priceOracle),
                minimum_debt: 1,
                safe_collateral_ratio: 120,
                minimum_collateral_ratio: MINIMUM_COLLATERAL_RATIO,
                max_penalty_collateral_ratio: 105,
                min_liquidation_fee: 50,
                max_liquidation_fee: 500,
                upfront_interest_period: 7 days,
                interest_rate_adj_cooldown: 7 days,
                minimum_price_buffer_percentage: 1e18 - 1e16, // 99%
                starting_price_buffer_percentage: 1e18, // 100% -> atomic take needs exactly the redeemed debt
                re_kick_starting_price_buffer_percentage: 1e18 + 1e15, // 100.1%
                step_duration: 60,
                step_decay_rate: 1,
                auction_length: 1 days,
                salt: bytes32(uint256(1))
            })
        );
        troveManager = ITroveManager(_troveManager);
        lender = _lender;

        // Accept Lender management and remove the deposit limit
        vm.prank(daddyOwner);
        DADDY.execute(lender, abi.encodeWithSignature("acceptManagement()"), 0, true);
        vm.mockCall(lender, abi.encodeWithSignature("availableDepositLimit(address)"), abi.encode(type(uint256).max));

        // Deploy NG periphery: swap executor, NG zapper, swap-based auction taker
        swapExecutor = deployCode("swap_executor");
        zapper = ILeverageZapperNG(deployCode("leverage_zapper_ng", abi.encode(address(DADDY), address(REGISTRY), swapExecutor)));
        auctionTaker = deployCode("swap_auction_taker", abi.encode(swapExecutor));

        // Deploy lossy mock router (crvusd arg == borrow so it routes collateral <-> borrow)
        mockRouter = new MockRouter(priceOracle, address(collateralToken), address(borrowToken), address(borrowToken), SLIPPAGE_BPS);

        // Endorse the market and whitelist the router + taker on the NG zapper
        vm.startPrank(daddyOwner);
        DADDY.execute(address(REGISTRY), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);
        DADDY.execute(address(zapper), abi.encodeWithSelector(ILeverageZapperNG.set_router.selector, address(mockRouter), true), 0, true);
        DADDY.execute(address(zapper), abi.encodeWithSelector(ILeverageZapperNG.set_auction_taker.selector, auctionTaker, true), 0, true);
        vm.stopPrank();

        // Set up "constants" for tests
        BORROW_TOKEN_PRECISION = 10 ** IERC20Metadata(address(borrowToken)).decimals();
        COLLATERAL_TOKEN_PRECISION = 10 ** IERC20Metadata(address(collateralToken)).decimals();
        MIN_RATE = troveManager.min_annual_interest_rate();
        LENDER_FUNDS = 10_000 * BORROW_TOKEN_PRECISION;
        DUST = BORROW_TOKEN_PRECISION / 100; // 0.01 borrow token

        // Set fuzz bounds (base collateral kept above min_debt; leverage capped below the MCR limit)
        minCollateralFuzzAmount = _collateralForDebt(troveManager.min_debt()) * 10;
        maxCollateralFuzzAmount = 100 * COLLATERAL_TOKEN_PRECISION;
        maxLeverage = (MINIMUM_COLLATERAL_RATIO / (MINIMUM_COLLATERAL_RATIO - 100)) * 70 / 100;
    }

    function test_openLeveragedTrove_noIdle(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        // Fund the lender, then drain all idle with a big low-rate trove (the redemption target)
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        _drainIdle(MIN_RATE);

        // Compute amounts: acquire (leverage - 1) more collateral, over-borrow for slippage, fund the taker
        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 baseDebt = _collateralValue(additionalCollateral);
        uint256 debtAmount = baseDebt * BPS / (BPS - SLIPPAGE_BPS) + DUST;
        uint256 takerFunding = debtAmount * SLIPPAGE_BPS / BPS + DUST; // just the take's shortfall (+ rounding cushion)

        // Approve zapper to pull collateral
        _airdrop(address(collateralToken), userBorrower, _userCollateral);
        vm.prank(userBorrower);
        collateralToken.approve(address(zapper), _userCollateral);

        // Open leveraged trove (no idle -> full redemption -> funded take)
        vm.prank(userBorrower);
        uint256 troveId = zapper.open_leveraged_trove(
            ILeverageZapperNG.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: auctionTaker,
                owner_index: ++_ownerIndex,
                flash_loan_amount: baseDebt + takerFunding,
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: MIN_RATE * 20, // above the redeemed trove's rate so it can redeem
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}),
                taker_funding: takerFunding,
                taker_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                })
            })
        );

        // Verify trove
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertApproxEqRel(trove.collateral, _userCollateral * _leverage, 3e16, "E2"); // 3% tolerance

        // Verify no leftover tokens, and the borrower got back a positive, dust-bounded borrow refund
        _assertNoLeftovers();
        assertGt(borrowToken.balanceOf(userBorrower), 0, "E3");
        assertLe(borrowToken.balanceOf(userBorrower), DUST, "E4");
    }

    function test_leverUpTrove_noIdle(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 3);

        // Fund the lender and open the borrower's base trove (low LTV, high rate so it can redeem)
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        uint256 troveId = _openTrove(userBorrower, _userCollateral, _collateralValue(_userCollateral) / 5, MIN_RATE * 20);

        // Drain remaining idle with a big low-rate trove (the redemption target)
        _drainIdle(MIN_RATE);

        // Compute amounts: add (additionalLeverage) more collateral, over-borrow for slippage, fund the taker
        uint256 additionalCollateral = _userCollateral * _additionalLeverage;
        uint256 baseDebt = _collateralValue(additionalCollateral);
        uint256 debtAmount = baseDebt * BPS / (BPS - SLIPPAGE_BPS) + DUST;
        uint256 takerFunding = debtAmount * SLIPPAGE_BPS / BPS + DUST; // just the take's shortfall (+ rounding cushion)

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(zapper), true);

        // Lever up (no idle -> full redemption -> funded take)
        vm.prank(userBorrower);
        zapper.lever_up_trove(
            ILeverageZapperNG.LeverUpData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: auctionTaker,
                trove_id: troveId,
                flash_loan_amount: baseDebt + takerFunding,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}),
                taker_funding: takerFunding,
                taker_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                })
            })
        );

        // Verify trove grew, no leftover tokens, and the borrower was swept dust at most
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertApproxEqRel(troveAfter.collateral, troveBefore.collateral + additionalCollateral, 3e16, "E0"); // 3% tolerance
        assertGt(troveAfter.debt, troveBefore.debt, "E1");
        _assertNoLeftovers();
        assertGt(borrowToken.balanceOf(userBorrower) - borrowBalanceBefore, 0, "E2");
        assertLe(borrowToken.balanceOf(userBorrower) - borrowBalanceBefore, DUST, "E3");
    }

    function test_leverUpTrove_noIdle_revertsWithoutTakerFunding(
        uint256 _userCollateral
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);

        // Fund the lender, open the borrower's base trove (low LTV), then drain all idle
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        uint256 troveId = _openTrove(userBorrower, _userCollateral, _collateralValue(_userCollateral) / 5, MIN_RATE * 20);
        _drainIdle(MIN_RATE);

        uint256 baseDebt = _collateralValue(_userCollateral * 3);
        uint256 debtAmount = baseDebt * BPS / (BPS - SLIPPAGE_BPS) + DUST;

        vm.prank(userBorrower);
        troveManager.approve(address(zapper), true);

        // Without taker funding the taker recovers only debt * (1 - slippage) < needed -> take reverts
        vm.prank(userBorrower);
        vm.expectRevert();
        zapper.lever_up_trove(
            ILeverageZapperNG.LeverUpData({
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: auctionTaker,
                trove_id: troveId,
                flash_loan_amount: baseDebt,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}),
                taker_funding: 0,
                taker_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                })
            })
        );
    }

    function test_openLeveragedTrove_noIdle_flashCollateral(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        // Fund the lender (borrow token), then drain all idle with a big low-rate trove (the redemption target)
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        _drainIdle(MIN_RATE);

        // Flash the COLLATERAL token directly (Morpho holds wstETH) so there is NO acquisition swap.
        // Over-borrow to cover the redemption-recovery + repayment swaps, and fund the taker in collateral
        // (carved from the flash); the taker swaps the redeemed + funding collateral to pay the auction.
        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 baseDebt = _collateralValue(additionalCollateral);
        uint256 debtAmount = baseDebt * BPS / (BPS - 100) + DUST;
        uint256 takerFunding = additionalCollateral * 100 / BPS; // collateral (== flash token)

        _airdrop(address(collateralToken), userBorrower, _userCollateral);
        vm.prank(userBorrower);
        collateralToken.approve(address(zapper), _userCollateral);

        vm.prank(userBorrower);
        uint256 troveId = zapper.open_leveraged_trove(
            ILeverageZapperNG.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                flash_loan_token: address(collateralToken), // flash the collateral, not the borrow token
                auction_taker: auctionTaker,
                owner_index: ++_ownerIndex,
                flash_loan_amount: additionalCollateral + takerFunding,
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: MIN_RATE * 20,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}), // no acquisition swap
                debt_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }), // borrow -> collateral to repay the flash
                taker_funding: takerFunding,
                taker_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                })
            })
        );

        // Verify trove opened at the target leverage (collateral flashed directly => no acquisition slippage)
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertApproxEqRel(trove.collateral, _userCollateral * _leverage, 1e15, "E2"); // ~exact, no acquisition slippage
        _assertNoLeftovers();

        // Refund comes back entirely as collateral (debt_swap converts all borrow to repay the collateral
        // flash): 0 borrow, and a positive collateral refund smaller than the funding we carved out (slippage eats the rest)
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E3");
        assertGt(collateralToken.balanceOf(userBorrower), 0, "E4");
        assertLe(collateralToken.balanceOf(userBorrower), takerFunding, "E5");
    }

    function test_leverUpTrove_noIdle_flashCollateral(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 3);

        // Fund the lender and open the borrower's base trove (low LTV, high rate so it can redeem)
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        uint256 troveId = _openTrove(userBorrower, _userCollateral, _collateralValue(_userCollateral) / 5, MIN_RATE * 20);

        // Drain remaining idle with a big low-rate trove (the redemption target)
        _drainIdle(MIN_RATE);

        // Flash the COLLATERAL token directly (Morpho holds wstETH) so there is NO acquisition swap.
        // Over-borrow to cover the recovery + repayment swaps, fund the taker in collateral (carved from the flash)
        uint256 additionalCollateral = _userCollateral * _additionalLeverage;
        uint256 baseDebt = _collateralValue(additionalCollateral);
        uint256 debtAmount = baseDebt * BPS / (BPS - 100) + DUST;
        uint256 takerFunding = additionalCollateral * 100 / BPS; // collateral (== flash token)

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(zapper), true);

        // Lever up flashing the collateral token (no idle -> full redemption -> funded take)
        vm.prank(userBorrower);
        zapper.lever_up_trove(
            ILeverageZapperNG.LeverUpData({
                trove_manager: address(troveManager),
                flash_loan_token: address(collateralToken), // flash the collateral, not the borrow token
                auction_taker: auctionTaker,
                trove_id: troveId,
                flash_loan_amount: additionalCollateral + takerFunding,
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}), // no acquisition swap
                debt_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }), // borrow -> collateral to repay the flash
                taker_funding: takerFunding,
                taker_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                })
            })
        );

        // Verify trove grew by ~additionalCollateral (collateral flashed directly => no acquisition slippage)
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertApproxEqRel(troveAfter.collateral, troveBefore.collateral + additionalCollateral, 1e15, "E0"); // ~exact
        assertGt(troveAfter.debt, troveBefore.debt, "E1");
        _assertNoLeftovers();

        // Refund comes back entirely as collateral (debt_swap converts all borrow to repay the collateral
        // flash): 0 borrow, and a positive collateral refund smaller than the funding we carved out (slippage eats the rest)
        assertEq(borrowToken.balanceOf(userBorrower) - borrowBalanceBefore, 0, "E2");
        assertGt(collateralToken.balanceOf(userBorrower), 0, "E3");
        assertLe(collateralToken.balanceOf(userBorrower), takerFunding, "E4");
    }

    function test_openLeveragedTrove_noIdle_lossFree(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        // Fund the lender, then drain all idle with a big low-rate trove (the redemption target)
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        _drainIdle(MIN_RATE);

        // Deposit is exactly the target leverage; borrow just covers the redemption (+ DUST rounding cushion)
        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 debtAmount = _collateralValue(additionalCollateral) + DUST;

        _airdrop(address(collateralToken), userBorrower, _userCollateral);
        vm.prank(userBorrower);
        collateralToken.approve(address(zapper), _userCollateral);

        vm.prank(userBorrower);
        uint256 troveId = zapper.open_leveraged_trove(
            ILeverageZapperNG.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                flash_loan_token: address(collateralToken), // flash the collateral, not the borrow token
                auction_taker: address(0), // no taker -> zapper settles the auction itself, loss-free
                owner_index: ++_ownerIndex,
                flash_loan_amount: additionalCollateral, // no funding, no over-borrow
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: MIN_RATE * 20,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}), // no acquisition swap
                debt_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}), // no repayment swap
                taker_funding: 0,
                taker_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""})
            })
        );

        // Verify the trove opened at exactly the target leverage (no conversion loss anywhere)
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertApproxEqRel(trove.collateral, _userCollateral * _leverage, 1e15, "E2"); // ~exact

        // No stranded tokens; borrower gets back ~0 borrow and only a tiny collateral dust (the DUST cushion)
        _assertNoLeftovers();
        assertLe(borrowToken.balanceOf(userBorrower), DUST, "E3");
        assertLe(collateralToken.balanceOf(userBorrower), _collateralForDebt(DUST) + COLLATERAL_TOKEN_PRECISION / 100, "E4");
    }

    function test_leverUpTrove_noIdle_lossFree(
        uint256 _userCollateral,
        uint256 _additionalLeverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _additionalLeverage = bound(_additionalLeverage, 1, maxLeverage - 3);

        // Fund the lender and open the borrower's base trove (low LTV, high rate so it can redeem)
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        uint256 troveId = _openTrove(userBorrower, _userCollateral, _collateralValue(_userCollateral) / 5, MIN_RATE * 20);

        // Drain remaining idle with a big low-rate trove (the redemption target)
        _drainIdle(MIN_RATE);

        // Add exactly additionalCollateral; borrow just covers the redemption (+ DUST rounding cushion)
        uint256 additionalCollateral = _userCollateral * _additionalLeverage;
        uint256 debtAmount = _collateralValue(additionalCollateral) + DUST;

        ITroveManager.Trove memory troveBefore = troveManager.troves(troveId);
        uint256 borrowBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Approve zapper to operate on behalf of the borrower
        vm.prank(userBorrower);
        troveManager.approve(address(zapper), true);

        // Lever up flashing the collateral, with NO taker -> zapper settles the auction itself, loss-free
        vm.prank(userBorrower);
        zapper.lever_up_trove(
            ILeverageZapperNG.LeverUpData({
                trove_manager: address(troveManager),
                flash_loan_token: address(collateralToken), // flash the collateral, not the borrow token
                auction_taker: address(0), // no taker -> zapper settles the auction itself, loss-free
                trove_id: troveId,
                flash_loan_amount: additionalCollateral, // no funding, no over-borrow
                collateral_amount: 0,
                debt_amount: debtAmount,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}), // no acquisition swap
                debt_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}), // no repayment swap
                taker_funding: 0,
                taker_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""})
            })
        );

        // Verify the trove grew by exactly additionalCollateral (no conversion loss anywhere)
        ITroveManager.Trove memory troveAfter = troveManager.troves(troveId);
        assertApproxEqRel(troveAfter.collateral, troveBefore.collateral + additionalCollateral, 1e15, "E0"); // ~exact
        assertGt(troveAfter.debt, troveBefore.debt, "E1");

        // No stranded tokens; borrower gets back ~0 borrow and only a tiny collateral dust (the DUST cushion)
        _assertNoLeftovers();
        assertLe(borrowToken.balanceOf(userBorrower) - borrowBalanceBefore, DUST, "E2");
        assertLe(collateralToken.balanceOf(userBorrower), _collateralForDebt(DUST) + COLLATERAL_TOKEN_PRECISION / 100, "E3");
    }

    // Outside of an in-progress take `_active_auction` is empty, so the callback guard rejects every caller.
    function test_takeCallback_revertsWhenNoActiveAuction() public {
        vm.expectRevert("!active_auction");
        ISwapAuctionTaker(auctionTaker).takeCallback(0, address(this), 0, 0, "");
    }

    // A nested takeAuction (e.g. a malicious router/auction reentering mid-take) is rejected by the entry
    // guard, so it cannot overwrite `_active_auction` and sweep the in-flight funding to itself.
    function test_takeAuction_revertsOnReentrantTakeAuction() public {
        ReentrantAuctionMock mockAuction = new ReentrantAuctionMock(address(borrowToken), address(collateralToken));
        mockAuction.setTaker(auctionTaker);

        // outer take sets the guard then calls take(), which reenters takeAuction -> "active_auction" bubbles up
        vm.expectRevert("active_auction");
        ISwapAuctionTaker(auctionTaker).takeAuction(address(mockAuction), 0, address(0), "");
    }

    // During a take the guard is open for the auction only: a whitelisted-but-malicious taker_swap router that
    // reenters `takeCallback` mid-take (to drain the funding the taker holds) is rejected, reverting the whole take.
    function test_takeAuction_revertsWhenRouterReentersMidTake() public {
        uint256 userCollateral = 10 * COLLATERAL_TOKEN_PRECISION;
        uint256 leverage = 2;

        // Fund the lender, then drain all idle so the open triggers a redemption + funded take
        _mintAndDepositIntoLender(userLender, LENDER_FUNDS);
        _drainIdle(MIN_RATE);

        uint256 additionalCollateral = userCollateral * (leverage - 1);
        uint256 baseDebt = _collateralValue(additionalCollateral);
        uint256 debtAmount = baseDebt * BPS / (BPS - SLIPPAGE_BPS) + DUST;
        uint256 takerFunding = debtAmount * SLIPPAGE_BPS / BPS + DUST;

        // Malicious router that reenters the taker's callback when invoked mid-take, whitelisted like a real one
        ReentrantRouterMock reentrantRouter = new ReentrantRouterMock(auctionTaker);
        vm.prank(daddyOwner);
        DADDY.execute(address(zapper), abi.encodeWithSelector(ILeverageZapperNG.set_router.selector, address(reentrantRouter), true), 0, true);

        _airdrop(address(collateralToken), userBorrower, userCollateral);
        vm.prank(userBorrower);
        collateralToken.approve(address(zapper), userCollateral);

        // The reentrant call hits the guard and bubbles "!active_auction" up through the whole take
        vm.prank(userBorrower);
        vm.expectRevert("!active_auction");
        zapper.open_leveraged_trove(
            ILeverageZapperNG.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: auctionTaker,
                owner_index: ++_ownerIndex,
                flash_loan_amount: baseDebt + takerFunding,
                collateral_amount: userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: MIN_RATE * 20,
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapperNG.SwapData({
                    router: address(mockRouter), data: abi.encode(address(borrowToken), address(collateralToken))
                }),
                debt_swap: ILeverageZapperNG.SwapData({router: address(0), data: ""}),
                taker_funding: takerFunding,
                taker_swap: ILeverageZapperNG.SwapData({
                    router: address(reentrantRouter), data: abi.encode(address(collateralToken), address(borrowToken))
                })
            })
        );
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    function _collateralValue(
        uint256 _collateral
    ) internal view returns (uint256) {
        return _collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
    }

    function _collateralForDebt(
        uint256 _debt
    ) internal view returns (uint256) {
        return _debt * ORACLE_PRICE_SCALE / priceOracle.get_price();
    }

    function _airdrop(
        address _token,
        address _to,
        uint256 _amount
    ) internal {
        deal(_token, _to, _amount);
    }

    function _mintAndDepositIntoLender(
        address _user,
        uint256 _amount
    ) internal {
        _airdrop(address(borrowToken), _user, _amount);
        vm.startPrank(_user);
        borrowToken.approve(lender, _amount);
        ILender(lender).deposit(_amount, _user);
        vm.stopPrank();
    }

    function _openTrove(
        address _user,
        uint256 _collateral,
        uint256 _debt,
        uint256 _rate
    ) internal returns (uint256 _troveId) {
        _airdrop(address(collateralToken), _user, _collateral);
        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _collateral);
        _troveId = troveManager.open_trove(++_ownerIndex, _collateral, _debt, 0, 0, _rate, type(uint256).max, 0, 0);
        vm.stopPrank();
    }

    function _drainIdle(
        uint256 _rate
    ) internal {
        uint256 _idle = borrowToken.balanceOf(lender);
        _openTrove(anotherUserBorrower, _collateralForDebt(_idle) * 2, _idle, _rate);
        assertEq(borrowToken.balanceOf(lender), 0, "idle not drained");
    }

    function _assertNoLeftovers() internal {
        assertEq(collateralToken.balanceOf(address(zapper)), 0, "zapper collateral leftover");
        assertEq(borrowToken.balanceOf(address(zapper)), 0, "zapper borrow leftover");
        assertEq(collateralToken.balanceOf(auctionTaker), 0, "taker collateral leftover");
        assertEq(borrowToken.balanceOf(auctionTaker), 0, "taker borrow leftover");
        assertEq(collateralToken.balanceOf(swapExecutor), 0, "executor collateral leftover");
        assertEq(borrowToken.balanceOf(swapExecutor), 0, "executor borrow leftover");
    }

}

interface ISwapAuctionTaker {

    function takeAuction(
        address auction,
        uint256 auction_id,
        address swap_router,
        bytes calldata swap_data
    ) external;

    function takeCallback(
        uint256 auction_id,
        address taker,
        uint256 amount_taken,
        uint256 needed_amount,
        bytes calldata data
    ) external;

}

// Whitelisted router that, when invoked by the Swap Executor mid-take, reenters the taker's callback
contract ReentrantRouterMock {

    ISwapAuctionTaker immutable taker;

    constructor(
        address _taker
    ) {
        taker = ISwapAuctionTaker(_taker);
    }

    fallback() external {
        taker.takeCallback(0, address(this), 0, 0, "");
    }

}

// Mock auction whose take() reenters takeAuction on the taker, to exercise the reentrancy guard
contract ReentrantAuctionMock {

    address public buy_token;
    address public sell_token;
    ISwapAuctionTaker taker;

    constructor(
        address _buy_token,
        address _sell_token
    ) {
        buy_token = _buy_token;
        sell_token = _sell_token;
    }

    function setTaker(
        address _taker
    ) external {
        taker = ISwapAuctionTaker(_taker);
    }

    function take(
        uint256 auction_id,
        uint256,
        address,
        bytes calldata
    ) external returns (uint256) {
        // Reenter takeAuction mid-take; the guard must reject this
        taker.takeAuction(address(this), auction_id, address(0), "");
        return 0;
    }

}
