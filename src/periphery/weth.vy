# @version 0.4.1

"""
@title WETH --> crvUSD 
@license MIT
@author Flex Protocol
@notice Swaps WETH for crvUSD
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC4626

from interfaces import IExchange
from interfaces import ICurveTricrypto as ICurvePool


# ============================================================================================
# Interfaces
# ============================================================================================


implements: IExchange


# ============================================================================================
# Constants
# ============================================================================================


# Token addresses
_CRVUSD: constant(IERC20) = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E)
_WETH: constant(IERC20) = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)

# Curve pool
_TRICRV_WETH_INDEX: constant(uint256) = 1
_TRICRV_CRVUSD_INDEX: constant(uint256) = 0
_TRICRV: constant(ICurvePool) = ICurvePool(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14)  # crvUSD/WETH/CRV


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__():
    """
    @notice Initialize the contract
    """
    # @todo -- check indexes
    extcall _WETH.approve(_TRICRV.address, max_value(uint256), default_return_value=True)


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
    return _WETH.address


@external
@view
def price() -> uint256:
    """
    @notice Returns the price of the collateral token in terms of the borrow token
    @dev Price is in 1e18 format
    @return Price of the collateral token in terms of borrow token
    """
    return 0  # @todo


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

    # Pull WETH from the caller
    extcall _WETH.transferFrom(msg.sender, self, amount, default_return_value=True)

    # WETH --> crvUSD
    amount_out: uint256 = extcall _TRICRV.exchange(
        _TRICRV_WETH_INDEX,
        _TRICRV_CRVUSD_INDEX,
        amount,
        0,  # min_dy
        False,  # use_eth
        receiver  # receiver
    )

    return amount_out