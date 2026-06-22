# @version 0.4.3

"""
@title Swap Auction Taker
@license GNU AGPLv3
@author Flex
@notice Takes redemption auctions on markets where the auctioned collateral must be SWAPPED (not
        NAV-redeemed) into the borrow token, e.g. sfrxUSD/USDC. Converts the collateral via a router
        (using the Swap Executor), topped up with funding that the caller sends in the SAME transaction
        as the take.
@dev Permissionless: usable as the `auction_taker` in the NG Leverage Zapper, called directly by a
     keeper, or by a Lender unwinding its own position. The swap router is validated by the caller (the
     Zapper whitelists it); a direct caller is responsible for the router it passes.
@dev DO NOT leave a token balance on this contract between transactions. `takeAuction` is permissionless
     and sweeps all leftovers to `msg.sender`, so any standing balance (or funding sent in a separate tx)
     can be claimed by anyone. Always fund and take atomically, as the Zapper does. The caller receives
     every leftover: auction proceeds, unused funding, and any unswapped collateral.
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


# Auction currently being taken - transient guard so only it can invoke our callback
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
    @notice Take an auction, swapping the auctioned collateral into the borrow token to pay
    @dev Any funding (borrow token) must be transferred in the SAME transaction (see contract note);
         never leave a standing balance, as this is permissionless and anyone can sweep it.
         The swap router is validated by the caller (the Zapper whitelists it before passing it in)
    @param auction The auction contract address
    @param auction_id The auction ID to take
    @param swap_router The router used to convert collateral -> borrow token
    @param swap_data The router calldata (must encode slippage protection)
    """
    # Read tokens before taking (can't read during the callback due to the auction reentrancy guard)
    buy_token: address = staticcall IAuction(auction).buy_token()
    sell_token: address = staticcall IAuction(auction).sell_token()

    # Set the transient guard so only this auction can invoke our callback
    self._active_auction = auction

    # Take the full auction amount with callback
    extcall IAuction(auction).take(
        auction_id, max_value(uint256), self, abi_encode(buy_token, sell_token, swap_router, swap_data)
    )

    # Clear the transient guard
    self._active_auction = empty(address)

    # Transfer any leftover buy tokens (auction proceeds + unused funding) to the caller
    leftover: uint256 = staticcall IERC20(buy_token).balanceOf(self)
    if leftover > 0:
        assert extcall IERC20(buy_token).transfer(msg.sender, leftover, default_return_value=True)

    # Transfer any unswapped collateral (sell token the router did not consume) back to the caller
    sell_leftover: uint256 = staticcall IERC20(sell_token).balanceOf(self)
    if sell_leftover > 0:
        assert extcall IERC20(sell_token).transfer(msg.sender, sell_leftover, default_return_value=True)


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
    @param amount_taken The amount of collateral (sell token) received
    @param needed_amount The amount of buy tokens to pay
    @param data Encoded buy token, sell token, swap router and swap calldata
    """
    # Make sure the caller is the auction we're currently taking
    assert msg.sender == self._active_auction, "!auction"

    # Decode the callback data
    buy_token: address = empty(address)
    sell_token: address = empty(address)
    swap_router: address = empty(address)
    swap_data: Bytes[_MAX_SWAP_DATA_SIZE] = b""
    buy_token, sell_token, swap_router, swap_data = abi_decode(data, (address, address, address, Bytes[_MAX_SWAP_DATA_SIZE]))

    # Swap the received collateral into the buy token via the Swap Executor.
    # Transfer the full collateral balance and let the executor swap it and sweep the output back here.
    collateral_balance: uint256 = staticcall IERC20(sell_token).balanceOf(self)
    assert extcall IERC20(sell_token).transfer(SWAP_EXECUTOR.address, collateral_balance, default_return_value=True)
    extcall SWAP_EXECUTOR.swap(swap_router, swap_data, sell_token, buy_token)

    # Approve the auction to pull the needed buy tokens (swap output + any funding held).
    # If the swap output + funding don't cover `needed_amount`, the auction's pull reverts the whole take.
    assert extcall IERC20(buy_token).approve(msg.sender, needed_amount, default_return_value=True)
