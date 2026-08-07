# @version 0.4.3

"""
@title Morpho Price Oracle
@license GNU AGPLv3
@author Flex
@notice Provides the price of a collateral token in terms of a borrow token by wrapping a Morpho oracle
@dev The Morpho oracle's `price()` must return the collateral/borrow price in Morpho's standard
     10^(36 + borrow_decimals - collateral_decimals) format
"""

from ethereum.ercs import IERC20Detailed

from ..interfaces import IMorphoOracle
from ..interfaces import IPriceOracle

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


# Contracts
MORPHO_ORACLE: public(immutable(IMorphoOracle))

# Tokens
BORROW_TOKEN: public(immutable(IERC20Detailed))
COLLATERAL_TOKEN: public(immutable(IERC20Detailed))

# Decimals
_ORACLE_SCALE_FACTOR: immutable(uint256)  # 10^(36 + borrow_decimals - collateral_decimals)

# Internal constants
_WAD: constant(uint256) = 10 ** 18
_MAX_TOKEN_DECIMALS: constant(uint256) = 18
_ORACLE_PRICE_SCALE_DECIMALS: constant(uint256) = 36


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(morpho_oracle: address, borrow_token: address, collateral_token: address):
    """
    @notice Initialize the contract
    @param morpho_oracle The Morpho oracle
    @param borrow_token The borrow token
    @param collateral_token The collateral token
    """
    MORPHO_ORACLE = IMorphoOracle(morpho_oracle)
    BORROW_TOKEN = IERC20Detailed(borrow_token)
    COLLATERAL_TOKEN = IERC20Detailed(collateral_token)

    # Tokens cannot have more than 18 decimals
    borrow_token_decimals: uint256 = convert(staticcall BORROW_TOKEN.decimals(), uint256)
    collateral_token_decimals: uint256 = convert(staticcall COLLATERAL_TOKEN.decimals(), uint256)
    assert collateral_token_decimals <= _MAX_TOKEN_DECIMALS and borrow_token_decimals <= _MAX_TOKEN_DECIMALS, "!decimals"

    # Make sure the Morpho oracle returns a sane price
    assert staticcall MORPHO_ORACLE.price() > 0, "!morpho_oracle"

    # Precompute scale factor
    _ORACLE_SCALE_FACTOR = 10 ** (_ORACLE_PRICE_SCALE_DECIMALS + borrow_token_decimals - collateral_token_decimals)


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def get_price(scaled: bool = True) -> uint256:
    """
    @notice Get the collateral price in terms of borrow tokens
    @param scaled If True, returns 10^(36 + borrow_decimals - collateral_decimals) format,
                  if False, returns WAD format
    @return Price scaled to the required format
    """
    # Fetch the price from the Morpho oracle in the scaled format
    price: uint256 = staticcall MORPHO_ORACLE.price()

    # Make sure price is not zero
    assert price > 0, "wtf"

    # Scale price to the required format if needed and return
    return price if scaled else price * _WAD // _ORACLE_SCALE_FACTOR
