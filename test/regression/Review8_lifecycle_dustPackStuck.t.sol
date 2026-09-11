// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8LifecycleBase} from "./Review8_lifecycle_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// REVIEW 8 / lifecycle — `_mintPack`'s `maxIssuable` clamp (GenerousAuction.sol:1419-1421) at
/// the wei scale, against the succession runbook's checkpoint and `finalize`'s pack.
///
/// `_mintPack` mints `min(shares, maxIssuable(assets))` and returns 0 — packing NOTHING — when
/// that is 0. `Mono.maxIssuable(assets)` is `assets * supply / totalIndex`, which floors to 0
/// for any `assets` below one NAV-wei. So a booking of 1 token-wei against 1 currency-wei can
/// never be packed once NAV is strictly above 1.0 (i.e. after the first pack of any fill above
/// the floor), and since every later pack takes the WHOLE delta, the only way it ever clears
/// is a later, bigger pour merging with it. If it is the LAST pour of the sale — the residue
/// wei the inter-tick floors leave in `due()` (round-7 #25), sold by the next sync — it is
/// stuck for good:
///   - `currencyMinted() == currencyRaised()`, the runbook's "nothing left to pack" signal for
///     revoking the predecessor's role, is never true;
///   - `finalize`'s pack leaves the sale finalized-but-unpacked by that wei, so the
///     `finalized == packed` reading is false even with unlimited gas and the role held.
/// Economically nil (1 wei); operationally the documented checkpoint is unreachable.
/// Found by the lifecycle invariant handler (bounded variant, `invariant_finalizedIsTerminalAndPacked`).
contract Review8LifecycleDustPackStuck is Review8LifecycleBase {
    function setUp() public {
        _freshMono();
    }

    /// Deterministic shape: NAV lifted above 1.0 by a mid-sale claim, everything packed, then a
    /// lone 1-wei pour as the sale's last event (a 1-wei-per-block schedule queued for a final
    /// round that is one block long — the invariant run reached the same state through the
    /// lever set to 1 wei per round). Any later normal-scale pour would absorb the wei; the
    /// point is that nothing guarantees one.
    function test_CHAR_oneWeiBookingIsNeverPackable_checkpointIsOneNavWei() public {
        uint64 end = uint64(block.number) + 2 * K + 1;
        _deployWith(_config(100e18, end));
        _bidCap(aa, P(3), 1_000e18, FLOOR); // fills at 1.03: the first pack lifts NAV above 1.0
        vm.roll(block.number + K);
        auction.claim(aa);
        assertGt(mono.nav(), 1e18, "NAV strictly above 1.0 after the first pack");

        // Last round at 100 wei per round == 1 wei per block. Round 2 (still at 100e18) is
        // sold and packed at the boundary, so the dust round's first wei is the whole delta.
        vm.prank(ADMIN);
        auction.setRoundParams(K, 100);
        vm.roll(auction.pendingFrom());
        auction.sync(200);
        assertGt(auction.mintPack(), 0, "round 2 packed");
        assertEq(auction.currencyMinted(), auction.currencyRaised(), "clean before the dust");
        vm.roll(block.number + 1); // == endBlock: one block of the dust round, 1 wei owed
        assertEq(uint64(block.number), end);
        assertEq(auction.due(), 1);
        auction.sync(200); // 1 token-wei booked at 1.03 -> 1 currency-wei
        uint256 unpackedT = auction.tokensBooked() - auction.tokensMinted();
        uint256 unpackedC = auction.currencyRaised() - auction.currencyMinted();
        emit log_named_uint("unpacked token-wei", unpackedT);
        emit log_named_uint("unpacked currency-wei", unpackedC);
        emit log_named_uint("maxIssuable(unpacked currency)", mono.maxIssuable(unpackedC));
        assertEq(auction.mintPack(), 0, "mintPack packs nothing");

        bool done;
        for (uint256 i; i < 6 && !done; ++i) {
            done = auction.finalize(400);
        }
        assertTrue(auction.finalized());
        emit log_named_uint(
            "currencyRaised - currencyMinted after finalize", auction.currencyRaised() - auction.currencyMinted()
        );
        assertEq(auction.mintPack(), 0, "still nothing packable");
        // The runbook checkpoint is "less than one NAV-wei unpacked": a delta `maxIssuable`
        // floors to zero can never pack, and it is at most `nav() / 1e18` (+1 for rounding).
        assertLe(
            auction.currencyRaised() - auction.currencyMinted(),
            mono.nav() / 1e18 + 1,
            "runbook checkpoint: at most one NAV-wei left to pack"
        );
    }

    /// Organic control, characterised: a two-tick book's end-of-sale sweep leaves a 1-wei
    /// flooring residue in `due()` (round-7 #25) — but that wei is never SOLD (the q-weighted
    /// payout floors it to 0), so `finalize` flips via the dead-book fallback with nothing
    /// unpacked. At deploy-script emission the stuck booking above needs the admin lever set to
    /// a dust rate; `emissionPerRound_` has no lower bound.
    function test_CHAR_endOfSaleResidueBookings() public {
        uint64[4] memory tails = [uint64(37), 53, 71, 89];
        for (uint256 t; t < 4; ++t) {
            uint256 snap = vm.snapshotState();
            uint64 end = uint64(block.number) + 2 * K + tails[t];
            _deployWith(_config(100e18, end));
            _bidCap(aa, P(3), 1_000e18, FLOOR);
            _bidCap(bb, P(0), 1_000e18, FLOOR);
            vm.roll(block.number + K);
            auction.claim(aa); // NAV > 1.0
            vm.roll(end);
            auction.sync(400);
            uint256 residue = auction.due();
            bool done;
            for (uint256 i; i < 6 && !done; ++i) {
                done = auction.finalize(400);
            }
            emit log_named_uint("tail blocks", tails[t]);
            emit log_named_uint("  residue in due() after the full end sweep (wei)", residue);
            emit log_named_uint(
                "  unpacked currency-wei after finalize", auction.currencyRaised() - auction.currencyMinted()
            );
            emit log_named_uint("  unpacked token-wei after finalize", auction.tokensBooked() - auction.tokensMinted());
            vm.revertToState(snap);
        }
    }
}
