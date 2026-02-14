# @version 0.4.3

"""
@title Dutch Desk
@license MIT
@author Flex
@notice Handles redemptions through Dutch Auctions
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC20Detailed

from interfaces import IAuction
from interfaces import IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


_WAD: constant(uint256) = 10 ** 18


# ============================================================================================
# Storage
# ============================================================================================


# Contracts
trove_manager: public(address)
lender: public(address)
price_oracle: public(IPriceOracle)
auction: public(IAuction)

# Collateral token
collateral_token: public(IERC20)
collateral_token_precision: public(uint256)

# Parameters
minimum_price_buffer_percentage: public(uint256)
starting_price_buffer_percentage: public(uint256)
re_kick_starting_price_buffer_percentage: public(uint256)

# Accounting
nonce: public(uint256)


# ============================================================================================
# Structs
# ============================================================================================


struct InitializeParams:
    trove_manager: address
    lender: address
    price_oracle: address
    auction: address
    borrow_token: address
    collateral_token: address
    minimum_price_buffer_percentage: uint256
    starting_price_buffer_percentage: uint256
    re_kick_starting_price_buffer_percentage: uint256


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
    assert self.trove_manager == empty(address), "initialized"

    # Set contract addresses
    self.trove_manager = params.trove_manager
    self.lender = params.lender
    self.price_oracle = IPriceOracle(params.price_oracle)
    self.auction = IAuction(params.auction)

    # Set collateral token addresses
    self.collateral_token = IERC20(params.collateral_token)

    # Set parameters
    self.minimum_price_buffer_percentage = params.minimum_price_buffer_percentage
    self.starting_price_buffer_percentage = params.starting_price_buffer_percentage
    self.re_kick_starting_price_buffer_percentage = params.re_kick_starting_price_buffer_percentage

    # Get collateral token decimals
    collateral_token_decimals: uint256 = convert(staticcall IERC20Detailed(params.collateral_token).decimals(), uint256)

    # Set collateral token precision
    self.collateral_token_precision = 10 ** collateral_token_decimals

    # Max approve the collateral token to the Auction
    assert extcall IERC20(params.collateral_token).approve(params.auction, max_value(uint256), default_return_value=True)


# ============================================================================================
# Kick
# ============================================================================================


@external
def kick(kick_amount: uint256, maximum_amount: uint256, receiver: address):
    """
    @notice Kicks an auction of collateral tokens for borrow tokens
    @dev Only callable by the Trove Manager contract
    @dev Caller must approve this contract to transfer collateral tokens on its behalf before calling
    @param kick_amount Amount of collateral tokens to auction
    @param maximum_amount The maximum amount borrow tokens to be received
    @param receiver Address to receive the auction proceeds in borrow tokens
    """
    # Make sure caller is the Trove Manager contract
    assert msg.sender == self.trove_manager, "!trove_manager"

    # Do nothing on zero amount
    if kick_amount == 0:
        return

    # Get the starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(
        kick_amount,
        self.starting_price_buffer_percentage,
    )

    # Use the nonce as auction identifier
    auction_id: uint256 = self.nonce

    # Increment the nonce
    self.nonce = auction_id + 1

    # Pull the collateral tokens from the Trove Manager contract
    assert extcall self.collateral_token.transferFrom(self.trove_manager, self, kick_amount, default_return_value=True)

    # Kick the auction
    extcall self.auction.kick(  # pulls collateral tokens
        auction_id,
        kick_amount,
        maximum_amount,
        starting_price,
        minimum_price,
        receiver,
        self.lender,  # surplus receiver
    )


@external
def re_kick(auction_id: uint256):
    """
    @notice Re-kick an inactive auction with new starting and minimum prices
    @dev Will revert if the auction is not kickable
    @dev An auction may need to be re-kicked if its price has fallen below its minimum price
    @dev May use a higher starting price buffer percentage to allow for takers to regroup
    @dev Does not set the receiver nor transfer collateral as those are already ready in the auction
    @param auction_id Identifier of the auction to re-kick
    """
    # Cache the Auction contract
    auction: IAuction = self.auction

    # Get the auction info
    auction_info: IAuction.AuctionInfo = staticcall self.auction.auctions(auction_id)

    # Get new starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(
        auction_info.current_amount,
        self.re_kick_starting_price_buffer_percentage,
    )

    # Re-kick with new prices
    extcall auction.re_kick(auction_id, starting_price, minimum_price)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_prices(kick_amount: uint256, starting_price_buffer_pct: uint256) -> (uint256, uint256):
    """
    @notice Gets the starting and minimum prices for an auction
    @param kick_amount Amount of collateral tokens to auction
    @param starting_price_buffer_pct The buffer percentage to apply to the starting price
    @return starting_price The calculated starting price
    @return minimum_price The calculated minimum price
    """
    # Get the collateral price
    collateral_price: uint256 = staticcall self.price_oracle.get_price(False)  # price in WAD format

    # Calculate the starting price with buffer to the collateral price
    # Starting price is WAD scaled "lot size"
    starting_price: uint256 = kick_amount * collateral_price * starting_price_buffer_pct // _WAD // self.collateral_token_precision

    # Calculate the minimum price with buffer to the collateral price
    # Minimum price is per token and is scaled to WAD
    minimum_price: uint256 = collateral_price * self.minimum_price_buffer_percentage // _WAD

    return starting_price, minimum_price