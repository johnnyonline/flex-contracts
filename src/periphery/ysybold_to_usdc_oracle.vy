# @version 0.4.3

"""
@title ysyBOLD Price Oracle
@license GNU AGPLv3
@author Flex
@notice Provides the price of ysyBOLD in USDC by converting ysyBOLD to BOLD through the vault
        exchange rates and pricing BOLD/USDC off the Curve pool's EMA oracle
@dev The BOLD/USDC price is capped at 1.01 and floored at 0.99. Daddy can lift the floor if
     BOLD actually depegs
"""

from ethereum.ercs import IERC4626

from ..interfaces import ICurveStableSwapNG
from ..interfaces import IMorphoOracle
from ..interfaces import IPriceOracle

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IMorphoOracle
implements: IPriceOracle


# ============================================================================================
# Events
# ============================================================================================


event DepegModeSet:
    depeg_mode: bool


# ============================================================================================
# Constants
# ============================================================================================


# Contracts
DADDY: public(constant(address)) = 0x4e8341C77c94cCE982AB96d92BB28D69f4638290
CURVE_POOL: public(constant(ICurveStableSwapNG)) = ICurveStableSwapNG(0xEFc6516323FbD28e80B85A497B65A86243a54B3E)  # BOLD/USDC

# Tokens
BOLD: public(constant(address)) = 0x6440f144b7e50D6a8439336510312d2F54beB01D
USDC: public(constant(address)) = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
YBOLD: public(constant(IERC4626)) = IERC4626(0x9F4330700a36B29952869fac9b33f45EEdd8A3d8)
YSYBOLD: public(constant(IERC4626)) = IERC4626(0x23346B04a7f55b8760E5860AA5A77383D63491cD)

# Bounds on the BOLD/USDC price
_UPPER_BOUND: constant(uint256) = 101 * 10 ** 16  # 1.01
_LOWER_BOUND: constant(uint256) = 99 * 10 ** 16  # 0.99

# Internal constants
_WAD: constant(uint256) = 10 ** 18
_ORACLE_SCALE_FACTOR: constant(uint256) = 10 ** 24  # 10^(36 + usdc_decimals - ysybold_decimals)


# ============================================================================================
# Storage
# ============================================================================================


# Whether the BOLD/USDC price is allowed below the floor
depeg_mode: public(bool)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__():
    """
    @notice Initialize the contract
    """
    # Make sure the vault chain and the pool composition line up
    assert staticcall YSYBOLD.asset() == YBOLD.address, "!ybold"
    assert staticcall YBOLD.asset() == BOLD, "!bold"
    assert staticcall CURVE_POOL.coins(0) == BOLD, "!coin0"
    assert staticcall CURVE_POOL.coins(1) == USDC, "!coin1"

    # Make sure the pool returns a sane price
    assert staticcall CURVE_POOL.price_oracle(0) > 0, "!curve_pool"


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def get_price(scaled: bool = True) -> uint256:
    """
    @notice Get the ysyBOLD price in terms of USDC
    @param scaled If True, returns 10^(36 + usdc_decimals - ysybold_decimals) format,
                  if False, returns WAD format
    @return Price scaled to the required format
    """
    return self._get_price(scaled)


@external
@view
def price() -> uint256:
    """
    @notice Get the ysyBOLD price in terms of USDC, in Morpho's oracle format
    @return Price scaled to 10^(36 + usdc_decimals - ysybold_decimals) format
    """
    return self._get_price()


# ============================================================================================
# Daddy functions
# ============================================================================================


@external
def set_depeg_mode(depeg_mode: bool):
    """
    @notice Allow or disallow the BOLD/USDC price to go below the floor
    @dev Only callable by Daddy
    @param depeg_mode Whether the price is allowed below the floor
    """
    assert msg.sender == DADDY, "bad daddy"
    self.depeg_mode = depeg_mode
    log DepegModeSet(depeg_mode=depeg_mode)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_price(scaled: bool = True) -> uint256:
    """
    @notice Get the ysyBOLD price in terms of USDC
    @param scaled If True, returns 10^(36 + usdc_decimals - ysybold_decimals) format,
                  if False, returns WAD format
    @return Price scaled to the required format
    """
    # BOLD/USDC from the Curve EMA. `price_oracle(0)` is USDC priced in BOLD, so invert
    bold_price: uint256 = _WAD * _WAD // (staticcall CURVE_POOL.price_oracle(0))

    # Cap the price, and unless in depeg mode, floor it
    bold_price = min(bold_price, _UPPER_BOUND)
    if not self.depeg_mode:
        bold_price = max(bold_price, _LOWER_BOUND)

    # ysyBOLD --> yBOLD
    ybold_per_share: uint256 = staticcall YSYBOLD.convertToAssets(_WAD)

    # yBOLD --> BOLD
    bold_per_share: uint256 = staticcall YBOLD.convertToAssets(ybold_per_share)

    # ysyBOLD price in USDC
    price: uint256 = bold_per_share * bold_price // _WAD

    # Make sure price is not zero
    assert price > 0, "wtf"

    # Scale price to the required format if needed and return
    return price * _ORACLE_SCALE_FACTOR // _WAD if scaled else price
