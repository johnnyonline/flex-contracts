# @version 0.4.1

"""
@title Liquidation Handler
@license MIT
@author Flex
@notice Handles selling collateral tokens from liquidated troves and returning borrow tokens to the lender
"""

from ethereum.ercs import IERC20

import periphery.ownable_2step as ownable


# ============================================================================================
# Modules
# ============================================================================================


initializes: ownable
exports: (
    ownable.owner,
    ownable.pending_owner,
    ownable.transfer_ownership,
    ownable.accept_ownership,
)


# ============================================================================================
# Constants
# ============================================================================================


LENDER: public(immutable(address))
TROVE_MANAGER: public(immutable(address))

BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))


# ============================================================================================
# Storage
# ============================================================================================


# Whether to dutch auction the liquidated collateral or not
use_auction: public(bool)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    owner: address,
    lender: address,
    trove_manager: address,
    borrow_token: address,
    collateral_token: address
):
    ownable.__init__(owner)

    LENDER = lender
    TROVE_MANAGER = trove_manager

    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)


# ============================================================================================
# Owner functions
# ============================================================================================


@external
def toggle_use_auction():
    """
    @notice Toggles the `use_auction` flag
    @dev Only callable by the current `owner`
    """
    # Make sure the caller is the current owner
    assert msg.sender == ownable.owner, "!owner"

    # Flip the flag
    self.use_auction = not self.use_auction


# ============================================================================================
# External mutative functions
# ============================================================================================


@external
def process(collateral_amount: uint256, debt_amount: uint256, liquidator: address):
    """
    @notice Handles selling of collateral tokens from liquidated troves and returning borrow tokens to the lender
    @dev Only callable by the `trove_manager` contract
    @dev `trove_manager` already transferred the collateral tokens before calling this function
    @param collateral_amount Amount of collateral tokens to sell
    @param debt_amount Minimum amount of debt tokens to buy
    @param liquidator Address that initiated the liquidation
    """
    # Make sure the caller is the trove manager
    assert msg.sender == TROVE_MANAGER, "!trove_manager"

    if self.use_auction:
        self._dutch_process(collateral_amount, debt_amount, liquidator)
    else:
        self._swap_process(collateral_amount, debt_amount, liquidator)


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def _dutch_process(collateral_amount: uint256, debt_amount: uint256, liquidator: address):
    pass


@internal
def _swap_process(collateral_amount: uint256, debt_amount: uint256, liquidator: address):
    # Pull the borrow tokens from caller and transfer them to the lender
    extcall BORROW_TOKEN.transferFrom(liquidator, LENDER, debt_amount, default_return_value=True)

    # Transfer the collateral tokens to caller
    extcall COLLATERAL_TOKEN.transfer(liquidator, collateral_amount, default_return_value=True)