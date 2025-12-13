# @version 0.4.3

"""
@title Price Oracle (tBTC/crvUSD, via the tBTC/crvUSD Yieldbasis Curve Pool)
@license MIT
@author Flex
@notice Provides the price of tBTC in terms of crvUSD
"""

from ethereum.ercs import IERC20Detailed

from ..interfaces import ICurveTwocryptoPool as ICurvePool
from ...interfaces import IPriceOracle


# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


_ORACLE_SCALE_FACTOR: immutable(uint256)  # 10^(36 + borrow_decimals - collateral_decimals)
_BORROW_TOKEN_DECIMALS: immutable(uint256)
_COLLATERAL_TOKEN_DECIMALS: immutable(uint256)

_ORACLE_PRICE_SCALE_DECIMALS: constant(uint256) = 36
_CURVE_POOL_ORACLE_DECIMALS: constant(uint256) = 18  # Curve pool price oracle returns price in 1e18 format
_CURVE_POOL: constant(ICurvePool) = ICurvePool(0xf1F435B05D255a5dBdE37333C0f61DA6F69c6127)  # YB tBTC


# ============================================================================================
# Constructor
# ============================================================================================

@deploy
def __init__(borrow_token: address, collateral_token: address):
    _BORROW_TOKEN_DECIMALS = convert(staticcall IERC20Detailed(borrow_token).decimals(), uint256)
    _COLLATERAL_TOKEN_DECIMALS = convert(staticcall IERC20Detailed(collateral_token).decimals(), uint256)
    assert _COLLATERAL_TOKEN_DECIMALS <= 18 and _BORROW_TOKEN_DECIMALS <= 18, "!decimals"

    _ORACLE_SCALE_FACTOR = 10 ** (_ORACLE_PRICE_SCALE_DECIMALS + _BORROW_TOKEN_DECIMALS - _COLLATERAL_TOKEN_DECIMALS)


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def price(scaled: bool = True) -> uint256:
    """
    @notice Returns collateral price in borrow token terms
    @param scaled If True, returns 10^(36 + borrow_decimals - collateral_decimals) format,
                  if False, returns 10^18 format
    @return Price scaled to the required format
    """
    price: uint256 = staticcall _CURVE_POOL.price_oracle()
    print("Curve Pool Oracle Price:", price, hardhat_compat=True)
    return price * _ORACLE_SCALE_FACTOR // 10 ** _CURVE_POOL_ORACLE_DECIMALS if scaled else price
