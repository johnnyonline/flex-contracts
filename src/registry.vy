# @version 0.4.3

"""
@title Registry
@license MIT
@author Flex
@notice Registry contract for storing addresses of deployed markets
"""

from interfaces import ITroveManager


# ============================================================================================
# Events
# ============================================================================================


event EndorseMarket:
    trove_manager: indexed(address)

event UnendorseMarket:
    trove_manager: indexed(address)


# ============================================================================================
# Flags
# ============================================================================================


flag Status:
    ENDORSED
    UNENDORSED


# ============================================================================================
# Constants
# ============================================================================================


# Daddy
DADDY: public(immutable(address))

# Version
VERSION: public(constant(String[28])) = "1.0.0"

# Utils
_WAD: constant(uint256) = 10 ** 18
_MAX_UINT32: constant(uint256) = 2 ** 32


# ============================================================================================
# Storage
# ============================================================================================


# Markets
markets: public(DynArray[address, _MAX_UINT32])  # append-only list of Trove Manager contracts
market_status: public(HashMap[address, Status])  # Trove Manager contract --> endorsement Status
markets_by_pair: HashMap[uint256, DynArray[address, _MAX_UINT32]]  # key --> list of Trove Manager contracts


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(daddy: address):
    """
    @notice Constructor
    @param daddy Address of Daddy
    """
    # Set Daddy
    DADDY = daddy


# ============================================================================================
# View functions
# ============================================================================================


@view
@external
def markets_count() -> uint256:
    """
    @notice Get the count of the markets that have been endorsed
    @return count The count of markets that have been endorsed
    """
    return len(self.markets)


@view
@external
def markets_count_for_pair(collateral_token: address, borrow_token: address) -> uint256:
    """
    @notice Get the count of the markets that have been endorsed for a specific pair
    @param collateral_token The address of the collateral token
    @param borrow_token The address of the borrow token
    @return count The count of markets that have been endorsed for the given pair
    """
    # Get key
    key: uint256 = self._get_pair_key(collateral_token, borrow_token)

    # Return count
    return len(self.markets_by_pair[key])


@view
@external
def find_market_for_pair(collateral_token: address, borrow_token: address, index: uint256 = 0) -> address:
    """
    @notice Find a market for a specific pair at a given index
    @param collateral_token The address of the collateral token
    @param borrow_token The address of the borrow token
    @param index The index of the market to retrieve
    @return market The address of the market
    """
    # Get key
    key: uint256 = self._get_pair_key(collateral_token, borrow_token)

    # Return market at index
    return self.markets_by_pair[key][index]


# ============================================================================================
# Endorse
# ============================================================================================


@external
def endorse(trove_manager: address):
    """
    @notice Endorse a market
    @dev Only callable by Daddy
    @dev Can't endorse an already endorsed market or reendorse an unendorsed market
    @param trove_manager Address of the Trove Manager contract of the market to endorse
    """
    # Make sure caller is Daddy
    assert msg.sender == DADDY, "bad daddy"

    # Make sure market has not been endorsed before
    assert self.market_status[trove_manager] == empty(Status), "!empty"

    # Add to the list
    self.markets.append(trove_manager)

    # Mark as endorsed
    self.market_status[trove_manager] = Status.ENDORSED

    # Get tokens
    borrow_token: address = staticcall ITroveManager(trove_manager).borrow_token()
    collateral_token: address = staticcall ITroveManager(trove_manager).collateral_token()

    # Get key
    key: uint256 = self._get_pair_key(borrow_token, collateral_token)

    # Add to the pair mapping
    self.markets_by_pair[key].append(trove_manager)

    # Emit event
    log EndorseMarket(trove_manager=trove_manager)


@external
def unendorse(trove_manager: address):
    """
    @notice Unendorse a market
    @dev Only callable by Daddy
    @param trove_manager Address of the Trove Manager contract of the market to unendorse
    """
    # Make sure caller is Daddy
    assert msg.sender == DADDY, "bad daddy"

    # Make sure market is endorsed
    assert self.market_status[trove_manager] == Status.ENDORSED, "!ENDORSED"

    # Mark as unendorsed
    self.market_status[trove_manager] = Status.UNENDORSED

    # Emit event
    log UnendorseMarket(trove_manager=trove_manager)


# ============================================================================================
# Internal helper
# ============================================================================================


@internal
@pure
def _get_pair_key(a: address, b: address) -> uint256:
    """
    @notice Compute an order-independent key for a token pair
    @dev The key is computed as the bitwise XOR of the two token addresses:
         `uint256(a) ^ uint256(b)`, such that `_get_pair_key(a, b) == _get_pair_key(b, a)`
    @param a The first token address
    @param b The second token address
    @return key The computed key for the token pair
    """
    return convert(a, uint256) ^ convert(b, uint256)