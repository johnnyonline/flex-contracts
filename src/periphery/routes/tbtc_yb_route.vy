# @version 0.4.1

"""
@title Exchange Route (tBTC --> crvUSD, via the tBTC/crvUSD Yieldbasis Curve Pool)
@license MIT
@author Flex
@notice Swaps tBTC for crvUSD
"""

from ethereum.ercs import IERC20

from ..interfaces import IExchangeRoute
from ..interfaces import ICurveTwocryptoPool as ICurvePool


# ============================================================================================
# Interfaces
# ============================================================================================


implements: IExchangeRoute


# ============================================================================================
# Constants
# ============================================================================================


# Token addresses
_CRVUSD: constant(IERC20) = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E)
_TBTC: constant(IERC20) = IERC20(0x18084fbA666a33d37592fA2633fD49a74DD93a88)

# Curve pool
_CURVE_POOL_TBTC_INDEX: constant(uint256) = 1
_CURVE_POOL_CRVUSD_INDEX: constant(uint256) = 0
_CURVE_POOL: constant(ICurvePool) = ICurvePool(0xf1F435B05D255a5dBdE37333C0f61DA6F69c6127)  # YB tBTC


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__():
    """
    @notice Initialize the contract
    """
    assert staticcall _CURVE_POOL.coins(_CURVE_POOL_TBTC_INDEX) == _TBTC.address, "!COLLATERAL_TOKEN"
    assert staticcall _CURVE_POOL.coins(_CURVE_POOL_CRVUSD_INDEX) == _CRVUSD.address, "!BORROW_TOKEN"

    extcall _TBTC.approve(_CURVE_POOL.address, max_value(uint256), default_return_value=True)


# ============================================================================================
# Mutative functions
# ============================================================================================


@external
def execute(amount: uint256, receiver: address) -> uint256:
    """
    @notice Execute the swap from collateral token to borrow token
    @dev Caller should add slippage protection
    @dev Caller should transfer `amount` of collateral tokens to this contract before calling
    @param amount Amount of collateral tokens to swap
    @param receiver Address to receive the borrow tokens
    @return Amount of borrow tokens received
    """
    # tBTC --> crvUSD
    amount_out: uint256 = extcall _CURVE_POOL.exchange(
        _CURVE_POOL_TBTC_INDEX,
        _CURVE_POOL_CRVUSD_INDEX,
        amount,
        0,  # min_dy
        receiver  # receiver
    )

    return amount_out