---
title: FLEX Audit 28 February 2026

---

# FLEX Audit 28 February 2026

## Context
### Repo: https://github.com/flexmeow/flex-contracts
### Hash: `10ef9edfb9ced6a440d5dc17e2dad02deaf9fe1f`


# Findings



## [M-1] There can be multiple zombie troves :zombie: :female_zombie: :male_zombie: 
### Summary
Due to an edge case during redemption on borrow, if the borrower already owns a zombie trove and triggers a redemption while opening/borrowing from another trove, they can create a second zombie trove while the contract tracks only one. This can overwrite `zombie_trove_id` and lose reference to the previous zombie trove.

### Vulnerability Details
Assume there is one zombie trove owned by Papichulo, and Papichulo also owns several non-zombie troves.

Papichulo borrows from one of his active troves while lender liquidity is insufficient, so redemptions are triggered to satisfy the borrow amount. Redemptions prioritize `zombie_trove_id` first. However, if the prioritized zombie trove is also owned by `msg.sender`, the block guarded by `if msg.sender != trove.owner` is skipped. The loop then advances to the next trove and clears the zombie flag path for that iteration.

If Papichulo chooses a borrow amount that causes another trove to fall below `min_debt`, that new trove can be marked zombie and assigned to `self.zombie_trove_id`, effectively overwriting the previous zombie tracking.

```vyper
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
```

As shown above, when `msg.sender == trove.owner`, the guarded branch is skipped, `trove_to_redeem` advances, and the flow can later assign a new zombie trove, potentially replacing the previously tracked zombie :zombie: 

### Code snippets
https://github.com/flexmeow/flex-contracts/blob/10ef9edfb9ced6a440d5dc17e2dad02deaf9fe1f/src/trove_manager.vy#L1197-L1360
### Impact
When there is a zombie trove liquidations for that zombie trove can go through. However, redemptions always prioritise zombie trove is not going to be hold because the overriden zombie trove is effectively not stored in the contract anymore.
### Recommendation

- [x] Fixed @ https://github.com/flexmeow/flex-contracts/commit/9f5e58b03a8bb8ef5001dc5c4ce7310e2ab7f0df
- [ ] Will not fix



## [M-2] Partial liq makes bad troves even worse

### Summary  
If a trove is deep underwater, partial liquidation **makes its CR worse**, not better.  
So the partial path fails its own checks and you’re forced into **full liquidation only**.  
Problem: full liquidation can be **negative EV**, so liquidators may just skip it.

### What’s happening  
`liquidate_trove` tries to pick a debt amount that brings CR back to `safeCollateralRatio`.  
But when the trove is really bad, that “safe” amount is **more than total debt**, so it just caps to full liquidation.

Math check:

```
CR(d) = (CV - (1+f)d) / (D - d)
```

If:

```
CV < (1+f)D
```

then CR gets worse as you repay debt.  
So any partial liquidation **pushes CR down**.

### Quick example  
- `safeCollateralRatio = 115%`  
- `minimumCollateralRatio = 110%`  
- `maxLiquidationFee = 5%`  
- Trove: `CV = 1040`, `D = 1000` (CR = 104%)

Safe target gives:

```
d_safe = (1.15*1000 - 1040) / (1.15 - 1 - 0.05) = 1100
```

That’s more than total debt → capped to full liq.

Try partial `d=100`:
- New CV = `1040 - 100*1.05 = 935`
- New D = `900`
- New CR = `935/900 = 103.89%` (worse)

So partial doesn’t help.  
And since partial path checks `new_CR >= minimumCollateralRatio`, it reverts anyway.

### Code  
https://github.com/flexmeow/flex-contracts/blob/10ef9edfb9ced6a440d5dc17e2dad02deaf9fe1f/src/trove_manager.vy#L959-L1174

### Impact  
- Partial liq basically doesn’t work for bad debt.  
- You end up with full‑liq‑or‑nothing.  
- If full liq is negative EV, liquidators may skip → bad debt stuck.
- Liquidator must need to liquidate all and take the loss or leave the trove forever and bad debt never gets socialised
### Recommendation  
Add a bad‑debt mode: if `CR <= 1+fee`, reduce fee/bonus (even to 0) so partial liq stops making CR worse.  
Or add a backstop/socialized loss path.  
Or accept that deep insolvency is full‑liq‑or‑nothing and make sure liquidators are always there.

- [x] Fixed @ https://github.com/flexmeow/flex-contracts/commit/5e6dc1c523ad786f6200f1a7b048c23ab07cb18a
- [ ] Will not fix

## [M-3] Undercollateralized Troves Can Be Redeemed Bypassing Liquidation Penalty Path

### Summary
A trove that is already below liquidation threshold can still be targeted by redemption.  
Because redemption excludes only `msg.sender == trove.owner`, the same economic actor can use a second account to redeem their own unhealthy trove and effectively avoid liquidation-bonus economics.

### Vulnerability Details
`_redeem` does not enforce a health/status gate that excludes unhealthy active troves.  
It only skips redemptions where caller is exactly the same owner address:

```vyper
if msg.sender != trove.owner:
    ...
```

So owner A can create/use account B to trigger redemption flow against A’s unhealthy trove.

This can produce better outcome for A versus third-party liquidation in stressed states:
- liquidation seizes collateral with bonus/fee (`> 1:1` collateral vs debt repaid),
- redemption removes collateral roughly 1:1 by oracle conversion,
- therefore cross-account redemption can reduce owner penalty relative to liquidation path.

### Example
Assume:
- `minimumCollateralRatio = 120%`
- Trove A: collateral value `110`, debt `100` (CR = 110%, liquidatable)
- A controls second account B.

B triggers borrow/redeem path and redemption reaches A’s trove:
- A’s trove can be redeemed because `msg.sender` is B, not A.
- Debt is reduced and collateral removed at redemption conversion.
- This path can be economically preferable to liquidation-fee seizure.

### Code
https://github.com/flexmeow/flex-contracts/blob/10ef9edfb9ced6a440d5dc17e2dad02deaf9fe1f/src/trove_manager.vy#L1197-L1360

### Impact
- Liquidation deterrence can be weakened for owner-controlled multi-account users.
- Owner can partially steer outcome away from liquidation bonus path.
- In deep undercollateralization, redemption can also create/leave residual bad debt states that are hard to clear economically.
- If the trove is already below 100% CR the redemption will make it worse

### Recommendation
Disallow redemption of troves with `CR < minimumCollateralRatio` (force liquidation path only), or
apply liquidation-equivalent penalty terms when redemption targets unhealthy troves, or
introduce an explicit rule that unhealthy active troves are only processed by liquidation logic.

- [ ] Fixed
- [x] Will not fix. if underwater lenders will lose assets anyways (if liquidated or closed/redeemed). if unhealthy but over collaterelized why not allow borrower to close instead of get liquidated? it's not like lenders get a fee



## [M-4] Re‑kick Can Zero the Price and Permanently Freeze Auctions

### Summary  
When `re_kick` recalculates the starting price using `current_amount` but still divides by the original `initial_amount`, the per‑token price can drop below `minimum_price`. `_get_price` then returns `0`, the auction becomes instantly inactive, and collateral stays stuck forever.

### Vulnerability Details  
`re_kick` computes a deflated starting price if most of the auction was already taken. `_get_price` returns `0` when that price is below `minimum_price`, so `take()` can never proceed and `initial_amount` never gets corrected.

### Quick Example  
- `initial_amount = 1e18`, `current_amount = 0.1e18`  
- re_kick starting price ≈ `210e18`  
- `minimum_price = 1900e18`  
- `_get_price` returns `0` → auction inactive → collateral stuck

### Code  
https://github.com/flexmeow/flex-contracts/blob/10ef9edfb9ced6a440d5dc17e2dad02deaf9fe1f/src/auction.vy  

### Impact  
Collateral can become permanently locked in the auction after a re_kick.

### Recommendation  
Reset `initial_amount` to `current_amount` during `re_kick` before price calculation.

- [x] Fixed @ https://github.com/flexmeow/flex-contracts/commit/034a2299eeb7d69a3393dabf36418efeb766dce1  
- [ ] Will not fix
## Low severity and Info 

* Impossible to reach, dead code due to assert in L1031
https://github.com/flexmeow/flex-contracts/blob/8d22695defb3fd84ee6d649ad62b3164c07cc906/src/trove_manager.vy#L1038-L1039
    - [x] Fixed @ https://github.com/flexmeow/flex-contracts/commit/709d53a03683c6349b85238b48e43423e6402ad2
    - [ ] Will not fix


* If `collateral_to_redeem = debt_to_free * 1e36 // collateral_price` rounds to 0, the flow still reduces `trove_debt`/`total_debt_decrease` but `total_collateral_decrease` stays 0, so `dutch_desk.kick(...)` becomes a no‑op. This burns debt without auctioning collateral, so the receiver gets no proceeds while debt disappears.
**Our justification here is that it is not benefitable for the redeemer to do this so no incentive hence, it's safe to keep it as it is.**
    - [ ] Fixed
    - [x] Will not fix

* A tiny repayment can “bake in” accrued interest, so subsequent interest accrues on a higher base and leaves the borrower worse off than if they hadn’t repaid. In effect, a small repay can increase total debt over time unless users repay enough to offset the compounding. Known issue per Liquity V2.
    - [ ] Fixed
    - [x] Will not fix

* For tiny lots, `kick()` succeeds but `_get_amount_needed` floors to 0 after downscaling, so `take()` reverts on `!needed_amount`, leaving a dust auction that can’t be purchased and collateral stuck (practically only at extremely small amounts, e.g., ~1e‑12 USD in the worst 18/6 case).
**Our justification here is that it is not benefitable for the redeemer to do this so no incentive hence, it's safe to keep it as it is.**
    - [ ] Fixed
    - [x] Will not fix. technically valid but practically dust is very tiny. the minimum kick_amount that produces this issue requires starting_price < buy_token_scaler. worst-case pair (18-dec collateral / 6-dec borrow token like yvWETH/USDC), buy_token_scaler = 1e12, which means the threshold kick_amount is ~333k wei of collateral — roughly $0.000000000001 worth. if such a tiny amount is left no solver will take it anyways

* `pricePerShare()` returns in the vault’s underlying decimals, not always 18, so the oracle’s scaling can be off and produce mis‑scaled prices unless it accounts for underlying decimals (though this specific oracle is scoped to yvWETH‑2).
    - [ ] Fixed
    - [x] Will not fix. this oracle is specific for yvWETH-2

* Interest accrual floors twice (`// _ONE_YEAR` then `// borrow_token_precision`), so frequent short-interval updates drop dust each time and under‑accrue trove‑level interest, which is noticeable for low‑decimal debt tokens like USDC. Also due to low precision on debt accounting the debt recorded will be lower than actual debt in paper.
    - [ ] Fixed
    - [x] Will not fix. individual trove interest uses floor division, while aggregate interest in _sync_total_debt uses ceiling division - this is by design to guarantee total_debt >= sum(trove debts) always holds. dust lost per individual trove interaction is negligible. pls see https://github.com/liquity/bold?tab=readme-ov-file#6---discrepancy-between-aggregate-and-sum-of-individual-debts and https://github.com/flexmeow/flex-contracts/blob/master/test/invariant/DebtInvariant.sol#L6 

* Leverage zapper flows can (1) leave swap dust if partial fills occur and no sweep/assert runs, (2) lack explicit post‑execution health bounds for the user beyond aggregator slippage, and (3) break on USDT‑style approvals due to residual non‑zero allowances (now fixed per commits).
    - [x] Fixed @ (1) [here](https://github.com/flexmeow/flex-contracts/commit/a20f1909beadb4b8c2c5d073345511ef7c5f2e8f) (2) slippage is already handled by the swap calldata itself (the aggregator enforces minOutputAmount) and min_borrow_out/min_collateral_out on open/lever up (3) [here](https://github.com/flexmeow/flex-contracts/commit/f0270c293b07ece0f1890bad7d7f80af2bd69522)
    - [ ] Will not fix

