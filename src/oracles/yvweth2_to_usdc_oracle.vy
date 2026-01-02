# @version 0.4.3

"""
@title Price Oracle
@license MIT
@author Flex
@notice Provides the price of yvWETH-2 in terms of USDC
"""

from ethereum.ercs import IERC20Detailed

from interfaces import IYearnVault
from interfaces import ICurveTricrypto as ICurvePool

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
_COLLATERAL_TOKEN: constant(IERC20Detailed) = IERC20Detailed(0xAc37729B76db6438CE62042AE1270ee574CA7571)  # yvWETH-2

# Curve Pool
_CURVE_POOL_TOKEN_INDEX: constant(uint256) = 1  # WETH index in the Curve pool
_CURVE_POOL_ORACLE_DECIMALS: constant(uint256) = 18  # Curve pool price oracle returns price in 1e18 format
_CURVE_POOL: constant(ICurvePool) = ICurvePool(0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B)  # TricryptoUSDC

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
    underlying_price: uint256 = staticcall _CURVE_POOL.price_oracle(_CURVE_POOL_TOKEN_INDEX)  # WETH in USDC in WAD
    pps: uint256 = staticcall IYearnVault(_COLLATERAL_TOKEN.address).pricePerShare()  # yvWETH-2 in WETH WAD
    price: uint256 = underlying_price * pps // _WAD  # yvWETH-2 in USDC WAD
    return price * _ORACLE_SCALE_FACTOR // 10 ** _CURVE_POOL_ORACLE_DECIMALS if scaled else price
