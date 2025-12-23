# @version 0.4.3

"""
@title Dutch Desk
@license MIT
@author Flex
@notice Handles liquidations and redemptions through Yearn Dutch Auctions
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC20Detailed

from periphery import ownable_2step as ownable

from interfaces import IAuction
from interfaces import IPriceOracle
# @todo -- auction step size? and buffers

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


# Contracts
TROVE_MANAGER: public(immutable(address))
PRICE_ORACLE: public(immutable(IPriceOracle))
AUCTION: public(immutable(IAuction))

# Tokens
BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

# Parameters
MINIMUM_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD - 5 * 10 ** 16  # 5%
STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 15 * 10 ** 16  # 15%
EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 100 * 10 ** 16  # 100% // @todo -- double check this value

# Internal constants
_COLLATERAL_TOKEN_PRECISION: immutable(uint256)
_WAD: constant(uint256) = 10 ** 18


# ============================================================================================
# Storage
# ============================================================================================


# Address of the keeper
keeper: public(address)

# Nonce for auction identifiers
nonce: public(uint256)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    owner: address,
    lender: address,
    trove_manager: address,
    price_oracle: address,
    auction: address,
    borrow_token: address,
    collateral_token: address,
):
    """
    @notice Initialize the contract
    @param owner Address of the initial owner
    @param lender Address of the lender (receiver of liquidation auction proceeds)
    @param trove_manager Address of the trove manager contract
    @param price_oracle Address of the price oracle contract
    @param auction Address of the auction contract
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    """
    ownable.__init__(owner)

    # Set immutable variables
    TROVE_MANAGER = trove_manager
    PRICE_ORACLE = IPriceOracle(price_oracle)
    AUCTION = IAuction(auction)
    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)

    # Make sure collateral token decimals is not higher than WAD
    _COLLATERAL_TOKEN_PRECISION = 10 ** convert(staticcall IERC20Detailed(collateral_token).decimals(), uint256)
    assert _COLLATERAL_TOKEN_PRECISION <= _WAD, "!decimals"

    # Max approve the collateral token to the auction contract and CoW vault relayer
    assert extcall COLLATERAL_TOKEN.approve(auction, max_value(uint256), default_return_value=True)
    #  ERC20(_from).forceApprove(VAULT_RELAYER, type(uint256).max);


# ============================================================================================
# Keeper functions
# ============================================================================================


# @todo - emit event
@external
def emergency_kick(auction_id: uint256):
    """
    @notice Emergency kicks the provided auction
    @dev Only callable by the keeper
    @dev Uses a higher starting price buffer percentage to allow for takers to re-group
    @dev Does not set the receiver nor transfer collateral as those are already ready in the auction
    @param auctions List of auctions to emergency kick
    """
    # Make sure the caller is the keeper
    assert msg.sender == self.keeper, "!keeper"

    # Check if we really need to emergency kick
    is_kickable: bool = staticcall auction.kickable(auction_id)

    # @todo -- add sweep_and_settle

    # Get the starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(amount_to_kick, starting_price_buffer_pct)

    # # @todo
    # @external
    # def re_kick(
    #     auction_id: uint256,
    #     starting_price: uint256,
    #     minimum_price: uint256,
    # ):

    # Kick with higher starting price buffer
    self._kick(auction_id, EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE)


# ============================================================================================
# Owner functions
# ============================================================================================


# @todo - emit event
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
def kick(amount_to_kick: uint256, receiver: address = empty(address)) -> uint256:
    """
    @notice Kicks an auction of collateral tokens for borrow tokens
    @dev Only callable by the Trove Manager contract
    @dev Pulls the collateral tokens from the Trove Manager before kicking the auction
    @param amount_to_kick Amount of collateral tokens to auction
    @param receiver Address to receive the auction proceeds in borrow tokens
    @return The auction ID used to kick the auction
    """
    # Make sure caller is the trove manager
    assert msg.sender == TROVE_MANAGER, "!trove_manager"

    # Do nothing on zero amount
    if amount_to_kick == 0:
        return

    # Use the nonce as auction identifier
    auction_id: uint256 = self.nonce

    # Increment the nonce
    self.nonce = auction_id + 1

    # Kick the auction
    self._kick(
        auction_id,
        amount_to_kick,
        STARTING_PRICE_BUFFER_PERCENTAGE,
        receiver,
    )

    # Return the used auction ID
    return auction_id


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def _kick(
    auction_id: uint256,
    amount_to_kick: uint256,
    starting_price_buffer_pct: uint256,
    receiver: address,
):
    """
    @notice Kicks off an auction with starting and minimum prices
    @dev Auction Proceeds are sent from the auction contract directly to the `receiver`
    @param auction_id The identifier for the auction
    @param amount_to_kick Amount of collateral tokens to auction
    @param starting_price_buffer_pct Buffer percentage to apply to the collateral price for the starting price
    @param receiver Address to receive the borrow tokens
    """
    # Get the starting and minimum prices
    starting_price: uint256 = 0
    minimum_price: uint256 = 0
    starting_price, minimum_price = self._get_prices(amount_to_kick, starting_price_buffer_pct)

    # Pull the collateral tokens from the Trove Manager
    assert extcall COLLATERAL_TOKEN.transferFrom(TROVE_MANAGER, self, amount_to_kick, default_return_value=True)

    # Kick the auction
    extcall auction.kick(auction_id, amount_to_kick, starting_price, minimum_price, receiver)  # Pulls collateral tokens


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_prices(
    amount_to_kick: uint256,
    starting_price_buffer_pct: uint256,
) -> (uint256, uint256):
    """
    @notice Gets the starting and minimum prices for an auction
    @param amount_to_kick Amount of collateral tokens to auction
    @param starting_price_buffer_pct Buffer percentage to apply to the collateral price for the starting price
    @return starting_price The calculated starting price
    @return minimum_price The calculated minimum price
    """
    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price(False)  # Price in 1e18 format

    # Calculate the starting price with buffer to the collateral price
    # Starting price is an unscaled "lot size"
    starting_price: uint256 = amount_to_kick * collateral_price // _WAD * starting_price_buffer_pct // _WAD // _COLLATERAL_TOKEN_PRECISION

    # Calculate the minimum price with buffer to the collateral price
    # Minimum price is per token and is scaled to 1e18
    minimum_price: uint256 = collateral_price * MINIMUM_PRICE_BUFFER_PERCENTAGE // _WAD

    return starting_price, minimum_price