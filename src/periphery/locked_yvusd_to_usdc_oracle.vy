# @version 0.4.3

"""
@title Locked yvUSD Price Oracle
@license GNU AGPLv3
@author Flex
@notice Provides the price of Locked yvUSD in USDC by converting Locked yvUSD to USDC through
        both vault exchange rates
"""

from ethereum.ercs import IERC20Detailed
from ethereum.ercs import IERC4626

from ..interfaces import IPriceOracle

# ============================================================================================
# Interfaces
# ============================================================================================


implements: IPriceOracle


# ============================================================================================
# Constants
# ============================================================================================


# Tokens
USDC: public(constant(address)) = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
YVUSD: public(constant(IERC4626)) = IERC4626(0x696d02Db93291651ED510704c9b286841d506987)
LOCKED_YVUSD: public(constant(IERC4626)) = IERC4626(0xAaaFEa48472f77563961Cdb53291DEDfB46F9040)

# Internal constants
_WAD: constant(uint256) = 10 ** 18
_LOCKED_YVUSD_DECIMALS: constant(uint256) = 6
_LOCKED_YVUSD_PRECISION: constant(uint256) = 10 ** _LOCKED_YVUSD_DECIMALS
_ORACLE_SCALE_FACTOR: constant(uint256) = 10 ** 36  # 10^(36 + usdc_decimals - locked_yvusd_decimals)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__():
    """
    @notice Initialize the contract
    """
    # Make sure the vault chain lines up
    assert staticcall LOCKED_YVUSD.asset() == YVUSD.address, "!yvusd"
    assert staticcall YVUSD.asset() == USDC, "!usdc"

    # Make sure the precision matches the token
    assert convert(staticcall IERC20Detailed(LOCKED_YVUSD.address).decimals(), uint256) == _LOCKED_YVUSD_DECIMALS, "!decimals"


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def get_price(scaled: bool = True) -> uint256:
    """
    @notice Get the Locked yvUSD price in terms of USDC
    @param scaled If True, returns 10^(36 + usdc_decimals - locked_yvusd_decimals) format,
                  if False, returns WAD format
    @return Price scaled to the required format
    """
    # Locked yvUSD --> yvUSD
    yvusd_per_share: uint256 = staticcall LOCKED_YVUSD.convertToAssets(_LOCKED_YVUSD_PRECISION)

    # yvUSD --> USDC
    usdc_per_share: uint256 = staticcall YVUSD.convertToAssets(yvusd_per_share)

    # Locked yvUSD price in USDC, scaled from one share's precision to WAD
    price: uint256 = usdc_per_share * _WAD // _LOCKED_YVUSD_PRECISION

    # Make sure price is not zero
    assert price > 0, "wtf"

    # Scale price to the required format if needed and return
    return price * _ORACLE_SCALE_FACTOR // _WAD if scaled else price
