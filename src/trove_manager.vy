# @version 0.4.1
# @todo -- instead of the whole zombie thing. redeem a borrower completely if a redemption would bring them below some threshold
# @todo -- improve funcs naming

"""
@title Trove Manager
@license MIT
@author Flex Protocol
@notice Core contract that manages all Troves. Handles opening, closing, and updating borrower positions,
        accrues interest, maintains aggregate debt accounting, and coordinates redemptions with the Lender
        and sorted_troves contracts.
"""

from ethereum.ercs import IERC20

from periphery.interfaces import IExchange

from interfaces import ISortedTroves


# ============================================================================================
# Flags
# ============================================================================================


flag Status:
    nonExistent
    active
    closed
    liquidated


# ============================================================================================
# Structs
# ============================================================================================


struct Trove:
    status: Status
    debt: uint256
    collateral: uint256
    annual_interest_rate: uint256
    last_debt_update_time: uint64
    last_interest_rate_adj_time: uint64 # @todo -- do we need both of these?


# ============================================================================================
# Constants
# ============================================================================================


LENDER: public(immutable(address))

EXCHANGE: public(immutable(IExchange))
SORTED_TROVES: public(immutable(ISortedTroves))

BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

_WAD: constant(uint256) = 10 ** 18
_ONE_PCT: constant(uint256) = _WAD // 100
_MAX_ITERATIONS: constant(uint256) = 1000
_ONE_YEAR: constant(uint256) = 365 * 60 * 60 * 24

MIN_DEBT: public(constant(uint256)) = 1000 * 10 ** 18
MIN_ANNUAL_INTEREST_RATE: public(constant(uint256)) = _ONE_PCT // 2  # 0.5%
MAX_ANNUAL_INTEREST_RATE: public(constant(uint256)) = 250 * _ONE_PCT  # 250%
MINIMUM_COLLATERAL_RATIO: public(constant(uint256)) = 110 * _ONE_PCT  # 110% // @todo -- make this configurable
UPFRONT_INTEREST_PERIOD: public(constant(uint256)) = 7 * 24 * 60 * 60  # 7 days


# ============================================================================================
# Storage
# ============================================================================================

# Total outstanding system debt
total_debt: public(uint256)

# Sum of individual trove debts weighted by their annual interest rates
total_weighted_debt: public(uint256)

# Last timestamp when `total_debt` and `total_weighted_debt` were updated
last_debt_update_time: public(uint256)

# Total collateral tokens currently held by the contract
collateral_balance: public(uint256)

# trove ID --> Trove info
troves: public(HashMap[uint256, Trove])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    lender: address,
    exchange: address,
    sorted_troves: address,
    borrow_token: address,
    collateral_token: address
):
    LENDER = lender
    EXCHANGE = IExchange(exchange)
    SORTED_TROVES = ISortedTroves(sorted_troves)
    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)


# ============================================================================================
# view
# ============================================================================================


# @external
# @view
# def get_trove_annual_interest_rate(trove_id: uint256) -> uint256:
#     """
#     """
#     return self.troves[trove_id].annual_interest_rate


# ============================================================================================
# Borrow
# ============================================================================================


# @todo -- add min_debt_out (for swap slippage protection)
# @todo -- add event
@external
def open_trove(
    owner: address,
    owner_index: uint256,
    collateral_amount: uint256,
    debt_amount: uint256,
    upper_hint: uint256,
    lower_hint: uint256,
    annual_interest_rate: uint256,
    max_upfront_fee: uint256
) -> uint256:
    """
    @notice Open a new Trove with specified collateral, debt, and interest rate
    @param owner Address that will own the Trove and receive the borrowed tokens
    @param owner_index Unique index to allow multiple Troves per owner
    @param collateral_amount Amount of collateral tokens to deposit
    @param debt_amount Amount of debt to issue before the upfront fee
    @param upper_hint Suggested upper neighbor in `sorted_troves`
    @param lower_hint Suggested lower neighbor in `sorted_troves`
    @param annual_interest_rate Fixed annual interest rate to pay on the debt
    @param max_upfront_fee Maximum upfront fee the caller is willing to pay
    @return trove_id Unique identifier for the new Trove
    """
    # Make sure collateral and debt amounts are non-zero
    assert collateral_amount > 0, "!collateral"
    assert debt_amount > 0, "!debt"

    # Make sure the annual interest rate is within bounds    
    assert annual_interest_rate >= MIN_ANNUAL_INTEREST_RATE, "rate too low"
    assert annual_interest_rate <= MAX_ANNUAL_INTEREST_RATE, "rate too high"

    # Generate the trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(msg.sender, owner, owner_index)), uint256)

    # Make sure the trove doesn't already exist
    assert self.troves[trove_id].status == Status.nonExistent, "trove exists"

    # Calculate the upfront fee using the average interest rate of all troves
    avg_interest_rate: uint256 = self._approx_avg_interest_rate(debt_amount, annual_interest_rate)
    upfront_fee: uint256 = self._calculate_interest(debt_amount * avg_interest_rate, UPFRONT_INTEREST_PERIOD)

    # Make sure the user is ok with the upfront fee
    assert upfront_fee <= max_upfront_fee, "!max_upfront_fee"

    # Record the debt with the upfront fee
    debt_amount_with_fee: uint256 = debt_amount + upfront_fee

    # Make sure enough debt is being borrowed
    assert debt_amount_with_fee >= MIN_DEBT, "debt too low"

    # Get the collateral price
    collateral_price: uint256 = staticcall EXCHANGE.price()

    # Calculate the collateral ratio
    trove_collateral_ratio: uint256 = self._calculate_collateral_ratio(collateral_amount, debt_amount_with_fee, collateral_price)

    # Make sure the collateral ratio is above the minimum collateral ratio
    assert trove_collateral_ratio >= MINIMUM_COLLATERAL_RATIO, "!MCR"

    # Store the trove information
    self.troves[trove_id] = Trove(
        status=Status.active,
        debt=debt_amount_with_fee,
        collateral=collateral_amount,
        annual_interest_rate=annual_interest_rate,
        last_debt_update_time=convert(block.timestamp, uint64),
        last_interest_rate_adj_time=convert(block.timestamp, uint64)
    )

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        debt_amount_with_fee, # debt_increase
        0, # debt_decrease
        0, # old_weighted_debt
        debt_amount_with_fee * annual_interest_rate, # new_weighted_debt
    )

    # Add the trove to the sorted troves list
    extcall SORTED_TROVES.insert(
        trove_id,
        annual_interest_rate,
        upper_hint,
        lower_hint
    )

    # Pull the collateral tokens from caller
    extcall COLLATERAL_TOKEN.transferFrom(msg.sender, self, collateral_amount, default_return_value=True)

    # Record the received collateral
    self.collateral_balance += collateral_amount

    # Check how much borrow token liquidity the lender has
    available_liquidity: uint256 = staticcall BORROW_TOKEN.balanceOf(LENDER)

    # If there's not enough liquidity, redeem the difference. Otherwise just transfer the full amount
    if debt_amount > available_liquidity:
        # Redeem the difference
        self._redeem(debt_amount - available_liquidity, owner)

        # Transfer whatever we have in the lender
        if available_liquidity > 0:
            extcall BORROW_TOKEN.transferFrom(LENDER, owner, available_liquidity, default_return_value=True)
    else:
        # Transfer the full amount
        extcall BORROW_TOKEN.transferFrom(LENDER, owner, debt_amount, default_return_value=True)

    return trove_id


# ============================================================================================
# redeem
# ============================================================================================


@external
def redeem(amount: uint256):
    """
    @notice Attempt to free the specified amount of borrow tokens by selling collateral
    @dev Can only be called by the Lender contract
    @dev Swap sandwich protection is the caller's responsibility
    @param amount Desired amount of borrow tokens to free
    """
    # Make sure the caller is the lender
    assert msg.sender == LENDER, "!lender"

    # Redeem collateral equal to `amount` of debt and transfer the borrow tokens to the lender
    self._redeem(amount)


@internal
def _redeem(amount: uint256, receiver: address = LENDER):
    """
    @notice Internal implementation of `redeem`
    @dev Swap sandwich protection is the caller's responsibility
    @param amount Target amount of borrow tokens to free
    @param receiver Address to receive the resulting borrow tokens
    """
    # Accrue interest on the total debt and get the updated figure
    total_debt: uint256 = self._accrue_interest()

    # Make sure we're not trying to redeem more than the total debt
    assert amount <= total_debt, "total_debt"

    # Get the collateral price
    collateral_price: uint256 = staticcall EXCHANGE.price()

    # Get the trove with the smallest annual interest rate
    trove_to_redeem: uint256 = staticcall SORTED_TROVES.last()

    # Cache the amount of debt we need to free
    remaining_debt_to_free: uint256 = amount

    # Cache the total changes we're making so that later we can update the accounting
    total_debt_decrease: uint256 = 0
    total_collateral_decrease: uint256 = 0
    total_new_weighted_debt: uint256 = 0
    total_old_weighted_debt: uint256 = 0

    # Loop through as many Troves as we're allowed or until we redeem all the debt we need
    for _: uint256 in range(_MAX_ITERATIONS):
        print("iteration: _", _, hardhat_compat=True)

        # Get the Trove we're redeeming
        trove: Trove = self.troves[trove_to_redeem]

        # Accrue interest on the Trove's debt
        trove_debt_before_interest: uint256 = trove.debt
        trove_debt_after_interest: uint256 = trove_debt_before_interest + self._calculate_interest(
            trove_debt_before_interest * trove.annual_interest_rate,  # trove_weighted_debt
            block.timestamp - convert(trove.last_debt_update_time, uint256)  # period since last update
        )

        # Determine the amount to be freed
        debt_to_free: uint256 = min(remaining_debt_to_free, trove_debt_after_interest)

        # @todo -- if debt_to_free leaves the trove below min debt, redeem the whole trove

        # Get the amount of collateral equal to `debt_to_free`
        collateral_to_redeem: uint256 = debt_to_free * _WAD // collateral_price

        # Decrease the debt and collateral of the current Trove according to the amounts redeemed
        trove_new_debt: uint256 = trove_debt_after_interest - debt_to_free
        trove_new_collateral: uint256 = trove.collateral - collateral_to_redeem

        # Calculate the Trove's old and new weighted debt
        trove_old_weighted_debt: uint256 = trove_debt_before_interest * trove.annual_interest_rate
        trove_new_weighted_debt: uint256 = trove_new_debt * trove.annual_interest_rate

        # Update the Trove's information
        trove.debt = trove_new_debt
        trove.collateral = trove_new_collateral
        trove.last_debt_update_time = convert(block.timestamp, uint64)

        # Increment the total debt and collateral decrease
        total_debt_decrease += debt_to_free
        total_collateral_decrease += collateral_to_redeem

        # Increment the total old and new weighted debt
        total_old_weighted_debt += trove_old_weighted_debt
        total_new_weighted_debt += trove_new_weighted_debt

        # Update the remaining debt to free
        remaining_debt_to_free -= debt_to_free

        # Check if we freed all the debt we wanted
        if remaining_debt_to_free == 0:
            break

        # Get the next Trove to redeem
        trove_to_redeem = staticcall SORTED_TROVES.prev(trove_to_redeem)

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        0, # debt_increase
        total_debt_decrease, # debt_decrease
        total_old_weighted_debt, # old_weighted_debt
        total_new_weighted_debt, # new_weighted_debt
    )

    # Make sure we don't try to redeem more collateral than we can
    assert total_collateral_decrease <= self.collateral_balance, "rekt"  # This should never happen

    # Update the contract's recorded collateral balance
    self.collateral_balance -= total_collateral_decrease

    # Swap the collateral to borrow token and transfer it to the receiver
    extcall EXCHANGE.swap(total_collateral_decrease, receiver)


# ============================================================================================
# Internal pure functions
# ============================================================================================


@internal
@pure
def _calculate_collateral_ratio(collateral: uint256, debt: uint256, collateral_price: uint256) -> uint256:
    """
    @notice Calculate the collateral ratio given collateral, debt, and collateral price
    @param collateral The amount of collateral tokens
    @param debt The amount of debt
    @param collateral_price The price of one collateral token
    @return collateral_ratio The collateral ratio
    """
    return collateral * collateral_price // debt


@internal
@pure
def _calculate_interest(weighted_debt: uint256, period: uint256) -> uint256:
    """
    @notice Calculate the interest accrued on weighted debt over a given period
    @param weighted_debt The debt weighted by the annual interest rate
    @param period The time period over which interest is calculated (in seconds)
    @return interest The interest accrued over the period
    """
    return weighted_debt * period // _ONE_YEAR // _WAD


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _approx_avg_interest_rate(debt_amount: uint256, annual_interest_rate: uint256) -> uint256:
    """
    @notice Approximate the new average annual interest rate after adding a Trove with specified debt and rate
    @param debt_amount The debt of the new Trove
    @param annual_interest_rate The annual interest rate of the new Trove
    @return new_avg_interest_rate The approximated new average annual interest rate
    """
    # Total debt after adding the new debt
    new_total_debt: uint256 = self.total_debt + debt_amount

    # Total weighted debt after adding the new weighted debt
    new_total_weighted_debt: uint256 = self.total_weighted_debt + (debt_amount * annual_interest_rate)

    return new_total_weighted_debt // new_total_debt


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def _accrue_interest_and_account_for_trove_change(
    debt_increase: uint256,
    debt_decrease: uint256,
    old_weighted_debt: uint256,
    new_weighted_debt: uint256
):
    """
    @notice Accrue interest on the total debt and update total debt and total weighted debt accounting
    @param debt_increase Amount of debt to add to the total debt
    @param debt_decrease Amount of debt to subtract from the total debt
    @param old_weighted_debt Amount of weighted debt to subtract from the total weighted debt
    @param new_weighted_debt Amount of weighted debt to add to the total weighted debt
    """
    # Update total debt
    new_total_debt: uint256 = self.total_debt
    new_total_debt += self._accrue_interest()
    new_total_debt += debt_increase
    new_total_debt -= debt_decrease
    self.total_debt = new_total_debt

    # Update total weighted debt
    new_total_weighted_debt: uint256 = self.total_weighted_debt
    new_total_weighted_debt += new_weighted_debt
    new_total_weighted_debt -= old_weighted_debt
    self.total_weighted_debt = new_total_weighted_debt


@internal
def _accrue_interest() -> uint256:
    """
    @notice Accrue interest on the total debt based on the elapsed time since the last update
    @return new_total_debt The updated total debt after accruing interest
    """
    # @todo -- use ceiling
    # We use the ceiling of the division here to ensure positive error, while we use regular floor division
    # when calculating the interest accrued by individual Troves.
    # This ensures that `system debt >= sum(trove debt)` always holds, and thus system debt won't turn negative
    # even if all Trove debt is repaid. The difference should be small and it should scale with the number of
    # interest minting events.
    # Calculate the pending aggregate interest
    pending_agg_interest: uint256 = (self.total_weighted_debt * (block.timestamp - self.last_debt_update_time)) // (_ONE_YEAR * _WAD)

    # Calculate the new total debt after interest
    new_total_debt: uint256 = self.total_debt + pending_agg_interest

    # Update the total debt
    self.total_debt = new_total_debt

    # Update the last debt update time
    self.last_debt_update_time = block.timestamp

    return new_total_debt