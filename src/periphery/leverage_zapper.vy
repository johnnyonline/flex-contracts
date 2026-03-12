# @version 0.4.3

"""
@title Leverage Zapper
@license MIT
@author Flex
@notice Enables leveraged positions using crvUSD flash loans and DEX aggregator swaps
"""

from ethereum.ercs import IERC20

from ..interfaces import IFlashLender
from ..interfaces import ITroveManager

# ============================================================================================
# Flags
# ============================================================================================


flag Operation:
    OPEN
    CLOSE
    LEVER_UP
    LEVER_DOWN


# ============================================================================================
# Structs
# ============================================================================================


struct SwapData:
    router: address
    data: Bytes[_MAX_SWAP_DATA_SIZE]


struct OpenLeveragedData:
    owner: address
    trove_manager: address
    owner_index: uint256
    flash_loan_amount: uint256
    collateral_amount: uint256
    debt_amount: uint256
    prev_id: uint256
    next_id: uint256
    annual_interest_rate: uint256
    max_upfront_fee: uint256
    min_borrow_out: uint256
    min_collateral_out: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


struct CloseLeveragedData:
    owner: address
    trove_manager: address
    trove_id: uint256
    flash_loan_amount: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


struct LeverUpData:
    owner: address
    trove_manager: address
    trove_id: uint256
    flash_loan_amount: uint256
    collateral_amount: uint256
    debt_amount: uint256
    max_upfront_fee: uint256
    min_borrow_out: uint256
    min_collateral_out: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


struct LeverDownData:
    owner: address
    trove_manager: address
    trove_id: uint256
    flash_loan_amount: uint256
    collateral_to_remove: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


# ============================================================================================
# Constants
# ============================================================================================


# Max swap calldata size
_MAX_SWAP_DATA_SIZE: constant(uint256) = 10 ** 4

# ERC3156
_MAX_FLASHLOAN_CALLBACK_DATA_SIZE: constant(uint256) = 10 ** 5
_FLASHLOAN_CALLBACK_SUCCESS: constant(bytes32) = keccak256("ERC3156FlashBorrower.onFlashLoan")

# Flash loan token
_CRVUSD: constant(IERC20) = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E)

# Flashloan provider (ERC-3156 compliant)
_FLASH_LENDER: constant(IFlashLender) = IFlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1)


# ============================================================================================
# Open leveraged trove
# ============================================================================================


@external
def open_leveraged_trove(data: OpenLeveragedData) -> uint256:
    """
    @notice Open a new leveraged Trove
    @dev After this call, the owner must call `accept_ownership` on the Trove Manager to claim the Trove
    @param data The open leveraged Trove parameters
    @return The Trove ID
    """
    # Make sure the owner is non-zero
    assert data.owner != empty(address), "!owner"

    # Pull collateral from the caller
    collateral_token: address = staticcall ITroveManager(data.trove_manager).collateral_token()
    assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, data.collateral_amount, default_return_value=True)

    # Initiate flash loan
    extcall _FLASH_LENDER.flashLoan(
        self,  # receiver
        _CRVUSD.address,  # token
        data.flash_loan_amount,  # amount
        abi_encode(Operation.OPEN, data),  # data
    )

    # Compute the Trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(self, data.owner_index)), uint256)

    # Transfer the Trove ownership to the owner
    extcall ITroveManager(data.trove_manager).transfer_ownership(trove_id, data.owner)

    # Sweep any remaining crvUSD tokens to caller
    self._sweep(_CRVUSD.address, msg.sender)

    # Return the Trove ID
    return trove_id


# ============================================================================================
# Close leveraged trove
# ============================================================================================


@external
def close_leveraged_trove(data: CloseLeveragedData):
    """
    @notice Close a leveraged Trove
    @dev Only callable by the Trove owner
    @dev User must call `trove_manager.transfer_ownership(trove_id, zapper)` before calling this
    @param data The close leveraged Trove parameters
    """
    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the current Trove owner
    assert trove.owner == msg.sender, "!owner"

    # Accept Trove ownership
    extcall trove_manager.accept_ownership(data.trove_id)

    # Initiate flash loan
    extcall _FLASH_LENDER.flashLoan(
        self,  # receiver
        _CRVUSD.address,  # token
        data.flash_loan_amount,  # amount
        abi_encode(Operation.CLOSE, data),  # data
    )

    # Get collateral and borrow tokens from the Trove Manager
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Sweep any remaining crvUSD tokens to caller
    self._sweep(_CRVUSD.address, msg.sender)

    # Sweep any remaining collateral tokens to caller
    if collateral_token != _CRVUSD.address:
        self._sweep(collateral_token, msg.sender)

    # Sweep any remaining borrow tokens to caller
    if borrow_token != _CRVUSD.address:
        self._sweep(borrow_token, msg.sender)


# ============================================================================================
# Lever up trove
# ============================================================================================


@external
def lever_up_trove(data: LeverUpData):
    """
    @notice Add leverage to an existing Trove
    @dev Only callable by the Trove owner
    @dev User must call `trove_manager.transfer_ownership(trove_id, zapper)` before calling this
    @param data The lever up parameters
    """
    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the current Trove owner
    assert trove.owner == msg.sender, "!owner"

    # Accept Trove ownership
    extcall trove_manager.accept_ownership(data.trove_id)

    # Pull collateral from the caller
    collateral_token: address = staticcall trove_manager.collateral_token()
    if data.collateral_amount > 0:
        assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, data.collateral_amount, default_return_value=True)

    # Initiate flash loan
    extcall _FLASH_LENDER.flashLoan(
        self,  # receiver
        _CRVUSD.address,  # token
        data.flash_loan_amount,  # amount
        abi_encode(Operation.LEVER_UP, data),  # data
    )

    # Transfer Trove ownership back to caller
    extcall trove_manager.transfer_ownership(data.trove_id, msg.sender)

    # Sweep any remaining crvUSD tokens to caller
    self._sweep(_CRVUSD.address, msg.sender)


# ============================================================================================
# Lever down trove
# ============================================================================================


@external
def lever_down_trove(data: LeverDownData):
    """
    @notice Reduce leverage on an existing Trove
    @dev Only callable by the Trove owner
    @dev User must call `trove_manager.transfer_ownership(trove_id, zapper)` before calling this
    @param data The lever down parameters
    """
    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the current Trove owner
    assert trove.owner == msg.sender, "!owner"

    # Accept Trove ownership
    extcall trove_manager.accept_ownership(data.trove_id)

    # Initiate flash loan
    extcall _FLASH_LENDER.flashLoan(
        self,  # receiver
        _CRVUSD.address,  # token
        data.flash_loan_amount,  # amount
        abi_encode(Operation.LEVER_DOWN, data),  # data
    )

    # Transfer Trove ownership back to caller
    extcall trove_manager.transfer_ownership(data.trove_id, msg.sender)

    # Get collateral and borrow tokens from the Trove Manager
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Sweep any remaining crvUSD tokens to caller
    self._sweep(_CRVUSD.address, msg.sender)

    # Sweep any remaining collateral tokens to caller
    if collateral_token != _CRVUSD.address:
        self._sweep(collateral_token, msg.sender)

    # Sweep any remaining borrow tokens to caller
    if borrow_token != _CRVUSD.address:
        self._sweep(borrow_token, msg.sender)


# ============================================================================================
# Flash loan callback
# ============================================================================================


@external
def onFlashLoan(
    initiator: address,
    token: address,
    amount: uint256,
    fee: uint256,
    data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE],
) -> bytes32:
    """
    @notice ERC-3156 flash loan callback
    @dev Only callable by the flash lender
    @param initiator The address that initiated the flash loan
    @param token The token that was flash loaned
    @param amount The amount that was flash loaned
    @param fee The fee charged for the flash loan
    @param data Encoded operation parameters
    @return The ERC-3156 callback success hash
    """
    # Sanity checks
    assert msg.sender == _FLASH_LENDER.address, "!caller"
    assert initiator == self, "!initiator"
    assert token == _CRVUSD.address, "!token"
    assert len(data) > 4, "!data"
    assert staticcall _CRVUSD.balanceOf(self) >= amount, "!amount"
    assert fee == 0, "!fee"

    # Decode operation type from the first 32 bytes of the flash loan data
    operation: Operation = abi_decode(slice(data, 0, 32), Operation)

    # Branch on operation
    if operation == Operation.OPEN:
        self._handle_open(amount, data)
    elif operation == Operation.CLOSE:
        self._handle_close(amount, data)
    elif operation == Operation.LEVER_UP:
        self._handle_lever_up(amount, data)
    elif operation == Operation.LEVER_DOWN:
        self._handle_lever_down(amount, data)
    else:
        raise "!operation"

    # Repay the flash loan
    assert extcall _CRVUSD.transfer(_FLASH_LENDER.address, amount, default_return_value=True)

    # Return success hash
    return _FLASHLOAN_CALLBACK_SUCCESS


# ============================================================================================
# Internal handlers
# ============================================================================================


@internal
def _handle_open(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]):
    """
    @notice Handle the open leveraged Trove operation inside the flash loan callback
    @param flash_loan_amount The amount of crvUSD that was flash loaned
    @param data The encoded parameters
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: OpenLeveragedData = empty(OpenLeveragedData)
    operation, params = abi_decode(data, (Operation, OpenLeveragedData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # crvUSD --> collateral
    self._swap(params.collateral_swap, _CRVUSD.address, flash_loan_amount)

    # Get the available collateral
    available_collateral: uint256 = staticcall IERC20(collateral_token).balanceOf(self)

    # Approve spending of the collateral by the Trove Manager
    assert extcall IERC20(collateral_token).approve(params.trove_manager, available_collateral, default_return_value=True)

    # Open the Trove
    extcall trove_manager.open_trove(
        params.owner_index,
        available_collateral,
        params.debt_amount,
        params.prev_id,
        params.next_id,
        params.annual_interest_rate,
        params.max_upfront_fee,
        params.min_borrow_out,
        params.min_collateral_out,
    )

    # Make sure our approval is always back to 0
    assert extcall IERC20(collateral_token).approve(params.trove_manager, 0, default_return_value=True)

    # Borrow token --> crvUSD
    borrow_token_balance: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    self._swap(params.debt_swap, borrow_token, borrow_token_balance)


@internal
def _handle_close(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]):
    """
    @notice Handle the close leveraged Trove operation inside the flash loan callback
    @param flash_loan_amount The amount of crvUSD that was flash loaned
    @param data The encoded parameters
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: CloseLeveragedData = empty(CloseLeveragedData)
    operation, params = abi_decode(data, (Operation, CloseLeveragedData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # crvUSD --> borrow token
    self._swap(params.debt_swap, _CRVUSD.address, flash_loan_amount)

    # Get the Trove debt after interest
    trove_debt: uint256 = staticcall trove_manager.get_trove_debt_after_interest(params.trove_id)

    # Approve spending of the borrow token by the Trove Manager
    assert extcall IERC20(borrow_token).approve(params.trove_manager, trove_debt, default_return_value=True)

    # Close the Trove
    extcall trove_manager.close_trove(params.trove_id)

    # Make sure our approval is always back to 0
    assert extcall IERC20(borrow_token).approve(params.trove_manager, 0, default_return_value=True)

    # Collateral --> crvUSD
    collateral_balance: uint256 = staticcall IERC20(collateral_token).balanceOf(self)
    self._swap(params.collateral_swap, collateral_token, collateral_balance)


@internal
def _handle_lever_up(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]):
    """
    @notice Handle the lever up operation inside the flash loan callback
    @param flash_loan_amount The amount of crvUSD that was flash loaned
    @param data The encoded parameters
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: LeverUpData = empty(LeverUpData)
    operation, params = abi_decode(data, (Operation, LeverUpData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # crvUSD --> collateral
    self._swap(params.collateral_swap, _CRVUSD.address, flash_loan_amount)

    # Get the available collateral
    available_collateral: uint256 = staticcall IERC20(collateral_token).balanceOf(self)

    # Approve spending of the collateral by the Trove Manager
    assert extcall IERC20(collateral_token).approve(params.trove_manager, available_collateral, default_return_value=True)

    # Add collateral to the Trove
    extcall trove_manager.add_collateral(params.trove_id, available_collateral)

    # Make sure our approval is always back to 0
    assert extcall IERC20(collateral_token).approve(params.trove_manager, 0, default_return_value=True)

    # Borrow additional debt
    extcall trove_manager.borrow(
        params.trove_id,
        params.debt_amount,
        params.max_upfront_fee,
        params.min_borrow_out,
        params.min_collateral_out,
    )

    # Borrow token --> crvUSD
    borrow_token_balance: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    self._swap(params.debt_swap, borrow_token, borrow_token_balance)


@internal
def _handle_lever_down(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]):
    """
    @notice Handle the lever down operation inside the flash loan callback
    @param flash_loan_amount The amount of crvUSD that was flash loaned
    @param data The encoded parameters
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: LeverDownData = empty(LeverDownData)
    operation, params = abi_decode(data, (Operation, LeverDownData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # crvUSD --> borrow token
    self._swap(params.debt_swap, _CRVUSD.address, flash_loan_amount)

    # Get the available borrow tokens
    available_borrow: uint256 = staticcall IERC20(borrow_token).balanceOf(self)

    # Approve spending of the borrow token by the Trove Manager
    assert extcall IERC20(borrow_token).approve(params.trove_manager, available_borrow, default_return_value=True)

    # Repay debt (Trove Manager caps the actual amount)
    extcall trove_manager.repay(params.trove_id, available_borrow)

    # Make sure our approval is always back to 0
    assert extcall IERC20(borrow_token).approve(params.trove_manager, 0, default_return_value=True)

    # Remove collateral
    extcall trove_manager.remove_collateral(params.trove_id, params.collateral_to_remove)

    # Collateral --> crvUSD
    collateral_balance: uint256 = staticcall IERC20(collateral_token).balanceOf(self)
    self._swap(params.collateral_swap, collateral_token, collateral_balance)


# ============================================================================================
# Internal helpers
# ============================================================================================


@internal
def _swap(swap: SwapData, token_in: address, amount_in: uint256):
    """
    @notice Execute a swap via a DEX aggregator router
    @dev Skips if swap data is empty
    @param swap The swap parameters (router address + calldata)
    @param token_in The input token to approve
    @param amount_in The amount to approve for the swap
    """
    # Return early if no swap data
    if len(swap.data) == 0:
        return

    # Approve input token to the router
    assert extcall IERC20(token_in).approve(swap.router, amount_in, default_return_value=True)

    # Execute the swap
    raw_call(swap.router, swap.data)

    # Make sure our approval is always back to 0
    assert extcall IERC20(token_in).approve(swap.router, 0, default_return_value=True)


@internal
def _sweep(token: address, receiver: address):
    """
    @notice Transfer the entire balance of a token held by this contract to the `receiver`
    @param token The token to sweep
    @param receiver The receiver of the swept tokens
    """
    balance: uint256 = staticcall IERC20(token).balanceOf(self)
    if balance > 0:
        assert extcall IERC20(token).transfer(receiver, balance, default_return_value=True)
