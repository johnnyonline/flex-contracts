# @version 0.4.3

"""
@title Debt In Front Helper
@license MIT
@author Flex
@notice Helper contract used by the frontend to calculate debt-in-front
"""

from interfaces import ITroveManager
from interfaces import ISortedTroves


# ============================================================================================
# Constants
# ============================================================================================


_MAX_ITERATIONS: constant(uint256) = 10_000


# ============================================================================================
# Storage
# ============================================================================================


TROVE_MANAGER: public(immutable(ITroveManager))
SORTED_TROVES: public(immutable(ISortedTroves))


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(trove_manager: address, sorted_troves: address):
    """
    @notice Initialize the contract
    @param trove_manager Address of the Trove Manager contract
    @param sorted_troves Address of the Sorted Troves contract
    """
    TROVE_MANAGER = ITroveManager(trove_manager)
    SORTED_TROVES = ISortedTroves(sorted_troves)


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def get_debt_in_front(
    interest_rate_low: uint256,
    interest_rate_high: uint256,
    stop_at_trove_id: uint256 = 0,
    hint_prev_id: uint256 = 0,
    hint_next_id: uint256 = 0,
) -> uint256:
    """
    @notice Get the total debt of all troves between two interest rates
    @dev Use case 1 - Find debt in front of an existing trove:
         Call with `interest_rate_low = 0`, `interest_rate_high = trove's rate`,
         and `stop_at_trove_id = trove's ID`.
         This returns the debt of all troves with rates lower than the trove's rate (redeemed before it)
    @dev Use case 2 - Preview debt in front for a new interest rate:
         Call with `interest_rate_low = 0`, `interest_rate_high = desired rate`,
         and `stop_at_trove_id = 0`. This returns the total debt of all troves with rates < the desired rate
    @param interest_rate_low Lower bound interest rate
    @param interest_rate_high Upper bound interest rate
    @param stop_at_trove_id Trove ID to stop at (excluded from calculation). Pass 0 to not stop early
    @param hint_prev_id Hint for finding the insert position (prev_id)
    @param hint_next_id Hint for finding the insert position (next_id)
    @return debt Total debt of all troves in the range
    """
    # Find insert position for the lower interest rate
    prev_id: uint256 = 0
    next_id: uint256 = 0
    prev_id, next_id = staticcall SORTED_TROVES.find_insert_position(interest_rate_low, hint_prev_id, hint_next_id)

    debt: uint256 = 0

    for _: uint256 in range(_MAX_ITERATIONS):
        if prev_id == 0:
            break

        # Stop if we hit the specified trove
        if prev_id == stop_at_trove_id:
            break

        trove: ITroveManager.Trove = staticcall TROVE_MANAGER.troves(prev_id)

        if trove.annual_interest_rate >= interest_rate_high:
            break

        debt += staticcall TROVE_MANAGER.get_trove_debt_after_interest(prev_id)

        prev_id = staticcall SORTED_TROVES.prev(prev_id)

    return debt