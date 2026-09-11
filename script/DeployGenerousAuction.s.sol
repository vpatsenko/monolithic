// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {GenerousAuction} from "../src/GenerousAuction.sol";
import {MockIndex} from "../src/MockIndex.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";

/// @notice Deploys one `GenerousAuction`. One deployment is one sale — there is no registry and no
///         second market, so a second sale is a second run of this script.
/// @dev Signer and network come from `.env` (forge loads it automatically): `WALLET_PRIVATE_KEY`,
///      `WALLET_ADDRESS`, and `RPC_URL_46630` behind the `chain46630` alias in `foundry.toml`. Run:
///
///          forge script script/DeployGenerousAuction.s.sol --rpc-url chain46630 --broadcast
///
///      The key is read inside the script rather than passed as `--private-key`, so it stays out of
///      the command line and the shell history.
///
///      The constructor validates everything — `InvalidParams`, `TickNotAligned`, `InvalidDecay`,
///      `WindowTooNarrow` — so this script re-checks none of it.
///
///      There is no funding step: the auction mints MONO at claim. What this script does instead is
///      the three-step bootstrap the mint path needs — deploy `Mono` (deployer is owner), `mint`
///      once to set the opening NAV, then transfer ownership to the fresh auction. After
///      the handoff — `grantRole(MINTER_ROLE, auction)` then `renounceRole(MINTER_ROLE, deployer)` —
///      the auction is the only address that can mint. The deployer keeps `DEFAULT_ADMIN_ROLE` and
///      could grant itself the minter role back; see `agent-docs/Mono.md` on why that is bounded.
contract DeployGenerousAuction is Script {
    // ---------------------------------------------------------------- the pair

    /// @dev The one currency bids are escrowed in, and the vault's backing asset — the constructor
    ///      requires `currency == Mono.asset()`. MockIndex, 18 decimals: the WAD fill math is not
    ///      decimal-agnostic, so that is a hard requirement, not a preference.
    address internal constant CURRENCY = 0x3a6Ff23D4f0Ae2E15499Dc198913e352965c8784;

    /// @dev The MONO/INDEX Uniswap v3 pool the premium gate reads. Create it out of band — it needs
    ///      MONO's address, which does not exist until this script runs, so it cannot be a constant
    ///      on a first deploy. Set `MONO_POOL_ADDRESS` in `.env` once the pool exists; the run
    ///      before that will revert `PremiumTooLow` or `PoolNotSet`, which is the gate working.

    // ---------------------------------------------------------------- economics

    /// @dev Lowest biddable price, in INDEX per 1e18 MONO. Must be a multiple of `TICK_SPACING`,
    ///      and bids are capped at 1e4x it.
    uint256 internal constant FLOOR_PRICE = 1e18;

    /// @dev Bid prices snap to this grid — 0.01 INDEX here, so 100 steps to double the floor. Fine
    ///      enough that rounding to a tick costs a bidder less than the gas to bid, coarse enough
    ///      that a live book is a few hundred ticks.
    uint256 internal constant TICK_SPACING = 1e16;

    /// @dev Per-step decay `q`, in Q96 (`1 << 96` is 1.0, i.e. a flat split). Below, 0.5.
    ///      Calibrate WITH `TICK_SPACING`: weights decay per grid step, so on this arithmetic grid
    ///      `q`'s reach is an absolute price band of `WINDOW_TICKS * TICK_SPACING` — 0.08 INDEX
    ///      here. In a dense book the top tick's share tends to `(1 - q)`, so this is also the soft
    ///      anti-whale cap: window width and top-cap strength are one knob, not two.
    uint256 internal constant DECAY_Q = (1 << 96) / 2;

    /// @dev How many grid steps below the top of book still receive supply, and the size bound on a
    ///      settle window. The constructor rejects `q^WINDOW_TICKS > 1%` so a pairing cannot
    ///      silently strand demand just past the edge; 0.5^8 = 0.39% clears it.
    ///
    ///      This is also the real ceiling on what one bidder pays for someone else's backlog —
    ///      ~9-17k gas per live tick, so ~150k dragged behind a bid at 8 and ~2.3M at the 255
    ///      maximum. Pick it against the bid cost, not only the edge weight.
    uint256 internal constant WINDOW_TICKS = 8;

    // ---------------------------------------------------------------- schedule

    /// @dev First block that accrues emission, on the clock the CONTRACT reads.
    ///
    ///      Read this from the chain before every deploy, and hardcode it. Do NOT derive it from
    ///      `block.number` here: chain 46630 is an Arbitrum Orbit rollup, where `block.number`
    ///      inside a contract returns the SETTLEMENT chain's height (Sepolia, ~11.5M) while
    ///      `eth_blockNumber` — what forge sees off-chain during simulation — returns the rollup's
    ///      own height (~101.6M). Deriving it here bakes in the second number, the contract then
    ///      compares against the first, and the schedule never starts. That killed
    ///      0x815B7e9705d16a67567B73425170d0bec260b049.
    ///
    ///      Get the right number with:
    ///
    ///          cast call --rpc-url chain46630 <AuctionBids> 'getBlock()(uint256)'
    ///
    ///      then add ~20 blocks of headroom so emission begins after the funding transfer below has
    ///      landed. A `START_BLOCK` in the past is REJECTED by the constructor (a stale start would
    ///      open the sale with a backlog already owed — 2.3 days stale is the whole sale); if the
    ///      deploy lands late, read the height again and redeploy.
    uint64 internal constant START_BLOCK = 11_494_800;

    /// @dev Last block that accrues emission; 0 = open-ended. Accrual is block-linear, so a life
    ///      that is not a whole multiple of `ROUND_BLOCKS` emits the exact pro-rata tail. A bounded
    ///      life must be at least one round long (constructor check).
    uint64 internal constant END_BLOCK = 0;

    /// @dev `EMISSION_PER_ROUND` MONO released every `ROUND_BLOCKS` blocks. The only two values
    ///      `ADMIN` can change later, and only from a future round boundary.
    ///
    ///      These count the same blocks `START_BLOCK` does — Sepolia's, at ~12.45 s — NOT the
    ///      rollup's ~0.17 s blocks. Sizing a round against the rollup's clock makes it ~73x longer
    ///      than intended. The conversion is roughly:
    ///
    ///          1 minute ≈ 5          1 hour ≈ 290
    ///          10 minutes ≈ 50       1 day  ≈ 6_950
    ///
    ///      15 puts a round every ~3 minutes, short enough to watch emission land during a test
    ///      session. At 100 MONO/round that draws ~48k MONO/day, so the 1M funded below lasts about
    ///      three weeks. Lengthen both if this is meant to run longer than that.
    uint64 internal constant ROUND_BLOCKS = 15;
    uint128 internal constant EMISSION_PER_ROUND = 100e18;

    /// @dev The premium MONO must be trading at for this sale to open, in bips. The harvest sells
    ///      into the spread between NAV and the market; at or below book there is no spread and the
    ///      sale is just supply. 15%.
    uint16 internal constant MIN_PREMIUM_BIPS = 1_500;

    // ---------------------------------------------------------------- genesis

    /// @dev The opening book: `GENESIS_SHARES` MONO against `GENESIS_ASSETS` INDEX, so NAV starts at
    ///      1.0 and every price on the grid at or above `FLOOR_PRICE` is a non-dilutive mint.
    uint256 internal constant GENESIS_SHARES = 1_000e18;
    uint256 internal constant GENESIS_ASSETS = 1_000e18;
    /// @dev Hard ceiling on that one mint, fixed in `Mono`'s constructor.
    uint256 internal constant GENESIS_CAP = 10_000e18;

    // ---------------------------------------------------------------- run

    /// @notice PHASE 1 of the deploy. The old single-shot `run()` was a deadlock: `setPool`
    ///         demands a pool paired with a Mono that does not exist until this very run, and
    ///         the auction constructor demands that pool be live and in-range — neither can
    ///         precede the other inside one atomic script. So: deploy Mono here, create and
    ///         seed the MONO/INDEX pool out of band against the printed address, then run
    ///         phase 2 (`run()`) with MONO_ADDRESS set.
    function deployMono() external returns (Mono mono) {
        address wallet = vm.envAddress("WALLET_ADDRESS");
        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));
        mono = new Mono(IIndex(CURRENCY), GENESIS_CAP);
        MockIndex(CURRENCY).approve(address(mono), GENESIS_ASSETS);
        mono.mint(GENESIS_SHARES, GENESIS_ASSETS, wallet);
        vm.stopBroadcast();
        console.log("Mono deployed :", address(mono));
        console.log("Next: create + seed the MONO/INDEX pool, then `run()` with MONO_ADDRESS set.");
    }

    /// @notice PHASE 2: wire the pool and deploy the auction against an EXISTING Mono.
    function run() external returns (GenerousAuction auction, Mono mono) {
        // The one privileged role goes to the deploying wallet. `admin` can do exactly one thing — re-schedule emission from a future boundary. It cannot
        // touch the book, the escrow, or anything already owed.
        address wallet = vm.envAddress("WALLET_ADDRESS");
        mono = Mono(vm.envAddress("MONO_ADDRESS"));

        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));

        // One shot, and it has to happen before the auction: its constructor reads the premium.
        mono.setPool(vm.envAddress("MONO_POOL_ADDRESS"));

        IGenerousAuction.Config memory c = IGenerousAuction.Config({
            token: address(mono),
            currency: CURRENCY,
            admin: wallet,
            floorPrice: FLOOR_PRICE,
            tickSpacing: TICK_SPACING,
            decayQ: DECAY_Q,
            windowTicks: WINDOW_TICKS,
            startBlock: START_BLOCK,
            endBlock: END_BLOCK,
            roundBlocks: ROUND_BLOCKS,
            emissionPerRound: EMISSION_PER_ROUND,
            minPremiumBips: MIN_PREMIUM_BIPS,
            // First sale in the chain. A successor passes the outgoing auction here instead.
            previousAuction: address(0)
        });

        // For a SUCCESSOR sale (`previousAuction != 0`) this constructor calls `mintPack()` on the
        // outgoing auction, so that one must STILL HOLD `MINTER_ROLE` right now. Revoke it only
        // after this line — cleaning the old role up first reverts the deployment.
        auction = new GenerousAuction(c);

        // The handoff: the auction becomes a minter, and the deployer stops being one. Granting
        // alone would leave two minters — `renounceRole` is the half that actually hands over.
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), wallet);
        // Now, and not before, the outgoing sale can be retired:
        //     mono.revokeRole(mono.MINTER_ROLE(), c.previousAuction);
        vm.stopBroadcast();

        console.log("GenerousAuction :", address(auction));
        console.log("token    (MONO) :", c.token);
        console.log("currency (INDEX):", c.currency);
        console.log("admin           :", c.admin);
        console.log("floorPrice      :", c.floorPrice);
        console.log("tickSpacing     :", c.tickSpacing);
        console.log("windowTicks     :", c.windowTicks);
        console.log("startBlock      :", c.startBlock);
        console.log("roundBlocks     :", c.roundBlocks);
        console.log("emission/round  :", c.emissionPerRound);
        console.log("Mono            :", address(mono));
        console.log("nav             :", mono.nav());
        console.log("auction is minter:", mono.hasRole(mono.MINTER_ROLE(), address(auction)));
        console.log("deployer minter  :", mono.hasRole(mono.MINTER_ROLE(), wallet));
    }
}
