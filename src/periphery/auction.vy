# @version 0.4.3
# pragma nonreentrancy on

"""
@title Auction
@license MIT
@author Flex
@notice General use dutch auction contract for token sales.

        This contract is a Vyper rewrite of the following Auction.sol contract by Yearn:
        https://github.com/yearn/tokenized-strategy-periphery/blob/master/src/Auctions/Auction.sol
"""
# @todo -- make auction specific for flex, rename want/from to collateral/borrow
from ethereum.ercs import IERC20
from ethereum.ercs import IERC20Detailed

from interfaces import ITaker

# ============================================================================================
# Events
# ============================================================================================


event AuctionKicked:
    auction_id: indexed(uint256)
    amount_kicked: uint256

event AuctionTake:
    auction_id: indexed(uint256)
    amount_taken: uint256
    amount_left: uint256
    amount_paid: uint256
    taker: indexed(address)
    receiver: indexed(address)


# ============================================================================================
# Structs
# ============================================================================================


struct AuctionInfo:
    kicked_timestamp: uint256  # The timestamp the auction was kicked
    initial_amount: uint256  # The initial amount for the auction
    current_amount: uint256  # The current amount for the auction
    starting_price: uint256  # The amount to start the auction at, unscaled "lot size" in `want` token
    minimum_price: uint256  # The minimum price for the auction, scaled to 1e18
    receiver: address  # The address that will receive the auction proceeds


# ============================================================================================
# Constants
# ============================================================================================


# Only address that can kick auctions
PAPI: public(immutable(address))

# Info of the token being bought
WANT_TOKEN: public(immutable(IERC20))
WANT_SCALER: public(immutable(uint256))

# The auction being sold
FROM_TOKEN: public(immutable(IERC20))
FROM_SCALER: public(immutable(uint256))

# Auction parameters
STEP_DURATION: public(immutable(uint256))  # e.g., 60 for price change every minute
STEP_DECAY_RATE: public(immutable(uint256))  # e.g., 50 for 0.5% decrease per step

# Internal constants
_AUCTION_LENGTH: constant(uint256) = 86400  # 1 day
_MAX_CALLBACK_DATA_SIZE: constant(uint256) = 10**5
_WAD: constant(uint256) = 10 ** 18
_RAY: constant(uint256) = 10 ** 27


# ============================================================================================
# Storage
# ============================================================================================


# Mapping of auction id to auction info
_auctions: HashMap[uint256, AuctionInfo]


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(papi: address, want_token: address, from_token: address):
    """
    @notice Initialize the contract
    @param papi Address that is allowed to kick auctions
    @param want_token Address this auction is selling to
    @param from_token Address of the token being sold in the auction
    """
    # Make sure want is non-zero address
    assert want_token != empty(address), "!want_token"

    # Want cannot have more than 18 decimals
    want_decimals: uint256 = convert(staticcall IERC20Detailed(want_token).decimals(), uint256)
    assert want_decimals <= 18, "!want_decimals"

    # From token cannot have more than 18 decimals
    from_token_decimals: uint256 = convert(staticcall IERC20Detailed(from_token).decimals(), uint256)
    assert from_token_decimals <= 18, "!from_token_decimals"

    # Set papi address
    PAPI = papi

    # Set want token info
    WANT_TOKEN = IERC20(want_token)
    WANT_SCALER = _WAD // 10 ** want_decimals

    # Set from token address
    FROM_TOKEN = IERC20(from_token)
    FROM_SCALER = _WAD // 10 ** from_token_decimals

    # Set auction parameters
    # Default to 50bps every 60 seconds
    STEP_DURATION = 60
    STEP_DECAY_RATE = 50


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def available(auction_id: uint256) -> uint256:
    """
    @notice Get the amount that can be taken from an auction
    @param auction_id The identifier for the auction
    @return The amount that can be taken from an auction
    """
    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # If auction is not active, nothing is available
    if not self._is_active(auction):
        return 0
    
    # Otherwise return current amount
    return auction.current_amount


@external
@view
def kickable(auction_id: uint256) -> uint256:
    """
    @notice Get the amount that can be kicked from an auction
    @param auction_id The identifier for the auction
    @return The amount that can be kicked from the auction
    """
    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # If auction is still active, nothing is kickable
    if self._is_active(auction):
        return 0

    # Otherwise return current amount
    return auction.current_amount


@external
@view
def needed(
    auction_id: uint256,
    max_amount: uint256 = max_value(uint256),
    at_timestamp: uint256 = block.timestamp,
) -> uint256:
    """
    @notice Calculate the amount of want needed to buy `max_amount`
    @param auction_id The identifier for the auction
    @param max_amount The maximum amount to take
    @param at_timestamp The timestamp to calculate at
    @return The amount of want needed
    """
    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # Determine amount to take
    amount_to_take: uint256 = min(auction.current_amount, max_amount)

    # Return the needed amount
    return self._get_amount_needed(auction, amount_to_take, at_timestamp)


@external
@view
def price(auction_id: uint256, at_timestamp: uint256 = block.timestamp) -> uint256:
    """
    @notice Gets the price of the auction at `at_timestamp`
    @param auction_id The identifier for the auction
    @param at_timestamp The specific timestamp for calculating the price
    @return The price of the auction
    """
    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # Return the price
    return self._price(auction, at_timestamp)


@external
@view
def is_active(auction_id: uint256) -> bool:
    """
    @notice Check if the auction is active
    @param auction_id The identifier for the auction
    @return Whether the auction is active
    """
    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # Return true if auction is active, false otherwise
    return self._is_active(auction)


# ============================================================================================
# Storage read functions
# ============================================================================================


@external
@view
def kicked(auction_id: uint256) -> uint256:
    """
    @notice Get the kicked timestamp for the auction
    @param auction_id The identifier for the auction
    @return The kicked timestamp for the auction
    """
    return self._auctions[auction_id].kicked_timestamp


@external
@view
def initial_available(auction_id: uint256) -> uint256:
    """
    @notice Get the initial available amount for the auction
    @param auction_id The identifier for the auction
    @return The initial available amount for the auction
    """
    return self._auctions[auction_id].initial_amount


@external
@view
def current_available(auction_id: uint256) -> uint256:
    """
    @notice Get the current available amount for the auction
    @param auction_id The identifier for the auction
    @return The current available amount for the auction
    """
    return self._auctions[auction_id].current_amount


@external
@view
def starting_price(auction_id: uint256) -> uint256:
    """
    @notice Get the starting price for the auction
    @param auction_id The identifier for the auction
    @return The starting price for the auction
    """
    return self._auctions[auction_id].starting_price


@external
@view
def minimum_price(auction_id: uint256) -> uint256:
    """
    @notice Get the minimum price for the auction
    @param auction_id The identifier for the auction
    @return The minimum price for the auction
    """
    return self._auctions[auction_id].minimum_price


@external
@view
def receiver(auction_id: uint256) -> address:
    """
    @notice Get the receiver address for the auction
    @param auction_id The identifier for the auction
    @return The receiver address for the auction
    """
    return self._auctions[auction_id].receiver


# ============================================================================================
# Kick
# ============================================================================================


@external
def kick(
    auction_id: uint256,
    amount_to_kick: uint256,
    starting_price: uint256,
    minimum_price: uint256,
    receiver: address,
):
    """
    @notice Kicks off an auction
    @param auction_id The identifier for the auction
    @param amount_to_kick The amount to kick off in the auction
    @param starting_price The starting price for the auction (unscaled "lot size" in `want` token)
    @param minimum_price The minimum price for the auction (scaled to 1e18)
    @param receiver The address that will receive the auction proceeds
    """
    # Make sure caller is Papi
    assert msg.sender == PAPI, "!papi"

    # Make sure amount to kick is non-zero
    assert amount_to_kick != 0, "!amount_to_kick"

    # Make sure starting price is non-zero
    assert starting_price != 0, "!starting_price"

    # Make sure minimum price is non-zero
    assert minimum_price != 0, "!minimum_price"

    # Make sure receiver is non-zero address
    assert receiver != empty(address), "!receiver"

    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # Make sure auction is not already active
    assert not self._is_active(auction), "active"

    # Update storage
    self._auctions[auction_id] = AuctionInfo(
        kicked_timestamp=block.timestamp,
        initial_amount=amount_to_kick,
        current_amount=amount_to_kick,
        starting_price=starting_price,
        minimum_price=minimum_price,
        receiver=receiver,
    )

    # Pull in the tokens to be auctioned from Papi
    assert extcall FROM_TOKEN.transferFrom(PAPI, self, amount_to_kick, default_return_value=True)

    # Emit event
    log AuctionKicked(auction_id=auction_id, amount_kicked=amount_to_kick)

# # @todo
# @external
# def re_kick(
#     auction_id: uint256,
#     starting_price: uint256,
#     minimum_price: uint256,
# ):


# ============================================================================================
# External mutative functions
# ============================================================================================


@external
def take(
    auction_id: uint256,
    max_amount: uint256 = max_value(uint256),
    receiver: address = msg.sender,
    data: Bytes[_MAX_CALLBACK_DATA_SIZE] = empty(Bytes[_MAX_CALLBACK_DATA_SIZE]),
) -> uint256:
    """
    @notice Take the token being sold in a live auction
    @param auction_id The identifier for the auction
    @param max_amount The maximum amount to take
    @param receiver The address that will receive the token being sold
    @param data The data signify the callback should be used and send with it
    @return The amount taken
    """
    # Bring auction info into memory
    auction: AuctionInfo = self._auctions[auction_id]

    # Make sure auction is active
    assert self._is_active(auction), "!active"

    # Determine amount to take
    amount_to_take: uint256 = min(auction.current_amount, max_amount)

    # Get the needed amount of want token
    amount_needed: uint256 = self._get_amount_needed(auction, amount_to_take, block.timestamp)

    # Make sure needed is non-zero
    assert amount_needed != 0, "!needed"

    # Calculate how much will be left after this take
    amount_left: uint256 = auction.current_amount - amount_to_take

    # If entire amount is taken, end the auction, otherwise update available amount
    if amount_to_take == auction.current_amount:
        self._auctions[auction_id].kicked_timestamp = 0
    else:
        self._auctions[auction_id].current_amount = amount_left

    # Send token being sold to the take receiver
    assert extcall FROM_TOKEN.transfer(receiver, amount_to_take, default_return_value=True)

    # If the caller provided data, perform the callback
    if len(data) != 0:
        extcall ITaker(receiver).auctionTakeCallback(
            auction_id,
            msg.sender,
            amount_to_take,
            amount_needed,
            data,
        )

    # Pull the want token from the caller to the auction receiver
    assert extcall WANT_TOKEN.transferFrom(msg.sender, auction.receiver, amount_needed, default_return_value=True)

    # Emit event
    log AuctionTake(
        auction_id=auction_id,
        amount_taken=amount_to_take,
        amount_left=amount_left,
        amount_paid=amount_needed,
        taker=msg.sender,
        receiver=receiver,
    )

    # Return the amount taken
    return amount_to_take


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _is_active(auction: AuctionInfo) -> bool:
    """
    @notice Check if the auction is active
    @param auction The auction info
    @return Whether the auction is active
    """
    return self._price(auction, block.timestamp) > 0


@internal
@view
def _get_amount_needed(
    auction: AuctionInfo,
    amount_to_take: uint256,
    at_timestamp: uint256,
) -> uint256:
    """
    @notice Calculate the amount of want needed to buy `amount`
    @param auction The auction info
    @param amount_to_take The amount to take
    @param at_timestamp The timestamp to calculate at
    @return The amount of want needed
    """
    # Scale amount to take to WAD
    scaled_amount_to_take: uint256 = amount_to_take * FROM_SCALER

    # Calculate needed amount without scaling back to want yet
    # Price is always scaled to WAD
    amount_needed: uint256 = scaled_amount_to_take * self._price(auction, at_timestamp) // _WAD

    # Return `amount_needed` scaled back to want
    return amount_needed // WANT_SCALER


@internal
@view
def _price(auction: AuctionInfo, at_timestamp: uint256) -> uint256:
    """
    @notice Calculate the WAD scaled price based on auction parameters
    @param auction The auction info
    @param at_timestamp The specific timestamp for calculating the price
    @return The calculated price scaled to WAD
    """
    # Scale initial amount to WAD
    initial_amount: uint256 = auction.initial_amount * FROM_SCALER

    # Return early if no available amount
    if initial_amount == 0:
        return 0

    # Make sure `at_timestamp` is not before `kicked_timestamp`
    assert at_timestamp >= auction.kicked_timestamp, "!timestamp"

    # Time passed since auction was kicked
    seconds_elapsed: uint256 = at_timestamp - auction.kicked_timestamp

    # If auction duration has passed, price is `0`
    if seconds_elapsed > _AUCTION_LENGTH:
        return 0

    # Calculate the number of price steps that have passed
    steps: uint256 = seconds_elapsed // STEP_DURATION

    # Convert basis points to RAY multiplier (e.g., 50 bps = 0.995 * 1e27)
    # rayMultiplier = 1e27 - (basisPoints * 1e23)
    ray_multiplier: uint256 = _RAY - (STEP_DECAY_RATE * 10 ** 23)

    # Calculate the decay multiplier using the configurable decay rate per step
    decay_multiplier: uint256 = self._rpow(ray_multiplier, steps)

    # Calculate initial price per token
    initial_price: uint256 = self._wdiv(auction.starting_price * _WAD, initial_amount)

    # Apply the decay to get the current price
    current_price: uint256 = self._rmul(initial_price, decay_multiplier)

    # Return price `0` if below the minimum price
    if current_price < auction.minimum_price:
        return 0

    return current_price


# ============================================================================================
# Math functions
# ============================================================================================


@internal
@pure
def _wdiv(x: uint256, y: uint256) -> uint256:
    """
    @notice Divide two WAD numbers
    @param x The numerator
    @param y The denominator
    @return The result
    """
    return (x * _WAD + y // 2) // y


@internal
@pure
def _rmul(x: uint256, y: uint256) -> uint256:
    """
    @notice Multiply two numbers where one is in RAY
    @param x The first number
    @param y The second number (in RAY)
    @return The result
    """
    return (x * y + _RAY // 2) // _RAY


@internal
@pure
def _rpow(x: uint256, n: uint256) -> uint256:
    """
    @notice Raise x to the power of n (exponentiation by squaring) in RAY
    @param x The base (in RAY)
    @param n The exponent
    @return The result (in RAY)
    """
    if n == 0:
        return _RAY

    result: uint256 = _RAY
    base: uint256 = x

    for _: uint256 in range(256):
        if n == 0:
            break
        if n % 2 == 1:
            result = self._rmul(result, base)
        base = self._rmul(base, base)
        n = n // 2

    return result
