# @version 0.4.3

"""
@title Price Oracle
@license MIT
@author Flex
@notice Provides the price of yvcrvUSD-2 in terms of USDC
"""

from ethereum.ercs import IERC20Detailed

from interfaces import IYearnVault
from interfaces import IChainlinkPriceFeed

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
_COLLATERAL_TOKEN: constant(IERC20Detailed) = IERC20Detailed(0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F)  # yvcrvUSD-2

# Chainlink price feeds
_CRVUSD_USD_PRICE_FEED: constant(IChainlinkPriceFeed) = IChainlinkPriceFeed(0xEEf0C605546958c1f899b6fB336C20671f9cD49F)  # 0.5% deviation threshold
_USDC_USD_PRICE_FEED: constant(IChainlinkPriceFeed) = IChainlinkPriceFeed(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6)  # 0.25% deviation threshold

# Internal constants
_WAD: constant(uint256) = 10 ** 18
_MAX_TOKEN_DECIMALS: constant(uint256) = 18
_ORACLE_PRICE_SCALE_DECIMALS: constant(uint256) = 36
_CHAINLINK_PRICE_FEED_DECIMALS: constant(uint8) = 8


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

    # Make sure Chainlink price feeds have the expected 8 decimals
    assert staticcall _CRVUSD_USD_PRICE_FEED.decimals() == _CHAINLINK_PRICE_FEED_DECIMALS, "!CRVUSD_USD_PRICE_FEED"
    assert staticcall _USDC_USD_PRICE_FEED.decimals() == _CHAINLINK_PRICE_FEED_DECIMALS, "!USDC_USD_PRICE_FEED"

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
    # Fetch CRVUSD/USD price from the Chainlink price feed
    crvusd_usd_price: int256 = staticcall _CRVUSD_USD_PRICE_FEED.latestAnswer()

    # Make sure price is not negative
    assert crvusd_usd_price > 0, "wtf"

    # Fetch USDC/USD price from the Chainlink price feed
    usdc_usd_price: int256 = staticcall _USDC_USD_PRICE_FEED.latestAnswer()

    # Make sure price is not negative
    assert usdc_usd_price > 0, "wtf"

    # Fetch yvcrvUSD-2 price per share
    pps: uint256 = staticcall IYearnVault(_COLLATERAL_TOKEN.address).pricePerShare()  # yvcrvUSD-2 in USD WAD

    # Calculate yvcrvUSD-2/USDC price
    price: uint256 = convert(crvusd_usd_price, uint256) * _WAD // convert(usdc_usd_price, uint256) * pps // _WAD  # yvcrvUSD-2 in USDC WAD

    # Scale price to the required format if needed and return
    return price * _ORACLE_SCALE_FACTOR // _WAD if scaled else price