# @version 0.4.1
# @todo -- instead of the whole zombie thing. redeem a borrower completely if a redemption would bring them below some threshold
"""
@title Sorted Troves
@license MIT
@author Flex Protocol
@notice todo
"""

from ethereum.ercs import IERC20

from periphery.interfaces import IExchange

from interfaces import IPool
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
    last_interest_rate_adj_time: uint64


# ============================================================================================
# Constants
# ============================================================================================


LENDER: public(immutable(address))

POOL: public(immutable(IPool))
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


troves: public(HashMap[uint256, Trove])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    lender: address,
    pool: address,
    exchange: address,
    sorted_troves: address,
    borrow_token: address,
    collateral_token: address
):
    LENDER = lender
    POOL = IPool(pool)
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
    """
    # Make sure the annual interest rate is within bounds    
    assert annual_interest_rate >= MIN_ANNUAL_INTEREST_RATE, "rate too low"
    assert annual_interest_rate <= MAX_ANNUAL_INTEREST_RATE, "rate too high"

    # Generate trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(msg.sender, owner, owner_index)), uint256)

    # Make sure the trove doesn't already exist
    assert self.troves[trove_id].status == Status.nonExistent, "trove exists"

    # Calculate the upfront fee using the average interest rate of all troves
    avg_interest_rate: uint256 = staticcall POOL.approx_avg_interest_rate()
    upfront_fee: uint256 = self._calculate_interest(debt_amount * avg_interest_rate, UPFRONT_INTEREST_PERIOD)

    # Make sure the user is ok with the upfront fee
    assert upfront_fee <= max_upfront_fee, "!max_upfront_fee"

    # Record the debt with the upfront fee
    debt_amount_with_fee: uint256 = debt_amount + upfront_fee

    # Make sure enough debt is being borrowed
    assert debt_amount_with_fee >= MIN_DEBT, "debt too low"

    # Get collateral price
    collateral_price: uint256 = staticcall EXCHANGE.price()

    # Calculate the collateral ratio
    trove_collateral_ratio: uint256 = self._collateral_ratio(collateral_amount, debt_amount_with_fee, collateral_price)

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

    # Update pool accounting
    extcall POOL.mint_agg_interest_and_account_for_trove_change(
        debt_amount_with_fee, # debt_increase
        0, # debt_decrease
        0, # old_weighted_recorded_debt
        debt_amount_with_fee * annual_interest_rate, # new_weighted_recorded_debt
    )

    # Add the trove to the sorted troves list
    extcall SORTED_TROVES.insert(
        trove_id,
        annual_interest_rate,
        upper_hint,
        lower_hint
    )

    # Pull collateral tokens from sender to the pool
    extcall COLLATERAL_TOKEN.transferFrom(msg.sender, POOL.address, collateral_amount, default_return_value=True)

    # Let the pool know about the received collateral
    extcall POOL.account_for_received_collateral(collateral_amount)

    # Check how much borrow token liquidity the pool has
    available_liquidity: uint256 = staticcall BORROW_TOKEN.balanceOf(POOL.address)

    # If there's not enough liquidity, redeem the difference. Otherwise just transfer the full amount
    if debt_amount > available_liquidity:
        # Redeem the difference
        self._redeem(debt_amount - available_liquidity, owner)

        # Transfer whatever is left in the pool
        if available_liquidity > 0:
            extcall BORROW_TOKEN.transferFrom(POOL.address, owner, available_liquidity, default_return_value=True)
    else:
        # Transfer the full amount
        extcall BORROW_TOKEN.transferFrom(POOL.address, owner, debt_amount, default_return_value=True)

    return trove_id


# ============================================================================================
# redeem
# ============================================================================================


@external
def redeem(amount: uint256, max_iterations: uint256):
    """
    """
    # Make sure the caller is the lender
    assert msg.sender == LENDER, "!lender"

    # Redeem collateral equal to `amount` of debt and transfer the borrow tokens to the pool
    self._redeem(amount)


@internal
def _redeem(amount: uint256, receiver: address = POOL.address):
    """
    """
    # Mint the aggregate interest so that the total recorded debt is up to date
    total_debt: uint256 = extcall POOL.mint_agg_interest()

    # Make sure we're not trying to redeem more than the total debt
    assert amount <= total_debt, "total_debt"

    # Get collateral price
    collateral_price: uint256 = staticcall EXCHANGE.price()

    # Get the trove with the smallest annual interest rate
    trove_to_redeem: uint256 = staticcall SORTED_TROVES.last()

    # Cache the amount of debt we need to free
    remaining_debt_to_free: uint256 = amount

    # Cache the total changes we're making so that later we can update the aggregate accounting
    total_debt_decrease: uint256 = 0
    total_collateral_decrease: uint256 = 0
    total_new_weighted_recorded_debt: uint256 = 0
    total_old_weighted_recorded_debt: uint256 = 0

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

        # Calculate the Trove's old and new weighted recorded debt
        trove_old_weighted_recorded_debt: uint256 = trove_debt_before_interest * trove.annual_interest_rate
        trove_new_weighted_recorded_debt: uint256 = trove_new_debt * trove.annual_interest_rate

        # Update the Trove's information
        trove.debt = trove_new_debt
        trove.collateral = trove_new_collateral
        trove.last_debt_update_time = convert(block.timestamp, uint64)

        # Increment the total debt and collateral decrease
        total_debt_decrease += debt_to_free
        total_collateral_decrease += collateral_to_redeem

        # Increment the total new and old weighted recorded debt
        total_new_weighted_recorded_debt += trove_new_weighted_recorded_debt
        total_old_weighted_recorded_debt += trove_old_weighted_recorded_debt

        # Update the remaining debt to free
        remaining_debt_to_free -= debt_to_free

        # Check if we freed all the debt we wanted
        if remaining_debt_to_free == 0:
            break

        # Get the next Trove to redeem
        trove_to_redeem = staticcall SORTED_TROVES.prev(trove_to_redeem)

    # Update global accounting
    extcall POOL.mint_agg_interest_and_account_for_trove_change(
        0, # debt_increase
        total_debt_decrease, # debt_decrease
        total_old_weighted_recorded_debt, # old_weighted_recorded_debt
        total_new_weighted_recorded_debt, # new_weighted_recorded_debt
    )

    collateral_to_swap: uint256 = total_collateral_decrease
    collateral_balance: uint256 = staticcall POOL.balance_of_collateral()

    # Make sure we don't try to redeem more collateral than we can
    assert collateral_to_swap <= collateral_balance, "rekt"  # This should never happen

    # Swap the collateral to borrow token and transfer it to the receiver
    extcall EXCHANGE.swap(collateral_to_swap, receiver)


# ============================================================================================
# Internal pure functions
# ============================================================================================


@internal
@pure
def _collateral_ratio(collateral: uint256, debt: uint256, collateral_price: uint256) -> uint256:
    """
    """
    if debt > 0:
        return collateral * collateral_price // debt
    else:
        # Represents "infinite" CR
        return max_value(uint256)


@internal
@pure
def _calculate_interest(weighted_debt: uint256, period: uint256) -> uint256:
    return weighted_debt * period // _ONE_YEAR // _WAD


# ============================================================================================
# Internal view functions
# ============================================================================================


# ============================================================================================
# Internal mutative functions
# ============================================================================================