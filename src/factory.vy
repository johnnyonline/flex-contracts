# @version 0.4.3

"""
@title Factory
@license MIT
@author Flex
@notice Factory contract for deploying new markets
"""

from interfaces import ITroveManager
from interfaces import ISortedTroves
from interfaces import IDutchDesk
from interfaces import IAuction
from interfaces import ILenderFactory


# ============================================================================================
# Events
# ============================================================================================


event DeployNewMarket:
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

# Version
VERSION: public(constant(String[28])) = "1.0.0"


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
    TROVE_MANAGER = trove_manager
    SORTED_TROVES = sorted_troves
    DUTCH_DESK = dutch_desk
    AUCTION = auction
    LENDER_FACTORY = ILenderFactory(lender_factory)


# ============================================================================================
# Deploy
# ============================================================================================

# @todo -- add sanity checks for parameters
# @todo -- remove all sanity checks from other contracts other than if initialized
# @todo -- pass ALL params here
@external
def deploy_new_market(
    borrow_token: address,
    collateral_token: address,
    price_oracle: address,
    minimum_collateral_ratio: uint256,
    minimum_price_buffer_percentage: uint256,
    starting_price_buffer_percentage: uint256,
    emergency_starting_price_buffer_percentage: uint256,
):
    """
    @notice Deploys a new market
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    @param price_oracle Address of the Price Oracle contract
    @param minimum_collateral_ratio Minimum collateral ratio for Troves
    @param minimum_price_buffer_percentage Buffer percentage to apply to the collateral price for the minimum price
    @param starting_price_buffer_percentage Buffer percentage to apply to the collateral price for the starting price
    @param emergency_starting_price_buffer_percentage Buffer percentage to apply to the collateral price for the emergency starting price
    """
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

    # Deploy the Lender contract
    # address _asset,
    #     address _auction,
    #     address _troveManager,
    #     string memory _name // @todo -- can we generate name programmatically?
    lender: address = extcall LENDER_FACTORY.deploy()

    # Initialize the Trove Manager contract
    extcall ITroveManager(trove_manager).initialize(
        lender,
        dutch_desk,
        price_oracle,
        sorted_troves,
        borrow_token,
        collateral_token,
        minimum_collateral_ratio,
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
    extcall IAuction(auction).initialize(dutch_desk, borrow_token, collateral_token)

    # Emit event
    log DeployNewMarket(
        trove_manager=trove_manager,
        sorted_troves=sorted_troves,
        dutch_desk=dutch_desk,
        auction=auction,
        lender=lender,
    )