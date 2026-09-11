// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// `roundsElapsed()` used to divide the whole span since `startBlock` by whatever `roundBlocks`
/// happened to be stored, so it over-counted across a length change and jumped when an admin
/// queued something in the same block (round-11). It now carries completed rounds at the anchor
/// and applies an already-effective queued generation itself. Checked here against an
/// independent model that walks the schedule one boundary at a time.
contract RegressionRoundsElapsed is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    address internal constant ADMIN = address(0xF1);

    uint64 internal start;

    /// The model: replay the generations in order and count the boundaries that fit.
    /// `gens` is (fromBlock, roundBlocks) in ascending order, the first at `start`.
    function _model(uint64[] memory froms, uint64[] memory lens, uint256 n, uint256 t)
        internal
        pure
        returns (uint256 done)
    {
        for (uint256 i; i < n; ++i) {
            if (t <= froms[i]) break;
            uint256 upTo = i + 1 < n && t > froms[i + 1] ? froms[i + 1] : t;
            done += (upTo - froms[i]) / lens[i];
        }
    }

    function _deploy(uint64 end, uint64 k) internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        start = uint64(block.number);
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: ADMIN,
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: Q96 / 2,
                windowTicks: 8,
                startBlock: start,
                endBlock: end,
                roundBlocks: k,
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    /// Three generations, two folds, checked at every boundary and in between.
    function test_countsAcrossSeveralLengthChanges() public {
        _deploy(0, 100);
        uint64[] memory froms = new uint64[](3);
        uint64[] memory lens = new uint64[](3);
        froms[0] = start;
        lens[0] = 100;

        vm.roll(start + 50);
        vm.prank(ADMIN);
        auction.setRoundParams(200, 100e18); // effective at start+100
        froms[1] = auction.pendingFrom();
        lens[1] = 200;
        assertEq(froms[1], start + 100);

        vm.roll(start + 300); // rounds: [0,100] and [100,300] = 2
        assertEq(auction.roundsElapsed(), _model(froms, lens, 2, start + 300), "before the second queue");
        assertEq(auction.roundsElapsed(), 2, "two completed rounds");

        // Queuing a FUTURE change folds the effective one; the count must not move.
        vm.prank(ADMIN);
        auction.setRoundParams(50, 100e18);
        froms[2] = auction.pendingFrom();
        lens[2] = 50;
        assertGt(froms[2], start + 300);
        assertEq(auction.roundsElapsed(), 2, "queuing rewrote history");

        // Walk forward across the third generation's boundary and keep agreeing with the model.
        for (uint256 b = start + 300; b <= uint256(froms[2]) + 220; b += 37) {
            vm.roll(b);
            assertEq(auction.roundsElapsed(), _model(froms, lens, 3, b), "diverged from the model");
        }
    }

    /// Before `startBlock` nothing has elapsed, and the very first boundary lands exactly.
    function test_beforeStartAndFirstBoundary() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        uint64 later = uint64(block.number) + 500;
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: ADMIN,
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: Q96 / 2,
                windowTicks: 8,
                startBlock: later,
                endBlock: 0,
                roundBlocks: 100,
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        assertEq(auction.roundsElapsed(), 0, "nothing before the start");
        vm.roll(later);
        assertEq(auction.roundsElapsed(), 0, "at the start");
        vm.roll(later + 99);
        assertEq(auction.roundsElapsed(), 0, "one block short");
        vm.roll(later + 100);
        assertEq(auction.roundsElapsed(), 1, "first boundary");
    }

    /// Past `endBlock` the schedule is frozen, so the count freezes with it.
    function test_freezesAtEndBlock() public {
        uint64 end = uint64(block.number) + 350;
        _deploy(end, 100);
        vm.roll(end);
        uint256 atEnd = auction.roundsElapsed();
        assertEq(atEnd, 3, "three whole rounds inside the life");
        vm.roll(end + 10_000);
        assertEq(auction.roundsElapsed(), atEnd, "the frozen schedule completes no more rounds");
    }

    /// The count moves only when a boundary is crossed — never because someone called the admin.
    function testFuzz_queuingNeverMovesTheCount(uint64 rawLen, uint16 rawWait) public {
        _deploy(0, 100);
        uint64 len = uint64(bound(uint256(rawLen), 1, 5_000));
        uint256 wait = bound(uint256(rawWait), 1, 4_000);
        vm.roll(start + wait);
        uint256 before = auction.roundsElapsed();
        vm.prank(ADMIN);
        auction.setRoundParams(len, 100e18);
        assertEq(auction.roundsElapsed(), before, "a queue moved the completed-round count");
        // And folding it in later, in a block where no boundary is crossed, does not either.
        vm.roll(uint256(auction.pendingFrom()) + 1);
        uint256 mid = auction.roundsElapsed();
        vm.prank(ADMIN);
        auction.setRoundParams(len, 100e18);
        assertEq(auction.roundsElapsed(), mid, "a fold moved the completed-round count");
    }
}
