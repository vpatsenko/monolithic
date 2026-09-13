# Mono

`src/Mono.sol` — the MONO reserve token and its vault in one contract (HANDBOOK §3.1–3.2).
Interface: `src/interfaces/IMono.sol`. Tests: `test/IndexMono.t.sol`.

## What it is

An ERC-20 (solady) whose supply is a claim on a single asset: INDEX. NAV is
`totalAssets() / totalSupply()`, in INDEX per MONO, 18 decimals — the floor.

**The one invariant everything rests on: `nav()` never decreases.** Two halves:

- **One outflow, and it is accretive.** There is no path that moves INDEX out by calling this
  contract — not `withdraw`, not `redeem`, not a rescue. The single exception is the **wall**
  (HANDBOOK §3.3): `setWall` grants [`MonoHook`](MonoHook.md) an allowance, and the hook spends it
  buying MONO at `(1 - wallTick) x NAV` and burning it. The floor moves from `I/S` to
  `(I - R*w)/(S - R)`, strictly greater for any `w < NAV` — so even the exit raises the floor.
- **No dilutive mint.** `mint()` requires `assetsIn·S >= A·shares`, so post-mint NAV
  `(A + assetsIn)/(S + shares)` is >= pre-mint `A/S`. Checked exactly with
  `fullMulDivUp`, rounding against the harvester.

`burn()` retires a claim without touching the pot, so NAV rises. Anything transferred in
raises NAV with no entry point at all — that is how the tax sweep accrues.

## Surface

| | |
| --- | --- |
| `index` | INDEX. Immutable. The only thing held. |
| `MINTER_ROLE` | OpenZeppelin `AccessControl`. The only role that may mint. Deployer at first, then [`GenerousAuction`](GenerousAuction.md). |
| `DEFAULT_ADMIN_ROLE` | Grants and revokes `MINTER_ROLE`, and calls `setPool`. Stays with the deployer. |
| `genesisCap` | ceiling on the first mint. Immutable. |
| `mint(shares, assetsIn, to)` | owner-only. First call seeds the vault and sets opening NAV (capped). Later calls are non-dilutive. |
| `burn(shares)` | anyone, own balance. |
| `nav()`, `totalIndex()` | the floor and the pot. |
| `poolManager`, `poolId`, `hook`, `monoIsCurrency0` | the v4 pool and its oracle. Zero until `setPool`. |
| `setPool(manager, key)` | `DEFAULT_ADMIN_ROLE`, callable **once**. Names the pool and pins the hook. |
| `emaPrice(h)`, `emaPremiumBips(h)` | the same reads off the hook's EMA. What a mint gate uses. |
| `wall` | the hook holding the vault's one allowance. Zero until `setWall`. |
| `setWall(wall_)` | `DEFAULT_ADMIN_ROLE`, callable **once**. Arms the wall. |
| `poolPrice()`, `premium()`, `premiumBips()` | the market, and how far it sits above the floor. |

## Roles

OpenZeppelin `AccessControl`, **not** `Ownable` — [`Index`](Index.md) still uses `Ownable`, and the
two are allowed to differ. Two roles:

| Role | Gates | Held by |
| --- | --- | --- |
| `MINTER_ROLE` | `mint` | the deployer for the genesis mint, then the auction |
| `DEFAULT_ADMIN_ROLE` | `setPool`, and granting/revoking `MINTER_ROLE` | the deployer |

The constructor grants the deployer **both**: admin to wire the sale up, minter to run the genesis
mint that sets the opening NAV. `burn` is open to anyone over their own balance and always was.

`GenerousAuction`'s constructor needs this token's address, so this token's constructor cannot name
the auction. The handoff:

1. deploy `Mono` (deployer holds both roles);
2. `mint` once to seed the vault and set the opening NAV;
3. create the MONO/INDEX pool, `setPool(pool)`;
4. deploy `GenerousAuction`;
5. `grantRole(MINTER_ROLE, auction)`;
6. `renounceRole(MINTER_ROLE, deployer)`.

When a sale is *succeeded* rather than retired, the outgoing auction has to keep `MINTER_ROLE`
until the successor is deployed — the successor's constructor calls `mintPack()` on it. See
[Succession](GenerousAuction.md#succession).

**Step 6 is not optional.** Granting alone leaves *two* minters. Under `Ownable` the handoff was a
transfer and the deployer lost the power by construction; under `AccessControl` a grant only adds,
so the deployer has to give its own half up explicitly. `script/DeployGenerousAuction.s.sol` does
both and logs the resulting `hasRole` on each address.

### What the admin can still do

`DEFAULT_ADMIN_ROLE` can grant `MINTER_ROLE` back to itself at any time. This is a real
weakening versus `transferOwnership`, and it is worth being precise about what it does and does
not buy:

- It **cannot** lower NAV. Every mint goes through the non-dilution check regardless of who holds
  the role, so a rogue minter can only add supply at or above book. The floor invariant is
  enforced in `mint`, not in the access control.
- It **can** add supply the auction did not sell, diluting nobody's backing but competing with the
  harvest for the same premium.

Revoking the deployer's admin role, or moving it to a timelock or multisig, closes that. Nothing in
this contract does it for you.

Why roles rather than ownership: several sales can hold `MINTER_ROLE` at once, and a finished sale
is torn down with `revokeRole` instead of an ownership transfer that has to go somewhere. The
handoff stops being a single-occupancy baton.

`test_vaultHasNoOutflow` still checks there is no INDEX exit — roles change who may add supply,
never whether backing can leave.

## A plain ERC-20, not an ERC-4626 vault

MONO is `solady/ERC20` plus the vault state. The 4626 entry and exit surface is **absent from
the bytecode** — no `deposit`/`mint(shares,to)`/`withdraw`/`redeem`, and no `max*`.
`test_noVaultEntryOrExitInBytecode` is the guard. Owner `mint(shares, assetsIn, to)` is a
different function.

Why not claim the standard and close it? Returning 0 from `max*` is technically conformant,
which is the worst place to be: it passes every automated sniff test and fails the real one. A
4626 indexer detects a vault; an integrator builds an unwind or liquidation route on `redeem()`;
that route always reverts. The liveness bug lands in *their* protocol and gets attributed to
this token. The one real benefit — NAV in a single standard call — is already served by `nav()`,
which promises nothing it cannot do.

What is kept — no 4626 names at all, because every one of them either promises an exit or
duplicates something clearer:

| | |
| --- | --- |
| `index()` | the INDEX it holds |
| `totalIndex()` | the pot |
| `nav()` | the one-call price read |
| `poolPrice()` | the market price, in the same unit as `nav()` |
| `premium()` | `poolPrice() - nav()`, signed |
| `premiumBips()` | the same gap over the floor, in bips. `+1500` is 15% above NAV |
| `premiumCloseAmount()` | the same gap restated as supply: MONO that would close it |
| `maxIssuable(indexAmount)` | the most MONO `mint` will accept that much INDEX for — the inverse of its non-dilution check. `GenerousAuction.claim` clamps to it, see [the NAV clamp](GenerousAuction.md#the-nav-clamp) |

Issuance emits `Minted`. There is no `Withdraw` counterpart, because there is no withdrawal.

### Why there is no entry or exit at all

- **Open deposit at NAV** lets anyone convert backing into MONO at book while MONO trades
  above book. The premium arbs to zero and the harvest has nothing to sell.
- **Open redeem at par** leaves `(A − x·NAV)/(S − x)` unchanged: the floor stops ratcheting
  and the vault drains at flat NAV.

The floor is defended by the **wall** — a hook-side bid below NAV whose fills burn — never by
redemption. The distinction is the tick: a redemption at par leaves NAV flat and drains the pot,
while the wall pays strictly *under* NAV and retires the shares, so the same outflow ratchets the
floor up. See [MonoHook](MonoHook.md#the-wall).

### `setWall`, and why the allowance is unbounded

`setWall` is `DEFAULT_ADMIN_ROLE`, one-shot, and stores the address and grants the allowance in
the same call — so `wall != address(0)` is an exact reading of "armed". An allowance is not a
budget here: the bound is arithmetic and it lives in the hook, which can only ever pay
`(1 - wallTick) x NAV` per MONO and burns every MONO it buys. Capping it would buy nothing except
a wall that bricks at some arbitrary cumulative volume. What a cap *would* protect against — a
hostile hook — is bought instead by this being one-shot at a checked address: `Mono` requires
`wall_.mono()` to be itself, and refuses a second call, so there is no path to re-point it later.

Same argument as `setPool`'s pairing check, and a worse failure if skipped: a wrong `pool`
misprices, a wrong `wall` approves a stranger for the whole vault.

## The pool, and the premium

`nav()` is the floor. `poolPrice()` is what the market actually pays. `premium()` is the gap:

```solidity
premium() == int256(poolPrice()) - int256(nav())
```

Both sides are **INDEX per MONO, 18 decimals**, which is why the comparison is a plain
subtraction with no conversion. That is the reason the pool is MONO/INDEX and not MONO/stablecoin
— a USD-denominated pool would drag Index's whole oracle path into this contract just to make the
two numbers comparable.

The venue is the **v4 MONO/INDEX pool with our own hook in its key** (HANDBOOK §3.6). `Mono` does
not import `IUniswapV3Pool` any more: spot and liquidity come off the `PoolManager` through
`StateLibrary`, and the EMA comes off [`MonoHook`](MonoHook.md).

### Two readings, and which one is for what

| read | source | for |
| --- | --- | --- |
| `poolPrice()`, `premium()`, `premiumBips()` | **spot** (`slot0`) | monitoring, sizing, and the tax — which reads spot deliberately (§3.4) |
| `emaPrice(h)`, `emaPremiumBips(h)` | the hook's EMA over `h` | **anything that mints** |

Spot is still spot: movable inside a single block by anyone willing to push the pool and push it
back. That is not a defect to be fixed — it is the honest answer to "what is the market paying",
and §3.4 wants the tax on it precisely because pushing the price toward a cheaper rate *is* the
taxed trade. What changed is that there is now a reading that is **not** movable that way, and the
rule is simply: **do not gate a mint on spot.** `emaPrice` accrues at the price that STOOD, so
faking it means holding the displacement across block boundaries, exposed to arbitrage and the
sell tax the whole time. `test_aOneBlockPumpCannotOpenASale` is that property, asserted.

`premiumBips()` is the same gap divided by the floor, in basis points — `+1500` is MONO trading
15% above NAV. **A threshold belongs against this, not `premium()`**: an absolute gap of 0.15 INDEX
is 15% at a floor of 1.0 and 1.5% at a floor of 10, and the floor only ratchets up.
[`GenerousAuction`'s premium gate](GenerousAuction.md#the-premium-gate) is the caller.

`premium()` is **signed on purpose**. A negative premium — MONO trading below book — is not an
error state; it is precisely the condition the wall exists to buy into. Flooring it at zero would
discard the only half that is actionable today.

### Sizing: the premium as supply

`premiumCloseAmount()` answers the gap in MONO instead of in price — how much MONO sold into the
pool would carry its price back down to `nav()`. [`GenerousAuction`](GenerousAuction.md) uses it as
the entire size of a sale.

Standard v3 single-range math, branching on which side of the pair MONO sits:

| MONO is | pool quotes | selling MONO | amount |
| --- | --- | --- | --- |
| `token0` | INDEX per MONO | drives it **down** | `dx = L x (1/sqrt(T) - 1/sqrt(C))` |
| `token1` | MONO per INDEX | drives it **up** | `dy = L x (sqrt(T) - sqrt(C))` |

`sqrt(C)` is the pool's live `sqrtPriceX96`; `sqrt(T)` is `sqrt(nav())` in the pool's own
orientation. Returns 0 when the market is already at or below book, and 0 when the pool reports no
liquidity.

**Known ceiling — this is a sizing heuristic, not a quote.** `StateLibrary.getLiquidity` is the
**in-range** `L` only. The formula is exact while the swap stays inside the current tick and
**understates** the moment it would cross one, because real books hold liquidity outside the
active tick that this cannot see. Walking the tick bitmap is the fix, and now that the pool is v4
the surface to do it with is actually there — `StateLibrary` exposes the bitmap and per-tick net
liquidity. It errs low, so a sale is sized conservatively rather than over-sold.

This one still reads **spot**, deliberately. It is a question about pool mechanics — how much MONO
it takes to walk the book from where it actually is down to NAV — and answering it from a lagging
price would mis-size whenever the market had genuinely moved. The manipulation that matters is
bounded by the EMA gate standing in front of it: to reach this call at all you must first clear
`emaPremiumBips`, which a one-block push cannot do.

### Why `setPool` is not a constructor argument

A Uniswap pool for MONO/INDEX cannot exist before MONO does: `createPool` takes both token
addresses. So the pool address cannot be a constructor immutable, and cannot be validated at
deploy. Same circularity as the [ownership handoff](#ownership) above. The deployment order is:

1. deploy `Mono`;
2. mine and deploy `MonoHook` (its address is its permissions — see [MonoHook](MonoHook.md#deploying));
3. initialise the MONO/INDEX v4 pool with that hook in its `PoolKey`;
4. admin calls `setPool(manager, key)`.

`setPool` is `DEFAULT_ADMIN_ROLE` and **one-shot** — a second call reverts `PoolAlreadySet`, so it
is immutable in every sense except the EVM's. The one call it gets checks four things, all
`InvalidPool`:

- the key's currencies are exactly MONO and INDEX, either order;
- the key has a hook at all;
- that hook's `mono()` is **this** vault — a hook built for another `Mono` would read a different
  NAV and tax a different book;
- the pool is live on the `manager` it was handed, proved by a non-zero `slot0`. Without that a
  wrong-but-plausible manager would leave every price read answering zero.

**Naming the pool is what pins the hook.** The hook lives inside the `PoolKey` and a v4 pool can
never be re-hooked, so there is no separate oracle setter that could later be pointed elsewhere —
which is the same reason a wrong precomputed address would be unverifiable and permanent.

`poolPrice()` reverts `PoolNotSet` until step 4, so nothing reads a zero price by accident.

## How MONO gets minted

The first `mint` is the seed: no prior NAV, so the ratio you pass *is* the floor, capped at
`genesisCap`. `genesisDone` stays true even if supply later burns to zero, so that path cannot
run again. After the handoff the auction is the only caller. On `claim` it passes the INDEX the
bid already spent, so the strike lands here in the same transaction the supply is created.
Later `mint`s reject anything dilutive; the auction floors bids at `nav()` and clamps a claim
through `maxIssuable` rather than letting a stale bid price revert. That contract's doc has the
detail:
[The mint path](GenerousAuction.md#the-mint-path).

## Deferred

`premiumCloseAmount()` is still single-range. Now that the pool is v4 the tick bitmap is reachable
through `StateLibrary`, so walking it is a real option rather than a wish; it errs low today, which
under-sizes a sale rather than over-selling one.

The wall itself is no longer deferred: D25 put it in the hook (it has to be atomic with the sell
it defends against, which a keeper cannot be), and `setWall` is the vault's half of it.
