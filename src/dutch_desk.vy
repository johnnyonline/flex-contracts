# @version 0.4.3

"""
@title Dutch Desk
@license MIT
@author Flex
@notice Handles liquidations and redemptions through Dutch Auctions
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

# Parameters
collateral_token_precision: public(uint256)
redemption_minimum_price_buffer_percentage: public(uint256)
redemption_starting_price_buffer_percentage: public(uint256)
redemption_re_kick_starting_price_buffer_percentage: public(uint256)
liquidation_minimum_price_buffer_percentage: public(uint256)
liquidation_starting_price_buffer_percentage: public(uint256)

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
    redemption_minimum_price_buffer_percentage: uint256
    redemption_starting_price_buffer_percentage: uint256
    redemption_re_kick_starting_price_buffer_percentage: uint256
    liquidation_minimum_price_buffer_percentage: uint256
    liquidation_starting_price_buffer_percentage: uint256


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
    self.redemption_minimum_price_buffer_percentage = params.redemption_minimum_price_buffer_percentage
    self.redemption_starting_price_buffer_percentage = params.redemption_starting_price_buffer_percentage
    self.redemption_re_kick_starting_price_buffer_percentage = params.redemption_re_kick_starting_price_buffer_percentage
    self.liquidation_minimum_price_buffer_percentage = params.liquidation_minimum_price_buffer_percentage
    self.liquidation_starting_price_buffer_percentage = params.liquidation_starting_price_buffer_percentage

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
def kick(
    kick_amount: uint256,
    maximum_amount: uint256 = 0,
    receiver: address = empty(address),
    is_liquidation: bool = True,
):
    """
    @notice Kicks an auction of collateral tokens for borrow tokens
    @dev Only callable by the Trove Manager contract
    @dev Will use the Lender contract as receiver of auction proceeds if `receiver` is zero address
    @dev Caller must approve this contract to transfer collateral tokens on its behalf before calling
    @param kick_amount Amount of collateral tokens to auction
    @param maximum_amount The maximum amount borrow tokens to be received
    @param receiver Address to receive the auction proceeds in borrow tokens
    @param is_liquidation Whether this auction is for liquidated collateral
    """
    # Make sure caller is the Trove Manager contract
    assert msg.sender == self.trove_manager, "!trove_manager"

    # Do nothing on zero amount
    if kick_amount == 0:
        return

    # Get the starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(kick_amount, is_liquidation)

    # Use the nonce as auction identifier
    auction_id: uint256 = self.nonce

    # Increment the nonce
    self.nonce = auction_id + 1

    # Pull the collateral tokens from the Trove Manager
    assert extcall self.collateral_token.transferFrom(self.trove_manager, self, kick_amount, default_return_value=True)

    # Kick the auction
    extcall self.auction.kick(  # pulls collateral tokens
        auction_id,
        kick_amount,
        maximum_amount,
        starting_price,
        minimum_price,
        receiver if receiver != empty(address) else self.lender,
        self.lender,  # surplus receiver
        is_liquidation,
    )


@external
def re_kick(auction_id: uint256):
    """
    @notice Re-kick an inactive auction with new starting and minimum prices
    @dev Will revert if the auction is not kickable
    @dev An auction may need to be re-kicked if its price has fallen below its minimum price
    @dev Uses a higher starting price buffer percentage to allow for takers to regroup
    @dev Does not set the receiver nor transfer collateral as those are already ready in the auction
    @param auction_id Identifier of the auction to re-kick
    """
    # Cache the Auction contract
    auction: IAuction = self.auction

    # Check if this is a liquidation or redemption auction
    is_liquidation: bool = staticcall auction.is_liquidation(auction_id)

    # Get new starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(
        staticcall auction.current_amount(auction_id),
        is_liquidation,
        True,  # is_rekick
    )

    # Re-kick with new prices
    extcall auction.re_kick(auction_id, starting_price, minimum_price)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_prices(
    kick_amount: uint256,
    is_liquidation: bool,
    is_rekick: bool = False,
) -> (uint256, uint256):
    """
    @notice Gets the starting and minimum prices for an auction
    @param kick_amount Amount of collateral tokens to auction
    @param is_liquidation Whether this is a liquidation or redemption auction
    @param is_rekick Whether this is a re-kick of an existing auction
    @return starting_price The calculated starting price
    @return minimum_price The calculated minimum price
    """
    # Determine the minimum and starting price buffer percentages
    minimum_price_buffer_pct: uint256 = 0
    starting_price_buffer_pct: uint256 = 0
    if is_liquidation:
        minimum_price_buffer_pct = self.liquidation_minimum_price_buffer_percentage
        starting_price_buffer_pct = self.liquidation_starting_price_buffer_percentage
    else:
        minimum_price_buffer_pct = self.redemption_minimum_price_buffer_percentage
        if is_rekick:
            starting_price_buffer_pct = self.redemption_re_kick_starting_price_buffer_percentage
        else:
            starting_price_buffer_pct = self.redemption_starting_price_buffer_percentage

    # Get the collateral price
    collateral_price: uint256 = staticcall self.price_oracle.get_price(False)  # price in WAD format

    # Calculate the starting price with buffer to the collateral price
    # Starting price is WAD scaled "lot size"
    starting_price: uint256 = kick_amount * collateral_price * starting_price_buffer_pct // _WAD // self.collateral_token_precision

    # Calculate the minimum price with buffer to the collateral price
    # Minimum price is per token and is scaled to WAD
    minimum_price: uint256 = collateral_price * minimum_price_buffer_pct // _WAD

    return starting_price, minimum_price