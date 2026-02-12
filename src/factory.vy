# @version 0.4.3

"""
@title Factory
@license MIT
@author Flex
@notice Factory contract for deploying new markets
"""

from ethereum.ercs import IERC20Detailed

from interfaces import IERC20Symbol
from interfaces import ITroveManager
from interfaces import ISortedTroves
from interfaces import IDutchDesk
from interfaces import IAuction
from interfaces import ILenderFactory

# ============================================================================================
# Events
# ============================================================================================


event DeployNewMarket:
    deployer: indexed(address)
    trove_manager: indexed(address)
    sorted_troves: address
    dutch_desk: address
    auction: address
    lender: address


# ============================================================================================
# Structs
# ============================================================================================


struct DeployParams:
    borrow_token: address  # address of the borrow token
    collateral_token: address  # address of the collateral token
    price_oracle: address  # address of the Price Oracle contract
    management: address  # address of the management
    performance_fee_recipient: address  # address of the performance fee recipient
    minimum_debt: uint256  # minimum borrowable amount, e.g., `500 * borrow_token_precision` for 500 tokens
    minimum_collateral_ratio: uint256  # minimum CR to avoid liquidation, e.g., `110 * one_pct` for 110%
    upfront_interest_period: uint256  # duration for upfront interest charges, e.g., `7 * 24 * 60 * 60` for 7 days
    interest_rate_adj_cooldown: uint256  # cooldown between rate adjustments, e.g., `7 * 24 * 60 * 60` for 7 days
    redemption_minimum_price_buffer_percentage: uint256  # redemption auction minimum price buffer, e.g. `WAD - 5 * 10 ** 16` for 5% below oracle price
    redemption_starting_price_buffer_percentage: uint256  # redemption auction starting price buffer, e.g. `WAD + 1 * 10 ** 16` for 1% above oracle price. must be >= max oracle deviation from market price to ensure the starting auction price is always above market price, preventing value extraction from oracle lag
    redemption_re_kick_starting_price_buffer_percentage: uint256  # redemption auction re-kick price buffer, e.g. `WAD + 5 * 10 ** 16` for 5% above oracle price
    liquidation_minimum_price_buffer_percentage: uint256  # liquidation auction minimum price buffer, e.g. `WAD - 10 * 10 ** 16` for 10% below oracle price
    liquidation_starting_price_buffer_percentage: uint256  # liquidation auction starting price buffer, e.g., `WAD - 1 * 10 ** 16` for 1% below oracle price
    step_duration: uint256  # duration of each price step, e.g., `60` for price change every minute
    step_decay_rate: uint256  # decay rate per step, e.g., `50` for 0.5% decrease per step
    auction_length: uint256  # total auction duration in seconds, e.g., `86400` for 1 day


# ============================================================================================
# Constants
# ============================================================================================


# Contracts
TROVE_MANAGER: public(immutable(address))
SORTED_TROVES: public(immutable(address))
DUTCH_DESK: public(immutable(address))
AUCTION: public(immutable(address))
LENDER_FACTORY: public(immutable(ILenderFactory))

# Version
VERSION: public(constant(String[28])) = "1.0.0"

# Utils
_WAD: constant(uint256) = 10 ** 18
_MAX_TOKEN_DECIMALS: constant(uint256) = 18


# ============================================================================================
# Constructor
# ============================================================================================

@deploy
def __init__(
    trove_manager: address,
    sorted_troves: address,
    dutch_desk: address,
    auction: address,
    lender_factory: address,
):
    """
    @notice Initialize the contract
    @param trove_manager Address of the Trove Manager contract to clone
    @param sorted_troves Address of the Sorted Troves contract to clone
    @param dutch_desk Address of the Dutch Desk contract to clone
    @param auction Address of the Auction contract to clone
    @param lender_factory Address of the Lender Factory contract
    """
    # Set immutable contracts
    TROVE_MANAGER = trove_manager
    SORTED_TROVES = sorted_troves
    DUTCH_DESK = dutch_desk
    AUCTION = auction
    LENDER_FACTORY = ILenderFactory(lender_factory)


# ============================================================================================
# Deploy
# ============================================================================================

# @todo -- add more input params sanity check here
@external
def deploy(params: DeployParams) -> (address, address, address, address, address):
    """
    @notice Deploys a new market
    @param params Deploy parameters struct
    @return trove_manager Address of the deployed Trove Manager contract
    @return sorted_troves Address of the deployed Sorted Troves contract
    @return dutch_desk Address of the deployed Dutch Desk contract
    @return auction Address of the deployed Auction contract
    @return lender Address of the deployed Lender contract
    """
    # Make sure borrow and collateral tokens are different
    assert params.borrow_token != params.collateral_token, "!tokens"

    # Borrow token cannot have more than 18 decimals
    borrow_token_decimals: uint256 = convert(staticcall IERC20Detailed(params.borrow_token).decimals(), uint256)
    assert borrow_token_decimals <= _MAX_TOKEN_DECIMALS, "!borrow_token_decimals"

    # Collateral token cannot have more than 18 decimals
    collateral_token_decimals: uint256 = convert(staticcall IERC20Detailed(params.collateral_token).decimals(), uint256)
    assert collateral_token_decimals <= _MAX_TOKEN_DECIMALS, "!collateral_token_decimals"

    # Compute the salt value
    salt: bytes32 = keccak256(abi_encode(msg.sender, params.collateral_token, params.borrow_token))

    # Clone a new version of the Trove Manager contract
    trove_manager: address = create_minimal_proxy_to(TROVE_MANAGER, salt=salt)

    # Clone a new version of the Sorted Troves contract
    sorted_troves: address = create_minimal_proxy_to(SORTED_TROVES, salt=salt)

    # Clone a new version of the Dutch Desk contract
    dutch_desk: address = create_minimal_proxy_to(DUTCH_DESK, salt=salt)

    # Clone a new version of the Auction contract
    auction: address = create_minimal_proxy_to(AUCTION, salt=salt)

    # Generate the Lender vault name
    collateral_symbol: String[32] = staticcall IERC20Symbol(params.collateral_token).symbol()
    borrow_symbol: String[32] = staticcall IERC20Symbol(params.borrow_token).symbol()
    name: String[77] = concat("Flex ", collateral_symbol, "/", borrow_symbol, " Lender")

    # Deploy the Lender contract via the Lender Factory
    lender: address = extcall LENDER_FACTORY.deploy(
        params.borrow_token,
        auction,
        trove_manager,
        params.management,
        params.performance_fee_recipient,
        name,
    )

    # Initialize the Trove Manager contract
    extcall ITroveManager(trove_manager).initialize(ITroveManager.InitializeParams(
        lender=lender,
        dutch_desk=dutch_desk,
        price_oracle=params.price_oracle,
        sorted_troves=sorted_troves,
        borrow_token=params.borrow_token,
        collateral_token=params.collateral_token,
        minimum_debt=params.minimum_debt,
        minimum_collateral_ratio=params.minimum_collateral_ratio,
        upfront_interest_period=params.upfront_interest_period,
        interest_rate_adj_cooldown=params.interest_rate_adj_cooldown,
    ))

    # Initialize the Sorted Troves contract
    extcall ISortedTroves(sorted_troves).initialize(trove_manager)

    # Initialize the Dutch Desk contract
    extcall IDutchDesk(dutch_desk).initialize(IDutchDesk.InitializeParams(
        trove_manager=trove_manager,
        lender=lender,
        price_oracle=params.price_oracle,
        auction=auction,
        borrow_token=params.borrow_token,
        collateral_token=params.collateral_token,
        redemption_minimum_price_buffer_percentage=params.redemption_minimum_price_buffer_percentage,
        redemption_starting_price_buffer_percentage=params.redemption_starting_price_buffer_percentage,
        redemption_re_kick_starting_price_buffer_percentage=params.redemption_re_kick_starting_price_buffer_percentage,
        liquidation_minimum_price_buffer_percentage=params.liquidation_minimum_price_buffer_percentage,
        liquidation_starting_price_buffer_percentage=params.liquidation_starting_price_buffer_percentage,
    ))

    # Initialize the Auction contract
    extcall IAuction(auction).initialize(IAuction.InitializeParams(
        papi=dutch_desk,
        buy_token=params.borrow_token,
        sell_token=params.collateral_token,
        step_duration=params.step_duration,
        step_decay_rate=params.step_decay_rate,
        auction_length=params.auction_length,
    ))

    # Emit event
    log DeployNewMarket(
        deployer=msg.sender,
        trove_manager=trove_manager,
        sorted_troves=sorted_troves,
        dutch_desk=dutch_desk,
        auction=auction,
        lender=lender,
    )

    # Return addresses
    return (trove_manager, sorted_troves, dutch_desk, auction, lender)