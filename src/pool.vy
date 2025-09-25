# # @version 0.4.1

# """
# @title Sorted Troves
# @license MIT
# @author Flex Protocol
# @notice todo
# """


# # ============================================================================================
# # Constants
# # ============================================================================================


# _WAD: constant(uint256) = 10 ** 18
# _ONE_YEAR: constant(uint256) = 365 * 60 * 60 * 24


# # ============================================================================================
# # Storage
# # ============================================================================================


# agg_recorded_debt: public(uint256)  # "D" in spec
# agg_weighted_debt_sum: public(uint256)  # "S" in spec
# last_agg_update_time: public(uint256)  # Last time at which the aggregate recorded debt and weighted sum were updated
# coll_balance: public(uint256)  # deposited coll tracker


# # ============================================================================================
# # View functions
# # ============================================================================================


# # ============================================================================================
# # Mutative functions
# # ============================================================================================


# @external
# def account_for_received_collateral(amount: uint256):
#     """
#     """
#     # self._require_caller_is_borrower_operations_or_default_pool()
#     coll_balance: uint256 = self.coll_balance + amount
#     self.coll_balance = coll_balance


# @external
# def mint_agg_interest_and_account_for_trove_change(
#     debt_increase: uint256,
#     debt_decrease: uint256,
#     old_weighted_recorded_debt: uint256,
#     new_weighted_recorded_debt: uint256
# ):
#     """
#     """
#     # self._require_caller_is_bo_or_trove_manager()

#     # Update aggregate recorded debt
#     new_agg_recorded_debt: uint256 = self.agg_recorded_debt
#     new_agg_recorded_debt += self._mint_agg_interest()
#     new_agg_recorded_debt += debt_increase
#     new_agg_recorded_debt -= debt_decrease
#     self.agg_recorded_debt = new_agg_recorded_debt

#     # Update aggregate weighted debt sum
#     new_agg_weighted_debt_sum: uint256 = self.agg_weighted_debt_sum
#     new_agg_weighted_debt_sum += new_weighted_recorded_debt
#     new_agg_weighted_debt_sum -= old_weighted_recorded_debt
#     self.agg_weighted_debt_sum = new_agg_weighted_debt_sum


# @external
# def mint_agg_interest() -> uint256:
#     """
#     """
#     # self._require_caller_is_lender_strat()
#     self.agg_recorded_debt += self._mint_agg_interest()
#     return self.agg_recorded_debt


# # ============================================================================================
# # Internal view functions
# # ============================================================================================


# # ============================================================================================
# # Internal mutative functions
# # ============================================================================================


# def _mint_agg_interest() -> uint256:
#     """
#     """
#     # Calculate pending aggregate interest
#     minted_amount: uint256 = self._calc_pending_agg_interest()
    
#     # Update last aggregate update time
#     self.last_agg_update_time = block.timestamp

#     return minted_amount


# def _calc_pending_agg_interest() -> uint256:
#     """
#     """
#     # @todo
#     # We use the ceiling of the division here to ensure positive error, while we use regular floor division
#     # when calculating the interest accrued by individual Troves.
#     # This ensures that `system debt >= sum(trove debt)` always holds, and thus system debt won't turn negative
#     # even if all Trove debt is repaid. The difference should be small and it should scale with the number of
#     # interest minting events.
#     return (self.agg_weighted_debt_sum * (block.timestamp - self.last_agg_update_time)) // (ONE_YEAR * WAD)