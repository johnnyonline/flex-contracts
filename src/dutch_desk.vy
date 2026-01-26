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


# Contracts
TROVE_MANAGER: public(immutable(address))
LENDER: public(immutable(address))
PRICE_ORACLE: public(immutable(IPriceOracle))
AUCTION: public(immutable(IAuction))

# Tokens
BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

# Parameters
STARTING_PRICE_BUFFER_PERCENTAGE: public(immutable(uint256)) # e.g. `_WAD + 15 * 10 ** 16` for 15%
MINIMUM_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD - 5 * 10 ** 16  # 5%
EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 100 * 10 ** 16  # 100%

# Internal constants
_COLLATERAL_TOKEN_PRECISION: immutable(uint256)
_MAX_TOKEN_DECIMALS: constant(uint256) = 18
_WAD: constant(uint256) = 10 ** 18


# ============================================================================================
# Storage
# ============================================================================================


# Nonce for auction identifiers
nonce: public(uint256)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    trove_manager: address,
    lender: address,
    price_oracle: address,
    auction: address,
    borrow_token: address,
    collateral_token: address,
    starting_price_buffer_percentage: uint256,
):
    """
    @notice Initialize the contract
    @dev `starting_price_buffer_percentage` must be >= max oracle deviation from market price
         to ensure the starting auction price is always above market price, preventing value
         extraction from oracle lag
    @param trove_manager Address of the Trove Manager contract
    @param lender Address of the Lender contract
    @param price_oracle Address of the Price Oracle contract
    @param auction Address of the Auction contract
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    @param starting_price_buffer_percentage Buffer percentage to apply to the collateral price for the starting price
    """
    # Set immutable variables
    TROVE_MANAGER = trove_manager
    LENDER = lender
    PRICE_ORACLE = IPriceOracle(price_oracle)
    AUCTION = IAuction(auction)
    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)
    STARTING_PRICE_BUFFER_PERCENTAGE = starting_price_buffer_percentage

    # Borrow token cannot have more than 18 decimals
    borrow_token_decimals: uint256 = convert(staticcall IERC20Detailed(borrow_token).decimals(), uint256)
    assert borrow_token_decimals <= _MAX_TOKEN_DECIMALS, "!borrow_token_decimals"

    # Collateral token cannot have more than 18 decimals
    collateral_token_decimals: uint256 = convert(staticcall IERC20Detailed(collateral_token).decimals(), uint256)
    assert collateral_token_decimals <= _MAX_TOKEN_DECIMALS, "!collateral_token_decimals"

    # Set collateral token precision
    _COLLATERAL_TOKEN_PRECISION = 10 ** collateral_token_decimals

    # Max approve the collateral token to the Auction
    assert extcall COLLATERAL_TOKEN.approve(auction, max_value(uint256), default_return_value=True)


# ============================================================================================
# Kick
# ============================================================================================


@external
def kick(
    kick_amount: uint256,
    maximum_amount: uint256 = 0,
    receiver: address = LENDER,
    is_liquidation: bool = True,
):
    """
    @notice Kicks an auction of collateral tokens for borrow tokens
    @dev Only callable by the Trove Manager contract
    @dev Caller must approve this contract to transfer collateral tokens on its behalf before calling
    @param kick_amount Amount of collateral tokens to auction
    @param maximum_amount The maximum amount borrow tokens to be received
    @param receiver Address to receive the auction proceeds in borrow tokens
    @param is_liquidation Whether this auction is for liquidated collateral
    """
    # Make sure caller is the Trove Manager contract
    assert msg.sender == TROVE_MANAGER, "!trove_manager"

    # Do nothing on zero amount
    if kick_amount == 0:
        return

    # Get the starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(
        kick_amount,
        STARTING_PRICE_BUFFER_PERCENTAGE,
    )

    # Use the nonce as auction identifier
    auction_id: uint256 = self.nonce

    # Increment the nonce
    self.nonce = auction_id + 1

    # Pull the collateral tokens from the Trove Manager
    assert extcall COLLATERAL_TOKEN.transferFrom(TROVE_MANAGER, self, kick_amount, default_return_value=True)

    # Kick the auction
    extcall AUCTION.kick(  # pulls collateral tokens
        auction_id,
        kick_amount,
        maximum_amount,
        starting_price,
        minimum_price,
        receiver,
        LENDER,  # surplus receiver
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
    # Get new starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(
        staticcall AUCTION.current_amount(auction_id),
        EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE,
    )

    # Re-kick with new prices
    extcall AUCTION.re_kick(auction_id, starting_price, minimum_price)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_prices(
    kick_amount: uint256,
    starting_price_buffer_pct: uint256,
) -> (uint256, uint256):
    """
    @notice Gets the starting and minimum prices for an auction
    @param kick_amount Amount of collateral tokens to auction
    @param starting_price_buffer_pct Buffer percentage to apply to the collateral price for the starting price
    @return starting_price The calculated starting price
    @return minimum_price The calculated minimum price
    """
    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.get_price(False)  # Price in 1e18 format

    # Calculate the starting price with buffer to the collateral price
    # Starting price is an unscaled "lot size"
    starting_price: uint256 = kick_amount * collateral_price * starting_price_buffer_pct // _WAD // _WAD // _COLLATERAL_TOKEN_PRECISION

    # Calculate the minimum price with buffer to the collateral price
    # Minimum price is per token and is scaled to 1e18
    minimum_price: uint256 = collateral_price * MINIMUM_PRICE_BUFFER_PERCENTAGE // _WAD

    return starting_price, minimum_price