# @version 0.4.3

"""
@title ERC20 Wrapper
@license MIT
@author Flex
@notice A simple ERC20 token wrapper contract to standardize tokens with different decimals to 18 decimals
"""

from snekmate.auth import ownable
from snekmate.tokens import erc20


# ============================================================================================
# Modules
# ============================================================================================


initializes: ownable
initializes: erc20[ownable := ownable]
exports: (
    erc20.IERC20,
    erc20.IERC20Detailed,
    erc20.renounce_ownership,
    ownable.owner
)


# ============================================================================================
# Constants
# ============================================================================================


UNDERLYING: public(immutable(erc20.IERC20))
DECIMALS_DIFFERENCE: public(immutable(uint256))


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(name: String[25], symbol: String[5], underlying: address):
    """
    @dev Ownership is transferred to msg.sender after deployment.
         `renounce_ownership` should be called as part of setup
    @param name Name of the token
    @param symbol Symbol of the token
    @param underlying Address of the underlying token to be wrapped
    """
    ownable.__init__()
    erc20.__init__(name, symbol, 18, "Just say no", "to EIP712")

    UNDERLYING = erc20.IERC20(underlying)

    underlying_decimals: uint256 = convert(staticcall erc20.IERC20Detailed(underlying).decimals(), uint256)
    assert underlying_decimals < 18, "!underlying_decimals"

    DECIMALS_DIFFERENCE = 18 - underlying_decimals


# ============================================================================================
# Mutative functions
# ============================================================================================


@external
def wrap(amount: uint256, receiver: address = msg.sender):
    """
    @notice Wrap underlying tokens to standardized 18 decimals wrapped tokens
    @param amount Amount of underlying tokens to wrap (in underlying decimals)
    @param receiver Address to receive the wrapped tokens
    """
    # Pull tokens from caller
    extcall UNDERLYING.transferFrom(msg.sender, self, amount, default_return_value=True)

    # Determine amount in 18 decimals
    amount_in_decimals: uint256 = amount * 10 ** DECIMALS_DIFFERENCE

    # Mint wrapped tokens to receiver
    erc20._mint(receiver, amount_in_decimals)


@external
def unwrap(amount: uint256, receiver: address = msg.sender):
    """
    @notice Unwrap wrapped tokens to the underlying token
    @param amount Amount of wrapped tokens to unwrap (in 18 decimals)
    @param receiver Address to receive the underlying tokens
    """
    # Burn wrapped tokens from caller
    erc20._burn(msg.sender, amount)

    # Determine amount in underlying decimals
    amount_in_underlying_decimals: uint256 = amount // 10 ** DECIMALS_DIFFERENCE  # Be careful with precision loss!

    # Transfer underlying tokens to receiver
    extcall UNDERLYING.transfer(receiver, amount_in_underlying_decimals, default_return_value=True)