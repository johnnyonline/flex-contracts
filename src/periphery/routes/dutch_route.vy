# @version 0.4.1

"""
@title Exchange Route using Yearn Dutch Auctions
@license MIT
@author Flex
@notice Can dump anything
"""

from ethereum.ercs import IERC20

from .. import ownable_2step as ownable

from ...interfaces import IAuction
from ...interfaces import IPriceOracle

from ..interfaces import IAuctionFactory
from ..interfaces import IExchangeRoute


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
# Interfaces
# ============================================================================================


implements: IExchangeRoute


# ============================================================================================
# Constants
# ============================================================================================


EXCHANGE_HANDLER: public(immutable(address))

PRICE_ORACLE: public(immutable(IPriceOracle))
AUCTION_FACTORY: public(immutable(IAuctionFactory))

BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

DUST_THRESHOLD: public(immutable(uint256))
MAX_AUCTION_AMOUNT: public(immutable(uint256))
MIN_AUCTION_AMOUNT: public(immutable(uint256))

STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 15 * 10 ** 16  # 15%
EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 100 * 10 ** 16  # 100%
MINIMUM_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD - 5 * 10 ** 16  # 5%
MAX_GAS_PRICE_TO_TRIGGER: public(constant(uint256)) = 50 * 10 ** 9  # 50 gwei
MAX_AUCTIONS: public(constant(uint256)) = 20

_WAD: constant(uint256) = 10 ** 18


# ============================================================================================
# Storage
# ============================================================================================


# Address of the keeper
keeper: public(address)

# List of auctions
auctions: public(DynArray[IAuction, MAX_AUCTIONS])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    owner: address,
    exchange_handler: address,
    price_oracle: address,
    auction_factory: address,
    borrow_token: address,
    collateral_token: address,
    dust_threshold: uint256,
    max_auction_amount: uint256,
    min_auction_amount: uint256,
):
    """
    @notice Initialize the contract
    @param owner Address of the initial owner
    @param exchange_handler Address of the exchange handler contract
    @param price_oracle Address of the price oracle contract
    @param auction_factory Address of the auction factory contract
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    @param dust_threshold Minimum amount of kickable collateral to trigger an auction
    @param max_auction_amount Maximum amount of collateral to auction at once
    @param min_auction_amount Minimum amount of collateral that is needed to kick an auction
    """
    ownable.__init__(owner)

    EXCHANGE_HANDLER = exchange_handler

    PRICE_ORACLE = IPriceOracle(price_oracle)
    AUCTION_FACTORY = IAuctionFactory(auction_factory)

    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)

    DUST_THRESHOLD = dust_threshold
    MAX_AUCTION_AMOUNT = max_auction_amount
    MIN_AUCTION_AMOUNT = min_auction_amount


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def kick_trigger() -> DynArray[IAuction, MAX_AUCTIONS]:
    """
    @notice Loops through all auctions to see if any needs to be kicked
    @dev This is a view function for external systems
    @dev Need to manually kick if auction stopped as a result of price being too low
    @return List of auctions that needs to be kicked
    """
    # List of auctions to kick
    auctions_to_kick: DynArray[IAuction, MAX_AUCTIONS] = []

    # If gas price too high, return empty list
    if block.basefee > MAX_GAS_PRICE_TO_TRIGGER:
        return auctions_to_kick

    # Loop through auctions
    for auction: IAuction in self.auctions:
        # Check if there's enough to kick
        is_kickable: bool = staticcall auction.kickable(COLLATERAL_TOKEN.address) > DUST_THRESHOLD

        # If kickable, add to the list
        if is_kickable:
            auctions_to_kick.append(auction)

    return auctions_to_kick


# ============================================================================================
# Keeper functions
# ============================================================================================


@external
def kick(auctions: DynArray[IAuction, MAX_AUCTIONS]):
    """
    @notice Kicks the provided auctions
    @dev Only callable by the keeper
    @dev Uses a higher starting price buffer percentage to allow for takers to re-group
    @dev Does not set the receiver nor transfer collateral as those are already ready in the auction
    @param auctions List of auctions to kick
    """
    # Make sure the caller is the keeper
    assert msg.sender == self.keeper, "!keeper"

    # Loop through provided auctions and kick them
    for auction: IAuction in auctions:
        self._kick(auction, EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE)


# ============================================================================================
# Owner functions
# ============================================================================================


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
def execute(amount: uint256, receiver: address) -> uint256:
    """
    @notice Execute the swap from collateral token to borrow token
    @dev Only callable by the `exchange_handler` contract
    @dev Caller should transfer `amount` of collateral tokens to this contract before calling
    @dev Kicks an auction with up to `MAX_AUCTION_AMOUNT` of collateral tokens
    @dev Can't kick less than `MIN_AUCTION_AMOUNT` of collateral tokens
    @param amount Amount of collateral tokens to swap
    @param receiver Address to receive the borrow tokens
    @return Amount Always `0` as the swap is not atomic
    """
    # Make sure caller is the exchange handler
    assert msg.sender == EXCHANGE_HANDLER, "!exchange_handler"

    # Make sure `amount` is not too high
    assert amount <= MAX_AUCTION_AMOUNT, "!max_auction_amount"

    # Make sure `amount` is not too low
    assert amount >= MIN_AUCTION_AMOUNT, "!min_auction_amount"

    # Get an available auction
    auction: IAuction = self._get_available_auction()

    # Kick the auction
    self._kick(auction, STARTING_PRICE_BUFFER_PERCENTAGE, amount, receiver)

    # Always return 0 as the swap is not atomic
    return 0


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def _kick(
    auction: IAuction,
    starting_price_buffer_pct: uint256,
    amount: uint256 = 0,
    receiver: address = empty(address),
):
    """
    @notice Kicks off an auction with starting and minimum prices
    @dev Proceeds are sent from the auction contract directly to the `receiver`
    @param amount Amount of collateral tokens to swap
    @param starting_price_buffer_pct Buffer percentage to apply to the collateral price for the starting price
    @param receiver Address to receive the borrow tokens
    @param auction Auction contract to use
    """
    # Check if there's an active auction
    is_active_auction: bool = staticcall auction.isActive(COLLATERAL_TOKEN.address)

    # If there's an active auction, sweep if needed, and settle
    if is_active_auction:
        # Check if we have anything to sweep
        to_sweep: uint256 = staticcall auction.available(COLLATERAL_TOKEN.address)

        # Sweep if needed
        if to_sweep > 0:
            extcall auction.sweep(COLLATERAL_TOKEN.address)

        # Settle
        extcall auction.settle(COLLATERAL_TOKEN.address)

    # Get collateral balance in the auction contract
    collateral_balance_auction: uint256 = staticcall COLLATERAL_TOKEN.balanceOf(auction.address)

    # Total collateral we have to auction
    available: uint256 = collateral_balance_auction + amount

    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Set the starting price with buffer to the collateral price
    # Starting price is an unscaled "lot size"
    extcall auction.setStartingPrice(available * collateral_price // _WAD * starting_price_buffer_pct // _WAD // _WAD)

    # Set the minimum price with buffer to the collateral price
    # Minimum price is per token and is scaled to 1e18
    extcall auction.setMinimumPrice(collateral_price * MINIMUM_PRICE_BUFFER_PERCENTAGE // _WAD)

    # Set the receiver of auction proceeds if needed
    if receiver != empty(address):
        extcall auction.setReceiver(receiver)

    # Transfer collateral to the auction contract if needed
    if amount > 0:
        extcall COLLATERAL_TOKEN.transfer(auction.address, amount, default_return_value=True)

    # Kick the auction
    extcall auction.kick(COLLATERAL_TOKEN.address)


@internal
def _get_available_auction() -> IAuction:
    """
    @notice Get an available auction or create a new one
    @dev An available auction is one that is not active _and_ has no kickable collateral
         An auction could be inactive but with kickable collateral if it was stopped due to "price too low"
         In that case, the inactive auction should be kicked again and so it's still used by someone
    @return An available auction
    """
    # Bring auctions into memory
    auctions: DynArray[IAuction, MAX_AUCTIONS] = self.auctions

    # Make sure we don't exceed max auctions
    assert len(auctions) < MAX_AUCTIONS, "max_auctions"

    # Check existing auctions first
    for auction: IAuction in auctions:
        # Check if there's an active auction
        # We consider an auction "active" if it tries to sell more than dust
        # NOTE: an auction could be partially taken and left with a small amount below dust
        is_active: bool = staticcall auction.available(COLLATERAL_TOKEN.address) > DUST_THRESHOLD

        # Skip if active
        if is_active:
            continue

        # Check if there's enough to kick
        is_kickable: bool = staticcall auction.kickable(COLLATERAL_TOKEN.address) > DUST_THRESHOLD

        # Skip if kickable
        if is_kickable:
            continue

        # Return if not active and not kickable
        return auction

    # Otherwise, create a new auction
    new_auction: IAuction = IAuction(extcall AUCTION_FACTORY.createNewAuction(
        BORROW_TOKEN.address,  # want
        self,  # receiver
        self,  # governance
        1_000_000,  # startingPrice
        keccak256(convert(len(auctions), bytes32))  # salt
    ))
    extcall new_auction.enable(COLLATERAL_TOKEN.address)

    # Add new auction to the list
    self.auctions.append(new_auction)

    return new_auction