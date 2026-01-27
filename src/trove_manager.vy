# @version 0.4.3

"""
@title Trove Manager
@license MIT
@author Flex
@notice Core contract that manages all Troves. Handles opening, closing, liquidating, and updating borrower positions,
        accrues interest, maintains aggregate debt accounting, and coordinates redemptions with the Lender,
        Sorted Troves and Dutch Desk contracts
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC20Detailed

from snekmate.utils import math

from interfaces import IDutchDesk
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
    trove_owner: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256
    upfront_fee: uint256
    annual_interest_rate: uint256

event AddCollateral:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    collateral_amount: uint256

event RemoveCollateral:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    collateral_amount: uint256

event Borrow:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    debt_amount: uint256
    upfront_fee: uint256

event Repay:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    debt_amount: uint256

event AdjustInterestRate:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    new_annual_interest_rate: uint256
    upfront_fee: uint256

event CloseTrove:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event CloseZombieTrove:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event LiquidateTrove:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    liquidator: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event RedeemTrove:
    trove_id: indexed(uint256)
    trove_owner: indexed(address)
    redeemer: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256

event Redeem:
    redeemer: indexed(address)
    collateral_amount: uint256
    debt_amount: uint256


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


_PRICE_ORACLE_PRECISION: constant(uint256) = 10 ** 36
_WAD: constant(uint256) = 10 ** 18
_MAX_ITERATIONS: constant(uint256) = 700
_ONE_YEAR: constant(uint256) = 365 * 60 * 60 * 24
_REDEMPTION_AUCTION: constant(bool) = False


# ============================================================================================
# Storage
# ============================================================================================


# Contracts
lender: public(address)
dutch_desk: public(IDutchDesk)
price_oracle: public(IPriceOracle)
sorted_troves: public(ISortedTroves)

# Tokens
borrow_token: public(IERC20)
collateral_token: public(IERC20)

# Parameters
one_pct: public(uint256)
borrow_token_precision: public(uint256)
min_debt: public(uint256)  # in borrow token precision
minimum_collateral_ratio: public(uint256)  # e.g., `110 * one_pct` for 110%
min_annual_interest_rate: public(uint256) # e.g., `0.5 * one_pct` for 0.5%
max_annual_interest_rate: public(uint256) # e.g., `250 * one_pct` for 250%
upfront_interest_period: public(uint256)  # e.g., `7 * 24 * 60 * 60` for 7 days
interest_rate_adj_cooldown: public(uint256)  # e.g., `7 * 24 * 60 * 60` for 7 days

# Accounting
zombie_trove_id: public(uint256)  # partially redeemed Trove ID; prioritized for continued redemption until fully redeemed
total_debt: public(uint256)  # total outstanding system debt
total_weighted_debt: public(uint256)  # sum of individual trove debts weighted by their annual interest rates
last_debt_update_time: public(uint256)  # last timestamp when `total_debt` and `total_weighted_debt` were updated
collateral_balance: public(uint256)  # total collateral tokens currently held by the contract
troves: public(HashMap[uint256, Trove])  # Trove ID --> Trove info


# ============================================================================================
# Initialize
# ============================================================================================


@external
def initialize(
    lender: address,
    dutch_desk: address,
    price_oracle: address,
    sorted_troves: address,
    borrow_token: address,
    collateral_token: address,
    minimum_collateral_ratio: uint256
):
    """
    @notice Initialize the contract
    @param lender Address of the Lender contract
    @param dutch_desk Address of the Dutch Desk contract
    @param price_oracle Address of the Price Oracle contract
    @param sorted_troves Address of the Sorted Troves contract
    @param borrow_token Address of the borrow token
    @param collateral_token Address of the collateral token
    @param minimum_collateral_ratio Minimum collateral ratio for Troves
    """
    # Make sure the contract is not already initialized
    assert self.lender == empty(address), "initialized"

    # Set contract addresses
    self.lender = lender
    self.dutch_desk = IDutchDesk(dutch_desk)
    self.price_oracle = IPriceOracle(price_oracle)
    self.sorted_troves = ISortedTroves(sorted_troves)

    # Set token addresses
    self.borrow_token = IERC20(borrow_token)
    self.collateral_token = IERC20(collateral_token)

    # Borrow token precision cannot be more than WAD
    borrow_token_precision: uint256 = 10 ** convert(staticcall IERC20Detailed(borrow_token).decimals(), uint256)
    assert borrow_token_precision <= _WAD, "!borrow_token"

    # Define 1% using borrow token precision
    one_pct: uint256 = borrow_token_precision // 100

    # Set market parameters
    self.one_pct = one_pct
    self.borrow_token_precision = borrow_token_precision
    self.min_debt = 500 * borrow_token_precision  # 500 borrow tokens
    self.minimum_collateral_ratio = minimum_collateral_ratio * one_pct
    self.min_annual_interest_rate = one_pct // 2  # 0.5%
    self.max_annual_interest_rate = 250 * one_pct  # 250%
    self.upfront_interest_period = 7 * 24 * 60 * 60  # 7 days
    self.interest_rate_adj_cooldown = 7 * 24 * 60 * 60  # 7 days

    # Max approve the collateral token to the dutch desk
    assert extcall IERC20(collateral_token).approve(dutch_desk, max_value(uint256), default_return_value=True)


# ============================================================================================
# External view functions
# ============================================================================================


@external
@view
def get_upfront_fee(debt_amount: uint256, annual_interest_rate: uint256) -> uint256:
    """
    @notice Get the upfront fee for borrowing a specified amount of debt at a given annual interest rate
    @dev The fee represents prepaid interest over upfront interest period using the system's average rate after the new debt
    @param debt_amount The amount of debt to be borrowed
    @param annual_interest_rate The annual interest rate for the debt
    @return upfront_fee The calculated upfront fee
    """
    return self._get_upfront_fee(debt_amount, annual_interest_rate)


@external
@view
def get_trove_debt_after_interest(trove_id: uint256) -> uint256:
    """
    @notice Get the Trove's debt after accruing interest
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
    @return new_total_debt The updated total debt after accruing interest
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
    min_debt_out: uint256,
    min_collateral_out: uint256,
) -> uint256:
    """
    @notice Open a new Trove with specified collateral, debt, and interest rate
    @dev Caller will become the owner of the Trove
    @dev Caller must approve this contract to transfer collateral tokens on its behalf before calling
    @dev Trove debt increases by `debt_amount` plus the upfront fee. Tokens from idle liquidity arrive
         atomically; any shortfall is redeemed from other troves and airdropped on auction settlement.
         Total delivered can be less than requested if lender liquidity or redeemable collateral are insufficient
    @param owner_index Unique index to allow multiple Troves per caller
    @param collateral_amount Amount of collateral tokens to deposit
    @param debt_amount Amount of debt to issue before the upfront fee
    @param prev_id ID of previous Trove for the insert position
    @param next_id ID of next Trove for the insert position
    @param annual_interest_rate Fixed annual interest rate to pay on the debt
    @param max_upfront_fee Maximum upfront fee the caller is willing to pay
    @param min_debt_out Minimum amount of debt tokens to be received atomically from idle liquidity
    @param min_collateral_out Minimum amount of collateral tokens to be redeemed
    @return trove_id Unique identifier for the new Trove
    """
    # Make sure collateral and debt amounts are non-zero
    assert collateral_amount > 0, "!collateral_amount"
    assert debt_amount > 0, "!debt_amount"

    # Make sure the annual interest rate is within bounds
    assert annual_interest_rate >= self.min_annual_interest_rate, "!min_annual_interest_rate"
    assert annual_interest_rate <= self.max_annual_interest_rate, "!max_annual_interest_rate"

    # Generate the Trove ID
    trove_id: uint256 = convert(keccak256(abi_encode(msg.sender, owner_index)), uint256)

    # Make sure the Trove status is empty
    assert self.troves[trove_id].status == empty(Status), "!empty"

    # Calculate the upfront fee and make sure the user is ok with it
    upfront_fee: uint256 = self._get_upfront_fee(debt_amount, annual_interest_rate, max_upfront_fee)

    # Record the debt with the upfront fee
    debt_amount_with_fee: uint256 = debt_amount + upfront_fee

    # Make sure enough debt is being borrowed
    assert debt_amount_with_fee > self.min_debt, "!min_debt"

    # Get the collateral price
    collateral_price: uint256 = staticcall self.price_oracle.get_price()

    # Calculate the collateral ratio
    trove_collateral_ratio: uint256 = self._calculate_collateral_ratio(
        collateral_amount, debt_amount_with_fee, collateral_price
    )

    # Make sure the collateral ratio is above the minimum collateral ratio
    assert trove_collateral_ratio >= self.minimum_collateral_ratio, "!minimum_collateral_ratio"

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
        debt_amount_with_fee * annual_interest_rate, # weighted_debt_increase
        0, # weighted_debt_decrease
    )

    # Record the received collateral
    self.collateral_balance += collateral_amount

    # Add the Trove to the sorted troves list
    extcall self.sorted_troves.insert(
        trove_id,
        annual_interest_rate,
        prev_id,
        next_id
    )

    # Pull the collateral tokens from caller
    assert extcall self.collateral_token.transferFrom(msg.sender, self, collateral_amount, default_return_value=True)

    # Deliver borrow tokens to the caller, redeem if liquidity is insufficient
    self._transfer_borrow_tokens(debt_amount, annual_interest_rate, min_debt_out, min_collateral_out)

    # Emit event
    log OpenTrove(
        trove_id=trove_id,
        trove_owner=msg.sender,
        collateral_amount=collateral_amount,
        debt_amount=debt_amount,
        upfront_fee=upfront_fee,
        annual_interest_rate=annual_interest_rate
    )

    return trove_id


# ============================================================================================
# Adjust trove
# ============================================================================================


@external
def add_collateral(trove_id: uint256, collateral_amount: uint256):
    """
    @notice Add collateral to an existing Trove
    @dev Only callable by the Trove owner
    @dev Caller must approve this contract to transfer collateral tokens on its behalf before calling
    @param trove_id Unique identifier of the Trove
    @param collateral_amount Amount of collateral tokens to add
    """
    # Make sure collateral amount is non-zero
    assert collateral_amount > 0, "!collateral_amount"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Update the Trove's collateral info
    self.troves[trove_id].collateral += collateral_amount

    # Update the contract's recorded collateral balance
    self.collateral_balance += collateral_amount

    # Pull the collateral tokens from caller
    assert extcall self.collateral_token.transferFrom(msg.sender, self, collateral_amount, default_return_value=True)

    # Emit event
    log AddCollateral(
        trove_id=trove_id,
        trove_owner=msg.sender,
        collateral_amount=collateral_amount
    )


@external
def remove_collateral(trove_id: uint256, collateral_amount: uint256):
    """
    @notice Remove collateral from an existing Trove
    @dev Only callable by the Trove owner
    @param trove_id Unique identifier of the Trove
    @param collateral_amount Amount of collateral tokens to remove
    """
    # Make sure collateral amount is non-zero
    assert collateral_amount > 0, "!collateral_amount"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Make sure the Trove has enough collateral
    assert trove.collateral >= collateral_amount, "!trove.collateral"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Get the collateral price
    collateral_price: uint256 = staticcall self.price_oracle.get_price()

    # Calculate the new collateral amount and collateral ratio
    new_collateral: uint256 = trove.collateral - collateral_amount
    collateral_ratio: uint256 = self._calculate_collateral_ratio(
        new_collateral, trove_debt_after_interest, collateral_price
    )

    # Make sure the new collateral ratio is above the minimum collateral ratio
    assert collateral_ratio >= self.minimum_collateral_ratio, "!minimum_collateral_ratio"

    # Update the Trove's collateral info
    self.troves[trove_id].collateral = new_collateral

    # Update the contract's recorded collateral balance
    self.collateral_balance -= collateral_amount

    # Transfer the collateral tokens to caller
    assert extcall self.collateral_token.transfer(msg.sender, collateral_amount, default_return_value=True)

    # Emit event
    log RemoveCollateral(
        trove_id=trove_id,
        trove_owner=msg.sender,
        collateral_amount=collateral_amount
    )


@external
def borrow(
    trove_id: uint256,
    debt_amount: uint256,
    max_upfront_fee: uint256,
    min_debt_out: uint256,
    min_collateral_out: uint256,
):
    """
    @notice Borrow more tokens from an existing Trove
    @dev Only callable by the Trove owner
    @dev Trove debt increases by `debt_amount` plus the upfront fee. Tokens from idle liquidity arrive
         atomically; any shortfall is redeemed from other troves and airdropped on auction settlement.
         Total delivered can be less than requested if lender liquidity or redeemable collateral are insufficient
    @param trove_id Unique identifier of the Trove
    @param debt_amount Amount of additional debt to issue before the upfront fee
    @param max_upfront_fee Maximum upfront fee the caller is willing to pay
    @param min_debt_out Minimum amount of debt tokens to be received atomically from idle liquidity
    @param min_collateral_out Minimum amount of collateral tokens to be redeemed
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
    collateral_price: uint256 = staticcall self.price_oracle.get_price()

    # Calculate the collateral ratio
    collateral_ratio: uint256 = self._calculate_collateral_ratio(trove.collateral, new_debt, collateral_price)

    # Make sure the new collateral ratio is above the minimum collateral ratio
    assert collateral_ratio >= self.minimum_collateral_ratio, "!minimum_collateral_ratio"

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
        new_debt * trove.annual_interest_rate, # weighted_debt_increase
        old_debt * trove.annual_interest_rate, # weighted_debt_decrease
    )

    # Deliver borrow tokens to the caller, redeem if liquidity is insufficient
    self._transfer_borrow_tokens(
        debt_amount,
        trove.annual_interest_rate,
        min_debt_out,
        min_collateral_out,
    )

    # Emit event
    log Borrow(
        trove_id=trove_id,
        trove_owner=msg.sender,
        debt_amount=new_debt,
        upfront_fee=upfront_fee
    )


@external
def repay(trove_id: uint256, debt_amount: uint256):
    """
    @notice Repay part of the debt of an existing Trove
    @dev Only callable by the Trove owner
    @dev Caller must approve this contract to transfer borrow tokens on its behalf before calling
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
    max_repayment: uint256 = trove_debt_after_interest - self.min_debt

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
        new_debt * trove.annual_interest_rate, # weighted_debt_increase
        old_debt * trove.annual_interest_rate, # weighted_debt_decrease
    )

    # Pull the borrow tokens from caller and transfer them to the Lender contract
    assert extcall self.borrow_token.transferFrom(msg.sender, self.lender, debt_to_repay, default_return_value=True)

    # Emit event
    log Repay(
        trove_id=trove_id,
        trove_owner=msg.sender,
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
    @param max_upfront_fee Maximum upfront fee the caller is willing to pay
    """
    # Make sure the new annual interest rate is within bounds
    assert new_annual_interest_rate >= self.min_annual_interest_rate, "!min_annual_interest_rate"
    assert new_annual_interest_rate <= self.max_annual_interest_rate, "!max_annual_interest_rate"

    # Cache Trove info
    trove: Trove = self.troves[trove_id]

    # Make sure the caller is the owner of the Trove
    assert trove.owner == msg.sender, "!owner"

    # Make sure the Trove is active
    assert trove.status == Status.ACTIVE, "!active"

    # Make sure user is actually changing their rate
    assert new_annual_interest_rate != trove.annual_interest_rate, "!new_annual_interest_rate"

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Initialize the new debt amount variable
    # We will charge an upfront fee only if the user is adjusting their rate prematurely
    new_debt: uint256 = trove_debt_after_interest

    # Initialize the upfront fee variable. We will need to increase the global debt by this amount if we charge it
    upfront_fee: uint256 = 0

    # Apply upfront fee on premature adjustments and check collateral ratio
    if block.timestamp < convert(trove.last_interest_rate_adj_time, uint256) + self.interest_rate_adj_cooldown:
        # Calculate the upfront fee and make sure the user is ok with it
        upfront_fee = self._get_upfront_fee(new_debt, new_annual_interest_rate, max_upfront_fee)

        # Charge the upfront fee
        new_debt += upfront_fee

        # Get the collateral price
        collateral_price: uint256 = staticcall self.price_oracle.get_price()

        # Calculate the collateral ratio
        collateral_ratio: uint256 = self._calculate_collateral_ratio(trove.collateral, new_debt, collateral_price)

        # Make sure the new collateral ratio is above the minimum collateral ratio
        assert collateral_ratio >= self.minimum_collateral_ratio, "!minimum_collateral_ratio"

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
        new_debt * new_annual_interest_rate, # weighted_debt_increase
        old_debt * old_annual_interest_rate, # weighted_debt_decrease
    )

    # Reinsert the Trove in the sorted list at its new position
    extcall self.sorted_troves.re_insert(
        trove_id,
        new_annual_interest_rate,
        prev_id,
        next_id
    )

    # Emit event
    log AdjustInterestRate(
        trove_id=trove_id,
        trove_owner=msg.sender,
        new_annual_interest_rate=new_annual_interest_rate,
        upfront_fee=upfront_fee
    )


# ============================================================================================
# Close trove
# ============================================================================================


@external
def close_trove(trove_id: uint256):
    """
    @notice Close an existing Trove by repaying all its debt and withdrawing all its collateral
    @dev Only callable by the Trove owner
    @dev Caller must approve this contract to transfer borrow tokens on its behalf before calling
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
        0, # weighted_debt_increase
        old_trove.debt * old_trove.annual_interest_rate, # weighted_debt_decrease
    )

    # Remove from sorted list
    extcall self.sorted_troves.remove(trove_id)

    # Pull the borrow tokens from caller and transfer them to the Lender contract
    assert extcall self.borrow_token.transferFrom(msg.sender, self.lender, trove_debt_after_interest, default_return_value=True)

    # Transfer the collateral tokens to caller
    assert extcall self.collateral_token.transfer(msg.sender, old_trove.collateral, default_return_value=True)

    # Emit event
    log CloseTrove(
        trove_id=trove_id,
        trove_owner=msg.sender,
        collateral_amount=old_trove.collateral,
        debt_amount=trove_debt_after_interest
    )


@external
def close_zombie_trove(trove_id: uint256):
    """
    @notice Close a zombie Trove by repaying all its debt (if it has any) and withdrawing all its collateral
    @dev Only callable by the Trove owner
    @dev If non-zero debt, caller must approve this contract to transfer borrow tokens on its behalf before calling
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
            0, # weighted_debt_increase
            old_trove.debt * old_trove.annual_interest_rate, # weighted_debt_decrease
        )

        # Pull the borrow tokens from caller and transfer them to the Lender contract
        assert extcall self.borrow_token.transferFrom(msg.sender, self.lender, trove_debt_after_interest, default_return_value=True)

    # Transfer the collateral tokens to caller
    assert extcall self.collateral_token.transfer(msg.sender, old_trove.collateral, default_return_value=True)

    # Emit event
    log CloseZombieTrove(
        trove_id=trove_id,
        trove_owner=msg.sender,
        collateral_amount=old_trove.collateral,
        debt_amount=trove_debt_after_interest
    )


# ============================================================================================
# Liquidate trove
# ============================================================================================


@external
def liquidate_troves(trove_ids: uint256[_MAX_ITERATIONS]):
    """
    @notice Liquidate a list of unhealthy Troves
    @dev Uses the Dutch Desk contract to auction off the collateral tokens
    @param trove_ids List of unique identifiers of the unhealthy Troves
    """
    # Make sure that first trove id is non-zero
    assert trove_ids[0] != 0, "!trove_ids"

    # Cache the current zombie trove id to avoid multiple SLOADs inside `_liquidate_single_trove`
    current_zombie_trove_id: uint256 = self.zombie_trove_id

    # Get the collateral price
    collateral_price: uint256 = staticcall self.price_oracle.get_price()

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

        # Liquidate the Trove and get the changes
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
        0, # weighted_debt_increase
        total_weighted_debt_to_decrease, # weighted_debt_decrease
    )

    # Kick the auction. Proceeds will be sent to the Lender contract
    extcall self.dutch_desk.kick(total_collateral_to_decrease)  # pulls collateral tokens


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

    # Get the Trove's debt after accruing interest
    trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

    # Calculate the collateral ratio
    collateral_ratio: uint256 = self._calculate_collateral_ratio(
        trove.collateral, trove_debt_after_interest, collateral_price
    )

    # Make sure the collateral ratio is below the minimum collateral ratio
    assert collateral_ratio < self.minimum_collateral_ratio, "!collateral_ratio"

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
        extcall self.sorted_troves.remove(trove_id)

    # Emit event
    log LiquidateTrove(
        trove_id=trove_id,
        trove_owner=old_trove.owner,
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
def redeem(debt_amount: uint256, receiver: address):
    """
    @notice Attempt to free the specified amount of borrow tokens by selling collateral
    @dev Can only be called by the Lender contract
    @dev Uses the Dutch Desk contract to auction off the redeemed collateral tokens
    @param debt_amount Target amount of borrow tokens to free
    @param receiver Address to transfer the auction proceeds to
    """
    # Make sure the caller is the Lender contract
    assert msg.sender == self.lender, "!lender"

    # Attempt to redeem the specified `debt_amount` and transfer the resulting borrow tokens to the `receiver`
    self._redeem(debt_amount, max_value(uint256), receiver)


@internal
def _redeem(
    debt_amount: uint256,
    redeemer_annual_interest_rate: uint256,
    receiver: address = msg.sender
) -> uint256:
    """
    @notice Internal implementation of `redeem`
    @dev Borrowers can only redeem other borrowers if they're paying a higher interest rate.
         Zombie troves are exempt since they're already below min debt and should be cleared.
         The Lender (for withdrawals) can redeem anyone
    @param debt_amount Target amount of borrow tokens to free
    @param redeemer_annual_interest_rate Annual interest rate paid by the redeemer
    @param receiver Address to transfer the auction proceeds to
    @return Amount of collateral tokens that were redeemed
    """
    # Accrue interest on the total debt
    self._sync_total_debt()

    # Get the collateral price
    collateral_price: uint256 = staticcall self.price_oracle.get_price()

    # Initialize the `is_zombie_trove` flag
    is_zombie_trove: bool = False

    # Initialize the Trove to redeem variable
    trove_to_redeem: uint256 = self.zombie_trove_id

    # Cache the Sorted Troves contract
    sorted_troves: ISortedTroves = self.sorted_troves

    # Use zombie Trove from previous redemption if it exists. Otherwise get the Trove with the lowest interest rate
    if trove_to_redeem != 0:
        is_zombie_trove = True
    else:
        trove_to_redeem = staticcall sorted_troves.last()

    # Cache the amount of debt we need to free
    remaining_debt_to_free: uint256 = debt_amount

    # Cache the total changes we're making so that later we can update the accounting
    total_debt_decrease: uint256 = 0
    total_collateral_decrease: uint256 = 0
    total_weighted_debt_increase: uint256 = 0
    total_weighted_debt_decrease: uint256 = 0

    # Loop through as many Troves as we're allowed or until we redeem all the debt we need
    for _: uint256 in range(_MAX_ITERATIONS):
        # Cache the Trove to redeem info
        trove: Trove = self.troves[trove_to_redeem]

        # Stop if we reached a Trove that doesn't qualify for redemption
        if not is_zombie_trove and redeemer_annual_interest_rate <= trove.annual_interest_rate:
            break

        # Cache the ID of the next Trove to redeem, i.e., the previous Trove in the sorted list
        next_trove_to_redeem: uint256 = staticcall sorted_troves.prev(trove_to_redeem)

        # Don't want to redeem a borrower's own Trove
        if msg.sender != trove.owner:
            # Get the Trove's debt after accruing interest
            trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)

            # Determine the amount to be freed
            debt_to_free: uint256 = min(remaining_debt_to_free, trove_debt_after_interest)

            # Calculate the Trove's new debt amount
            trove_new_debt: uint256 = trove_debt_after_interest - debt_to_free

            # If trove would be left with debt below the minimum, go zombie
            if trove_new_debt < self.min_debt:
                # If the trove is not already a zombie trove, we need to mark it as such
                if not is_zombie_trove:
                    # Mark trove as zombie
                    trove.status = Status.ZOMBIE

                    # Remove trove from sorted list
                    extcall sorted_troves.remove(trove_to_redeem)

                    # If it's a partial redemption, record it so we know to continue with it next time
                    if trove_new_debt > 0:
                        self.zombie_trove_id = trove_to_redeem

                # If we fully redeemed a zombie trove, reset the `zombie_trove_id` variable
                elif trove_new_debt == 0:
                    self.zombie_trove_id = 0

            # Get the amount of collateral equal to `debt_to_free`
            collateral_to_redeem: uint256 = debt_to_free * _PRICE_ORACLE_PRECISION // collateral_price

            # Calculate the Trove's new collateral amount
            trove_new_collateral: uint256 = trove.collateral - collateral_to_redeem

            # Calculate the Trove's old and new weighted debt
            trove_weighted_debt_decrease: uint256 = trove.debt * trove.annual_interest_rate
            trove_weighted_debt_increase: uint256 = trove_new_debt * trove.annual_interest_rate

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
            total_weighted_debt_decrease += trove_weighted_debt_decrease
            total_weighted_debt_increase += trove_weighted_debt_increase

            # Update the remaining debt to free
            remaining_debt_to_free -= debt_to_free

            # Emit event
            log RedeemTrove(
                trove_id=trove_to_redeem,
                trove_owner=trove.owner,
                redeemer=msg.sender,
                collateral_amount=collateral_to_redeem,
                debt_amount=debt_to_free,
            )

            # Break if we freed all the debt we wanted
            if remaining_debt_to_free == 0:
                break

        # Get the next Trove to redeem. If we just processed a zombie Trove (which is not in the sorted Troves list),
        # get the Trove with the lowest interest rate. Otherwise, use the previous Trove from the list
        trove_to_redeem = staticcall sorted_troves.last() if is_zombie_trove else next_trove_to_redeem

        # Break if we reached the end of the list
        if trove_to_redeem == 0:
            break

        # Reset the `is_zombie_trove` flag
        is_zombie_trove = False

    # Accrue interest on the total debt and update accounting
    self._accrue_interest_and_account_for_trove_change(
        0, # debt_increase
        total_debt_decrease, # debt_decrease
        total_weighted_debt_increase, # weighted_debt_increase
        total_weighted_debt_decrease, # weighted_debt_decrease
    )

    # Update the contract's recorded collateral balance
    self.collateral_balance -= total_collateral_decrease

    # Kick the auction.
    # Proceeds up to `total_debt_decrease` will be sent to the `receiver`, any surplus will be sent to the Lender contract
    extcall self.dutch_desk.kick(total_collateral_decrease, total_debt_decrease, receiver, _REDEMPTION_AUCTION)  # pulls collateral tokens

    # Emit event
    log Redeem(
        redeemer=msg.sender,
        collateral_amount=total_collateral_decrease,
        debt_amount=total_debt_decrease,
    )

    # Return the amount of collateral tokens that were redeemed
    return total_collateral_decrease


# ============================================================================================
# Internal view functions
# ============================================================================================


@internal
@view
def _calculate_collateral_ratio(
    collateral_amount: uint256,
    debt_amount: uint256,
    collateral_price: uint256
) -> uint256:
    """
    @notice Calculate the collateral ratio
    @param collateral_amount Amount of collateral
    @param debt_amount Amount of debt
    @param collateral_price Price from oracle scaled by 10^(36 + borrow_decimals - collateral_decimals)
    @return collateral_ratio The collateral ratio
    """
    # Convert collateral to borrow token value
    collateral_value: uint256 = collateral_amount * collateral_price // _PRICE_ORACLE_PRECISION

    # Return ratio as percentage
    return collateral_value * self.borrow_token_precision // debt_amount


@internal
@view
def _calculate_accrued_interest(weighted_debt: uint256, period: uint256) -> uint256:
    """
    @notice Calculate the interest accrued on weighted debt over a given period
    @param weighted_debt The debt weighted by the annual interest rate
    @param period The time period over which interest is calculated
    @return interest The interest accrued over the period
    """
    return weighted_debt * period // _ONE_YEAR // self.borrow_token_precision


@internal
@view
def _get_upfront_fee(
    debt_amount: uint256,
    annual_interest_rate: uint256,
    max_upfront_fee: uint256 = max_value(uint256)
) -> uint256:
    """
    @notice Get the upfront fee for borrowing a specified amount of debt at a given annual interest rate
    @dev Make sure the calculated fee does not exceed `max_upfront_fee`
    @dev The fee represents prepaid interest over upfront interest period using the system's average rate after the new debt
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
    upfront_fee: uint256 = self._calculate_accrued_interest(debt_amount * avg_interest_rate, self.upfront_interest_period)

    # Make sure the user is ok with the upfront fee
    assert upfront_fee <= max_upfront_fee, "!max_upfront_fee"

    return upfront_fee


@internal
@view
def _get_trove_debt_after_interest(trove: Trove) -> uint256:
    """
    @notice Get the Trove's debt after accruing interest
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


@internal
def _accrue_interest_and_account_for_trove_change(
    debt_increase: uint256,
    debt_decrease: uint256,
    weighted_debt_increase: uint256,
    weighted_debt_decrease: uint256,
):
    """
    @notice Accrue interest on the total debt and update total debt and total weighted debt accounting
    @param debt_increase Amount of debt to add to the total debt
    @param debt_decrease Amount of debt to subtract from the total debt
    @param weighted_debt_increase Amount of weighted debt to add to the total weighted debt
    @param weighted_debt_decrease Amount of weighted debt to subtract from the total weighted debt
    """
    # Update total debt
    new_total_debt: uint256 = self._sync_total_debt()
    new_total_debt += debt_increase
    new_total_debt -= debt_decrease
    self.total_debt = new_total_debt

    # Update total weighted debt
    new_total_weighted_debt: uint256 = self.total_weighted_debt
    new_total_weighted_debt += weighted_debt_increase
    new_total_weighted_debt -= weighted_debt_decrease
    self.total_weighted_debt = new_total_weighted_debt


@internal
def _sync_total_debt() -> uint256:
    """
    @notice Accrue interest on the total debt and return the updated figure
    @return new_total_debt The updated total debt after accruing interest
    """
    # Calculate the pending aggregate interest using ceiling division.
    # Individual trove interest uses floor division, so we use ceiling here to ensure
    # `total_debt >= sum(trove debts)` always holds. This prevents `total_debt` from
    # going negative if all troves repay. The difference is small and it should scale
    # with the number of interest minting events
    pending_agg_interest: uint256 = math._ceil_div(
        self.total_weighted_debt * (block.timestamp - self.last_debt_update_time),
        _ONE_YEAR * self.borrow_token_precision
    )

    # Calculate the new total debt after interest
    new_total_debt: uint256 = self.total_debt + pending_agg_interest

    # Update the total debt
    self.total_debt = new_total_debt

    # Update the last debt update time
    self.last_debt_update_time = block.timestamp

    return new_total_debt


@internal
def _transfer_borrow_tokens(
    amount: uint256,
    annual_interest_rate: uint256,
    min_debt_out: uint256,
    min_collateral_out: uint256,
):
    """
    @notice Transfer borrow tokens to the caller, redeeming other borrowers' collateral if necessary
    @param amount Amount of borrow tokens to transfer
    @param annual_interest_rate Annual interest rate paid by the borrower
    @param min_debt_out Minimum amount of debt tokens to be received atomically from idle liquidity
    @param min_collateral_out Minimum amount of collateral tokens to be redeemed
    """
    # Cache the Lender contract address
    lender: address = self.lender

    # Cache the borrow token contract
    borrow_token: IERC20 = self.borrow_token

    # Check how much borrow token liquidity the Lender contract has
    available_liquidity: uint256 = staticcall borrow_token.balanceOf(lender)

    # Make sure we can satisfy the `min_debt_out` requirement
    assert available_liquidity >= min_debt_out, "!min_debt_out"

    # If there's not enough liquidity, redeem the difference. Otherwise just transfer the full amount
    if amount > available_liquidity:
        # Transfer whatever we have first
        if available_liquidity > 0:
            assert extcall borrow_token.transferFrom(lender, msg.sender, available_liquidity, default_return_value=True)

        # Redeem the difference
        collateral_out: uint256 = self._redeem(amount - available_liquidity, annual_interest_rate)

        # Make sure we satisfied the `min_collateral_out` requirement
        assert collateral_out >= min_collateral_out, "!min_collateral_out"
    else:
        # Transfer the full amount
        assert extcall borrow_token.transferFrom(lender, msg.sender, amount, default_return_value=True)