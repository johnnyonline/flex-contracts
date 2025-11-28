# @version 0.4.1

"""
@title Liquidation Handler
@license MIT
@author Flex
@notice Handles selling collateral tokens from liquidated troves and returning borrow tokens to the lender
"""

from ethereum.ercs import IERC20

import periphery.ownable_2step as ownable

from interfaces import IPriceOracle
from interfaces import IAuction
from interfaces import IAuctionFactory


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

AUCTION: public(immutable(IAuction))
PRICE_ORACLE: public(immutable(IPriceOracle))
AUCTION_FACTORY: public(immutable(IAuctionFactory))

BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

DUST_THRESHOLD: public(immutable(uint256))
MAX_AUCTION_AMOUNT: public(immutable(uint256))

STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 15 * 10 ** 16  # 15%
EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 100 * 10 ** 16  # 100%
MINIMUM_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD - 5 * 10 ** 16  # 5%
MAX_GAS_PRICE_TO_TRIGGER: public(constant(uint256)) = 50 * 10 ** 9  # 50 gwei

_WAD: constant(uint256) = 10 ** 18


# ============================================================================================
# Storage
# ============================================================================================


# Indicates whether to auction collateral or swap it atomically
use_auction: public(bool)

# Address of the keeper
keeper: public(address)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    owner: address,
    lender: address,
    trove_manager: address,
    price_oracle: address,
    auction_factory: address,
    borrow_token: address,
    collateral_token: address,
    dust_threshold: uint256,
    max_auction_amount: uint256,
):
    """
    @notice Initialize the contract
    @param owner Address of the initial owner
    @param lender Address of the lender contract
    @param trove_manager Address of the trove manager contract
    @param price_oracle Address of the price oracle contract
    @param auction_factory Address of the auction factory contract
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    @param dust_threshold Minimum amount of kickable collateral to trigger an auction
    @param max_auction_amount Maximum amount of collateral to auction at once
    """
    ownable.__init__(owner)

    LENDER = lender
    TROVE_MANAGER = trove_manager

    PRICE_ORACLE = IPriceOracle(price_oracle)
    AUCTION_FACTORY = IAuctionFactory(auction_factory)

    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)

    DUST_THRESHOLD = dust_threshold
    MAX_AUCTION_AMOUNT = max_auction_amount

    AUCTION = IAuction(extcall AUCTION_FACTORY.createNewAuction(borrow_token))
    extcall AUCTION.enable(collateral_token)
    extcall AUCTION.setReceiver(lender)


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def kick_trigger() -> bool:
    """
    @notice Indicates whether we should call the `kick` function
    @dev This is a view function for external systems
    @dev Need to manually kick if auction stopped as a result of price being too low
    @return True if we should kick, false otherwise
    """
    # Trigger if basefee is fine and we have enough kickable collateral
    return block.basefee <= MAX_GAS_PRICE_TO_TRIGGER and staticcall AUCTION.kickable(COLLATERAL_TOKEN.address) > DUST_THRESHOLD


# ============================================================================================
# Keeper functions
# ============================================================================================


@external
def kick():
    """
    @notice Kicks off an auction with a starting price
    @dev Only callable by the keeper
    @dev Uses a higher starting price buffer percentage to allow for takers to re-group
    """
    # Make sure the caller is the keeper
    assert msg.sender == self.keeper, "!keeper"

    # Kick it
    self._kick(EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE)


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


@external
def set_keeper(new_keeper: address):
    """
    @notice Set the `keeper` variable
    @dev Only callable by the current `owner`
    @param new_keeper New keeper address
    """
    # Make sure the caller is the current owner
    assert msg.sender == ownable.owner, "!owner"

    # Set the new keeper
    self.keeper = new_keeper


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
        self._kick(STARTING_PRICE_BUFFER_PERCENTAGE)
    else:
        self._swap(collateral_amount, debt_amount, liquidator)


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def _kick(starting_price_buffer_pct: uint256):
    """
    @notice Kicks off an auction with starting and minimum prices
    @dev Proceeds are sent from the auction contract directly to the lender
    @param starting_price_buffer_pct Buffer percentage to apply to the collateral price for the starting price
    """
    # Check if there's an active auction
    is_active_auction: bool = staticcall AUCTION.isActive(COLLATERAL_TOKEN.address)

    # If there's an active auction, sweep if needed, and settle
    if is_active_auction:
        # Check if we have anything to sweep
        to_sweep: uint256 = staticcall AUCTION.available(COLLATERAL_TOKEN.address)

        # Sweep if needed
        if to_sweep > 0:
            extcall AUCTION.sweep(COLLATERAL_TOKEN.address)

        # Settle
        extcall AUCTION.settle(COLLATERAL_TOKEN.address)

    # Get collateral token balances
    collateral_balance_self: uint256 = staticcall COLLATERAL_TOKEN.balanceOf(self)
    collateral_balance_auction: uint256 = staticcall COLLATERAL_TOKEN.balanceOf(AUCTION.address)

    # Determine how much collateral we can kick
    to_auction: uint256 = min(collateral_balance_self, MAX_AUCTION_AMOUNT)

    # Total collateral we have to auction
    available: uint256 = collateral_balance_auction + to_auction

    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Set the starting price with buffer to the collateral price
    # Starting price is an unscaled "lot size"
    extcall AUCTION.setStartingPrice(available * collateral_price // _WAD * starting_price_buffer_pct // _WAD // _WAD)

    # Set the minimum price with buffer to the collateral price
    # Minimum price is per token and is scaled to 1e18
    extcall AUCTION.setMinimumPrice(collateral_price * MINIMUM_PRICE_BUFFER_PERCENTAGE // _WAD)

    # Transfer collateral to the auction contract
    extcall COLLATERAL_TOKEN.transfer(AUCTION.address, to_auction, default_return_value=True)

    # Kick the auction
    extcall AUCTION.kick(COLLATERAL_TOKEN.address)


@internal
def _swap(collateral_amount: uint256, debt_amount: uint256, liquidator: address):
    """
    @notice Swaps collateral tokens for borrow tokens and returns them to the lender
    @param collateral_amount Amount of collateral tokens to sell
    @param debt_amount Minimum amount of debt tokens to buy
    @param liquidator Address that initiated the liquidation
    """
    # Pull the borrow tokens from caller and transfer them to the lender
    extcall BORROW_TOKEN.transferFrom(liquidator, LENDER, debt_amount, default_return_value=True)

    # Transfer the collateral tokens to caller
    extcall COLLATERAL_TOKEN.transfer(liquidator, collateral_amount, default_return_value=True)