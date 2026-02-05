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
# Constants
# ============================================================================================


# Contracts
TROVE_MANAGER: public(immutable(address))
SORTED_TROVES: public(immutable(address))
DUTCH_DESK: public(immutable(address))
AUCTION: public(immutable(address))
LENDER_FACTORY: public(immutable(ILenderFactory))

# Default parameters
MINIMUM_DEBT: public(constant(uint256)) = 500  # 500 units of borrow token
MINIMUM_COLLATERAL_RATIO: public(constant(uint256)) = 110  # 110%
UPFRONT_INTEREST_PERIOD: public(constant(uint256)) = 7 * 24 * 60 * 60  # 7 days
INTEREST_RATE_ADJ_COOLDOWN: public(constant(uint256)) = 7 * 24 * 60 * 60  # 7 days
LIQUIDATOR_FEE_PERCENTAGE: public(constant(uint256)) = 10 ** 15  # 0.1%
MINIMUM_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD - 5 * 10 ** 16  # 5%
STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 15 * 10 ** 16  # 15%
EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE: public(constant(uint256)) = _WAD + 20 * 10 ** 16  # 20%
STEP_DURATION: public(constant(uint256)) = 20  # 20 seconds (i.e., reduce price by step decay rate every 20 seconds)
STEP_DECAY_RATE: public(constant(uint256)) = 20  # 0.2% (i.e., reduce price by 0.2% every step duration)
AUCTION_LENGTH: public(constant(uint256)) = 1 * 24 * 60 * 60  # 1 day

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


@external
def deploy(
    borrow_token: address,
    collateral_token: address,
    price_oracle: address,
    management: address,
    performance_fee_recipient: address,
    minimum_debt: uint256 = MINIMUM_DEBT,
    minimum_collateral_ratio: uint256 = MINIMUM_COLLATERAL_RATIO,
    upfront_interest_period: uint256 = UPFRONT_INTEREST_PERIOD,
    interest_rate_adj_cooldown: uint256 = INTEREST_RATE_ADJ_COOLDOWN,
    liquidator_fee_percentage: uint256 = LIQUIDATOR_FEE_PERCENTAGE,
    minimum_price_buffer_percentage: uint256 = MINIMUM_PRICE_BUFFER_PERCENTAGE,
    starting_price_buffer_percentage: uint256 = STARTING_PRICE_BUFFER_PERCENTAGE,
    emergency_starting_price_buffer_percentage: uint256 = EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE,
    step_duration: uint256 = STEP_DURATION,
    step_decay_rate: uint256 = STEP_DECAY_RATE,
    auction_length: uint256 = AUCTION_LENGTH,
) -> (address, address, address, address, address):
    """
    @notice Deploys a new market
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    @param price_oracle Address of the Price Oracle contract
    @param management Address of the management
    @param performance_fee_recipient Address of the performance fee recipient
    @param minimum_debt Minimum borrowable amount
    @param minimum_collateral_ratio Minimum CR to avoid liquidation
    @param upfront_interest_period Duration for upfront interest charges
    @param interest_rate_adj_cooldown Cooldown between rate adjustments
    @param liquidator_fee_percentage Portion of liquidated collateral paid to the caller
    @param minimum_price_buffer_percentage Minimum auction price buffer
    @param starting_price_buffer_percentage Starting auction price buffer
    @param emergency_starting_price_buffer_percentage Emergency starting auction price buffer
    @return trove_manager Address of the deployed Trove Manager contract
    @return sorted_troves Address of the deployed Sorted Troves contract
    @return dutch_desk Address of the deployed Dutch Desk contract
    @return auction Address of the deployed Auction contract
    @return lender Address of the deployed Lender contract
    """
    # Make sure borrow and collateral tokens are different
    assert borrow_token != collateral_token, "!tokens"

    # Borrow token cannot have more than 18 decimals
    borrow_token_decimals: uint256 = convert(staticcall IERC20Detailed(borrow_token).decimals(), uint256)
    assert borrow_token_decimals <= _MAX_TOKEN_DECIMALS, "!borrow_token_decimals"

    # Collateral token cannot have more than 18 decimals
    collateral_token_decimals: uint256 = convert(staticcall IERC20Detailed(collateral_token).decimals(), uint256)
    assert collateral_token_decimals <= _MAX_TOKEN_DECIMALS, "!collateral_token_decimals"

    # Compute the salt value
    salt: bytes32 = keccak256(abi_encode(msg.sender, collateral_token, borrow_token))

    # Clone a new version of the Trove Manager contract
    trove_manager: address = create_minimal_proxy_to(TROVE_MANAGER, salt=salt)

    # Clone a new version of the Sorted Troves contract
    sorted_troves: address = create_minimal_proxy_to(SORTED_TROVES, salt=salt)

    # Clone a new version of the Dutch Desk contract
    dutch_desk: address = create_minimal_proxy_to(DUTCH_DESK, salt=salt)

    # Clone a new version of the Auction contract
    auction: address = create_minimal_proxy_to(AUCTION, salt=salt)

    # Generate the Lender vault name
    collateral_symbol: String[32] = staticcall IERC20Symbol(collateral_token).symbol()
    borrow_symbol: String[32] = staticcall IERC20Symbol(borrow_token).symbol()
    name: String[77] = concat("Flex ", collateral_symbol, "/", borrow_symbol, " Lender")

    # Deploy the Lender contract via the Lender Factory
    lender: address = extcall LENDER_FACTORY.deploy(
        borrow_token,
        auction,
        trove_manager,
        management,
        performance_fee_recipient,
        name,
    )

    # Initialize the Trove Manager contract
    extcall ITroveManager(trove_manager).initialize(
        lender,
        dutch_desk,
        price_oracle,
        sorted_troves,
        borrow_token,
        collateral_token,
        minimum_debt,
        minimum_collateral_ratio,
        upfront_interest_period,
        interest_rate_adj_cooldown,
        liquidator_fee_percentage,
    )

    # Initialize the Sorted Troves contract
    extcall ISortedTroves(sorted_troves).initialize(trove_manager)

    # Initialize the Dutch Desk contract
    extcall IDutchDesk(dutch_desk).initialize(
        trove_manager,
        lender,
        price_oracle,
        auction,
        borrow_token,
        collateral_token,
        minimum_price_buffer_percentage,
        starting_price_buffer_percentage,
        emergency_starting_price_buffer_percentage,
    )

    # Initialize the Auction contract
    extcall IAuction(auction).initialize(
        dutch_desk,
        borrow_token,
        collateral_token,
        step_duration,
        step_decay_rate,
        auction_length,
    )

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