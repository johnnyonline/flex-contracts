# @version 0.4.1

"""
@title tBTC --> crvUSD 
@license MIT
@author Flex Protocol
@notice Swaps tBTC for crvUSD
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC4626

from interfaces import IExchange
from interfaces import ICurveTwocryptoPool as ICurvePool


# ============================================================================================
# Interfaces
# ============================================================================================


implements: IExchange


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
# View functions
# ============================================================================================


@external
@view
def BORROW_TOKEN() -> address:
    """
    @notice Returns the address of the borrow token
    @return Address of the borrow token
    """
    return _CRVUSD.address


@external
@view
def COLLATERAL_TOKEN() -> address:
    """
    @notice Returns the address of the collateral token
    @return Address of the collateral token
    """
    return _TBTC.address


@external
@view
def price() -> uint256:
    """
    @notice Returns the price of the collateral token in terms of the borrow token
    @dev Price is in 1e18 format
    @return Price of the collateral token in terms of borrow token
    """
    return staticcall _CURVE_POOL.price_oracle()


# ============================================================================================
# Mutative functions
# ============================================================================================


@external
def swap(amount: uint256, receiver: address = msg.sender) -> uint256:
    """
    @notice Swap from the collateral token to the borrow token
    @dev Caller should add slippage protection
    @param amount Amount of collateral tokens to swap
    @return Amount of borrow tokens received
    """
    # Do nothing on zero amount
    if amount == 0:
        return 0

    # Pull tBTC from the caller
    extcall _TBTC.transferFrom(msg.sender, self, amount, default_return_value=True)

    # tBTC --> crvUSD
    amount_out: uint256 = extcall _CURVE_POOL.exchange(
        _CURVE_POOL_TBTC_INDEX,
        _CURVE_POOL_CRVUSD_INDEX,
        amount,
        0,  # min_dy
        receiver  # receiver
    )

    return amount_out