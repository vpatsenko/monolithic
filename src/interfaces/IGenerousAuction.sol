// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IGenerousAuction
/// @notice Public surface of `src/GenerousAuction.sol`: a geometric pay-as-bid tick book run as
///         one continuous sale over a persistent book, emitting `emissionPerRound` every
///         `roundBlocks` blocks. Within a tick, supply is split by STAKE of the sale token, not
///         by escrow — see `stake`/`unstake` and `agent-docs/GenerousAuction.md`.
/// @dev Types, events and errors live here so the ABI has one definition. Implementation notes
///      stay in the contract; see `agent-docs/GenerousAuction.md` for the mechanism.
interface IGenerousAuction {
    // ---------------------------------------------------------------- types

    /// @notice Everything a deployment is. All of it becomes immutable except the last two, which
    ///         are the initial emission schedule and the only thing `admin` can ever change.
    /// @dev One struct rather than fourteen positional arguments: at that arity the constructor
    ///      does not fit the stack, and a deployer transposing two `uint64`s would not either.
    struct Config {
        address token;
        address currency;
        address admin;
        uint256 floorPrice;
        uint256 tickSpacing;
        uint256 decayQ; // q, Q96
        uint256 windowTicks;
        uint64 startBlock;
        uint64 endBlock; // 0 = open-ended
        uint64 roundBlocks;
        uint128 emissionPerRound;
        /// @dev The premium MONO must be trading at, in basis points, for this sale to open at
        ///      all. Checked once, in the constructor. `1500` is the intended 15%.
        uint16 minPremiumBips;
        /// @dev The sale this one succeeds, or `address(0)` for the first. Its constructor calls
        ///      `mintPack()` on it, so the outgoing sale's supply is minted before this one opens.
        ///      That auction must still hold `MINTER_ROLE` at that moment — deploy first, then
        ///      grant to this one, then revoke from it.
        address previousAuction;
    }

    /// @notice A price level in the persistent book.
    /// @dev `acc` is the additive depletion index: tokens per unit of stake, Q128, monotone.
    ///      `capTokens` is the tick's remaining capacity in SALE TOKENS — the sum of what its
    ///      seated (staked, un-exhausted) positions can still buy. Un-staked escrow is not in it
    ///      (the strict rule). `stakeSum` is the stake standing behind that capacity, and
    ///      `heapSize` counts the seated positions: each live tick keeps a min-heap of its
    ///      positions keyed by exhaustion point, so a pour touches only the ones that die.
    struct Tick {
        uint256 next; // next higher price (0 = none)
        uint256 prev; // next lower price (0 = none)
        uint256 capTokens; // remaining stake-covered capacity, in sale tokens
        uint256 stakeSum; // total stake of the seated positions
        uint256 acc; // Q128 tokens-per-stake, additive, only ever grows
        uint32 heapSize; // seated positions in the tick's kappa-heap
        bool init;
    }

    /// @notice One owner's standing offer. ONE bid per owner across the whole book: to change
    ///         price, withdraw and bid again. Survives rounds untouched.
    /// @dev Consumption is `min(cap, stake * (Tick.acc - accAtEntry))` where `cap` is the tokens
    ///      `amount` can buy at `price` — a closed form, so the pair `(amount, accAtEntry)` is
    ///      only readable together and is re-anchored by every harvest. `kappa` is the value of
    ///      `Tick.acc` at which the position exhausts — its key in the tick's heap — and
    ///      `heapIdx` is its 1-based seat there (0 = not seated: no stake, or exhausted).
    struct Position {
        uint256 price; // the one tick this owner bids at; 0 = no bid
        uint128 amount; // escrow as of `accAtEntry`; live escrow is derived, not stored
        uint128 tokensOwed; // harvested, unclaimed
        uint256 accAtEntry; // snapshot of `Tick.acc` when `amount` was last written
        uint256 kappa; // Tick.acc at which this position exhausts; heap key
        uint128 assetsOwed; // escrow charged for `tokensOwed`, recorded at harvest — the cost basis
        uint32 heapIdx; // 1-based index in the tick's heap; 0 = not seated
    }

    /// @notice One settle window as gathered: the live ticks inside the price band
    ///         `[tau - span, tau]`, where `span = windowTicks * tickSpacing`. Memory-only.
    /// @dev A band that wide holds at most `windowTicks + 1` distinct tick prices, so every array
    ///      here is sized once and the gather walk cannot outrun it. The pour itself moves the
    ///      band as its top runs dry (`_solveBand`), admitting lower ticks as it goes; `tau`,
    ///      `resume` and `steps` are updated in place to where it ended.
    struct Window {
        uint256 n; // live ticks collected
        uint256 tau; // price of the highest live tick — this window's top of book
        uint256 weightSum; // W = sum(w_i), Q96
        uint256 resume; // price to begin the next window from (0 = list exhausted)
        uint256 steps; // list nodes visited, charged against the caller's budget
        uint256[] price;
        uint256[] cap; // remaining capacity per tick, in sale tokens
        uint256[] weight; // q^d in Q96, always in (0, Q96]
    }

    // ---------------------------------------------------------------- events

    event BidSubmitted(address indexed owner, uint256 indexed price, uint128 amount);
    event BidWithdrawn(address indexed owner, uint256 indexed price, uint256 amount);
    event TickFilled(uint256 indexed price, uint256 currencyFilled, bool marginal);
    event Synced(uint256 emittedToDate, uint256 sold, uint256 carried);
    event RoundParamsQueued(uint64 fromBlock, uint64 roundBlocks, uint128 emissionPerRound);
    /// @param price The CURRENT bid price of the position — 0 if the bid was withdrawn, or a
    ///        re-bound price if it moved; use `assetsIn` for cost accounting, never this.
    /// @param tokens MONO paid to `owner`. May be under what the fill owed, if NAV rose past the
    ///        bid price between the fill and the claim — see `GenerousAuction.claim`.
    /// @param assetsIn The escrow these winnings actually spent, recorded at harvest time.
    event Claimed(address indexed owner, uint256 indexed price, uint256 tokens, uint256 assetsIn);
    /// @notice A pack was minted: `tokens` MONO now held here, bought with `assetsIn` of escrow
    ///         paid into the vault.
    event PackMinted(uint256 tokens, uint256 assetsIn);
    event Staked(address indexed owner, uint256 amount);
    event Unstaked(address indexed owner, uint256 amount);
    event Finalized();

    // ---------------------------------------------------------------- errors

    error InvalidParams();
    error AuctionEnded();
    error Unauthorized();
    error BidTooLow();
    error BidTooHigh();
    error BidTooSmall();
    error TickNotAligned();
    error TickSpacingTooSmall();
    error BelowNav();
    error NoPosition();
    error InvalidDecay();
    error InvalidWindow();
    error WindowTooNarrow();
    error PremiumTooLow();
    error NothingToSell();
    error NoStake();
    error StakeLocked();
    error BidExists();
    error InsufficientStake();
    error NotFinalizable();
    error SettleFirst();
    /// @notice `setRoundParams` past the last round boundary of a bounded sale: the schedule is
    ///         frozen at `endBlock`, a generation queued for a later boundary could never bite.
    error ScheduleFrozen();

    // ---------------------------------------------------------------- config

    /// @notice The token being sold — and the token that is staked.
    function token() external view returns (address);

    /// @notice The one currency bids may be placed and escrowed in. 18 decimals assumed.
    function currency() external view returns (address);

    /// @notice Lowest biddable price, and the one tick initialised at deploy.
    function floorPrice() external view returns (uint256);

    /// @notice Bid prices must be a multiple of this.
    function tickSpacing() external view returns (uint256);

    /// @notice Per-tick decay `q`, in Q96. `Q96` is 1.0 (flat split); smaller concentrates
    ///         supply at the top of the book.
    function decayQ() external view returns (uint256);

    /// @notice How many grid steps below the top of book still receive supply. Also the size
    ///         bound on a settle window.
    function windowTicks() external view returns (uint256);

    /// @notice The only address that may re-schedule emission.
    function admin() external view returns (address);

    /// @notice First block that accrues emission.
    function startBlock() external view returns (uint64);

    /// @notice Last block that accrues emission. 0 = open-ended.
    function endBlock() external view returns (uint64);

    // ---------------------------------------------------------------- state

    function ticks(uint256 price)
        external
        view
        returns (
            uint256 next,
            uint256 prev,
            uint256 capTokens,
            uint256 stakeSum,
            uint256 acc,
            uint32 heapSize,
            bool init
        );

    function positions(address owner)
        external
        view
        returns (
            uint256 price,
            uint128 amount,
            uint128 tokensOwed,
            uint256 accAtEntry,
            uint256 kappa,
            uint128 assetsOwed,
            uint32 heapIdx
        );

    /// @notice The stake standing behind `owner`'s bid, in sale tokens.
    function stakes(address owner) external view returns (uint256);

    /// @notice All stake held here. Never available to claims or packs.
    function totalStaked() external view returns (uint256);

    /// @notice True once the post-`endBlock` backlog is fully distributed and stakes unlock.
    function finalized() external view returns (bool);

    /// @notice The owners currently seated (staked, un-exhausted) at `price`, in heap order.
    function tickPositions(uint256 price) external view returns (address[] memory);

    /// @notice Booked and not yet claimed — what the pot owes claimants, a lower bound of the
    ///         sum of every position's `tokensOwed` (see `tokensBooked`).
    function tokensUnclaimed() external view returns (uint256);

    /// @notice Currency taken out of escrow by fills, cumulative. Never decreases — it is the
    ///         numerator `mintPack` measures against, not a live balance.
    function currencyRaised() external view returns (uint256);

    /// @notice Tokens minted into this contract by `mintPack`, cumulative. Trails `tokensBooked`
    ///         by whatever the last fill has not been packed yet, and by any NAV-clamp shortfall.
    function tokensMinted() external view returns (uint256);

    /// @notice Currency already paid into the vault by `mintPack`, cumulative.
    function currencyMinted() external view returns (uint256);

    /// @notice Mint the MONO for every fill that has not been packed yet, backed by the escrow
    ///         those fills spent, and hold it here for claimants. Permissionless and idempotent:
    ///         it mints the delta, so calling it twice in a block is a no-op the second time.
    /// @dev Deliberately NOT run by `sync` (a pack lifts NAV and would ratchet the bid floor
    ///      mid-sale): it runs at the head of every `claim`, on direct calls, and from the next
    ///      sale's constructor — which is how a successor closes this sale out.
    function mintPack() external returns (uint256 minted);

    /// @notice High-water mark of initialised ticks. May sit above every live tick.
    function highestTick() external view returns (uint256);

    /// @notice Where a `sync` truncated by its tick budget resumes. 0 = start from the top.
    function settleCursor() external view returns (uint256);

    /// @notice Tokens distributed since deploy, cumulative. Never decreases. Paces the
    ///         schedule: `due()` and `remaining()` are measured against it.
    function tokensSold() external view returns (uint256);

    /// @notice The part of `tokensSold` the pot owes claimants, cumulative: each pour books one
    ///         token-wei less per extra seated position than it hands out, the lower bound of
    ///         what those positions can crystallise and be charged for. `mintPack` mints the
    ///         gap to `tokensMinted`; the gap to `tokensSold` is uncollectable flooring dust.
    function tokensBooked() external view returns (uint256);

    /// @notice Blocks per emission round, and the tokens each completed round releases.
    function roundBlocks() external view returns (uint64);
    function emissionPerRound() external view returns (uint128);

    /// @notice Queued schedule, effective from `pendingFrom`. `pendingFrom == 0` = none queued.
    function pendingFrom() external view returns (uint64);
    function pendingRoundBlocks() external view returns (uint64);
    function pendingEmission() external view returns (uint128);

    /// @notice Cumulative tokens the schedule has released by now, over completed rounds only.
    function emittedToDate() external view returns (uint256);

    /// @notice What a `sync` right now would distribute: everything emitted and not yet sold,
    ///         including the carry from rounds the book could not absorb, capped at `saleSupply`.
    function due() external view returns (uint256);

    /// @notice Completed emission rounds since `startBlock`, counted under the schedule that
    ///         actually ran: a change of round length splits the count at its boundary, and a
    ///         queued generation already in effect is applied without waiting to be folded.
    function roundsElapsed() external view returns (uint256);

    // ---------------------------------------------------------------- emission

    /// @notice Distribute everything emitted and not yet sold across the book.
    /// @dev Permissionless and always callable. Also runs at the head of `submitBid`,
    ///      `withdrawBid`, `claim`, `stake` and `unstake`, so the book is never stale when it
    ///      changes shape or weight.
    /// @param maxTicks Budget in list nodes visited, not work inside a window; raised to the
    ///                 implicit-sync budget (128) when lower, so no call can park the cursor
    ///                 without doing at least that much work. A truncated sync saves
    ///                 `settleCursor` and the undistributed part stays in `due()`.
    function sync(uint256 maxTicks) external;

    /// @notice Queue a new emission schedule, effective from the next round boundary.
    /// @dev Admin only. Never retroactive: rounds already elapsed keep the rate they ran under,
    ///      whether or not anyone has synced them. A second call before the boundary replaces the
    ///      first.
    function setRoundParams(uint64 roundBlocks_, uint128 emissionPerRound_) external;

    // ---------------------------------------------------------------- staking

    /// @notice Stake `amount` of the sale token behind `msg.sender`'s bid. Within a tick, supply
    ///         is split proportionally to stake — escrow without stake buys nothing at all.
    /// @dev Allowed until `endBlock`, locked from `endBlock` until `finalize()`, free after.
    ///      Settles the book first, so the stake weighs only rounds from now on.
    function stake(uint256 amount) external;

    /// @notice Take back `amount` of stake. Same lock window as `stake`.
    /// @dev Unstaking to zero with a live bid leaves the bid inert: it stops buying and its
    ///      escrow stops counting as tick capacity, until re-staked or withdrawn.
    function unstake(uint256 amount) external;

    /// @notice Unlock stakes once the sale is over and the backlog is drained. Permissionless.
    /// @dev Flips (and returns true) when everything owed is distributed, or when a full sweep
    ///      can sell nothing — the book is dead and, with bids and stakes both frozen, will stay
    ///      dead. A call that still made progress keeps it and returns false: call again.
    ///      Packs on completion, so a finalized sale has nothing left to mint (to within one
    ///      NAV-wei); only a revoked minter role is tolerated there, any other pack failure
    ///      reverts the finalize. `maxTicks` is floored like `sync`'s. Reverts only before
    ///      `endBlock` or after the flag is already set.
    function finalize(uint256 maxTicks) external returns (bool done);

    // ---------------------------------------------------------------- bidding

    /// @notice Bid at `price`, escrowing `amount` of currency. ONE bid per owner: a second bid at
    ///         the same price tops the position up, a different price reverts `BidExists` — to
    ///         move, withdraw and bid again. Requires stake: escrow without stake buys nothing.
    /// @param owner Who controls and is paid by the position. Must equal `msg.sender` for every
    ///              bid, including same-price top-ups (`Unauthorized` otherwise).
    /// @param prevTick A hint: the exact predecessor of `price` in the book — the highest LINKED
    ///                 tick below it, read by walking `next` up from `floorPrice` on the public
    ///                 `ticks` getter. Verified in O(1) and used as is when right; when wrong,
    ///                 stale, or 0, the contract walks the list for the real predecessor at the
    ///                 caller's gas expense. Never reverts on the hint.
    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick) external;

    /// @notice Take back all of `msg.sender`'s standing escrow and close the bid. Tokens already
    ///         won stay claimable; the stake stays staked.
    function withdrawBid() external returns (uint256 live);

    // ---------------------------------------------------------------- payouts

    /// @notice Mint the tokens accrued by `owner`'s bid and send the escrow that paid for them
    ///         to the vault. Does NOT close the position — escrow still live keeps competing in
    ///         later rounds. Permissionless; pays `owner`.
    function claim(address owner) external returns (uint256 tokens);

    /// @notice Claim the caller's winnings straight into their stake account — one transaction,
    ///         no transfer out and back. Caller-only: nobody may compound someone else's tokens
    ///         into a stake they did not ask for. Inside the stake lock window it degrades to a
    ///         plain claim (winnings always flow; only the stake leg is frozen).
    function claimAndStake() external returns (uint256 tokens);

    // ---------------------------------------------------------------- views

    /// @notice What `owner` holds right now: escrow still competing, and tokens won.
    /// @dev The raw `positions` getter shows only the already-crystallised half; this adds the
    ///      part still folded into the tick's index.
    function positionOf(address owner) external view returns (uint256 live, uint256 tokensOwed);

    /// @notice The weight `q^d` a tick `d` grid steps below the top of book carries, in Q96.
    function weightAt(uint256 d) external view returns (uint256);

    /// @notice What the next sync window would look like right now, without changing anything.
    function previewWindow()
        external
        view
        returns (uint256 tau, uint256 weightSum, uint256[] memory price, uint256[] memory tokens);
}
