# @version 0.4.3

"""
@title yvcrvUSD Price Oracle
@license GNU AGPLv3
@author Flex
@notice Provides the price of yvcrvUSD in USDC by converting yvcrvUSD to crvUSD through the vault
        exchange rate and pricing crvUSD/USDC off the Curve peg keeper pool's EMA oracle
@dev The crvUSD/USDC price is capped at 1.01
"""

from ethereum.ercs import IERC4626

from ..interfaces import ICurveStableSwap
from ..interfaces import IPriceOracle

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


# Contracts
CURVE_POOL: public(constant(ICurveStableSwap)) = ICurveStableSwap(0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E)  # USDC/crvUSD

# Tokens
CRVUSD: public(constant(address)) = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
USDC: public(constant(address)) = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
YVCRVUSD: public(constant(IERC4626)) = IERC4626(0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F)

# Bound on the crvUSD/USDC price
_UPPER_BOUND: constant(uint256) = 101 * 10 ** 16  # 1.01

# Internal constants
_WAD: constant(uint256) = 10 ** 18
_ORACLE_SCALE_FACTOR: constant(uint256) = 10 ** 24  # 10^(36 + usdc_decimals - yvcrvusd_decimals)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__():
    """
    @notice Initialize the contract
    """
    # Make sure the vault and the pool composition line up
    assert staticcall YVCRVUSD.asset() == CRVUSD, "!crvusd"
    assert staticcall CURVE_POOL.coins(0) == USDC, "!coin0"
    assert staticcall CURVE_POOL.coins(1) == CRVUSD, "!coin1"

    # Make sure the pool returns a sane price
    assert staticcall CURVE_POOL.price_oracle() > 0, "!curve_pool"


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def get_price(scaled: bool = True) -> uint256:
    """
    @notice Get the yvcrvUSD price in terms of USDC
    @param scaled If True, returns 10^(36 + usdc_decimals - yvcrvusd_decimals) format,
                  if False, returns WAD format
    @return Price scaled to the required format
    """
    return self._get_price(scaled)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_price(scaled: bool = True) -> uint256:
    """
    @notice Get the yvcrvUSD price in terms of USDC
    @param scaled If True, returns 10^(36 + usdc_decimals - yvcrvusd_decimals) format,
                  if False, returns WAD format
    @return Price scaled to the required format
    """
    # crvUSD/USDC from the Curve EMA. `price_oracle()` is crvUSD priced in USDC
    crvusd_price: uint256 = min(staticcall CURVE_POOL.price_oracle(), _UPPER_BOUND)

    # yvcrvUSD --> crvUSD
    crvusd_per_share: uint256 = staticcall YVCRVUSD.convertToAssets(_WAD)

    # yvcrvUSD price in USDC
    price: uint256 = crvusd_per_share * crvusd_price // _WAD

    # Make sure price is not zero
    assert price > 0, "wtf"

    # Scale price to the required format if needed and return
    return price * _ORACLE_SCALE_FACTOR // _WAD if scaled else price
