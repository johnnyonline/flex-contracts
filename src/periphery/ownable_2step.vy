# @version 0.4.1

"""
@title Ownable 2-step
@license MIT
@author Flex
@notice Provides a 2-step ownership transfer mechanism
"""

# ============================================================================================
# Events
# ============================================================================================


event PendingOwnershipTransfer:
    old_owner: indexed(address)
    new_owner: indexed(address)

event OwnershipTransferred:
    old_owner: indexed(address)
    new_owner: indexed(address)


# ============================================================================================
# Storage
# ============================================================================================


owner: public(address)
pending_owner: public(address)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(owner: address):
    assert owner != empty(address), "!owner"

    self.owner = owner


# ============================================================================================
# Owner functions
# ============================================================================================


@external
def transfer_ownership(new_owner: address):
    """
    @notice Starts the ownership transfer of the contract to a new owner
    @dev Only callable by the current `owner`
    @dev Replaces the pending transfer if there is one
    @dev New owner must call `accept_ownership` to finalize the transfer
    @param new_owner The address of the new owner
    """
    # Make sure the caller is the current owner
    assert msg.sender == self.owner, "!owner"

    # Set the pending owner
    self.pending_owner = new_owner

    # Emit event
    log PendingOwnershipTransfer(
        old_owner=self.owner,
        new_owner=new_owner
    )


@external
def accept_ownership():
    """
    @notice The new owner accepts the ownership transfer
    @dev Only callable by the current `pending_owner`
    """
    # Cache the new owner
    new_owner: address = self.pending_owner

    # Make sure the caller is the pending owner
    assert new_owner == msg.sender, "!pending_owner"

    # Cache the old owner for the event
    old_owner: address = self.owner

    # Clear the pending owner
    self.pending_owner = empty(address)

    # Set the new owner
    self.owner = new_owner

    # Emit event
    log OwnershipTransferred(
        old_owner=old_owner,
        new_owner=new_owner
    )