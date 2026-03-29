# @version 0.4.3

"""
@title Yearn Vault Auction Taker
@license GNU AGPLv3
@author Flex
@notice Takes auctions for markets where the collateral is a Yearn vault
        and the borrow token is the vault's underlying asset (e.g. yvUSD/USDC)
@dev Can be used as the `auction_taker` in the Leverage Zapper or called directly
"""

from ethereum.ercs import IERC20

from ..interfaces import IAuction
from ..interfaces import IVault
from ..interfaces import IZapperAuctionTaker
from ..interfaces import ITaker

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IZapperAuctionTaker
implements: ITaker


# ============================================================================================
# Constants
# ============================================================================================


# Max callback data size
_MAX_CALLBACK_DATA_SIZE: constant(uint256) = 10 ** 5


# ============================================================================================
# Auction Taker
# ============================================================================================


@external
def takeAuction(auction: address, auction_id: uint256):
    """
    @notice Take an auction, redeeming vault collateral to pay
    @param auction The auction contract address
    @param auction_id The auction ID to take
    """
    # Read tokens before taking (can't read during callback due to reentrancy guard)
    buy_token: address = staticcall IAuction(auction).buy_token()
    sell_token: address = staticcall IAuction(auction).sell_token()

    # Take the full auction amount with callback
    extcall IAuction(auction).take(auction_id, max_value(uint256), self, abi_encode(buy_token, sell_token))


@external
def takeCallback(
    auction_id: uint256,
    taker: address,
    amount_taken: uint256,
    needed_amount: uint256,
    data: Bytes[_MAX_CALLBACK_DATA_SIZE],
):
    """
    @notice Auction callback - redeems vault tokens for underlying and approves payment
    @dev Called by the auction contract during `take`
    @param auction_id The auction ID
    @param taker The address that initiated the take
    @param amount_taken The amount of vault tokens received
    @param needed_amount The amount of buy tokens to pay
    @param data Encoded buy token and sell token addresses
    """
    # Decode the token addresses
    buy_token: address = empty(address)
    sell_token: address = empty(address)
    buy_token, sell_token = abi_decode(data, (address, address))

    # Redeem the vault collateral for the underlying
    extcall IVault(sell_token).redeem(amount_taken, self, self)

    # Approve the auction to pull the needed buy tokens
    assert extcall IERC20(buy_token).approve(msg.sender, needed_amount, default_return_value=True)
