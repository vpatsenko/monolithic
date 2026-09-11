// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 7 / organic-UX lens — NO adversary. A deterministic 8-step replay of what the random
/// honest-population simulation (`Review7_organic_Base.t.sol`, keeper sync(64) every 25 blocks,
/// 36 users) reached on its own at block ~11,400: a self-loop in the tick list that bricks every
/// entry point, escrow and stakes included.
///
/// Mechanism (all `src/GenerousAuction.sol`):
///   - `_splice(hi, lo)` (l.725) rewrites only `ticks[hi].prev` and `ticks[lo].next`; the OLD
///     `lo.next` and `hi.prev` partners keep pointing at `lo`/`hi`. When the same `lo` is spliced
///     to a second `hi'` (after a trap node was re-exposed and died), `lo.next` moves to `hi'`
///     while `hi.prev` still says `lo` — so `hi` now FAILS `_initializeTick`'s back-pointer check
///     (l.1233) although it is the top of the list.
///   - The exact chain predecessor of `hi` is `lo` (its `prev`), but `ticks[lo].next < hi`, so
///     the correct hint reverts `BadPrevHint` (l.1239). The ONLY init tick `x < hi` with
///     `next >= hi` is the stale node whose `.next == hi`. `_initializeTick` accepts
///     `nextPrice == price` (the check is `nextPrice < price`, l.1239) and then executes
///     `ticks[nextPrice].prev = price` (l.1247) — i.e. `ticks[hi].prev = hi`.
///   - `submitBid` lifts `highestTick` onto `hi` (l.580). Every `_gather` (l.741) now walks
///     `hi -> hi -> hi ...`, `w.n` outruns the `windowTicks + 1` arrays and the call panics
///     0x32. `_sync` runs first in `sync`/`submitBid`/`withdrawBid`/`claim`/`stake`/`unstake`/
///     `finalize`, so all of them revert forever. There is no admin path that touches links.
contract Review7OrganicSelfLoopBrick is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    uint256 internal constant P7 = FLOOR + 7 * SPACING;
    uint256 internal constant P9 = FLOOR + 9 * SPACING;
    uint256 internal constant P10 = FLOOR + 10 * SPACING;
    uint256 internal constant P11 = FLOOR + 11 * SPACING;
    uint256 internal constant P12 = FLOOR + 12 * SPACING;

    address internal alice = address(0xA11CE); // long-lived bidder at 1.07
    address internal b9 = address(0xB9);
    address internal b10 = address(0xB10);
    address internal b11 = address(0xB11);
    address internal b12 = address(0xB12);
    address internal carol = address(0xCA201); // honest re-bid at 1.10 (an old price)
    address internal dave = address(0xDA4E); // honest re-bid at 1.12 (an old price)

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));

        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 50e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        address[7] memory all = [alice, b9, b10, b11, b12, carol, dave];
        for (uint256 i; i < 7; ++i) {
            mono.transfer(all[i], 1e18);
            cur.mint(all[i], 10_000e18);
            vm.startPrank(all[i]);
            mono.approve(address(auction), type(uint256).max);
            cur.approve(address(auction), type(uint256).max);
            auction.stake(1e18);
            vm.stopPrank();
        }
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 hint)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(who);
        (ok, ret) = address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (price, amount, who, hint)));
    }

    /// What a UI computes: the top of the list via `next` from `highestTick`, then the first
    /// node below `price` walking `prev`.
    function _chainHint(uint256 price) internal view returns (uint256 p) {
        p = auction.highestTick();
        for (uint256 i; i < 64; ++i) {
            (uint256 nx,,,,,,) = auction.ticks(p);
            if (nx == 0) break;
            p = nx;
        }
        for (uint256 i; i < 64 && p != 0; ++i) {
            if (p < price) return p;
            (, uint256 pv,,,,,) = auction.ticks(p);
            p = pv;
        }
        return FLOOR;
    }

    function _links(string memory tag) internal {
        emit log_string(tag);
        for (uint256 d; d <= 12; ++d) {
            uint256 p = FLOOR + d * SPACING;
            (uint256 nx, uint256 pv, uint256 cap,,,, bool init) = auction.ticks(p);
            if (!init) continue;
            emit log_string(string.concat(
                    "  d",
                    vm.toString(d),
                    ": next d",
                    vm.toString(nx / 1e16),
                    " prev d",
                    vm.toString(pv / 1e16),
                    cap != 0 ? "  LIVE" : ""
                ));
        }
        emit log_named_uint("  highestTick d", auction.highestTick() / 1e16);
    }

    /// The eight honest steps that used to brick the sale. Now: the splice unlinks the dead
    /// interior run, every re-bid with the hint the book itself shows is accepted and linked,
    /// the list stays sound, and every entry point keeps working.
    function test_honestRebidsKeepTheListSoundAndTheSaleAlive() public {
        // 1. A normal book: a long-lived bidder at 1.07 and four small bidders above it.
        (bool ok,) = _bid(alice, P7, 1000e18, FLOOR);
        assertTrue(ok);
        (ok,) = _bid(b9, P9, 2e18, P7);
        assertTrue(ok);
        (ok,) = _bid(b10, P10, 2e18, P9);
        assertTrue(ok);
        (ok,) = _bid(b11, P11, 2e18, P10);
        assertTrue(ok);
        (ok,) = _bid(b12, P12, 2e18, P11);
        assertTrue(ok);

        // 2. One round: the four small positions exhaust; alice absorbs the rest.
        vm.roll(block.number + K);
        auction.sync(64);
        // 3. Next round: whatever the sweep walked dead is spliced out, interior nodes unlinked;
        //    what it did not walk stays linked and dead. Either way the list is sound.
        vm.roll(block.number + K);
        auction.sync(64);
        _links("after the small seats died:");
        _assertListSound();

        // 4. carol re-bids at 1.10 with the hint the book shows.
        (ok,) = _bid(carol, P10, 2e18, _chainHint(P10));
        assertTrue(ok, "carol's re-bid at 1.10 is accepted");
        assertEq(auction.highestTick(), P10);
        _assertListSound();

        // 5-6. carol exhausts; the next sweeps walk 10 -> 7. Nothing is left stale.
        vm.roll(block.number + K);
        auction.sync(64);
        vm.roll(block.number + K);
        auction.sync(64);
        _links("after the second sweep:");
        _assertListSound();

        // 7. dave re-bids at 1.12 with the exact predecessor the list shows. Accepted, no loop.
        uint256 hint = _chainHint(P12);
        (ok,) = _bid(dave, P12, 2e18, hint);
        assertTrue(ok, "the hint read off the live list is accepted");
        _links("after dave's re-bid:");
        (uint256 nx12, uint256 pv12,,,,,) = auction.ticks(P12);
        assertTrue(pv12 != P12 && nx12 != P12, "no self-loop");
        assertEq(auction.highestTick(), P12);
        _assertListSound();

        // 8. Everything keeps working: sync, preview, withdraw, unstake, claim.
        vm.roll(block.number + 1);
        auction.sync(64);
        auction.previewWindow();
        vm.prank(alice);
        auction.withdrawBid();
        vm.prank(alice);
        auction.unstake(1e18);
        auction.claim(alice);
        (uint256 live, uint256 owed) = auction.positionOf(alice);
        assertEq(live, 0, "alice took her escrow home");
        assertEq(owed, 0, "and her winnings");
        assertGt(mono.balanceOf(alice), 1e18, "alice holds her stake back plus winnings");
    }

    /// The exact walk `_gather` does: strictly decreasing, consistent links, ends at the floor.
    function _assertListSound() internal view {
        uint256 p = auction.highestTick();
        uint256 last = type(uint256).max;
        for (uint256 i; i < 32 && p != 0; ++i) {
            assertLt(p, last, "not strictly decreasing");
            (uint256 nx, uint256 pv,,,,,) = auction.ticks(p);
            if (pv != 0) {
                (uint256 pvNext,,,,,,) = auction.ticks(pv);
                assertEq(pvNext, p, "prev.next != self");
            }
            if (nx != 0) {
                (, uint256 nxPrev,,,,,) = auction.ticks(nx);
                assertEq(nxPrev, p, "next.prev != self");
            }
            last = p;
            p = pv;
        }
        assertEq(p, 0, "walk did not terminate");
        assertEq(last, FLOOR, "walk did not end at the floor");
    }
}
