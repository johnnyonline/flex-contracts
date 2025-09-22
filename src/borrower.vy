# @version 0.4.1
# @todo -- instead of the whole zombie thing. redeem a borrower completely if a redemption would bring them below some threshold
"""
@title Sorted Troves
@license MIT
@author Flex Protocol
@notice
"""

from ethereum.ercs import IERC20

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


POOL: public(immutable(IPool))
SORTED_TROVES: public(immutable(ISortedTroves))

BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

WAD: constant(uint256) = 10 ** 18
ONE_PCT: constant(uint256) = WAD // 100
ONE_YEAR: constant(uint256) = 365 * 60 * 60 * 24

MIN_DEBT: public(constant(uint256)) = 1000 * 10 ** 18
MIN_ANNUAL_INTEREST_RATE: public(constant(uint256)) = ONE_PCT // 2  # 0.5%
MAX_ANNUAL_INTEREST_RATE: public(constant(uint256)) = 250 * ONE_PCT  # 250%
MINIMUM_COLLATERAL_RATIO: public(constant(uint256)) = 110 * ONE_PCT  # 110% // @todo -- make this configurable


# ============================================================================================
# Storage
# ============================================================================================


troves: public(HashMap[uint256, Trove])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    pool: address,
    sorted_troves: address,
    borrow_token: address,
    collateral_token: address
):
    POOL = IPool(pool)
    SORTED_TROVES = ISortedTroves(sorted_troves)
    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)

# @external
# def set_lender(lender: address):
#     self.LENDER = lender

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
    # Make sure enough debt is being borrowed
    assert debt_amount >= MIN_DEBT, "debt too low"

    # Make sure the annual interest rate is within bounds    
    assert annual_interest_rate >= MIN_ANNUAL_INTEREST_RATE, "rate too low"
    assert annual_interest_rate <= MAX_ANNUAL_INTEREST_RATE, "rate too high"

    # Generate trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(msg.sender, owner, owner_index)), uint256)

    # Make sure the trove doesn't already exist
    assert self.troves[trove_id].status == Status.nonExistent, "trove exists"

    # Calculate the collateral ratio
    trove_collateral_ratio: uint256 = self._collateral_ratio(collateral_amount, debt_amount, self._collateral_price())

    # Make sure the collateral ratio is above the minimum collateral ratio
    assert trove_collateral_ratio >= MINIMUM_COLLATERAL_RATIO, "!MCR"

    # Calculate the upfront fee using the average interest rate of all troves
    avg_interest_rate: uint256 = staticcall POOL.approx_avg_interest_rate()
    upfront_fee: uint256 = debt_amount * avg_interest_rate // ONE_YEAR

    # Make sure the user is ok with the upfront fee
    assert upfront_fee <= max_upfront_fee, "!max_upfront_fee"

    # Store the trove information
    self.troves[trove_id] = Trove(
        status=Status.active,
        debt=debt_amount,
        collateral=collateral_amount,
        annual_interest_rate=annual_interest_rate,
        last_debt_update_time=convert(block.timestamp, uint64),
        last_interest_rate_adj_time=convert(block.timestamp, uint64)
    )

    # Update pool accounting
    extcall POOL.mint_agg_interest_and_account_for_trove_change(
        debt_amount, # debt_increase
        0, # debt_decrease
        0, # old_weighted_recorded_debt
        debt_amount * annual_interest_rate, # new_weighted_recorded_debt
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
        # self._redeem(debt_amount - available_liquidity, 50, owner)

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
    redeem collateral for borrow tokens. sells enough collateral to satisfy for `amount` of borrowed tokens (minus slippage/swap fees)
    """
    # Require the caller is the lender strat
    # _require_caller_is_lender();

    # self._redeem(amount, max_iterations, self.LENDER)
    pass


def _redeem(amount: uint256, max_iterations: uint256, receiver: address):
    pass
    # # cant redeem more than debt
    # if amount > staticcall ACTIVE_POOL.agg_recorded_debt():
    #     raise "redeem: amount > total debt"

    # # Get collateral price
    # collateral_price: uint256 = self._get_collateral_price()

    # # Get the trove ID of the trove with the smallest annual interest rate
    # trove_to_redeem: uint256 = staticcall SORTED_TROVES.getLast()

    # # Cache the amount of debt we need to redeem
    # remaining_debt_to_redeem: uint256 = amount

    # # Cache the total changes we're making so that later we can update the aggregate accounting
    # total_debt_decrease: uint256 = 0
    # total_collateral_decrease: uint256 = 0
    # total_new_weighted_recorded_debt: uint256 = 0
    # total_old_weighted_recorded_debt: uint256 = 0

    # # Loop through as many Troves as we're allowed to, or until we redeem all the debt we wanted
    # for _: uint256 in range(max_iterations, bound = 50):
    #     print("iteration: _", _, hardhat_compat=True)

    #     # Get the Trove we're redeeming
    #     trove: Trove = self.troves[trove_to_redeem]

    #     # Accrue interest on the Trove's debt
    #     trove_debt_before_interest: uint256 = trove.debt
    #     trove_debt_after_interest: uint256 = trove_debt_before_interest + self._calculate_interest(
    #         trove.debt * trove.annual_interest_rate,  # trove_weighted_debt
    #         block.timestamp - convert(trove.last_debt_update_time, uint256)  # period since last update
    #     )

    #     # Determine the remaining amount to be redeemed, capped by the entire debt of the Trove
    #     debt_to_redeem: uint256 = min(remaining_debt_to_redeem, trove_debt_after_interest)

    #     # Get the amount of collateral equal to `debt_to_redeem`
    #     collateral_to_redeem: uint256 = debt_to_redeem * WAD // collateral_price

    #     # Decrease the debt and collateral of the current Trove according to the amounts redeemed
    #     trove_new_debt: uint256 = trove_debt_after_interest - debt_to_redeem
    #     trove_new_collateral: uint256 = trove.collateral - collateral_to_redeem

    #     # Calculate what we need to add and subtract from the weighted debt sum
    #     trove_old_weighted_recorded_debt: uint256 = trove_debt_before_interest * trove.annual_interest_rate
    #     trove_new_weighted_recorded_debt: uint256 = trove_new_debt * trove.annual_interest_rate

    #     # Update the Trove's debt, collateral, and last debt update time
    #     trove.debt = trove_new_debt
    #     trove.collateral = trove_new_collateral
    #     trove.last_debt_update_time = convert(block.timestamp, uint64)

    #     # Increment the total debt and collateral decrease
    #     total_debt_decrease += debt_to_redeem
    #     total_collateral_decrease += collateral_to_redeem

    #     # Increment the total new and old weighted recorded debt
    #     total_new_weighted_recorded_debt += trove_new_weighted_recorded_debt
    #     total_old_weighted_recorded_debt += trove_old_weighted_recorded_debt

    #     # Update the remaining debt to redeem
    #     remaining_debt_to_redeem -= debt_to_redeem

    #     # Check if we redeemed all the debt we wanted
    #     if remaining_debt_to_redeem == 0:
    #         break

    #     # Get the next Trove to redeem
    #     trove_to_redeem = staticcall SORTED_TROVES.getPrev(trove_to_redeem)

    # # Update global accounting
    # extcall ACTIVE_POOL.mint_agg_interest_and_account_for_trove_change(
    #     0, # debt_increase
    #     total_debt_decrease, # debt_decrease
    #     total_old_weighted_recorded_debt, # old_weighted_recorded_debt
    #     total_new_weighted_recorded_debt, # new_weighted_recorded_debt
    # )

    # # Make sure we don't try to redeem more than we can
    # collateral_to_swap: uint256 = total_collateral_decrease
    # collateral_balance: uint256 = staticcall COLLATERAL_TOKEN.balanceOf(self)
    # if collateral_to_swap > collateral_balance:
    #     raise "this should def never happen"  # probably a bug?
    #     # collateral_to_swap = collateral_balance  # but ... we do what we can?

    # # Swap the collateral for the borrow token and transfer it to the lender
    # self._swap(collateral_to_swap, receiver)

# ============================================================================================
# helpers
# ============================================================================================


def _collateral_price() -> uint256:
    return 0
    # return staticcall TRICRV.price_oracle(0)  # WETH price in crvUSD


def _swap(amount: uint256, receiver: address):
    pass
    # extcall COLLATERAL_TOKEN.approve(TRICRV.address, amount, default_return_value=True)

    # # DUMPIT
    # extcall TRICRV.exchange(
    #     1,  # WETH
    #     0,  # crvUSD
    #     amount,
    #     0,  # min_dy
    #     False,  # use_eth
    #     receiver  # receiver
    # )

# @todo -- what about borrow token price?
def _collateral_ratio(collateral: uint256, debt: uint256, collateral_price: uint256) -> uint256:
    """
    """
    if debt > 0:
        return collateral * collateral_price // debt
    else:
        # Represents "infinite" CR
        return max_value(uint256)


def _calculate_interest(weighted_debt: uint256, period: uint256) -> uint256:
    return weighted_debt * period // ONE_YEAR // WAD