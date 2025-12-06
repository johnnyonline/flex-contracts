# @version 0.4.3

"""
@title Price Oracle (tBTC/crvUSD, via the tBTC/crvUSD Yieldbasis Curve Pool)
@license MIT
@author Flex
@notice Provides the price of tBTC in terms of crvUSD
"""

from ...interfaces import IPriceOracle

from ..interfaces import ICurveTwocryptoPool as ICurvePool


# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


_CURVE_POOL: constant(ICurvePool) = ICurvePool(0xf1F435B05D255a5dBdE37333C0f61DA6F69c6127)  # YB tBTC


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def price() -> uint256:
    """
    @notice Returns the price of the collateral token in terms of the borrow token
    @dev Price is in 1e18 format
    @return Price of the collateral token in terms of borrow token
    """
    return staticcall _CURVE_POOL.price_oracle()