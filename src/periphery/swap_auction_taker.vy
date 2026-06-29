# @version 0.4.3

"""
@title Swap Auction Taker
@license GNU AGPLv3
@author Flex
@notice Takes auctions for markets where the collateral must be swapped (not redeemed) into the borrow token.
        Converts the collateral via a router (using the Swap Executor), can be topped up with funding that the
        caller sends in the same transaction
@dev Can be used as the `auction_taker` in the Leverage Zapper NG or called directly
"""

from ethereum.ercs import IERC20

from ..interfaces import IAuction
from ..interfaces import ISwapExecutor
from ..interfaces import IZapperAuctionTakerNG
from ..interfaces import ITaker

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IZapperAuctionTakerNG
implements: ITaker


# ============================================================================================
# Constants
# ============================================================================================


# Contracts
SWAP_EXECUTOR: public(immutable(ISwapExecutor))

# Max swap calldata size
_MAX_SWAP_DATA_SIZE: constant(uint256) = 10 ** 4

# Max callback data size
_MAX_CALLBACK_DATA_SIZE: constant(uint256) = 10 ** 5


# ============================================================================================
# Storage
# ============================================================================================


# Auction currently being taken. Transient guard to prevent the router calling `takeCallback`
_active_auction: transient(address)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(swap_executor: address):
    """
    @notice Initialize the contract
    @param swap_executor Address of the Swap Executor contract
    """
    SWAP_EXECUTOR = ISwapExecutor(swap_executor)


# ============================================================================================
# Auction Taker
# ============================================================================================


@external
def takeAuction(auction: address, auction_id: uint256, swap_router: address, swap_data: Bytes[_MAX_SWAP_DATA_SIZE]):
    """
    @notice Take an auction, swapping the collateral to pay
    @dev Any funding must be transferred before calling this, in the same transaction
    @param auction The auction contract address
    @param auction_id The auction ID to take
    @param swap_router The router used for the collateral token --> borrow token conversion
    @param swap_data The router calldata
    """
    # Make sure the active auction guard is clear
    assert self._active_auction == empty(address), "active_auction"

    # Read tokens before taking (can't read during callback due to reentrancy guard)
    buy_token: address = staticcall IAuction(auction).buy_token()
    sell_token: address = staticcall IAuction(auction).sell_token()

    # Activate the transient guard so the router cannot call `takeCallback`
    self._active_auction = auction

    # Take the full auction amount with callback
    extcall IAuction(auction).take(
        auction_id, max_value(uint256), self, abi_encode(buy_token, sell_token, swap_router, swap_data)
    )

    # Clear the transient guard
    self._active_auction = empty(address)

    # Reset any residual approval, just in case
    assert extcall IERC20(buy_token).approve(auction, 0, default_return_value=True)

    # Transfer any leftover buy tokens to the caller
    buy_token_leftover: uint256 = staticcall IERC20(buy_token).balanceOf(self)
    if buy_token_leftover > 0:
        assert extcall IERC20(buy_token).transfer(msg.sender, buy_token_leftover, default_return_value=True)

    # Transfer any leftover sell tokens to the caller
    sell_token_leftover: uint256 = staticcall IERC20(sell_token).balanceOf(self)
    if sell_token_leftover > 0:
        assert extcall IERC20(sell_token).transfer(msg.sender, sell_token_leftover, default_return_value=True)


@external
def takeCallback(
    auction_id: uint256,
    taker: address,
    amount_taken: uint256,
    needed_amount: uint256,
    data: Bytes[_MAX_CALLBACK_DATA_SIZE],
):
    """
    @notice Auction callback - swaps the received collateral into the borrow token and approves payment
    @dev Only callable by the auction currently being taken
    @param auction_id The auction ID
    @param taker The address that initiated the take
    @param amount_taken The amount of collateral tokens received
    @param needed_amount The amount of buy tokens to pay
    @param data Encoded buy token, sell token, swap router and swap calldata
    """
    # Make sure the caller is the auction we're currently taking
    assert msg.sender == self._active_auction, "!active_auction"

    # Decode the callback data
    buy_token: address = empty(address)
    sell_token: address = empty(address)
    swap_router: address = empty(address)
    swap_data: Bytes[_MAX_SWAP_DATA_SIZE] = b""
    buy_token, sell_token, swap_router, swap_data = abi_decode(data, (address, address, address, Bytes[_MAX_SWAP_DATA_SIZE]))

    # Swap the received collateral into the buy token via the Swap Executor.
    # Transfer the full collateral balance and let the executor swap it and sweep the output and leftovers back here
    collateral_balance: uint256 = staticcall IERC20(sell_token).balanceOf(self)
    assert extcall IERC20(sell_token).transfer(SWAP_EXECUTOR.address, collateral_balance, default_return_value=True)
    extcall SWAP_EXECUTOR.swap(swap_router, swap_data, sell_token, buy_token)

    # Approve the auction to pull the needed buy tokens (swap output + any funding held)
    assert extcall IERC20(buy_token).approve(msg.sender, needed_amount, default_return_value=True)
