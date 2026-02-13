# @version 0.4.3
# pragma nonreentrancy on

"""
@title Auction
@license MIT
@author Flex
@notice Dutch Auctions for selling one token for another

        This contract is based off of the following Auction.sol contract by Yearn:
        https://github.com/yearn/tokenized-strategy-periphery/blob/master/src/Auctions/Auction.sol
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC20Detailed

from interfaces import ITaker

# ============================================================================================
# Events
# ============================================================================================


event AuctionKick:
    auction_id: indexed(uint256)
    kick_amount: uint256
    is_re_kick: indexed(bool)

event AuctionTake:
    auction_id: indexed(uint256)
    take_amount: uint256
    remaining_amount: uint256
    needed_amount: uint256
    taker: address
    receiver: address


# ============================================================================================
# Structs
# ============================================================================================


struct AuctionInfo:
    kick_timestamp: uint256
    initial_amount: uint256
    current_amount: uint256
    maximum_amount: uint256
    amount_received: uint256
    starting_price: uint256
    minimum_price: uint256
    receiver: address
    surplus_receiver: address
    is_liquidation: bool


struct InitializeParams:
    papi: address
    buy_token: address
    sell_token: address
    step_duration: uint256
    step_decay_rate: uint256
    auction_length: uint256


# ============================================================================================
# Constants
# ============================================================================================


_MAX_CALLBACK_DATA_SIZE: constant(uint256) = 10**5
_WAD: constant(uint256) = 10 ** 18
_RAY: constant(uint256) = 10 ** 27


# ============================================================================================
# Storage
# ============================================================================================


# Papi
papi: public(address)  # only address that can kick auctions (the Dutch Desk contract)

# Info of the token being bought
buy_token: public(IERC20)
buy_token_scaler: public(uint256)

# Info of the token being sold
sell_token: public(IERC20)
sell_token_scaler: public(uint256)

# Auction parameters
step_duration: public(uint256)
step_decay_rate: public(uint256)
auction_length: public(uint256)

# Accounting
liquidation_auctions: public(uint256)  # count of active liquidation auctions
auctions: public(HashMap[uint256, AuctionInfo])  # auction ID --> AuctionInfo


# ============================================================================================
# Initialize
# ============================================================================================


@external
def initialize(params: InitializeParams):
    """
    @notice Initialize the contract
    @param params Initialization parameters struct
    """
    # Make sure the contract is not already initialized
    assert self.papi == empty(address), "initialized"

    # Set papi address
    self.papi = params.papi

    # Get buy token decimals
    buy_token_decimals: uint256 = convert(staticcall IERC20Detailed(params.buy_token).decimals(), uint256)

    # Set buy token info
    self.buy_token = IERC20(params.buy_token)
    self.buy_token_scaler = _WAD // 10 ** buy_token_decimals

    # Get sell token decimals
    sell_token_decimals: uint256 = convert(staticcall IERC20Detailed(params.sell_token).decimals(), uint256)

    # Set sell token info
    self.sell_token = IERC20(params.sell_token)
    self.sell_token_scaler = _WAD // 10 ** sell_token_decimals

    # Set auction parameters
    self.step_duration = params.step_duration
    self.step_decay_rate = params.step_decay_rate
    self.auction_length = params.auction_length


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def get_available_amount(auction_id: uint256) -> uint256:
    """
    @notice Get the available amount that can be taken from an auction
    @param auction_id The identifier for the auction
    @return The available amount that can be taken from an auction
    """
    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # If auction is not active, nothing is available
    if not self._is_active(auction):
        return 0

    # Otherwise return current amount
    return auction.current_amount


@external
@view
def get_kickable_amount(auction_id: uint256) -> uint256:
    """
    @notice Get the amount that can be kicked from an auction
    @param auction_id The identifier for the auction
    @return The amount that can be kicked from the auction
    """
    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # If auction is still active, nothing is kickable
    if self._is_active(auction):
        return 0

    # Otherwise return current amount
    return auction.current_amount


@external
@view
def get_needed_amount(
    auction_id: uint256,
    max_take_amount: uint256 = max_value(uint256),
    at_timestamp: uint256 = block.timestamp,
) -> uint256:
    """
    @notice Get the amount of buy token needed to buy `max_take_amount` of sell token
    @dev Uses the minimum of `max_take_amount` and the current available amount
    @param auction_id The identifier for the auction
    @param max_take_amount The maximum amount to take
    @param at_timestamp The timestamp to calculate at. Defaults to current block timestamp
    @return The amount of buy token needed
    """
    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # Determine amount to take
    take_amount: uint256 = min(auction.current_amount, max_take_amount)

    # Return the needed amount
    return self._get_amount_needed(auction, take_amount, at_timestamp)


@external
@view
def get_price(auction_id: uint256, at_timestamp: uint256 = block.timestamp) -> uint256:
    """
    @notice Gets the price per token in an auction at `at_timestamp`
    @dev Always scaled to WAD
    @param auction_id The identifier for the auction
    @param at_timestamp The timestamp to calculate at. Defaults to current block timestamp
    @return The price per token in the auction in WAD
    """
    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # Return the price
    return self._get_price(auction, at_timestamp)


@external
@view
def is_active(auction_id: uint256) -> bool:
    """
    @notice Check if the auction is active
    @dev Does not check if there's any amount left in the auction
    @param auction_id The identifier for the auction
    @return Whether the auction is active
    """
    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # Return true if auction is active, false otherwise
    return self._is_active(auction)


@external
@view
def is_ongoing_liquidation_auction() -> bool:
    """
    @notice Check if there's at least one ongoing liquidation auction
    @return Whether there's at least one ongoing liquidation auction
    """
    return self.liquidation_auctions > 0


# ============================================================================================
# Kick
# ============================================================================================


@external
def kick(
    auction_id: uint256,
    kick_amount: uint256,
    maximum_amount: uint256,
    starting_price: uint256,
    minimum_price: uint256,
    receiver: address,
    surplus_receiver: address,
    is_liquidation: bool,
):
    """
    @notice Kick off an auction
    @dev Only callable by Papi
    @dev Caller must approve this contract to transfer sell tokens on its behalf before calling
    @param auction_id The identifier for the auction
    @param kick_amount The amount of sell token to kick the auction with
    @param maximum_amount The maximum amount of buy token to be received
    @param starting_price The starting price for the auction, WAD scaled "lot size" in buy token
    @param minimum_price The minimum price for the auction, WAD scaled in buy token
    @param receiver The address that will receive the auction proceeds
    @param surplus_receiver The address that will receive any surplus proceeds above maximum_amount
    @param is_liquidation Whether this auction is selling liquidated collateral
    """
    # Make sure caller is Papi
    assert msg.sender == self.papi, "!papi"

    # Make sure amount to kick is non-zero
    assert kick_amount != 0, "!kick_amount"

    # Make sure starting price is non-zero
    assert starting_price != 0, "!starting_price"

    # Make sure minimum price is non-zero
    assert minimum_price != 0, "!minimum_price"

    # Make sure receiver is non-zero address
    assert receiver != empty(address), "!receiver"

    # Make sure surplus receiver is non-zero address
    assert surplus_receiver != empty(address), "!surplus_receiver"

    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # Make sure auction is not already active
    assert not self._is_active(auction), "active"

    # If liquidation auction, increment counter
    if is_liquidation:
        self.liquidation_auctions += 1

    # Update storage
    self.auctions[auction_id] = AuctionInfo(
        kick_timestamp=block.timestamp,
        initial_amount=kick_amount,
        current_amount=kick_amount,
        maximum_amount=maximum_amount,
        amount_received=0,
        starting_price=starting_price,
        minimum_price=minimum_price,
        receiver=receiver,
        surplus_receiver=surplus_receiver,
        is_liquidation=is_liquidation,
    )

    # Pull the tokens from Papi
    assert extcall self.sell_token.transferFrom(self.papi, self, kick_amount, default_return_value=True)

    # Emit event
    log AuctionKick(auction_id=auction_id, kick_amount=kick_amount, is_re_kick=False)


@external
def re_kick(
    auction_id: uint256,
    starting_price: uint256,
    minimum_price: uint256,
):
    """
    @notice Re-kick an inactive auction with new starting and minimum prices
    @dev Only callable by Papi
    @dev An auction may need to be re-kicked if its price has fallen below its minimum price
    @param auction_id The identifier for the auction
    @param starting_price The new starting price for the auction, WAD scaled "lot size" in buy token
    @param minimum_price The new minimum price for the auction, WAD scaled in buy token
    """
    # Make sure caller is Papi
    assert msg.sender == self.papi, "!papi"

    # Make sure starting price is non-zero
    assert starting_price != 0, "!starting_price"

    # Make sure minimum price is non-zero
    assert minimum_price != 0, "!minimum_price"

    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # Make sure auction is not already active
    assert not self._is_active(auction), "active"

    # Make sure there's actually something to kick
    assert auction.current_amount != 0, "!current_amount"

    # Update kick timestamp, starting price, and minimum price
    auction.kick_timestamp = block.timestamp
    auction.starting_price = starting_price
    auction.minimum_price = minimum_price

    # Update storage
    self.auctions[auction_id] = auction

    # Emit event
    log AuctionKick(auction_id=auction_id, kick_amount=auction.current_amount, is_re_kick=True)


# ============================================================================================
# Take
# ============================================================================================


@external
def take(
    auction_id: uint256,
    max_take_amount: uint256 = max_value(uint256),
    receiver: address = msg.sender,
    data: Bytes[_MAX_CALLBACK_DATA_SIZE] = empty(Bytes[_MAX_CALLBACK_DATA_SIZE]),
) -> uint256:
    """
    @notice Take the token being sold in a live auction
    @dev Empty `data` will skip the callback
    @dev Uses the minimum of `max_take_amount` and the current available amount
    @dev Caller must approve this contract to transfer buy tokens on its behalf before calling
    @param auction_id The identifier for the auction
    @param max_take_amount The maximum amount to take. Defaults to max uint256
    @param receiver The address that will receive the token being sold. Defaults to msg.sender
    @param data The data to pass to the taker callback. Defaults to empty
    @return The amount taken
    """
    # Bring auction info into memory
    auction: AuctionInfo = self.auctions[auction_id]

    # Make sure auction is active
    assert self._is_active(auction), "!active"

    # Determine amount to take
    take_amount: uint256 = min(auction.current_amount, max_take_amount)

    # Get the needed amount of buy token to pay
    needed_amount: uint256 = self._get_amount_needed(auction, take_amount)

    # Make sure needed amount is not zero
    assert needed_amount != 0, "!needed_amount"

    # Calculate how much will be left after this take
    remaining_amount: uint256 = auction.current_amount - take_amount

    # Update auction's current amount
    auction.current_amount = remaining_amount

    # If entire amount is taken, end the auction
    if remaining_amount == 0:
        # Reset kick timestamp to mark auction as inactive
        auction.kick_timestamp = 0

        # If it was a liquidation auction, decrement counter
        if auction.is_liquidation:
            self.liquidation_auctions -= 1

    # Send the token being sold to the take receiver
    assert extcall self.sell_token.transfer(receiver, take_amount, default_return_value=True)

    # If the caller provided data, perform the callback
    if len(data) != 0:
        extcall ITaker(receiver).auctionTakeCallback(
            auction_id,
            msg.sender,
            take_amount,
            needed_amount,
            data,
        )
    
    # Cache the buy token contract
    buy_token: IERC20 = self.buy_token

    # If liquidation auction, all proceeds goes to the Lender contract.
    # Otherwise, make sure the receiver does not get more than the maximum and transfer the surplus to the surplus receiver
    if auction.is_liquidation:
        # Liquidation: all to the Lender contract
        assert extcall buy_token.transferFrom(msg.sender, auction.receiver, needed_amount, default_return_value=True)
    else:
        # How much the receiver still needs
        receiver_remaining: uint256 = auction.maximum_amount - auction.amount_received

        # If the bought amount is less than the receiver's maximum amount, transfer him all of it.
        # Otherwise, cover the receiver first, then transfer the surplus to the surplus receiver
        if needed_amount <= receiver_remaining:
            # Entire amount to the receiver
            auction.amount_received += needed_amount
            assert extcall buy_token.transferFrom(msg.sender, auction.receiver, needed_amount, default_return_value=True)
        else:
            # Cover the receiver first
            if receiver_remaining > 0:
                auction.amount_received = auction.maximum_amount
                assert extcall buy_token.transferFrom(msg.sender, auction.receiver, receiver_remaining, default_return_value=True)

            # Transfer the surplus to the Lender contract
            surplus: uint256 = needed_amount - receiver_remaining
            assert extcall buy_token.transferFrom(msg.sender, auction.surplus_receiver, surplus, default_return_value=True)

    # Update storage. No need to worry about re-entrancy since non-reentrant pragma is enabled
    self.auctions[auction_id] = auction

    # Emit event
    log AuctionTake(
        auction_id=auction_id,
        take_amount=take_amount,
        remaining_amount=remaining_amount,
        needed_amount=needed_amount,
        taker=msg.sender,
        receiver=receiver,
    )

    # Return the amount taken
    return take_amount


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_amount_needed(
    auction: AuctionInfo,
    take_amount: uint256,
    at_timestamp: uint256 = block.timestamp,
) -> uint256:
    """
    @notice Get the amount of buy token needed to buy `take_amount` of sell token
    @param auction The auction info
    @param take_amount The amount of sell token to take
    @param at_timestamp The timestamp to calculate at. Defaults to current block timestamp
    @return The amount of buy token needed
    """
    # Scale amount to take to WAD
    scaled_take_amount: uint256 = take_amount * self.sell_token_scaler

    # Calculate needed amount without scaling back to buy yet
    # Price is always scaled to WAD
    needed_amount: uint256 = scaled_take_amount * self._get_price(auction, at_timestamp) // _WAD

    # Return needed amount scaled back to buy
    return needed_amount // self.buy_token_scaler


@internal
@view
def _get_price(auction: AuctionInfo, at_timestamp: uint256 = block.timestamp) -> uint256:
    """
    @notice Calculate the WAD scaled price based on auction parameters
    @param auction The auction info
    @param at_timestamp The timestamp to calculate at. Defaults to current block timestamp
    @return The calculated price scaled to WAD
    """
    # Scale initial amount to WAD
    initial_amount: uint256 = auction.initial_amount * self.sell_token_scaler

    # Return early if no available amount
    if initial_amount == 0:
        return 0

    # Make sure `at_timestamp` is not before `kick_timestamp`
    assert at_timestamp >= auction.kick_timestamp, "!timestamp"

    # Time passed since auction was kicked
    seconds_elapsed: uint256 = at_timestamp - auction.kick_timestamp

    # If auction duration has passed, price is `0`
    if seconds_elapsed > self.auction_length:
        return 0

    # Calculate the number of price steps that have passed
    steps: uint256 = seconds_elapsed // self.step_duration

    # Convert basis points to RAY multiplier (e.g., 50 bps = 0.995 * 1e27)
    # rayMultiplier = 1e27 - (basisPoints * 1e23)
    ray_multiplier: uint256 = _RAY - (self.step_decay_rate * 10 ** 23)

    # Calculate the decay multiplier using the configurable decay rate per step
    decay_multiplier: uint256 = self._rpow(ray_multiplier, steps)

    # Calculate initial price per token
    initial_price: uint256 = self._wdiv(auction.starting_price, initial_amount)

    # Apply the decay to get the current price
    current_price: uint256 = self._rmul(initial_price, decay_multiplier)

    # Return price `0` if below the minimum price
    if current_price < auction.minimum_price:
        return 0

    return current_price


@internal
@view
def _is_active(auction: AuctionInfo) -> bool:
    """
    @notice Check if the auction is active
    @dev Does not check if there's any amount left in the auction
    @param auction The auction info
    @return Whether the auction is active
    """
    return self._get_price(auction) > 0


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
