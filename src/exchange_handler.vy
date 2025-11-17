# @version 0.4.1

"""
@title Exchange Handler
@license MIT
@author Flex
@notice Handles swapping from collateral tokens to borrow tokens via registered exchange routes
"""

from ethereum.ercs import IERC20

from periphery.interfaces import IExchangeRoute

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


event RouteAdded:
    index: indexed(uint256)
    route: indexed(address)


# ============================================================================================
# Constants
# ============================================================================================


BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))


# ============================================================================================
# Storage
# ============================================================================================


# Next route index
route_index: public(uint256)

# Route index --> Route
routes: public(HashMap[uint256, IExchangeRoute])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(owner: address, borrow_token: address, collateral_token: address):
    ownable.__init__(owner)

    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)


# ============================================================================================
# Owner functions
# ============================================================================================


@external
def add_route(route: address):
    """
    @notice Adds a new exchange route
    @dev Only callable by the current `owner`
    @param route Address of the route to add
    """
    # Make sure the caller is the current owner
    assert msg.sender == ownable.owner, "!owner"

    # Cache the current route index
    index: uint256 = self.route_index

    # Add the route
    self.routes[index] = IExchangeRoute(route)

    # Increment the route index
    self.route_index = index + 1

    # Emit event
    log RouteAdded(
        index=index,
        route=route
    )


# ============================================================================================
# Mutative functions
# ============================================================================================


@external
def swap(amount: uint256, route_index: uint256 = 0, receiver: address = msg.sender) -> uint256:
    """
    @notice Swap from collateral token to borrow token
    @dev Caller should add slippage protection
    @param amount Amount of collateral tokens to swap
    @param route_index Index of the exchange route to use. Defaults to 0
    @param receiver Address to receive the borrow tokens. Defaults to caller
    @return Amount of borrow tokens received
    """
    # Do nothing on zero amount
    if amount == 0:
        return 0

    # Cache the route
    route: IExchangeRoute = self.routes[route_index]

    # Make sure the route exists
    assert route.address != empty(address), "!route"

    # Pull collateral token from the caller to the route contract
    extcall COLLATERAL_TOKEN.transferFrom(msg.sender, route.address, amount, default_return_value=True)

    # Execute the swap via the route and transfer output tokens directly to the receiver
    amount_out: uint256 = extcall route.execute(amount, receiver)

    return amount_out