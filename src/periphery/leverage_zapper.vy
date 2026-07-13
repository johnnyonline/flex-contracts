# @version 0.4.3

"""
@title Leverage Zapper
@license GNU AGPLv3
@author Flex
@notice Enables leveraged positions using Morpho flash loans and DEX aggregator swaps
@dev The Morpho contract address is hardcoded to the Ethereum mainnet deployment
"""

from ethereum.ercs import IERC20

from ..interfaces import IAuction
from ..interfaces import IDutchDesk
from ..interfaces import IMorpho
from ..interfaces import IRegistry
from ..interfaces import ISwapExecutor
from ..interfaces import ITroveCallback
from ..interfaces import ITroveManager

# ============================================================================================
# Interfaces
# ============================================================================================


implements: ITroveCallback


# ============================================================================================
# Events
# ============================================================================================


event SetRouter:
    router: indexed(address)
    allowed: bool


# ============================================================================================
# Flags
# ============================================================================================


flag Operation:
    CLOSE
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
    initial_collateral: uint256
    collateral_amount: uint256
    debt_amount: uint256
    prev_id: uint256
    next_id: uint256
    annual_interest_rate: uint256
    max_upfront_fee: uint256
    min_borrow_out: uint256
    min_collateral_out: uint256
    debt_swap: SwapData


struct CloseLeveragedData:
    trove_manager: address
    flash_loan_token: address
    trove_id: uint256
    flash_loan_amount: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


struct LeverUpData:
    trove_manager: address
    trove_id: uint256
    initial_collateral: uint256
    collateral_amount: uint256
    debt_amount: uint256
    max_upfront_fee: uint256
    min_borrow_out: uint256
    min_collateral_out: uint256
    debt_swap: SwapData


struct LeverDownData:
    trove_manager: address
    flash_loan_token: address
    trove_id: uint256
    flash_loan_amount: uint256
    collateral_to_remove: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


# ============================================================================================
# Constants
# ============================================================================================


# Contracts
DADDY: public(immutable(address))
REGISTRY: public(immutable(IRegistry))
SWAP_EXECUTOR: public(immutable(ISwapExecutor))

# Max calldata size
_MAX_SWAP_DATA_SIZE: constant(uint256) = 10 ** 4
_MAX_CALLBACK_DATA_SIZE: constant(uint256) = 10 ** 5

# Max starting price buffer the take supports (no buffer)
_MAX_STARTING_PRICE_BUFFER: constant(uint256) = 10 ** 18

# Flash loan provider
_MORPHO: constant(IMorpho) = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb)


# ============================================================================================
# Storage
# ============================================================================================


# Whitelists
routers: public(HashMap[address, bool])

# Transient guard that allows only the Trove Manager to call `troveCallback`
_pending_trove_manager: transient(address)


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(daddy: address, registry: address, swap_executor: address):
    """
    @notice Initialize the contract
    @param daddy Address of the Daddy contract
    @param registry Address of the Registry contract
    @param swap_executor Address of the Swap Executor contract
    """
    DADDY = daddy
    REGISTRY = IRegistry(registry)
    SWAP_EXECUTOR = ISwapExecutor(swap_executor)


# ============================================================================================
# Whitelist
# ============================================================================================


@external
def set_router(router: address, allowed: bool):
    """
    @notice Whitelist or remove a swap router
    @dev Only callable by Daddy
    @param router The router address
    @param allowed True to whitelist, False to remove
    """
    # Make sure the caller is Daddy
    assert msg.sender == DADDY, "bad daddy"

    # Update whitelist
    self.routers[router] = allowed

    # Emit event
    log SetRouter(
        router=router,
        allowed=allowed,
    )


# ============================================================================================
# Open leveraged trove
# ============================================================================================


@external
@nonreentrant
def open_leveraged_trove(data: OpenLeveragedData) -> uint256:
    """
    @notice Open a new leveraged Trove
    @dev `collateral_amount` is the total collateral the Trove is opened with: the caller's
         `initial_collateral` plus whatever the callback sources from the kicked auction and the
         `debt_swap`. If the callback falls short, the Trove Manager's collateral pull reverts
    @param data The open leveraged Trove parameters
    @return The Trove ID
    """
    # Validate input parameters
    self._validate_params(data.trove_manager, data.debt_swap.router)

    # Get the collateral token from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()

    # Pull the initial collateral from the caller
    assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, data.initial_collateral, default_return_value=True)

    # Record the Dutch Desk nonce before opening the Trove
    nonce_before: uint256 = staticcall IDutchDesk(staticcall trove_manager.dutch_desk()).nonce()

    # Approve the Trove Manager to pull the collateral after the callback
    assert extcall IERC20(collateral_token).approve(data.trove_manager, data.collateral_amount, default_return_value=True)

    # Activate the transient guard so the Trove Manager can call `troveCallback`
    self._pending_trove_manager = data.trove_manager

    # Open the Trove. The loan is delivered, `troveCallback` is invoked, then the collateral is pulled
    trove_id: uint256 = extcall trove_manager.open_trove(
        data.owner_index,
        data.collateral_amount,
        data.debt_amount,
        data.prev_id,
        data.next_id,
        data.annual_interest_rate,
        data.max_upfront_fee,
        data.min_borrow_out,
        data.min_collateral_out,
        data.owner,
        abi_encode(nonce_before, data.debt_swap),
    )

    # Clear the transient guard
    self._pending_trove_manager = empty(address)

    # Make sure our approval is always back to 0
    assert extcall IERC20(collateral_token).approve(data.trove_manager, 0, default_return_value=True)

    # Sweep any remaining tokens to caller
    self._sweep_all(data.trove_manager)

    # Return the Trove ID
    return trove_id


# ============================================================================================
# Close leveraged trove
# ============================================================================================


@external
@nonreentrant
def close_leveraged_trove(data: CloseLeveragedData):
    """
    @notice Close a leveraged Trove
    @dev Only callable by the Trove owner or an approved operator
    @dev The Zapper must be approved to operate on behalf of the Trove owner
    @param data The close leveraged Trove parameters
    """
    # Validate input parameters
    self._validate_params(data.trove_manager, data.debt_swap.router, data.collateral_swap.router)

    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the Trove owner or an approved operator
    assert trove.owner == msg.sender or staticcall trove_manager.approved(trove.owner, msg.sender), "!owner"

    # Initiate flash loan
    extcall _MORPHO.flashLoan(
        data.flash_loan_token,  # token
        data.flash_loan_amount,  # assets
        abi_encode(Operation.CLOSE, data),  # data
    )

    # Sweep any remaining tokens to caller
    self._sweep_all(data.trove_manager, data.flash_loan_token)


# ============================================================================================
# Lever up trove
# ============================================================================================


@external
@nonreentrant
def lever_up_trove(data: LeverUpData):
    """
    @notice Add leverage to an existing Trove
    @dev Only callable by the Trove owner or an approved operator
    @dev The Zapper must be approved to operate on behalf of the Trove owner
    @dev `collateral_amount` is the total collateral added to the Trove: the caller's
         `initial_collateral` plus whatever the callback sources from the kicked auction and the
         `debt_swap`. If the callback falls short, the Trove Manager's collateral pull reverts
    @param data The lever up parameters
    """
    # Validate input parameters
    self._validate_params(data.trove_manager, data.debt_swap.router)

    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the Trove owner or an approved operator
    assert trove.owner == msg.sender or staticcall trove_manager.approved(trove.owner, msg.sender), "!owner"

    # Get the collateral token from the Trove Manager
    collateral_token: address = staticcall trove_manager.collateral_token()

    # If needed, pull the initial collateral from the caller
    if data.initial_collateral > 0:
        assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, data.initial_collateral, default_return_value=True)

    # Record the Dutch Desk nonce before borrowing
    nonce_before: uint256 = staticcall IDutchDesk(staticcall trove_manager.dutch_desk()).nonce()

    # Approve the Trove Manager to pull the collateral after the callback
    assert extcall IERC20(collateral_token).approve(data.trove_manager, data.collateral_amount, default_return_value=True)

    # Activate the transient guard so the Trove Manager can call `troveCallback`
    self._pending_trove_manager = data.trove_manager

    # Borrow, adding the collateral in the same call. The loan is delivered, `troveCallback` is
    # invoked, then the collateral is pulled
    extcall trove_manager.borrow(
        data.trove_id,
        data.debt_amount,
        data.max_upfront_fee,
        data.min_borrow_out,
        data.min_collateral_out,
        data.collateral_amount,
        abi_encode(nonce_before, data.debt_swap),
    )

    # Clear the transient guard
    self._pending_trove_manager = empty(address)

    # Make sure our approval is always back to 0
    assert extcall IERC20(collateral_token).approve(data.trove_manager, 0, default_return_value=True)

    # Sweep any remaining tokens to caller
    self._sweep_all(data.trove_manager)


# ============================================================================================
# Lever down trove
# ============================================================================================


@external
@nonreentrant
def lever_down_trove(data: LeverDownData):
    """
    @notice Reduce leverage on an existing Trove
    @dev Only callable by the Trove owner or an approved operator
    @dev The Zapper must be approved to operate on behalf of the Trove owner
    @param data The lever down parameters
    """
    # Validate input parameters
    self._validate_params(data.trove_manager, data.debt_swap.router, data.collateral_swap.router)

    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the Trove owner or an approved operator
    assert trove.owner == msg.sender or staticcall trove_manager.approved(trove.owner, msg.sender), "!owner"

    # Initiate flash loan
    extcall _MORPHO.flashLoan(
        data.flash_loan_token,  # token
        data.flash_loan_amount,  # assets
        abi_encode(Operation.LEVER_DOWN, data),  # data
    )

    # Sweep any remaining tokens to caller
    self._sweep_all(data.trove_manager, data.flash_loan_token)


# ============================================================================================
# Trove callback
# ============================================================================================


@external
def troveCallback(trove_id: uint256, data: Bytes[_MAX_CALLBACK_DATA_SIZE]):
    """
    @notice Trove Manager callback, invoked mid open/lever up after the loan is delivered but before
            the collateral is pulled. Sources the collateral from the kicked auction and the `debt_swap`
    @dev Only callable by the Trove Manager the Zapper is currently operating on
    @param trove_id Unique identifier of the Trove
    @param data The callback data encoded in the outer call
    """
    # Make sure the caller is the Trove Manager we are currently operating on
    assert msg.sender == self._pending_trove_manager, "!caller"

    # Decode the callback data
    nonce_before: uint256 = 0
    debt_swap: SwapData = empty(SwapData)
    nonce_before, debt_swap = abi_decode(data, (uint256, SwapData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(msg.sender)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Get the Dutch Desk from the Trove Manager
    dutch_desk: IDutchDesk = IDutchDesk(staticcall trove_manager.dutch_desk())

    # Take the auction, if one was kicked
    if staticcall dutch_desk.nonce() > nonce_before:
        # Make sure there is no starting price buffer. Otherwise we would not have enough buy tokens to take the auction
        assert staticcall dutch_desk.starting_price_buffer_percentage() == _MAX_STARTING_PRICE_BUFFER, "!buffer"

        # Take the auction
        extcall IAuction(staticcall dutch_desk.auction()).take(nonce_before)

    # Borrow token --> collateral (the idle-liquidity portion of the loan)
    borrow_token_balance: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    self._swap(debt_swap, borrow_token, collateral_token, borrow_token_balance)


# ============================================================================================
# Flash loan callback
# ============================================================================================


@external
def onMorphoFlashLoan(
    assets: uint256,
    data: Bytes[_MAX_CALLBACK_DATA_SIZE],
):
    """
    @notice Morpho flash loan callback
    @dev Only callable by Morpho
    @param assets The amount that was flash loaned
    @param data Encoded operation parameters
    """
    # Sanity checks
    assert msg.sender == _MORPHO.address, "!caller"
    assert len(data) >= 32, "!data"

    # Decode operation type from the first 32 bytes
    operation: Operation = abi_decode(slice(data, 0, 32), Operation)

    # Branch on operation
    flash_loan_token: address = empty(address)
    if operation == Operation.CLOSE:
        flash_loan_token = self._handle_close(assets, data)
    elif operation == Operation.LEVER_DOWN:
        flash_loan_token = self._handle_lever_down(assets, data)
    else:
        raise "!operation"

    # Approve Morpho to pull repayment (no fee)
    assert extcall IERC20(flash_loan_token).approve(_MORPHO.address, assets, default_return_value=True)


# ============================================================================================
# Internal handlers
# ============================================================================================


@internal
def _handle_close(flash_loan_amount: uint256, data: Bytes[_MAX_CALLBACK_DATA_SIZE]) -> address:
    """
    @notice Handle the close leveraged Trove operation inside the flash loan callback
    @param flash_loan_amount The amount that was flash loaned
    @param data The encoded parameters
    @return The flash loan token address
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: CloseLeveragedData = empty(CloseLeveragedData)
    operation, params = abi_decode(data, (Operation, CloseLeveragedData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Flash loan token --> borrow token
    self._swap(params.debt_swap, params.flash_loan_token, borrow_token, flash_loan_amount)

    # Get the Trove debt after interest
    trove_debt: uint256 = staticcall trove_manager.get_trove_debt_after_interest(params.trove_id)

    # Approve spending of the borrow token by the Trove Manager
    assert extcall IERC20(borrow_token).approve(params.trove_manager, trove_debt, default_return_value=True)

    # Close the Trove
    extcall trove_manager.close_trove(params.trove_id)

    # Make sure our approval is always back to 0
    assert extcall IERC20(borrow_token).approve(params.trove_manager, 0, default_return_value=True)

    # Collateral --> flash loan token
    collateral_balance: uint256 = staticcall IERC20(collateral_token).balanceOf(self)
    self._swap(params.collateral_swap, collateral_token, params.flash_loan_token, collateral_balance)

    return params.flash_loan_token


@internal
def _handle_lever_down(flash_loan_amount: uint256, data: Bytes[_MAX_CALLBACK_DATA_SIZE]) -> address:
    """
    @notice Handle the lever down operation inside the flash loan callback
    @param flash_loan_amount The amount that was flash loaned
    @return The flash loan token address
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

    # Flash loan token --> borrow token
    self._swap(params.debt_swap, params.flash_loan_token, borrow_token, flash_loan_amount)

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

    # Collateral --> flash loan token
    collateral_balance: uint256 = staticcall IERC20(collateral_token).balanceOf(self)
    self._swap(params.collateral_swap, collateral_token, params.flash_loan_token, collateral_balance)

    return params.flash_loan_token


# ============================================================================================
# Internal helpers
# ============================================================================================


@internal
@view
def _validate_params(
    trove_manager: address,
    debt_swap_router: address,
    collateral_swap_router: address = empty(address),
):
    """
    @notice Validate input parameters for the external functions
    @param trove_manager The Trove Manager address
    @param debt_swap_router The debt swap router address
    @param collateral_swap_router The collateral swap router address
    """
    # Make sure the Trove Manager is endorsed
    assert staticcall REGISTRY.market_status(trove_manager) == IRegistry.Status.ENDORSED, "!endorsed"

    # If provided, make sure the debt swap router is whitelisted
    if debt_swap_router != empty(address):
        assert self.routers[debt_swap_router], "!debt_swap_router"

    # If provided, make sure the collateral swap router is whitelisted
    if collateral_swap_router != empty(address):
        assert self.routers[collateral_swap_router], "!collateral_swap_router"


@internal
def _swap(swap: SwapData, token_in: address, token_out: address, amount_in: uint256):
    """
    @notice Execute a swap via the Swap Executor
    @dev Skips if swap data is empty. Caller should encode slippage protection in the router calldata
    @param swap The swap parameters (router address + calldata)
    @param token_in The input token
    @param token_out The output token
    @param amount_in The amount to swap
    """
    # Return early if no swap data
    if len(swap.data) == 0:
        return

    # Transfer input tokens to the Swap Executor
    assert extcall IERC20(token_in).transfer(SWAP_EXECUTOR.address, amount_in, default_return_value=True)

    # Execute the swap via the Swap Executor. Output tokens are sent back to this contract
    extcall SWAP_EXECUTOR.swap(swap.router, swap.data, token_in, token_out)


@internal
def _sweep_all(trove_manager: address, flash_loan_token: address = empty(address)):
    """
    @notice Sweep the flash loan, collateral and borrow tokens to the caller
    @param trove_manager The Trove Manager contract
    @param flash_loan_token The flash loan token, if the operation used one
    """
    if flash_loan_token != empty(address):
        self._sweep(flash_loan_token)
    self._sweep(staticcall ITroveManager(trove_manager).collateral_token())
    self._sweep(staticcall ITroveManager(trove_manager).borrow_token())


@internal
def _sweep(token: address):
    """
    @notice Transfer the entire balance of a token held by this contract to the caller
    @param token The token to sweep
    """
    balance: uint256 = staticcall IERC20(token).balanceOf(self)
    if balance > 0:
        assert extcall IERC20(token).transfer(msg.sender, balance, default_return_value=True)
