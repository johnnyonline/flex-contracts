# @version 0.4.1

"""
@title Sorted Troves
@license MIT
@author Flex Protocol
@notice A sorted doubly linked list with nodes sorted in descending order.
        Nodes map to active Troves in the system - the ID property is the address of a Trove owner.
        Nodes are ordered according to the borrower's chosen annual interest rate.

        The list optionally accepts insert position hints.

        The annual interest rate is stored on the Trove struct in TroveManager, not directly on the Node. // @todo -- fix

        A node need only be re-inserted when the borrower adjusts their interest rate. Interest rate order is preserved
        under all other system operations.

        This contract is a Vyper rewrite of the following SortedTroves.sol contract by Liquity:
        https://github.com/liquity/bold/blob/main/contracts/src/SortedTroves.sol
"""

from interfaces import IBorrower


# ============================================================================================
# Structs
# ============================================================================================


struct Node:
    nextId: uint256
    prevId: uint256
    exists: bool


# ============================================================================================
# Constants
# ============================================================================================


BORROWER: public(immutable(IBorrower))

# ID of head & tail of the list. Callers should stop iterating with `get_next()` / `get_prev()` when encountering this node ID
ROOT_NODE_ID: public(constant(uint256)) = 0

UNINITIALIZED_ID: constant(uint256) = 0
BAD_HINT: constant(uint256) = 0
MAX_NODES: constant(uint256) = 1000


# ============================================================================================
# Storage
# ============================================================================================


# Current size of the list
size: public(uint256)

# Doubly linked list storage mapping node IDs to Node structs.
# Each Node tracks its `prevId`, `nextId`, and existence flag.
# The special entry `nodes[ROOT_NODE_ID]` anchors both ends of the list,
# simplifying inserts/removals at the head, tail, in an empty list, or for a single element
nodes: public(HashMap[uint256, Node])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(borrower: address):
    """
    @notice Initialize the contract
    """
    BORROWER = IBorrower(borrower)

    # Technically this is not needed as long as ROOT_NODE_ID is 0, but it doesn't hurt
    self.nodes[ROOT_NODE_ID].nextId = ROOT_NODE_ID
    self.nodes[ROOT_NODE_ID].prevId = ROOT_NODE_ID


# ============================================================================================
# View functions
# ============================================================================================


@view
def contains(id: uint256) -> bool:
    """
    @notice Checks if the list contains a node
    """
    return self.nodes[id].exists


@view
def find_insert_position(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (uint256, uint256):
    """
    @notice Find the insert position for a new node with the given interest rate
    @dev Uses the provided (`prev_id`, `next_id`) as hints, but will always return a correct position even if they are wrong
    @param annual_interest_rate New node’s annual interest rate
    @param prev_id Suggested previous node for the insert position
    @param next_id Suggested next node for the insert position
    @return (prev_id, next_id) A valid insert position
    """
    if prev_id == ROOT_NODE_ID:
        # Position is likely near the head - descend from ROOT
        return self.descend_list(annual_interest_rate, ROOT_NODE_ID)
    else:
        if not self.contains(prev_id) or self.trove_annual_interest_rate(prev_id) < annual_interest_rate:
            # `prev_id` no longer valid (removed or has lower rate)
            prev_id = BAD_HINT

    if next_id == ROOT_NODE_ID:
        # Position is likely near the tail - ascend from ROOT
        return self.ascend_list(annual_interest_rate, ROOT_NODE_ID)
    else:
        if not self.contains(next_id) or annual_interest_rate <= self.trove_annual_interest_rate(next_id):
            # `next_id` no longer valid (removed or has higher rate)
            next_id = BAD_HINT

    if prev_id == BAD_HINT and next_id == BAD_HINT:
        # Both hints invalid - fall back to descending from head
        return self.descend_list(annual_interest_rate, ROOT_NODE_ID)
    elif prev_id == BAD_HINT:
        # Only `prev_id` invalid - ascend from `next_id`
        return self.ascend_list(annual_interest_rate, next_id)
    elif next_id == BAD_HINT:
        # Only `next_id` invalid - descend from `prev_id`
        return self.descend_list(annual_interest_rate, prev_id)
    else:
        # Both hints still plausible - search between them from both sides
        return self.descend_and_ascend_list(annual_interest_rate, prev_id, next_id)


# ============================================================================================
# Mutative functions
# ============================================================================================


@external
def insert(id: uint256, annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Add a Trove to the list
    @param id Trove's id
    @param annual_interest_rate Trove's annual interest rate
    @param prev_id Id of previous Trove for the insert position
    @param next_id Id of next Trove for the insert position
    """
    assert msg.sender == BORROWER.address, "not borrower"
    assert not self.contains(id), "trove exists"
    assert id != ROOT_NODE_ID, "invalid id"

    self.insert_slice(id, id, annual_interest_rate, prev_id, next_id)

    self.nodes[id].exists = True
    self.size += 1


@external
def remove(id: uint256):
    """
    @notice Remove a Trove from the list
    @param id Trove's id
    """
    assert msg.sender == BORROWER.address, "not borrower"
    assert self.contains(id), "trove does not exist"

    # Remove logic to be implemented
    # self.remove_slice(id, id)

    self.nodes[id].exists = False  # @todo -- notice we dont remove the `nextId` and `prevId` properties here -- is this a problem?
    self.size -= 1


@external
def re_insert(id: uint256, new_annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Re-insert a Trove at a new position based on its new annual interest rate
    @param id Trove's id
    @param new_annual_interest_rate Trove's new annual interest rate
    @param prev_id Id of previous Trove for the new insert position
    @param next_id Id of next Trove for the new insert position
    """
    assert msg.sender == BORROWER.address, "not borrower"
    assert self.contains(id), "trove does not exist"

    # Re-insert logic to be implemented
    # self.re_insert_slice(id, id, new_annual_interest_rate, prev_id, next_id)


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def valid_insert_position(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> bool:
    """
    @notice Check if (`prev_id`, `next_id`) is a valid insert position for a node with `annual_interest_rate`
    @dev Requires:
         - `prev_id` and `next_id` must be adjacent
         - `prev_id` is ROOT or has rate >= new rate
         - `next_id` is ROOT or has rate < new rate
    """
    # Ensure the nodes are adjacent
    is_adjacent: bool = self.nodes[prev_id].nextId == next_id and self.nodes[next_id].prevId == prev_id

    # Previous node must be ROOT or have a rate >= new rate
    prev_ok: bool = prev_id == ROOT_NODE_ID or self.trove_annual_interest_rate(prev_id) >= annual_interest_rate

    # Next node must be ROOT or have a rate < new rate
    next_ok: bool = next_id == ROOT_NODE_ID or annual_interest_rate > self.trove_annual_interest_rate(next_id)

    return is_adjacent and prev_ok and next_ok


@internal
@view
def descend_list(annual_interest_rate: uint256, start_id: uint256) -> (uint256, uint256):
    """
    @notice Find a valid insert position by descending the list (higher --> lower rates)
    @param annual_interest_rate New node’s interest rate
    @param start_id Node ID to start the descent from
    @return (prev_id, next_id) valid insert position
    """
    prev_id: uint256 = start_id
    next_id: uint256 = self.nodes[start_id].nextId

    found: bool = False

    for i: uint256 in range(MAX_NODES):
        found, prev_id, next_id = self.descend_one(annual_interest_rate, prev_id, next_id)
        if found:
            break

    return prev_id, next_id


@internal
@view
def descend_one(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (bool, uint256, uint256):
    """
    @notice Descend one step in the list (higher --> lower rates)
    @param annual_interest_rate New node’s interest rate
    @param prev_id Current previous node ID
    @param next_id Current next node ID
    @return (found, prev_id, next_id) `found` indicates if a valid insert position has been found
    """
    if next_id == ROOT_NODE_ID or annual_interest_rate > self.trove_annual_interest_rate(next_id):
        # Found a valid position
        return True, prev_id, next_id
    else:
        # Move one step forward
        prev_id = next_id
        next_id = self.nodes[next_id].nextId
        return False, prev_id, next_id


@internal
@view
def ascend_list(annual_interest_rate: uint256, start_id: uint256) -> (uint256, uint256):
    """
    @notice Find a valid insert position by ascending the list (lower --> higher rates)
    @param annual_interest_rate New node’s interest rate
    @param start_id Node ID to start the ascent from
    @return (prev_id, next_id) valid insert position
    """
    prev_id: uint256 = self.nodes[start_id].prevId
    next_id: uint256 = start_id

    found: bool = False

    for i: uint256 in range(MAX_NODES):
        found, prev_id, next_id = self.ascend_one(annual_interest_rate, prev_id, next_id)
        if found:
            break

    return prev_id, next_id


@internal
@view
def ascend_one(annual_interest_rate: uint256, prev_id: uint256, next_id: uint256) -> (bool, uint256, uint256):
    """
    @notice Ascend one step in the list (lower --> higher rates)
    @param annual_interest_rate New node’s interest rate
    @param prev_id Current previous node ID
    @param next_id Current next node ID
    @return (found, prev_id, next_id) `found` indicates if a valid insert position has been found
    """
    if prev_id == ROOT_NODE_ID or self.trove_annual_interest_rate(prev_id) >= annual_interest_rate:
        # Found a valid position
        return True, prev_id, next_id
    else:
        # Move one step backward
        next_id = prev_id
        prev_id = self.nodes[prev_id].prevId
        return False, prev_id, next_id


@internal
@view
def descend_and_ascend_list(annual_interest_rate: uint256, descent_start_id: uint256, ascent_start_id: uint256) -> (uint256, uint256):
    """
    @notice Search for a valid insert position by alternating descent and ascent from two hints
    @param annual_interest_rate New node’s annual interest rate
    @param descent_start_id Node ID to start the descent from
    @param ascent_start_id Node ID to start the ascent from
    @return (prev_id, next_id) valid insert position
    """
    descent_prev: uint256 = descent_start_id
    descent_next: uint256 = self.nodes[descent_start_id].nextId
    ascent_prev: uint256 = self.nodes[ascent_start_id].prevId
    ascent_next: uint256 = ascent_start_id

    found: bool = False

    for i: uint256 in range(MAX_NODES):
        found, descent_prev, descent_next = self.descend_one(annual_interest_rate, descent_prev, descent_next)
        if found:
            return descent_prev, descent_next

        found, ascent_prev, ascent_next = self.ascend_one(annual_interest_rate, ascent_prev, ascent_next)
        if found:
            return ascent_prev, ascent_next

    raise "rekt"  # This should not happen


@internal
@view
def trove_annual_interest_rate(trove_id: uint256) -> uint256:
    """
    @notice Internal helper to get the annual interest rate of a node
    @param trove_id Trove's id
    """
    return staticcall BORROWER.trove_annual_interest_rate(trove_id)


# ============================================================================================
# Internal mutative functions
# ============================================================================================


@internal
def insert_slice(slice_head: uint256, slice_tail: uint256, annual_interest_rate: uint256, prev_id: uint256, next_id: uint256):
    """
    @notice Insert a slice of nodes between `prev_id` and `next_id`
    @dev If (`prev_id`, `next_id`) is not a valid insert position for
         the given `annual_interest_rate`, a valid position is found first
    """
    if not self.valid_insert_position(annual_interest_rate, prev_id, next_id):
        # If the provided hint is invalid, find it ourselves
        prev_id, next_id = self.find_insert_position(annual_interest_rate, prev_id, next_id)

    # Insert the slice between `prev_id` and `next_id`
    self.nodes[prev_id].nextId = slice_head
    self.nodes[slice_head].prevId = prev_id
    self.nodes[slice_tail].nextId = next_id
    self.nodes[next_id].prevId = slice_tail


#     // Remove the entire slice between `_sliceHead` and `_sliceTail` from the list while keeping
#     // the removed nodes connected to each other, such that they can be reinserted into a different
#     // position with `_insertSlice()`.
#     // Can be used to remove a single node by passing its ID as both `_sliceHead` and `_sliceTail`.
#     function _removeSlice(uint256 _sliceHead, uint256 _sliceTail) internal {
#         nodes[nodes[_sliceHead].prevId].nextId = nodes[_sliceTail].nextId;
#         nodes[nodes[_sliceTail].nextId].prevId = nodes[_sliceHead].prevId;
#     }

#     function _reInsertSlice(
#         ITroveManager _troveManager,
#         uint256 _sliceHead,
#         uint256 _sliceTail,
#         uint256 _annualInterestRate,
#         uint256 _prevId,
#         uint256 _nextId
#     ) internal {
#         if (!_validInsertPosition(_troveManager, _annualInterestRate, _prevId, _nextId)) {
#             // Sender's hint was not a valid insert position
#             // Use sender's hint to find a valid insert position
#             (_prevId, _nextId) = _findInsertPosition(_troveManager, _annualInterestRate, _prevId, _nextId);
#         }

#         // Check that the new insert position isn't the same as the existing one
#         if (_nextId != _sliceHead && _prevId != _sliceTail) {
#             _removeSlice(_sliceHead, _sliceTail);
#             _insertSliceIntoVerifiedPosition(_sliceHead, _sliceTail, _prevId, _nextId);
#         }
#     }


#     /*
#      * @dev Checks if the list is empty
#      */
#     function isEmpty() external view override returns (bool) {
#         return size == 0;
#     }

#     /*
#      * @dev Returns the current size of the list
#      */
#     function getSize() external view override returns (uint256) {
#         return size;
#     }

#     /*
#      * @dev Returns the first node in the list (node with the largest annual interest rate)
#      */
#     function getFirst() external view override returns (uint256) {
#         return nodes[ROOT_NODE_ID].nextId;
#     }

#     /*
#      * @dev Returns the last node in the list (node with the smallest annual interest rate)
#      */
#     function getLast() external view override returns (uint256) {
#         return nodes[ROOT_NODE_ID].prevId;
#     }

#     /*
#      * @dev Returns the next node (with a smaller interest rate) in the list for a given node
#      * @param _id Node's id
#      */
#     function getNext(uint256 _id) external view override returns (uint256) {
#         return nodes[_id].nextId;
#     }

#     /*
#      * @dev Returns the previous node (with a larger interest rate) in the list for a given node
#      * @param _id Node's id
#      */
#     function getPrev(uint256 _id) external view override returns (uint256) {
#         return nodes[_id].prevId;
#     }

#     /*
#      * @dev Check if a pair of nodes is a valid insertion point for a new node with the given interest rate
#      * @param _annualInterestRate Node's annual interest rate
#      * @param _prevId Id of previous node for the insert position
#      * @param _nextId Id of next node for the insert position
#      */
#     function validInsertPosition(uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)
#         external
#         view
#         override
#         returns (bool)
#     {
#         return _validInsertPosition(troveManager, _annualInterestRate, _prevId, _nextId);
#     }

#     // --- 'require' functions ---

#     function _requireCallerIsBOorTM() internal view {
#         require(
#             msg.sender == borrowerOperationsAddress || msg.sender == address(troveManager),
#             "SortedTroves: Caller is not BorrowerOperations nor TroveManager"
#         );
#     }

#     function _requireCallerIsBorrowerOperations() internal view {
#         require(msg.sender == borrowerOperationsAddress, "SortedTroves: Caller is not BorrowerOperations");
#     }
# }


