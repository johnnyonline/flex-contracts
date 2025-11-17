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
# Events
# ============================================================================================


# event RouteAdded:
#     index: indexed(uint256)
#     route: indexed(address)


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


# # Next route index
# route_index: public(uint256)

# # Route index --> Route
# routes: public(HashMap[uint256, IExchangeRoute])


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


# @external
# def add_route(route: address):
#     """
#     @notice Adds a new exchange route
#     @dev Only callable by the current `owner`
#     @param route Address of the route to add
#     """
#     # Make sure the caller is the current owner
#     assert msg.sender == ownable.owner, "!owner"

#     # Cache the current route index
#     index: uint256 = self.route_index

#     # Add the route
#     self.routes[index] = IExchangeRoute(route)

#     # Increment the route index
#     self.route_index = index + 1

#     # Emit event
#     log RouteAdded(
#         index=index,
#         route=route
#     )


# ============================================================================================
# Mutative functions
# ============================================================================================

# @todo -- here -- add dutch
@external
def notify(collateral_amount: uint256, debt_amount: uint256, liquidator: address):
    """
    @notice Notify the liquidation handler of a liquidation
    @dev Only callable by the `trove_manager` contract
    @dev `trove_manager` already transferred the collateral tokens before calling this function
    @param collateral_amount Amount of collateral tokens to sell
    @param debt_amount Minimum amount of debt tokens to buy
    @param liquidator Address that initiated the liquidation
    """
    # Make sure the caller is the trove manager
    assert msg.sender == TROVE_MANAGER, "!trove_manager"

    # Pull the borrow tokens from caller and transfer them to the lender
    extcall BORROW_TOKEN.transferFrom(liquidator, LENDER, debt_amount, default_return_value=True)

    # Transfer the collateral tokens to caller
    extcall COLLATERAL_TOKEN.transfer(liquidator, collateral_amount, default_return_value=True)