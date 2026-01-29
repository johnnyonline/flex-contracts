# @version 0.4.3

"""
@title Sorted Troves
@license MIT
@author Flex
@notice A sorted doubly linked list with Troves sorted in descending order.
        Troves are ordered according to the borrower's chosen annual interest rate.

        The list optionally accepts insert position hints.

        A Trove only needs to be re-inserted when the borrower adjusts their interest rate. Interest rate order is preserved
        under all other system operations.

        This contract is a Vyper rewrite of the following SortedTroves.sol contract by Liquity:
        https://github.com/liquity/bold/blob/main/contracts/src/SortedTroves.sol
"""

from interfaces import ITroveManager

# ============================================================================================
# Structs
# ============================================================================================


struct Trove:
    next_id: uint256
    prev_id: uint256
    exists: bool


# ============================================================================================
# Constants
# ============================================================================================


_ROOT_TROVE_ID: constant(uint256) = 0
_BAD_HINT: constant(uint256) = 0
_MAX_TROVES: constant(uint256) = 1000


# ============================================================================================
# Storage
# ============================================================================================


# Trove Manager contract
trove_manager: public((ITroveManager))

# Current size of the list
_size: uint256

# Doubly linked list storage mapping Trove IDs to Trove structs.
# Each Trove tracks its `prev_id`, `next_id`, and existence flag.
# The special entry `_troves[_ROOT_TROVE_ID]` anchors both ends of the list,
# simplifying inserts/removals at the head, tail, in an empty list, or for a single element
_troves: HashMap[uint256, Trove]


# ============================================================================================
# Initialize
# ============================================================================================


@external
def initialize(trove_manager: address):
    """
    @notice Initialize the contract
    @param trove_manager Address of the Trove Manager
    """
    # Make sure the contract is not already initialized
    assert self.trove_manager.address == empty(address), "initialized"

    # Set Trove Manager address
    self.trove_manager = ITroveManager(trove_manager)

    # Technically this is not needed as long as _ROOT_TROVE_ID is 0, but it doesn't hurt
    trove: Trove = empty(Trove)
    trove.next_id = _ROOT_TROVE_ID
    trove.prev_id = _ROOT_TROVE_ID

    # Save to storage
    self._troves[_ROOT_TROVE_ID] = trove


# ============================================================================================
# View functions
# ============================================================================================


@external
@view
def empty() -> bool:
    """
    @notice Checks if the list is empty
    @return True if the list is empty. False otherwise
    """
    return self._size == 0


@external
@view
def size() -> uint256:
    """
    @notice Returns the current size of the list
    @return Current size of the list
    """
    return self._size


@external
@view
def first() -> uint256:
    """
    @notice Returns the first Trove in the list (Trove with the largest annual interest rate)
    @return ID of the first Trove in the list
    """
    return self._troves[_ROOT_TROVE_ID].next_id


@external
@view
def last() -> uint256:
    """
    @notice Returns the last Trove in the list (Trove with the smallest annual interest rate)
    @return ID of the last Trove in the list
    """
    return self._troves[_ROOT_TROVE_ID].prev_id


@external
@view
def next(trove_id: uint256) -> uint256:
    """
    @notice Returns the next Trove (with a smaller interest rate) in the list for a given Trove
    @param trove_id Trove's ID
    @return ID of the next Trove in the list
    """
    return self._troves[trove_id].next_id


@external
@view
def prev(trove_id: uint256) -> uint256:
    """
    @notice Returns the previous Trove (with a larger interest rate) in the list for a given Trove
    @param trove_id Trove's ID
    @return ID of the previous Trove in the list
    """
    return self._troves[trove_id].prev_id


@external
@view
def contains(trove_id: uint256) -> bool:
    """
    @notice Checks if the list contains a Trove
    @param trove_id Trove's ID
    @return True if the Trove exists in the list. False otherwise
    """
    return self._contains(trove_id)


@external
@view
def valid_insert_position(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> bool:
    """
    @notice Check if (`prev_id`, `next_id`) is a valid insert position for a Trove with `annual_interest_rate`
    @dev Requires:
         - `prev_id` and `next_id` must be adjacent
         - `prev_id` is ROOT or has rate >= new rate
         - `next_id` is ROOT or has rate < new rate
    @param annual_interest_rate New Trove's annual interest rate
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    @return True if (`prev_id`, `next_id`) is a valid insert position. False otherwise
    """
    return self._valid_insert_position(annual_interest_rate, prev_id, next_id)


@external
@view
def find_insert_position(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (uint256, uint256):
    """
    @notice Find the insert position for a new Trove with the given interest rate
    @dev Uses the provided (`prev_id`, `next_id`) as hints. If they are invalid,
         the function searches until a valid position is found or the `_MAX_TROVES` iteration limit is reached
    @param annual_interest_rate New Trove's annual interest rate
    @param prev_id Suggested previous Trove for the insert position
    @param next_id Suggested next Trove for the insert position
    @return (prev_id, next_id) A valid insert position
    """
    return self._find_insert_position(annual_interest_rate, prev_id, next_id)


# ============================================================================================
# Mutative functions
# ============================================================================================


@external
def insert(trove_id: uint256, annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Add a Trove to the list
    @param trove_id Trove's ID
    @param annual_interest_rate Trove's annual interest rate
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    """
    # Make sure caller is the trove manager
    assert msg.sender == self.trove_manager.address, "!trove_manager"

    # Make sure the trove is not already in the list
    assert not self._contains(trove_id), "exists"

    # Make sure trove_id is not the ROOT Trove
    assert trove_id != _ROOT_TROVE_ID, "!trove_id"

    # Insert the Trove
    self._insert(trove_id, annual_interest_rate, prev_id, next_id)

    # Mark Trove as existing and increase size
    self._troves[trove_id].exists = True
    self._size += 1


@external
def remove(trove_id: uint256):
    """
    @notice Remove a Trove from the list
    @param trove_id Trove's ID
    """
    # Make sure caller is the trove manager
    assert msg.sender == self.trove_manager.address, "!trove_manager"

    # Make sure the Trove is in the list
    assert self._contains(trove_id), "!exists"

    # Remove the Trove
    self._remove(trove_id)

    # Delete the Trove from storage and decrease size
    self._troves[trove_id] = empty(Trove)
    self._size -= 1


@external
def re_insert(trove_id: uint256, new_annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Re-insert a Trove at a new position based on its new annual interest rate
    @param trove_id Trove's ID
    @param new_annual_interest_rate Trove's new annual interest rate
    @param prev_id ID of previous Trove for the new insert position
    @param next_id ID of next Trove for the new insert position
    """
    # Make sure caller is the trove manager
    assert msg.sender == self.trove_manager.address, "!trove_manager"

    # Make sure the Trove is in the list
    assert self._contains(trove_id), "!exists"

    # Re-insert the Trove at the new position
    self._re_insert(trove_id, new_annual_interest_rate, prev_id, next_id)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _contains(trove_id: uint256) -> bool:
    """
    @notice Checks if the list contains a Trove
    @param trove_id Trove's ID
    @return True if the Trove exists in the list. False otherwise
    """
    return self._troves[trove_id].exists


@internal
@view
def _valid_insert_position(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> bool:
    """
    @notice Check if (`prev_id`, `next_id`) is a valid insert position for a Trove with `annual_interest_rate`
    @dev Requires:
         - `prev_id` and `next_id` must be adjacent
         - `prev_id` is ROOT or has rate >= new rate
         - `next_id` is ROOT or has rate < new rate
    @param annual_interest_rate New Trove's annual interest rate
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    @return True if (`prev_id`, `next_id`) is a valid insert position. False otherwise
    """
    # Ensure the Troves are adjacent
    is_adjacent: bool = self._troves[prev_id].next_id == next_id and self._troves[next_id].prev_id == prev_id

    # Previous Trove must be ROOT or have a rate >= new rate
    prev_ok: bool = prev_id == _ROOT_TROVE_ID or self._trove_annual_interest_rate(prev_id) >= annual_interest_rate

    # Next Trove must be ROOT or have a rate < new rate
    next_ok: bool = next_id == _ROOT_TROVE_ID or annual_interest_rate > self._trove_annual_interest_rate(next_id)

    return is_adjacent and prev_ok and next_ok


@internal
@view
def _find_insert_position(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (uint256, uint256):
    """
    @notice Find the insert position for a new Trove with the given interest rate
    @dev Uses the provided (`prev_id`, `next_id`) as hints. If they are invalid,
         the function searches until a valid position is found or the `_MAX_TROVES` iteration limit is reached
    @param annual_interest_rate New Trove's annual interest rate
    @param prev_id Suggested previous Trove for the insert position
    @param next_id Suggested next Trove for the insert position
    @return (prev_id, next_id) A valid insert position
    """
    if prev_id == _ROOT_TROVE_ID:
        # Position is likely near the head - descend from ROOT
        return self._descend_list(annual_interest_rate, _ROOT_TROVE_ID)
    else:
        if not self._contains(prev_id) or self._trove_annual_interest_rate(prev_id) < annual_interest_rate:
            # `prev_id` no longer valid (removed or has lower rate)
            prev_id = _BAD_HINT

    if next_id == _ROOT_TROVE_ID:
        # Position is likely near the tail - ascend from ROOT
        return self._ascend_list(annual_interest_rate, _ROOT_TROVE_ID)
    else:
        if not self._contains(next_id) or annual_interest_rate <= self._trove_annual_interest_rate(next_id):
            # `next_id` no longer valid (removed or has higher rate)
            next_id = _BAD_HINT

    if prev_id == _BAD_HINT and next_id == _BAD_HINT:
        # Both hints invalid - fall back to descending from head
        return self._descend_list(annual_interest_rate, _ROOT_TROVE_ID)
    elif prev_id == _BAD_HINT:
        # Only `prev_id` invalid - ascend from `next_id`
        return self._ascend_list(annual_interest_rate, next_id)
    elif next_id == _BAD_HINT:
        # Only `next_id` invalid - descend from `prev_id`
        return self._descend_list(annual_interest_rate, prev_id)
    else:
        # Both hints still plausible - search between them from both sides
        return self._descend_and_ascend_list(annual_interest_rate, prev_id, next_id)


@internal
@view
def _descend_list(annual_interest_rate: uint256, start_id: uint256) -> (uint256, uint256):
    """
    @notice Find a valid insert position by descending the list (higher --> lower rates)
    @dev Iterates until a valid position is found or the `_MAX_TROVES` limit is reached
    @param annual_interest_rate New Trove's interest rate
    @param start_id Trove ID to start the descent from
    @return (prev_id, next_id) valid insert position
    """
    prev_id: uint256 = start_id
    next_id: uint256 = self._troves[start_id].next_id

    found: bool = False

    for i: uint256 in range(_MAX_TROVES):
        found, prev_id, next_id = self._descend_one(annual_interest_rate, prev_id, next_id)
        if found:
            break

    return prev_id, next_id


@internal
@view
def _descend_one(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (bool, uint256, uint256):
    """
    @notice Descend one step in the list (higher --> lower rates)
    @param annual_interest_rate New Trove's interest rate
    @param prev_id Current previous Trove ID
    @param next_id Current next Trove ID
    @return (found, prev_id, next_id) `found` indicates if a valid insert position has been found
    """
    if next_id == _ROOT_TROVE_ID or annual_interest_rate > self._trove_annual_interest_rate(next_id):
        # Found a valid position
        return True, prev_id, next_id
    else:
        # Move one step forward
        prev_id = next_id
        next_id = self._troves[next_id].next_id
        return False, prev_id, next_id


@internal
@view
def _ascend_list(annual_interest_rate: uint256, start_id: uint256) -> (uint256, uint256):
    """
    @notice Find a valid insert position by ascending the list (lower --> higher rates)
    @dev Iterates until a valid position is found or the `_MAX_TROVES` limit is reached
    @param annual_interest_rate New Trove's interest rate
    @param start_id Trove ID to start the ascent from
    @return (prev_id, next_id) valid insert position
    """
    prev_id: uint256 = self._troves[start_id].prev_id
    next_id: uint256 = start_id

    found: bool = False

    for i: uint256 in range(_MAX_TROVES):
        found, prev_id, next_id = self._ascend_one(annual_interest_rate, prev_id, next_id)
        if found:
            break

    return prev_id, next_id


@internal
@view
def _ascend_one(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (bool, uint256, uint256):
    """
    @notice Ascend one step in the list (lower --> higher rates)
    @param annual_interest_rate New Trove's interest rate
    @param prev_id Current previous Trove ID
    @param next_id Current next Trove ID
    @return (found, prev_id, next_id) `found` indicates if a valid insert position has been found
    """
    if prev_id == _ROOT_TROVE_ID or self._trove_annual_interest_rate(prev_id) >= annual_interest_rate:
        # Found a valid position
        return True, prev_id, next_id
    else:
        # Move one step backward
        next_id = prev_id
        prev_id = self._troves[prev_id].prev_id
        return False, prev_id, next_id


@internal
@view
def _descend_and_ascend_list(annual_interest_rate: uint256, descent_start_id: uint256, ascent_start_id: uint256) -> (uint256, uint256):
    """
    @notice Search for a valid insert position by alternating descent and ascent from two hints
    @dev Iterates until a valid position is found or the `_MAX_TROVES` limit is reached
    @param annual_interest_rate New Trove's annual interest rate
    @param descent_start_id Trove ID to start the descent from
    @param ascent_start_id Trove ID to start the ascent from
    @return (prev_id, next_id) valid insert position
    """
    descent_prev: uint256 = descent_start_id
    descent_next: uint256 = self._troves[descent_start_id].next_id
    ascent_prev: uint256 = self._troves[ascent_start_id].prev_id
    ascent_next: uint256 = ascent_start_id

    found: bool = False

    for i: uint256 in range(_MAX_TROVES):
        found, descent_prev, descent_next = self._descend_one(annual_interest_rate, descent_prev, descent_next)
        if found:
            return descent_prev, descent_next

        found, ascent_prev, ascent_next = self._ascend_one(annual_interest_rate, ascent_prev, ascent_next)
        if found:
            return ascent_prev, ascent_next

    raise "rekt"  # this should not happen


@internal
@view
def _trove_annual_interest_rate(trove_id: uint256) -> uint256:
    """
    @notice Internal helper to get the annual interest rate of a Trove
    @param trove_id Trove's ID
    @return Annual interest rate of the Trove
    """
    trove: ITroveManager.Trove = staticcall self.trove_manager.troves(trove_id)
    return trove.annual_interest_rate


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def _insert(trove_id: uint256, annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Insert a Trove between `prev_id` and `next_id`
    @dev If (`prev_id`, `next_id`) is not a valid insert position for
         the given `annual_interest_rate`, a valid position is found first
    @param trove_id Trove's ID
    @param annual_interest_rate Interest rate for the Trove
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    """
    if not self._valid_insert_position(annual_interest_rate, prev_id, next_id):
        # If the provided hint is invalid, find it ourselves
        prev_id, next_id = self._find_insert_position(annual_interest_rate, prev_id, next_id)

    self._insert_into_verified_position(trove_id, prev_id, next_id)


@internal
def _remove(trove_id: uint256):
    """
    @notice Remove a Trove from the list while keeping the removed Troves connected to each other
    @dev The removed Troves remain linked to each other so they can be reinserted later with `_insert()`
    @param trove_id Trove's ID
    """
    trove_to_remove: Trove = self._troves[trove_id]
    self._troves[trove_to_remove.prev_id].next_id = trove_to_remove.next_id
    self._troves[trove_to_remove.next_id].prev_id = trove_to_remove.prev_id


@internal
def _re_insert(trove_id: uint256, annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Re-insert a Trove at a new position based on `annual_interest_rate`
    @dev If (`prev_id`, `next_id`) is not a valid insert position for
         the given `annual_interest_rate`, a valid position is found first
    @param trove_id Trove's ID
    @param annual_interest_rate New interest rate for the Trove
    @param prev_id Suggested previous Trove ID
    @param next_id Suggested next Trove ID
    """
    if not self._valid_insert_position(annual_interest_rate, prev_id, next_id):
        # If the provided hint is invalid, find it ourselves
        prev_id, next_id = self._find_insert_position(annual_interest_rate, prev_id, next_id)

    # Re-insert only if the new position is different from the current one
    if next_id != trove_id and prev_id != trove_id:
        self._remove(trove_id)
        self._insert_into_verified_position(trove_id, prev_id, next_id)


@internal
def _insert_into_verified_position(trove_id: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Insert a Trove between `prev_id` and `next_id`
    @dev Assumes (`prev_id`, `next_id`) is a valid insert position
    @param trove_id Trove's ID
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    """
    self._troves[prev_id].next_id = trove_id
    self._troves[trove_id].prev_id = prev_id
    self._troves[trove_id].next_id = next_id
    self._troves[next_id].prev_id = trove_id