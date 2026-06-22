# @version 0.4.3

"""
@title Price Oracle
@license GNU AGPLv3
@author Flex
@notice Provides the price of a collateral token in terms of a borrow token by wrapping a Morpho oracle
@dev The Morpho oracle's `price()` must return the collateral/borrow price in Morpho's standard
     10^(36 + borrow_decimals - collateral_decimals) format, which equals this oracle's scaled format,
     so the scaled price is returned as-is. Deploy one instance per (morpho_oracle, borrow, collateral);
     the borrow/collateral tokens passed in must match those the Morpho oracle was built for.
"""

from ethereum.ercs import IERC20Detailed

from interfaces import IMorphoOracle

from ..interfaces import IPriceOracle

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


# Contracts / tokens (set at deploy)
MORPHO_ORACLE: public(immutable(IMorphoOracle))
BORROW_TOKEN: public(immutable(IERC20Detailed))
COLLATERAL_TOKEN: public(immutable(IERC20Detailed))

# Decimals
_ORACLE_SCALE_FACTOR: immutable(uint256)  # 10^(36 + borrow_decimals - collateral_decimals)
_BORROW_TOKEN_DECIMALS: immutable(uint256)
_COLLATERAL_TOKEN_DECIMALS: immutable(uint256)

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
    @param morpho_oracle The Morpho oracle returning the collateral/borrow price (scaled format)
    @param borrow_token The borrow token
    @param collateral_token The collateral token
    """
    MORPHO_ORACLE = IMorphoOracle(morpho_oracle)
    BORROW_TOKEN = IERC20Detailed(borrow_token)
    COLLATERAL_TOKEN = IERC20Detailed(collateral_token)

    # Tokens cannot have more than 18 decimals
    _BORROW_TOKEN_DECIMALS = convert(staticcall BORROW_TOKEN.decimals(), uint256)
    _COLLATERAL_TOKEN_DECIMALS = convert(staticcall COLLATERAL_TOKEN.decimals(), uint256)
    assert _COLLATERAL_TOKEN_DECIMALS <= _MAX_TOKEN_DECIMALS and _BORROW_TOKEN_DECIMALS <= _MAX_TOKEN_DECIMALS, "!decimals"

    # Make sure the Morpho oracle returns a sane price
    assert staticcall MORPHO_ORACLE.price() > 0, "!morpho_oracle"

    # Precompute scale factor
    _ORACLE_SCALE_FACTOR = 10 ** (_ORACLE_PRICE_SCALE_DECIMALS + _BORROW_TOKEN_DECIMALS - _COLLATERAL_TOKEN_DECIMALS)


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
    # Fetch the collateral/borrow price from the Morpho oracle (already in the scaled format)
    price: uint256 = staticcall MORPHO_ORACLE.price()

    # Make sure price is not zero
    assert price > 0, "wtf"

    # Already scaled; convert to WAD if the unscaled price is requested
    return price if scaled else price * _WAD // _ORACLE_SCALE_FACTOR
