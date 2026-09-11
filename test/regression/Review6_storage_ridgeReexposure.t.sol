// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 6 / storage lens. Wall shaving + `_splice` are documented as making a dead ridge a
/// ONE-TIME cost. They are not: `_splice` (GenerousAuction.sol:725-730) re-links only the two
/// endpoints, every interior node keeps its stale `prev`/`next`, and `_initializeTick`
/// (GenerousAuction.sol:1228-1234) accepts a stale interior node as "linked" because its stale
/// predecessor's `next` still points back at it. One dust bid at such a node makes it
/// `highestTick` (GenerousAuction.sol:580), the next sweep starts there (:658) and re-walks the
/// stale chain below it (:745-754). Cost to the attacker: one bid. Cost to the book: O(chain)
/// SLOADs plus a `SettleFirst` lockout of every weight-moving entry point until the chain is
/// shaved 128 nodes per implicit sync (SYNC_TICKS, :122). Repeatable once per chain node.
contract Review6StorageRidgeReexposureTest is Test {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;
    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant N = 1000;

    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    address internal att = address(0xA77);
    address internal hh = address(0xB1);
    address internal hh2 = address(0xB2);

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
                decayQ: Q96 / 2,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function P(uint256 i) internal pure returns (uint256) {
        return FLOOR + i * SPACING;
    }

    function _stake(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, prev);
        vm.stopPrank();
    }

    function _syncGas() internal returns (uint256 used) {
        uint256 g = gasleft();
        auction.sync(type(uint256).max);
        used = g - gasleft();
    }

    /// Dust bid: escrow that buys exactly 1 token-wei, so the tick dies on the next pour and the
    /// sweep walks on past it.
    function _dust(address who, uint256 price) internal {
        uint128 amt = uint128(price / 1e18 + 1);
        _bid(who, price, amt, FLOOR);
    }

    function test_ridgeReexposure_oneDustBidRewalksWholeRidge() public {
        // Attacker ridge P1..PN, all dead. Honest floor bidder.
        _stake(att, 1e18);
        uint256 prev = FLOOR;
        for (uint256 i = 1; i <= N; ++i) {
            _bid(att, P(i), 2e18, prev);
            vm.prank(att);
            auction.withdrawBid();
            prev = P(i);
        }
        _stake(hh, 1e18);
        _bid(hh, FLOOR, 100_000e18, FLOOR);
        _stake(hh2, 1e18);

        // 1. First sweep walks the ridge and shaves/splices it: paid once, as documented.
        vm.roll(block.number + K);
        uint256 g1 = _syncGas();
        assertEq(auction.settleCursor(), 0);
        assertEq(auction.highestTick(), FLOOR, "wall shaved to the floor");

        // 2. Steady state: the ridge is gone from the sweep's path.
        vm.roll(block.number + K);
        uint256 g2 = _syncGas();
        emit log_named_uint("sync gas: first walk over N dead ticks", g1);
        emit log_named_uint("sync gas: steady state after shave+splice", g2);
        emit log_named_uint("approx gas per dead tick on the walk", (g1 - g2) / N);

        // 3. One dust bid at a stale INTERIOR node (P(N-1): P(N-2).next still == P(N-1)).
        _dust(att, P(N - 1));
        assertEq(auction.highestTick(), P(N - 1), "the orphan node became the high-water");

        // 4. The next honest weight change must NOT be locked out: the ridge was unlinked once,
        //    so the implicit sync(128) has nothing to re-walk and the bid lands.
        vm.roll(block.number + K);
        cur.mint(hh2, 10e18);
        vm.startPrank(hh2);
        cur.approve(address(auction), 10e18);
        auction.submitBid(FLOOR, 10e18, hh2, FLOOR);
        vm.stopPrank();
        assertEq(auction.settleCursor(), 0, "the implicit sync settled the book");

        // 5. What it now costs to make the book usable again.
        uint256 g3 = _syncGas();
        assertEq(auction.settleCursor(), 0, "full sweep restores the book");
        emit log_named_uint("sync gas: re-walk after ONE dust bid", g3);

        // 6. Repeatable: the chain below the previous splice point is still stale. The walk
        //    above spliced (P(N-1) -> P(N-9)... no: only the gather START nodes get re-linked),
        //    so a dust bid just below the last splice point re-walks the rest.
        //    Find the highest still-stale node under the floor's new `next`.
        (uint256 fNext,,,,,,) = auction.ticks(FLOOR);
        emit log_named_uint("F.next after re-walk", fNext);
        // Nothing is left stale-linked to re-expose: the sweep unlinks a window's whole dead band
        // (down to `w.resume`) once it has run dry, so the ridge is gone from BOTH chains and the
        // floor is the only node left. A second dust bid therefore re-inserts a fresh tick rather
        // than dragging the ridge back.
        assertEq(fNext, 0, "the whole ridge is reclaimed: the floor is the only node left");
        uint256 target = P(N / 2);
        vm.roll(block.number + K);
        _syncGas(); // clear the block first (steady state)
        _dust(att, target);
        (uint256 fNext2,,,,,,) = auction.ticks(FLOOR);
        assertEq(fNext2, target, "the dust bid is a plain insert above the floor");
        vm.roll(block.number + K);
        uint256 g4 = _syncGas();
        emit log_named_uint("sync gas: re-walk after a SECOND dust bid", g4);
        // One fresh tick to pour and unlink, not a thousand: a small multiple of the no-op
        // steady state, and orders below the first walk over the ridge.
        assertLt(g4, 4 * g2, "and it costs a steady-state sync, not a ridge re-walk");
        assertLt(g4, g1 / 10, "nowhere near the original ridge walk");

        // The documented claim: the ridge is a one-time cost. One dust bid must not bring it back.
        assertLt(g3, 2 * g2, "one dust bid must not re-expose the spliced ridge to the sweep");
    }
}
