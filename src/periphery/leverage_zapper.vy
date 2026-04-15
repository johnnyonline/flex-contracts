# @version 0.4.3

"""
@title Leverage Zapper
@license GNU AGPLv3
@author Flex
@notice Enables leveraged positions using Morpho flash loans and DEX aggregator swaps
@dev The Morpho contract address is hardcoded to the Ethereum mainnet deployment
"""

from ethereum.ercs import IERC20

from ..interfaces import IMorpho
from ..interfaces import IRegistry
from ..interfaces import ISwapExecutor
from ..interfaces import IZapperAuctionTaker
from ..interfaces import IDutchDesk
from ..interfaces import ITroveManager

# ============================================================================================
# Events
# ============================================================================================


event SetRouter:
    router: indexed(address)
    allowed: bool

event SetAuctionTaker:
    auction_taker: indexed(address)
    allowed: bool


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
    flash_loan_token: address
    auction_taker: address
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
    trove_manager: address
    flash_loan_token: address
    trove_id: uint256
    flash_loan_amount: uint256
    collateral_swap: SwapData
    debt_swap: SwapData


struct LeverUpData:
    trove_manager: address
    flash_loan_token: address
    auction_taker: address
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
_MAX_FLASHLOAN_CALLBACK_DATA_SIZE: constant(uint256) = 10 ** 5

# Flash loan provider
_MORPHO: constant(IMorpho) = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb)


# ============================================================================================
# Storage
# ============================================================================================


# Whitelists
routers: public(HashMap[address, bool])
auction_takers: public(HashMap[address, bool])


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


@external
def set_auction_taker(auction_taker: address, allowed: bool):
    """
    @notice Whitelist or remove an Auction Taker
    @dev Only callable by Daddy
    @param auction_taker The Auction Taker address
    @param allowed True to whitelist, False to remove
    """
    # Make sure the caller is Daddy
    assert msg.sender == DADDY, "bad daddy"

    # Update whitelist
    self.auction_takers[auction_taker] = allowed

    # Emit event
    log SetAuctionTaker(
        auction_taker=auction_taker,
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
    @dev If a redemption is triggered, an `auction_taker` should be provided.
         Otherwise, auction proceeds will be sent to this contract and may be swept by someone else
    @param data The open leveraged Trove parameters
    @return The Trove ID
    """
    # Validate input parameters
    self._validate_params(data.trove_manager, data.collateral_swap.router, data.debt_swap.router, data.auction_taker)

    # Pull collateral from the caller
    collateral_token: address = staticcall ITroveManager(data.trove_manager).collateral_token()
    assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, data.collateral_amount, default_return_value=True)

    # Initiate flash loan
    extcall _MORPHO.flashLoan(
        data.flash_loan_token,  # token
        data.flash_loan_amount,  # assets
        abi_encode(Operation.OPEN, data),  # data
    )

    # Compute the Trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(self, data.owner_index)), uint256)

    # Sweep any remaining flash loan tokens to caller
    self._sweep(data.flash_loan_token, msg.sender)

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
    self._validate_params(data.trove_manager, data.collateral_swap.router, data.debt_swap.router)

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

    # Get collateral and borrow tokens from the Trove Manager
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Sweep any remaining flash loan tokens to caller
    self._sweep(data.flash_loan_token, msg.sender)

    # Sweep any remaining collateral tokens to caller
    if collateral_token != data.flash_loan_token:
        self._sweep(collateral_token, msg.sender)

    # Sweep any remaining borrow tokens to caller
    if borrow_token != data.flash_loan_token and borrow_token != collateral_token:
        self._sweep(borrow_token, msg.sender)


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
    @dev If a redemption is triggered, an `auction_taker` should be provided.
         Otherwise, auction proceeds will be sent to this contract and may be swept by someone else
    @param data The lever up parameters
    """
    # Validate input parameters
    self._validate_params(data.trove_manager, data.collateral_swap.router, data.debt_swap.router, data.auction_taker)

    # Cache the Trove Manager instance
    trove_manager: ITroveManager = ITroveManager(data.trove_manager)

    # Get the Trove info
    trove: ITroveManager.Trove = staticcall trove_manager.troves(data.trove_id)

    # Make sure the caller is the Trove owner or an approved operator
    assert trove.owner == msg.sender or staticcall trove_manager.approved(trove.owner, msg.sender), "!owner"

    # Pull collateral from the caller
    collateral_token: address = staticcall trove_manager.collateral_token()
    if data.collateral_amount > 0:
        assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, data.collateral_amount, default_return_value=True)

    # Initiate flash loan
    extcall _MORPHO.flashLoan(
        data.flash_loan_token,  # token
        data.flash_loan_amount,  # assets
        abi_encode(Operation.LEVER_UP, data),  # data
    )

    # Sweep any remaining flash loan tokens to caller
    self._sweep(data.flash_loan_token, msg.sender)


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
    self._validate_params(data.trove_manager, data.collateral_swap.router, data.debt_swap.router)

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

    # Get collateral and borrow tokens from the Trove Manager
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Sweep any remaining flash loan tokens to caller
    self._sweep(data.flash_loan_token, msg.sender)

    # Sweep any remaining collateral tokens to caller
    if collateral_token != data.flash_loan_token:
        self._sweep(collateral_token, msg.sender)

    # Sweep any remaining borrow tokens to caller
    if borrow_token != data.flash_loan_token and borrow_token != collateral_token:
        self._sweep(borrow_token, msg.sender)


# ============================================================================================
# Flash loan callback
# ============================================================================================


@external
def onMorphoFlashLoan(
    assets: uint256,
    data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE],
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
    if operation == Operation.OPEN:
        flash_loan_token = self._handle_open(assets, data)
    elif operation == Operation.CLOSE:
        flash_loan_token = self._handle_close(assets, data)
    elif operation == Operation.LEVER_UP:
        flash_loan_token = self._handle_lever_up(assets, data)
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
def _handle_open(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]) -> address:
    """
    @notice Handle the open leveraged Trove operation inside the flash loan callback
    @param flash_loan_amount The amount that was flash loaned
    @param data The encoded parameters
    @return The flash loan token address
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: OpenLeveragedData = empty(OpenLeveragedData)
    operation, params = abi_decode(data, (Operation, OpenLeveragedData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Flash loan token --> collateral
    self._swap(params.collateral_swap, params.flash_loan_token, collateral_token, flash_loan_amount)

    # Get the available collateral
    available_collateral: uint256 = staticcall IERC20(collateral_token).balanceOf(self)

    # Approve spending of the collateral by the Trove Manager
    assert extcall IERC20(collateral_token).approve(params.trove_manager, available_collateral, default_return_value=True)

    # Record the Dutch Desk nonce before opening the Trove
    dutch_desk: IDutchDesk = IDutchDesk(staticcall trove_manager.dutch_desk())
    nonce_before: uint256 = staticcall dutch_desk.nonce()

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
        params.owner,
    )

    # Make sure our approval is always back to 0
    assert extcall IERC20(collateral_token).approve(params.trove_manager, 0, default_return_value=True)

    # Take the auction if one was kicked and an auction taker was provided
    if params.auction_taker != empty(address) and staticcall dutch_desk.nonce() > nonce_before:
        extcall IZapperAuctionTaker(params.auction_taker).takeAuction(staticcall dutch_desk.auction(), nonce_before)

    # Borrow token --> flash loan token
    borrow_token_balance: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    self._swap(params.debt_swap, borrow_token, params.flash_loan_token, borrow_token_balance)

    return params.flash_loan_token


@internal
def _handle_close(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]) -> address:
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
def _handle_lever_up(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]) -> address:
    """
    @notice Handle the lever up operation inside the flash loan callback
    @param flash_loan_amount The amount that was flash loaned
    @param data The encoded parameters
    @return The flash loan token address
    """
    # Decode parameters
    operation: Operation = empty(Operation)
    params: LeverUpData = empty(LeverUpData)
    operation, params = abi_decode(data, (Operation, LeverUpData))

    # Get collateral and borrow tokens from the Trove Manager
    trove_manager: ITroveManager = ITroveManager(params.trove_manager)
    collateral_token: address = staticcall trove_manager.collateral_token()
    borrow_token: address = staticcall trove_manager.borrow_token()

    # Flash loan token --> collateral
    self._swap(params.collateral_swap, params.flash_loan_token, collateral_token, flash_loan_amount)

    # Get the available collateral
    available_collateral: uint256 = staticcall IERC20(collateral_token).balanceOf(self)

    # Approve spending of the collateral by the Trove Manager
    assert extcall IERC20(collateral_token).approve(params.trove_manager, available_collateral, default_return_value=True)

    # Add collateral to the Trove
    extcall trove_manager.add_collateral(params.trove_id, available_collateral)

    # Make sure our approval is always back to 0
    assert extcall IERC20(collateral_token).approve(params.trove_manager, 0, default_return_value=True)

    # Record the Dutch Desk nonce before borrowing
    dutch_desk: IDutchDesk = IDutchDesk(staticcall trove_manager.dutch_desk())
    nonce_before: uint256 = staticcall dutch_desk.nonce()

    # Borrow additional debt
    extcall trove_manager.borrow(
        params.trove_id,
        params.debt_amount,
        params.max_upfront_fee,
        params.min_borrow_out,
        params.min_collateral_out,
    )

    # Take the auction if one was kicked and an auction taker was provided
    if params.auction_taker != empty(address) and staticcall dutch_desk.nonce() > nonce_before:
        extcall IZapperAuctionTaker(params.auction_taker).takeAuction(staticcall dutch_desk.auction(), nonce_before)

    # Borrow token --> flash loan token
    borrow_token_balance: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    self._swap(params.debt_swap, borrow_token, params.flash_loan_token, borrow_token_balance)

    return params.flash_loan_token


@internal
def _handle_lever_down(flash_loan_amount: uint256, data: Bytes[_MAX_FLASHLOAN_CALLBACK_DATA_SIZE]) -> address:
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
    collateral_swap_router: address,
    debt_swap_router: address,
    auction_taker: address = empty(address),
):
    """
    @notice Validate input parameters for the external functions
    @param trove_manager The Trove Manager address
    @param collateral_swap_router The collateral swap router address
    @param debt_swap_router The debt swap router address
    @param auction_taker The Auction Taker address
    """
    # Make sure the Trove Manager is endorsed
    assert staticcall REGISTRY.market_status(trove_manager) == IRegistry.Status.ENDORSED, "!endorsed"

    # If provided, make sure the collateral swap router is whitelisted
    if collateral_swap_router != empty(address):
        assert self.routers[collateral_swap_router], "!collateral_swap_router"
    
    # If provided, make sure the debt swap router is whitelisted
    if debt_swap_router != empty(address):
        assert self.routers[debt_swap_router], "!debt_swap_router"

    # If provided, make sure the Auction Taker is whitelisted
    if auction_taker != empty(address):
        assert self.auction_takers[auction_taker], "!auction_taker"


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
def _sweep(token: address, receiver: address):
    """
    @notice Transfer the entire balance of a token held by this contract to the `receiver`
    @param token The token to sweep
    @param receiver The receiver of the swept tokens
    """
    balance: uint256 = staticcall IERC20(token).balanceOf(self)
    if balance > 0:
        assert extcall IERC20(token).transfer(receiver, balance, default_return_value=True)
