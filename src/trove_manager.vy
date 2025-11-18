# @version 0.4.1

"""
@title Trove Manager
@license MIT
@author Flex
@notice Core contract that manages all Troves. Handles opening, closing, liquidating, and updating borrower positions,
        accrues interest, maintains aggregate debt accounting, and coordinates redemptions with the Lender
        and sorted_troves contracts
"""
# @todo -- decimals?
# @todo -- check round up thingy on `pending_agg_interest: uint256 = (self.total_weighted_deb.....`
# @todo -- finish tests...
# @todo -- liquidations
# @todo -- auction wishlist/dutch route

from ethereum.ercs import IERC20

from interfaces import ILiquidationHandler
from interfaces import IExchangeHandler
from interfaces import IPriceOracle
from interfaces import ISortedTroves


# ============================================================================================
# Events
# ============================================================================================


event PendingOwnershipTransfer:
    trove_id: indexed(uint256)
    old_owner: indexed(address)
    new_owner: indexed(address)

event OwnershipTransferred:
    trove_id: indexed(uint256)
    old_owner: indexed(address)
    new_owner: indexed(address)

event OpenTrove:
    trove_id: indexed(uint256)
    owner: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256
    upfront_fee: uint256
    annual_interest_rate: uint256

event AddCollateral:
    trove_id: indexed(uint256)
    owner: indexed(address)
    collateral_amount: uint256

event RemoveCollateral:
    trove_id: indexed(uint256)
    owner: indexed(address)
    collateral_amount: uint256

event Borrow:
    trove_id: indexed(uint256)
    owner: indexed(address)
    debt_amount: uint256
    upfront_fee: uint256

event Repay:
    trove_id: indexed(uint256)
    owner: indexed(address)
    debt_amount: uint256

event AdjustInterestRate:
    trove_id: indexed(uint256)
    owner: indexed(address)
    new_annual_interest_rate: uint256
    upfront_fee: uint256

event CloseTrove:
    trove_id: indexed(uint256)
    owner: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event CloseZombieTrove:
    trove_id: indexed(uint256)
    owner: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event LiquidateTrove:
    trove_id: indexed(uint256)
    liquidator: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event Redeem:
    redeemer: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256
    debt_amount_out: uint256


# ============================================================================================
# Flags
# ============================================================================================


flag Status:
    ACTIVE
    ZOMBIE
    CLOSED
    LIQUIDATED


# ============================================================================================
# Structs
# ============================================================================================


struct Trove:
    debt: uint256
    collateral: uint256
    annual_interest_rate: uint256
    last_debt_update_time: uint64
    last_interest_rate_adj_time: uint64
    owner: address
    pending_owner: address
    status: Status


# ============================================================================================
# Constants
# ============================================================================================


LENDER: public(immutable(address))

LIQUIDATION_HANDLER: public(immutable(ILiquidationHandler))
EXCHANGE_HANDLER: public(immutable(IExchangeHandler))
PRICE_ORACLE: public(immutable(IPriceOracle))
SORTED_TROVES: public(immutable(ISortedTroves))

BORROW_TOKEN: public(immutable(IERC20))
COLLATERAL_TOKEN: public(immutable(IERC20))

MINIMUM_COLLATERAL_RATIO: public(immutable(uint256))  # e.g., `110 * _ONE_PCT` for 110%

MIN_DEBT: public(constant(uint256)) = 500 * 10 ** 18
MIN_ANNUAL_INTEREST_RATE: public(constant(uint256)) = _ONE_PCT // 2  # 0.5%
MAX_ANNUAL_INTEREST_RATE: public(constant(uint256)) = 250 * _ONE_PCT  # 250%
UPFRONT_INTEREST_PERIOD: public(constant(uint256)) = 7 * 24 * 60 * 60  # 7 days
INTEREST_RATE_ADJ_COOLDOWN: public(constant(uint256)) = 7 * 24 * 60 * 60  # 7 days

_WAD: constant(uint256) = 10 ** 18
_ONE_PCT: constant(uint256) = _WAD // 100
_MAX_ITERATIONS: constant(uint256) = 1000
_MAX_LIQUIDATION_BATCH_SIZE: constant(uint256) = 50
_ONE_YEAR: constant(uint256) = 365 * 60 * 60 * 24


# ============================================================================================
# Storage
# ============================================================================================


# ID of a Trove that has been partially redeemed and is now a "zombie".
# We will continue redeeming this Trove first until it's fully redeemed
zombie_trove_id: public(uint256)

# Total outstanding system debt
total_debt: public(uint256)

# Sum of individual trove debts weighted by their annual interest rates
total_weighted_debt: public(uint256)

# Last timestamp when `total_debt` and `total_weighted_debt` were updated
last_debt_update_time: public(uint256)

# Total collateral tokens currently held by the contract
collateral_balance: public(uint256)

# Trove ID --> Trove info
troves: public(HashMap[uint256, Trove])


# ============================================================================================
# Constructor
# ============================================================================================


@deploy
def __init__(
    lender: address,
    liquidation_handler: address,
    exchange_handler: address,
    price_oracle: address,
    sorted_troves: address,
    borrow_token: address,
    collateral_token: address,
    minimum_collateral_ratio: uint256
):
    LENDER = lender
    LIQUIDATION_HANDLER = ILiquidationHandler(liquidation_handler)
    EXCHANGE_HANDLER = IExchangeHandler(exchange_handler)
    PRICE_ORACLE = IPriceOracle(price_oracle)
    SORTED_TROVES = ISortedTroves(sorted_troves)
    BORROW_TOKEN = IERC20(borrow_token)
    COLLATERAL_TOKEN = IERC20(collateral_token)
    MINIMUM_COLLATERAL_RATIO = minimum_collateral_ratio

    extcall COLLATERAL_TOKEN.approve(exchange_handler, max_value(uint256), default_return_value=True)


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def get_upfront_fee(debt_amount: uint256, annual_interest_rate: uint256) -> uint256:
    """
    @notice Calculate the upfront fee for borrowing a specified amount of debt at a given annual interest rate
    @dev The fee represents prepaid interest over `UPFRONT_INTEREST_PERIOD` using the system's average rate after the new debt
    @param debt_amount The amount of debt to be borrowed
    @param annual_interest_rate The annual interest rate for the debt
    @return upfront_fee The calculated upfront fee
    """
    return self._get_upfront_fee(debt_amount, annual_interest_rate)


@external
@view
def get_trove_debt_after_interest(trove_id: uint256) -> uint256:
    """
    @notice Calculate the Trove's debt after accruing interest
    @param trove_id Unique identifier of the Trove
    @return trove_debt_after_interest The Trove's debt after accruing interest
    """
    return self._get_trove_debt_after_interest(self.troves[trove_id])


# ============================================================================================
# Sync total debt
# ============================================================================================


@external
def sync_total_debt() -> uint256:
    """
    @notice Accrue interest on the total debt and return the updated figure
    @return The updated total debt after accruing interest
    """
    return self._sync_total_debt()


# ============================================================================================
# Ownership
# ============================================================================================


@external
def transfer_ownership(trove_id: uint256, new_owner: address):
    """
    @notice Starts the ownership transfer of a Trove to a new owner
    @dev Only callable by the current `owner`
    @dev Replaces the pending transfer if there is one
    @dev New owner must call `accept_ownership` to finalize the transfer
    @param trove_id Unique identifier of the Trove
    @param new_owner The address of the new owner
    """
    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Set the pending owner
    trove.pending_owner = new_owner

    # Save changes to storage
    self.troves[trove_id] = trove

    # Emit event
    log PendingOwnershipTransfer(
        trove_id=trove_id,
        old_owner=msg.sender,
        new_owner=new_owner
    )


@external
def accept_ownership(trove_id: uint256):
    """
    @notice Accept ownership of a Trove
    @dev Only callable by the current `pending_owner`
    @param trove_id Unique identifier of the Trove
    """
    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the pending owner of the Trove
    assert trove.pending_owner == msg.sender, "!pending_owner"

    # Cache the old owner for event
    old_owner: address = trove.owner

    # Set the new owner and clear the pending owner
    trove.owner = trove.pending_owner
    trove.pending_owner = empty(address)

    # Save changes to storage
    self.troves[trove_id] = trove

    # Emit event
    log OwnershipTransferred(
        trove_id=trove_id,
        old_owner=old_owner,
        new_owner=msg.sender
    )


@external
def force_transfer_ownership(trove_id: uint256, new_owner: address):
    """
    @notice Force transfer ownership of a Trove to a new owner
    @dev Only callable by the current `owner`
    @dev Does not require acceptance by the new owner
    @param trove_id Unique identifier of the Trove
    @param new_owner The address of the new owner
    """
    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Set the new owner
    trove.owner = new_owner

    # Save changes to storage
    self.troves[trove_id] = trove

    # Emit event
    log OwnershipTransferred(
        trove_id=trove_id,
        old_owner=msg.sender,
        new_owner=new_owner
    )


# ============================================================================================
# Open trove
# ============================================================================================


@external
def open_trove(
    owner_index: uint256,
    collateral_amount: uint256,
    debt_amount: uint256,
    prev_id: uint256,
    next_id: uint256,
    annual_interest_rate: uint256,
    max_upfront_fee: uint256,
    route_index: uint256,
    min_debt_out: uint256,
) -> uint256:
    """
    @notice Open a new Trove with specified collateral, debt, and interest rate
    @dev Caller will become the owner of the Trove
    @param owner_index Unique index to allow multiple Troves per caller
    @param collateral_amount Amount of collateral tokens to deposit
    @param debt_amount Amount of debt to issue before the upfront fee
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    @param annual_interest_rate Fixed annual interest rate to pay on the debt
    @param max_upfront_fee Maximum upfront fee the caller is willing to pay
    @param route_index Index of the exchange route to use
    @param min_debt_out Minimum amount of borrow tokens the caller is willing to receive
    @return trove_id Unique identifier for the new Trove
    """
    # Make sure collateral and debt amounts are non-zero
    assert collateral_amount > 0, "!collateral_amount"
    assert debt_amount > 0, "!debt_amount"

    # Make sure the annual interest rate is within bounds    
    assert annual_interest_rate >= MIN_ANNUAL_INTEREST_RATE, "!MIN_ANNUAL_INTEREST_RATE"
    assert annual_interest_rate <= MAX_ANNUAL_INTEREST_RATE, "!MAX_ANNUAL_INTEREST_RATE"

    # Generate the Trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(msg.sender, owner_index)), uint256)

    # Make sure the Trove status is empty
    assert self.troves[trove_id].status == empty(Status), "!empty"

    # Calculate the upfront fee and make sure the user is ok with it
    upfront_fee: uint256 = self._get_upfront_fee(debt_amount, annual_interest_rate, max_upfront_fee)

    # Record the debt with the upfront fee
    debt_amount_with_fee: uint256 = debt_amount + upfront_fee

    # Make sure enough debt is being borrowed
    assert debt_amount_with_fee > MIN_DEBT, "!MIN_DEBT"

    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Calculate the collateral ratio
    trove_collateral_ratio: uint256 = self._calculate_collateral_ratio(collateral_amount, debt_amount_with_fee, collateral_price)

    # Make sure the collateral ratio is above the minimum collateral ratio
    assert trove_collateral_ratio >= MINIMUM_COLLATERAL_RATIO, "!MINIMUM_COLLATERAL_RATIO"

    # Store the Trove info
    self.troves[trove_id] = Trove(
        debt=debt_amount_with_fee,
        collateral=collateral_amount,
        annual_interest_rate=annual_interest_rate,
        last_debt_update_time=convert(block.timestamp, uint64),
        last_interest_rate_adj_time=convert(block.timestamp, uint64),
        owner=msg.sender,
        pending_owner=empty(address),
        status=Status.ACTIVE
    )

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        debt_amount_with_fee, # debt_increase
        0, # debt_decrease
        0, # old_weighted_debt
        debt_amount_with_fee * annual_interest_rate, # new_weighted_debt
    )

    # Record the received collateral
    self.collateral_balance += collateral_amount

    # Add the Trove to the sorted troves list
    extcall SORTED_TROVES.insert(
        trove_id,
        annual_interest_rate,
        prev_id,
        next_id
    )

    # Pull the collateral tokens from caller
    extcall COLLATERAL_TOKEN.transferFrom(msg.sender, self, collateral_amount, default_return_value=True)

    # Deliver borrow tokens to the caller, redeem if liquidity is insufficient
    self._transfer_borrow_tokens(debt_amount, min_debt_out, route_index)

    # Emit event
    log OpenTrove(
        trove_id=trove_id,
        owner=msg.sender,
        collateral_amount=collateral_amount,
        debt_amount=debt_amount,
        upfront_fee=upfront_fee,
        annual_interest_rate=annual_interest_rate
    )

    return trove_id


# ============================================================================================
# Adjust trove
# ============================================================================================

# @todo -- rename collateral_change to collateral_amount...
@external
def add_collateral(trove_id: uint256, collateral_change: uint256):
    """
    @notice Add collateral to an existing Trove
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    @param collateral_change Amount of collateral tokens to add
    """
    # Make sure collateral amount is non-zero
    assert collateral_change > 0, "!collateral_change"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Update the Trove's collateral info
    self.troves[trove_id].collateral += collateral_change

    # Update the contract's recorded collateral balance
    self.collateral_balance += collateral_change

    # Pull the collateral tokens from caller
    extcall COLLATERAL_TOKEN.transferFrom(msg.sender, self, collateral_change, default_return_value=True)

    # Emit event
    log AddCollateral(
        trove_id=trove_id,
        owner=msg.sender,
        collateral_amount=collateral_change
    )

# @todo -- rename collateral_change to collateral_amount...
@external
def remove_collateral(trove_id: uint256, collateral_change: uint256):
    """
    @notice Remove collateral from an existing Trove
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    @param collateral_change Amount of collateral tokens to remove
    """
    # Make sure collateral amount is non-zero
    assert collateral_change > 0, "!collateral_change"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Make sure the Trove has enough collateral
    assert trove.collateral >= collateral_change, "!trove.collateral"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Calculate the new collateral amount and collateral ratio
    new_collateral: uint256 = trove.collateral - collateral_change
    collateral_ratio: uint256 = self._calculate_collateral_ratio(new_collateral, trove_debt_after_interest, collateral_price)

    # Make sure the new collateral ratio is above the minimum collateral ratio
    assert collateral_ratio >= MINIMUM_COLLATERAL_RATIO, "!MINIMUM_COLLATERAL_RATIO"

    # Update the Trove's collateral info
    self.troves[trove_id].collateral = new_collateral

    # Update the contract's recorded collateral balance
    self.collateral_balance -= collateral_change

    # Transfer the collateral tokens to caller
    extcall COLLATERAL_TOKEN.transfer(msg.sender, collateral_change, default_return_value=True)

    # Emit event
    log RemoveCollateral(
        trove_id=trove_id,
        owner=msg.sender,
        collateral_amount=collateral_change
    )


@external
def borrow(
    trove_id: uint256,
    debt_amount: uint256,
    max_upfront_fee: uint256,
    route_index: uint256,
    min_debt_out: uint256,
):
    """
    @notice Borrow more tokens from an existing Trove
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    @param debt_amount Amount of additional debt to issue before the upfront fee
    @param max_upfront_fee Maximum upfront fee the caller is willing to pay
    @param route_index Index of the exchange route to use
    @param min_debt_out Minimum amount of debt the caller is willing to receive
    """
    # Make sure debt amount is non-zero
    assert debt_amount > 0, "!debt_amount"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Calculate the upfront fee and make sure the user is ok with it
    upfront_fee: uint256 = self._get_upfront_fee(debt_amount, trove.annual_interest_rate, max_upfront_fee)

    # Record the debt with the upfront fee
    debt_amount_with_fee: uint256 = debt_amount + upfront_fee

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Calculate the new debt amount
    new_debt: uint256 = trove_debt_after_interest + debt_amount_with_fee

    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Calculate the collateral ratio
    collateral_ratio: uint256 = self._calculate_collateral_ratio(trove.collateral, new_debt, collateral_price)

    # Make sure the new collateral ratio is above the minimum collateral ratio
    assert collateral_ratio >= MINIMUM_COLLATERAL_RATIO, "!MINIMUM_COLLATERAL_RATIO"

    # Cache the Trove's old debt for global accounting
    old_debt: uint256 = trove.debt

    # Update the Trove's debt info
    trove.debt = new_debt
    trove.last_debt_update_time = convert(block.timestamp, uint64)

    # Save changes to storage
    self.troves[trove_id] = trove

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        debt_amount_with_fee, # debt_increase
        0, # debt_decrease
        old_debt * trove.annual_interest_rate, # old_weighted
        new_debt * trove.annual_interest_rate, # new_weighted_debt
    )

    # Deliver borrow tokens to the caller, redeem if liquidity is insufficient
    self._transfer_borrow_tokens(debt_amount, min_debt_out, route_index)

    # Emit event
    log Borrow(
        trove_id=trove_id,
        owner=msg.sender,
        debt_amount=new_debt,
        upfront_fee=upfront_fee
    )


@external
def repay(trove_id: uint256, debt_amount: uint256):
    """
    @notice Repay part of the debt of an existing Trove
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    @param debt_amount Amount of debt to repay
    """
    # Make sure debt amount is non-zero
    assert debt_amount > 0, "!debt_amount"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Calculate the maximum allowable repayment to keep the Trove above the minimum debt
    max_repayment: uint256 = trove_debt_after_interest - MIN_DEBT  # Assumes `trove_debt_after_interest > MIN_DEBT`

    # Scale down the repayment amount if necessary
    debt_to_repay: uint256 = min(debt_amount, max_repayment)

    # Calculate the new debt amount
    new_debt: uint256 = trove_debt_after_interest - debt_to_repay

    # Cache the Trove's old debt for global accounting
    old_debt: uint256 = trove.debt

    # Update the Trove's debt info
    trove.debt = new_debt
    trove.last_debt_update_time = convert(block.timestamp, uint64)

    # Save changes to storage
    self.troves[trove_id] = trove

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        0, # debt_increase
        debt_to_repay, # debt_decrease
        old_debt * trove.annual_interest_rate, # old_weighted_debt
        new_debt * trove.annual_interest_rate, # new_weighted_debt
    )

    # Pull the borrow tokens from caller and transfer them to the lender
    extcall BORROW_TOKEN.transferFrom(msg.sender, LENDER, debt_to_repay, default_return_value=True)

    # Emit event
    log Repay(
        trove_id=trove_id,
        owner=msg.sender,
        debt_amount=debt_to_repay
    )


@external
def adjust_interest_rate(
    trove_id: uint256,
    new_annual_interest_rate: uint256,
    prev_id: uint256,
    next_id: uint256,
    max_upfront_fee: uint256
):
    """
    @notice Adjust the annual interest rate of an existing Trove
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    @param new_annual_interest_rate New fixed annual interest rate to pay on the debt
    @param prev_id ID of previous Trove for the new insert position
    @param next_id ID of next Trove for the new insert position
    """
    # Make sure the new annual interest rate is within bounds
    assert new_annual_interest_rate >= MIN_ANNUAL_INTEREST_RATE, "!MIN_ANNUAL_INTEREST_RATE"
    assert new_annual_interest_rate <= MAX_ANNUAL_INTEREST_RATE, "!MAX_ANNUAL_INTEREST_RATE"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Make sure user is actually changing his rate
    assert new_annual_interest_rate != trove.annual_interest_rate, "!new_annual_interest_rate"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Initialize the new debt amount variable. We will charge an upfront fee only if the user is adjusting their rate prematurely
    new_debt: uint256 = trove_debt_after_interest

    # Initialize the upfront fee variable. We will need to increase the global debt by this amount if we charge it
    upfront_fee: uint256 = 0

    # Apply upfront fee on premature adjustments and check collateral ratio
    if block.timestamp < convert(trove.last_interest_rate_adj_time, uint256) + INTEREST_RATE_ADJ_COOLDOWN:
        # Calculate the upfront fee and make sure the user is ok with it
        upfront_fee = self._get_upfront_fee(new_debt, new_annual_interest_rate, max_upfront_fee)

        # Charge the upfront fee
        new_debt += upfront_fee

        # Get the collateral price
        collateral_price: uint256 = staticcall PRICE_ORACLE.price()

        # Calculate the collateral ratio
        collateral_ratio: uint256 = self._calculate_collateral_ratio(trove.collateral, new_debt, collateral_price)

        # Make sure the new collateral ratio is above the minimum collateral ratio
        assert collateral_ratio >= MINIMUM_COLLATERAL_RATIO, "!MINIMUM_COLLATERAL_RATIO"

    # Cache the Trove's old debt and interest rate for global accounting
    old_debt: uint256 = trove.debt
    old_annual_interest_rate: uint256 = trove.annual_interest_rate

    # Update the Trove's interest rate and last adjustment time
    trove.annual_interest_rate = new_annual_interest_rate
    trove.last_interest_rate_adj_time = convert(block.timestamp, uint64)

    # Update the Trove's debt info to reflect accrued interest
    trove.debt = new_debt
    trove.last_debt_update_time = convert(block.timestamp, uint64)

    # Save changes to storage
    self.troves[trove_id] = trove

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        upfront_fee, # debt_increase
        0, # debt_decrease
        old_debt * old_annual_interest_rate, # old_weighted_debt
        new_debt * new_annual_interest_rate # new_weighted_debt
    )

    # Reinsert the Trove in the sorted list at its new position
    extcall SORTED_TROVES.re_insert(
        trove_id,
        new_annual_interest_rate,
        prev_id,
        next_id
    )

    # Emit event
    log AdjustInterestRate(
        trove_id=trove_id,
        owner=msg.sender,
        new_annual_interest_rate=new_annual_interest_rate,
        upfront_fee=upfront_fee
    )


# ============================================================================================
# Close trove
# ============================================================================================

# @todo -- here -- tests
@external
def close_trove(trove_id: uint256):
    """
    @notice Close an existing Trove by repaying all its debt and withdrawing all its collateral
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    """
    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Cache the Trove's old info for global accounting
    old_trove: Trove = trove

    # Delete all Trove info and mark it as closed
    trove = empty(Trove)
    trove.status = Status.CLOSED

    # Save changes to storage
    self.troves[trove_id] = trove

    # Update the contract's recorded collateral balance
    self.collateral_balance -= old_trove.collateral

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        0, # debt_increase
        trove_debt_after_interest, # debt_decrease
        old_trove.debt * old_trove.annual_interest_rate, # old_weighted_debt
        0 # new_weighted_debt
    )

    # Remove from sorted list
    extcall SORTED_TROVES.remove(trove_id)

    # Pull the borrow tokens from caller and transfer them to the lender
    extcall BORROW_TOKEN.transferFrom(msg.sender, LENDER, trove_debt_after_interest, default_return_value=True)

    # Transfer the collateral tokens to caller
    extcall COLLATERAL_TOKEN.transfer(msg.sender, old_trove.collateral, default_return_value=True)

    # Emit event
    log CloseTrove(
        trove_id=trove_id,
        owner=msg.sender,
        collateral_amount=old_trove.collateral,
        debt_amount=trove_debt_after_interest
    )


@external
def close_zombie_trove(trove_id: uint256):
    """
    @notice Close a zombie Trove by repaying all its debt (if it has any) and withdrawing all its collateral
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    """
    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is zombie
    assert trove.status == Status.ZOMBIE, "!zombie"

    # Cache the Trove's old info for global accounting
    old_trove: Trove = trove

    # Delete all Trove info and mark it as closed
    trove = empty(Trove)
    trove.status = Status.CLOSED

    # Save changes to storage
    self.troves[trove_id] = trove

    # If Trove is the current zombie trove, reset the `zombie_trove_id` variable
    if self.zombie_trove_id == trove_id:
        self.zombie_trove_id = 0

    # Update the contract's recorded collateral balance
    self.collateral_balance -= old_trove.collateral

    # Initialize the Trove's debt after interest variable
    trove_debt_after_interest: uint256 = 0

    if old_trove.debt > 0:
        # Get the Trove's debt after accruing interest
        trove_debt_after_interest = self._get_trove_debt_after_interest(old_trove)

        # Accrue interest on the total debt and update accounting
        self._accrue_interest_and_account_for_trove_change(
            0, # debt_increase
            trove_debt_after_interest, # debt_decrease
            old_trove.debt * old_trove.annual_interest_rate, # old_weighted_debt
            0 # new_weighted_debt
        )

        # Pull the borrow tokens from caller and transfer them to the lender
        extcall BORROW_TOKEN.transferFrom(msg.sender, LENDER, trove_debt_after_interest, default_return_value=True)

    # Transfer the collateral tokens to caller
    extcall COLLATERAL_TOKEN.transfer(msg.sender, old_trove.collateral, default_return_value=True)

    # Emit event
    log CloseZombieTrove(
        trove_id=trove_id,
        owner=msg.sender,
        collateral_amount=old_trove.collateral,
        debt_amount=trove_debt_after_interest
    )


# ============================================================================================
# Liquidate trove
# ============================================================================================


@external
def liquidate_troves(trove_ids: uint256[_MAX_LIQUIDATION_BATCH_SIZE]):
    """
    @notice Liquidate a list of unhealthy Troves
    @dev Uses the `liquidation_handler` contract to sell the collateral tokens
    @param trove_ids List of unique identifiers of the unhealthy Troves
    """
    # Cache the current zombie trove id to avoid multiple SLOADs
    current_zombie_trove_id: uint256 = self.zombie_trove_id

    # Cache the collateral price to avoid multiple external calls
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Initialize variables to track total changes
    total_collateral_to_decrease: uint256 = 0
    total_debt_to_decrease: uint256 = 0
    total_weighted_debt_to_decrease: uint256 = 0

    # Iterate over the Troves and liquidate them one by one
    for trove_id: uint256 in trove_ids:
        if trove_id == 0:
            break

        # Initialize variables to capture individual trove liquidation results
        collateral_to_decrease: uint256 = 0
        debt_to_decrease: uint256 = 0
        weighted_debt_decrease: uint256 = 0

        # Liquidate the single Trove and get the changes
        (
            collateral_to_decrease,
            debt_to_decrease,
            weighted_debt_decrease
        ) = self._liquidate_single_trove(trove_id, current_zombie_trove_id, collateral_price)

        # Accumulate the total changes
        total_collateral_to_decrease += collateral_to_decrease
        total_debt_to_decrease += debt_to_decrease
        total_weighted_debt_to_decrease += weighted_debt_decrease

    # Update the contract's recorded collateral balance
    self.collateral_balance -= total_collateral_to_decrease

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        0, # debt_increase
        total_debt_to_decrease, # debt_decrease
        total_weighted_debt_to_decrease, # old_weighted_debt
        0 # new_weighted_debt
    )

    # Transfer collateral tokens to the liquidation handler for selling. Proceeds will be sent to the lender
    extcall COLLATERAL_TOKEN.transfer(LIQUIDATION_HANDLER.address, total_collateral_to_decrease, default_return_value=True)

    # Notify the liquidation handler of the liquidation. It will handle selling the collateral and transferring proceeds to the lender
    extcall LIQUIDATION_HANDLER.process(total_collateral_to_decrease, total_debt_to_decrease, msg.sender)


@internal
def _liquidate_single_trove(trove_id: uint256, current_zombie_trove_id: uint256, collateral_price: uint256) -> (uint256, uint256, uint256):
    """
    @notice Internal function to liquidate a single unhealthy Trove
    @dev Does not update global accounting or handle token transfers
    @param trove_id Unique identifier of the Trove
    @param current_zombie_trove_id Current zombie trove id
    @param collateral_price Current collateral price
    @return collateral_to_decrease Amount of collateral to subtract from the total collateral
    @return debt_to_decrease Amount of debt to subtract from the total debt
    @return weighted_debt_decrease Amount of weighted debt to subtract from the total weighted debt
    """
    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the Trove is active or zombie
    assert trove.status == Status.ACTIVE or trove.status == Status.ZOMBIE, "!active or zombie"

    # Make sure trove has debt
    assert trove.debt > 0, "!debt"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Calculate the collateral ratio
    collateral_ratio: uint256 = self._calculate_collateral_ratio(trove.collateral, trove_debt_after_interest, collateral_price)

    # Make sure the collateral ratio is below the minimum collateral ratio
    assert collateral_ratio < MINIMUM_COLLATERAL_RATIO, ">=MCR"

    # Cache the Trove's old info for global accounting
    old_trove: Trove = trove

    # Delete all Trove info and mark it as liquidated
    trove = empty(Trove)
    trove.status = Status.LIQUIDATED

    # Save changes to storage
    self.troves[trove_id] = trove

    # If Trove is the current zombie trove, reset the `zombie_trove_id` variable
    if current_zombie_trove_id == trove_id:
        self.zombie_trove_id = 0

    # Remove from sorted list if it was active
    if old_trove.status == Status.ACTIVE:
        extcall SORTED_TROVES.remove(trove_id)

    # Emit event
    log LiquidateTrove(
        trove_id=trove_id,
        liquidator=msg.sender,
        collateral_amount=old_trove.collateral,
        debt_amount=trove_debt_after_interest,
    )

    return (
        old_trove.collateral,  # collateral_to_decrease
        trove_debt_after_interest,  # debt_to_decrease
        old_trove.debt * old_trove.annual_interest_rate  # weighted_debt_decrease
    )


# ============================================================================================
# Redeem
# ============================================================================================


@external
def redeem(amount: uint256, route_index: uint256) -> uint256:
    """
    @notice Attempt to free the specified amount of borrow tokens by selling collateral
    @dev Can only be called by the Lender contract
    @dev Swap sandwich protection is the caller's responsibility
    @param amount Desired amount of borrow tokens to free
    @param route_index Index of the exchange route to use
    @return amount The actual amount of borrow tokens freed
    """
    # Make sure the caller is the lender
    assert msg.sender == LENDER, "!lender"

    # Attempt to redeem the specified amount and transfer the resulting borrow tokens to the lender
    return self._redeem(amount, route_index)


@internal
def _redeem(amount: uint256, route_index: uint256) -> uint256:
    """
    @notice Internal implementation of `redeem`
    @dev Swap sandwich protection is the caller's responsibility
    @param amount Target amount of borrow tokens to free
    @param route_index Index of the exchange route to use
    @return amount The actual amount of borrow tokens freed
    """
    # Accrue interest on the total debt and get the updated figure
    self._sync_total_debt()

    # Get the collateral price
    collateral_price: uint256 = staticcall PRICE_ORACLE.price()

    # Initialize the `is_zombie_trove` flag
    is_zombie_trove: bool = False

    # Initialize the Trove to redeem variable
    trove_to_redeem: uint256 = self.zombie_trove_id

    # Use zombie Trove from previous redemption if it exists. Otherwise get the Trove with the lowest interest rate
    if trove_to_redeem != 0:
        is_zombie_trove = True
    else:
        trove_to_redeem = staticcall SORTED_TROVES.last()

    # Cache the amount of debt we need to free
    remaining_debt_to_free: uint256 = amount

    # Cache the total changes we're making so that later we can update the accounting
    total_debt_decrease: uint256 = 0
    total_collateral_decrease: uint256 = 0
    total_new_weighted_debt: uint256 = 0
    total_old_weighted_debt: uint256 = 0

    # Loop through as many Troves as we're allowed or until we redeem all the debt we need
    for _: uint256 in range(_MAX_ITERATIONS):
        # Cache Trove info
        trove: Trove = self.troves[trove_to_redeem]

        # Don't want to redeem a borrower's own Trove
        if msg.sender != trove.owner:
            # Get the Trove's debt after accruing interest
            trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

            # Determine the amount to be freed
            debt_to_free: uint256 = min(remaining_debt_to_free, trove_debt_after_interest)

            # Calculate the Trove's new debt amount
            trove_new_debt: uint256 = trove_debt_after_interest - debt_to_free

            # If trove would be left with debt below the minimum, go zombie
            if trove_new_debt < MIN_DEBT:
                # If the trove is not already a zombie trove, we need to mark it as such
                if not is_zombie_trove:
                    # Mark trove as zombie
                    trove.status = Status.ZOMBIE

                    # Remove trove from sorted list
                    extcall SORTED_TROVES.remove(trove_to_redeem)

                    # If it's a partial redemption, record it so we know to continue with it next time
                    if trove_new_debt > 0:
                        self.zombie_trove_id = trove_to_redeem

                # If we fully redeemed a zombie trove, reset the `zombie_trove_id` variable
                elif trove_new_debt == 0:
                    self.zombie_trove_id = 0

            # Get the amount of collateral equal to `debt_to_free`
            collateral_to_redeem: uint256 = debt_to_free * _WAD // collateral_price

            # Calculate the Trove's new collateral amount
            trove_new_collateral: uint256 = trove.collateral - collateral_to_redeem

            # Calculate the Trove's old and new weighted debt
            trove_old_weighted_debt: uint256 = trove.debt * trove.annual_interest_rate
            trove_new_weighted_debt: uint256 = trove_new_debt * trove.annual_interest_rate

            # Update the Trove's info
            trove.debt = trove_new_debt
            trove.collateral = trove_new_collateral
            trove.last_debt_update_time = convert(block.timestamp, uint64)

            # Save changes to storage
            self.troves[trove_to_redeem] = trove

            # Increment the total debt and collateral decrease
            total_debt_decrease += debt_to_free
            total_collateral_decrease += collateral_to_redeem

            # Increment the total old and new weighted debt
            total_old_weighted_debt += trove_old_weighted_debt
            total_new_weighted_debt += trove_new_weighted_debt

            # Update the remaining debt to free
            remaining_debt_to_free -= min(debt_to_free, remaining_debt_to_free)

            # Check if we freed all the debt we wanted
            if remaining_debt_to_free == 0:
                break

        # Get the next trove to redeem
        trove_to_redeem = staticcall SORTED_TROVES.last() if is_zombie_trove else staticcall SORTED_TROVES.prev(trove_to_redeem)

        # If we reached the end of the list, break
        if trove_to_redeem == 0:
            break

        # Reset the `is_zombie_trove` flag
        is_zombie_trove = False

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        0, # debt_increase
        total_debt_decrease, # debt_decrease
        total_old_weighted_debt, # old_weighted_debt
        total_new_weighted_debt, # new_weighted_debt
    )

    # Update the contract's recorded collateral balance
    self.collateral_balance -= total_collateral_decrease

    # Swap the collateral to borrow token and transfer it to the caller. Does nothing on zero amount
    borrow_token_out: uint256 = extcall EXCHANGE_HANDLER.swap(total_collateral_decrease, route_index, msg.sender)

    # Emit event
    log Redeem(
        redeemer=msg.sender,
        collateral_amount=total_collateral_decrease,
        debt_amount=total_debt_decrease,
        debt_amount_out=borrow_token_out
    )

    return borrow_token_out


# ============================================================================================
# Internal pure functions
# ============================================================================================


@internal
@pure
def _calculate_collateral_ratio(collateral: uint256, debt: uint256, collateral_price: uint256) -> uint256:
    """
    @notice Calculate the collateral ratio given collateral, debt, and collateral price
    @param collateral The amount of collateral tokens
    @param debt The amount of debt
    @param collateral_price The price of one collateral token
    @return collateral_ratio The collateral ratio
    """
    return collateral * collateral_price // debt


@internal
@pure
def _calculate_accrued_interest(weighted_debt: uint256, period: uint256) -> uint256:
    """
    @notice Calculate the interest accrued on weighted debt over a given period
    @param weighted_debt The debt weighted by the annual interest rate
    @param period The time period over which interest is calculated (in seconds)
    @return interest The interest accrued over the period
    """
    return weighted_debt * period // _ONE_YEAR // _WAD


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _get_upfront_fee(
    debt_amount: uint256,
    annual_interest_rate: uint256,
    max_upfront_fee: uint256 = max_value(uint256)
) -> uint256:
    """
    @notice Calculate the upfront fee for borrowing a specified amount of debt at a given annual interest rate
    @dev Make sure the calculated fee does not exceed `max_upfront_fee`
    @dev The fee represents prepaid interest over `UPFRONT_INTEREST_PERIOD` using the system's average rate after the new debt
    @param debt_amount The amount of debt to be borrowed
    @param annual_interest_rate The annual interest rate for the debt
    @param max_upfront_fee The maximum upfront fee the caller is willing to pay
    @return upfront_fee The calculated upfront fee
    """
    # Total debt after adding the new debt
    new_total_debt: uint256 = self.total_debt + debt_amount

    # Total weighted debt after adding the new weighted debt
    new_total_weighted_debt: uint256 = self.total_weighted_debt + (debt_amount * annual_interest_rate)

    # Calculate the new average interest rate
    avg_interest_rate: uint256 = new_total_weighted_debt // new_total_debt

    # Calculate the upfront fee using the average interest rate
    upfront_fee: uint256 = self._calculate_accrued_interest(debt_amount * avg_interest_rate, UPFRONT_INTEREST_PERIOD)

    # Make sure the user is ok with the upfront fee
    assert upfront_fee <= max_upfront_fee, "!max_upfront_fee"

    return upfront_fee


@internal
@view
def _get_trove_debt_after_interest(trove: Trove) -> uint256:
    """
    @notice Calculate the Trove's debt after accruing interest
    @param trove The Trove struct
    @return trove_debt_after_interest The Trove's debt after accruing interest
    """
    return trove.debt + self._calculate_accrued_interest(
        trove.debt * trove.annual_interest_rate,  # trove_weighted_debt
        block.timestamp - convert(trove.last_debt_update_time, uint256)  # period since last update
    )


# ============================================================================================
# Internal mutative functions
# ============================================================================================

# @todo -- rename `old_weighted_debt` to `weighted_debt_decrease` and `new_weighted_debt` to `weighted_debt_increase`
@internal
def _accrue_interest_and_account_for_trove_change(
    debt_increase: uint256,
    debt_decrease: uint256,
    old_weighted_debt: uint256,
    new_weighted_debt: uint256
):
    """
    @notice Accrue interest on the total debt and update total debt and total weighted debt accounting
    @param debt_increase Amount of debt to add to the total debt
    @param debt_decrease Amount of debt to subtract from the total debt
    @param old_weighted_debt Amount of weighted debt to subtract from the total weighted debt
    @param new_weighted_debt Amount of weighted debt to add to the total weighted debt
    """
    # Update total debt
    new_total_debt: uint256 = self._sync_total_debt()
    new_total_debt += debt_increase
    new_total_debt -= debt_decrease
    self.total_debt = new_total_debt

    # Update total weighted debt
    new_total_weighted_debt: uint256 = self.total_weighted_debt
    new_total_weighted_debt += new_weighted_debt
    new_total_weighted_debt -= old_weighted_debt
    self.total_weighted_debt = new_total_weighted_debt


@internal
def _sync_total_debt() -> uint256:
    """
    @notice Accrue interest on the total debt and return the updated figure
    @return new_total_debt The updated total debt after accruing interest
    """
    # Calculate the pending aggregate interest
    pending_agg_interest: uint256 = (self.total_weighted_debt * (block.timestamp - self.last_debt_update_time)) // (_ONE_YEAR * _WAD)

    # Calculate the new total debt after interest
    new_total_debt: uint256 = self.total_debt + pending_agg_interest

    # Update the total debt
    self.total_debt = new_total_debt

    # Update the last debt update time
    self.last_debt_update_time = block.timestamp

    return new_total_debt


@internal
def _transfer_borrow_tokens(amount: uint256, min_out: uint256, route_index: uint256):
    """
    @notice Transfer borrow tokens to the caller, redeeming from borrowers if necessary
    @param amount Amount of borrow tokens to transfer
    @param min_out Minimum amount of borrow tokens the caller is willing to receive
    @param route_index Index of the exchange route to use
    """
    # Check how much borrow token liquidity the lender has
    available_liquidity: uint256 = staticcall BORROW_TOKEN.balanceOf(LENDER)

    # Cache the amount of borrow tokens that we were able to transfer
    amount_out: uint256 = 0

    # If there's not enough liquidity, redeem the difference. Otherwise just transfer the full amount
    if amount > available_liquidity:
        # Transfer whatever we have first
        if available_liquidity > 0:
            extcall BORROW_TOKEN.transferFrom(LENDER, msg.sender, available_liquidity, default_return_value=True)

        # Redeem the difference
        amount_out_of_redeem: uint256 = self._redeem(amount - available_liquidity, route_index)

        # Total amount we were able to transfer
        amount_out = amount_out_of_redeem + available_liquidity
    else:
        # We are able to transfer the full amount
        amount_out = amount

        # Transfer the full amount
        extcall BORROW_TOKEN.transferFrom(LENDER, msg.sender, amount, default_return_value=True)

    # Make sure the user is ok with the amount of borrow tokens he got
    assert amount_out >= min_out, "shrekt"