# @version 0.4.3

"""
@title Price Oracle
@license GNU AGPLv3
@author Flex
@notice Provides the price of yvUSD in terms of USDC
"""

from ethereum.ercs import IERC20Detailed

from interfaces import IYearnVault

from ..interfaces import IPriceOracle

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


# Decimals
_ORACLE_SCALE_FACTOR: immutable(uint256)  # 10^(36 + borrow_decimals - collateral_decimals)
_BORROW_TOKEN_DECIMALS: immutable(uint256)
_COLLATERAL_TOKEN_DECIMALS: immutable(uint256)

# Tokens
_BORROW_TOKEN: constant(IERC20Detailed) = IERC20Detailed(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)  # USDC
_COLLATERAL_TOKEN: constant(IERC20Detailed) = IERC20Detailed(0x696d02Db93291651ED510704c9b286841d506987)  # yvUSD

# Internal constants
_WAD: constant(uint256) = 10 ** 18
_MAX_TOKEN_DECIMALS: constant(uint256) = 18
_ORACLE_PRICE_SCALE_DECIMALS: constant(uint256) = 36


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__():
    """
    @notice Initialize the contract
    """
    # Tokens cannot have more than 18 decimals
    _BORROW_TOKEN_DECIMALS = convert(staticcall _BORROW_TOKEN.decimals(), uint256)
    _COLLATERAL_TOKEN_DECIMALS = convert(staticcall _COLLATERAL_TOKEN.decimals(), uint256)
    assert _COLLATERAL_TOKEN_DECIMALS <= _MAX_TOKEN_DECIMALS and _BORROW_TOKEN_DECIMALS <= _MAX_TOKEN_DECIMALS, "!decimals"

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
    # Fetch yvUSD price per share
    pps: uint256 = staticcall IYearnVault(_COLLATERAL_TOKEN.address).pricePerShare()

    # Scale price to WAD
    price: uint256 = pps * _WAD // 10 ** _COLLATERAL_TOKEN_DECIMALS

    # Scale price to the required format if needed and return
    return price * _ORACLE_SCALE_FACTOR // _WAD if scaled else price