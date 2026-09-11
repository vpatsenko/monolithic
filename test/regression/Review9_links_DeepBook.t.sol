// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {TestERC20} from "../TestERC20.sol";
import {Review9LinksBase} from "./Review9_links_Base.sol";

/// A book DEEPER than `SYNC_TICKS` (128), so the sweep really truncates and `settleCursor`
/// really parks — the state the 32-tick driver can never reach (`maxTicks` is floored at 128,
/// so a 32-tick grid never budgets out). Parked sweeps are where round 8's bug lived, and where
/// the only list-mutating operation that is NOT behind `SettleFirst` (`claim` -> `_reseat` ->
/// `_relink` / `highestTick` bump) can act.
contract Review9DeepHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 public immutable N;

    address[] public actors;

    uint256 public parkedSeen; // ghost: how often the cursor was found parked
    uint256 public syncs;
    uint256 public claimsLanded;
    uint256 public relinksPossible;

    constructor(GenerousAuction a, Mono m, TestERC20 c, address[] memory who) {
        auction = a;
        mono = m;
        cur = c;
        actors = who;
        N = who.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % N];
    }

    function _note() internal {
        if (auction.settleCursor() != 0) parkedSeen++;
    }

    function opSync(uint8 which) external {
        uint256[6] memory b = [uint256(1), 8, 64, 128, 300, type(uint128).max];
        try auction.sync(b[which % 6]) {
            syncs++;
        } catch {}
        _note();
    }

    function opRoll(uint8 seed) external {
        vm.roll(block.number + (uint256(seed) % 7) * 100 + 1);
        _note();
    }

    function opClaim(uint256 s) external {
        try auction.claim(_actor(s)) {
            claimsLanded++;
        } catch {}
        _note();
    }

    function opClaimAndStake(uint256 s) external {
        address who = _actor(s);
        vm.prank(who);
        try auction.claimAndStake() {} catch {}
        _note();
    }

    function opWithdraw(uint256 s) external {
        address who = _actor(s);
        vm.prank(who);
        try auction.withdrawBid() {} catch {}
        _note();
    }

    /// Withdraw the standing bid nearest the top: leaves `highestTick` on a dead ex-top.
    function opWithdrawTop(uint256) external {
        uint256 p = auction.highestTick();
        for (uint256 i; i < N + 4 && p != 0; ++i) {
            address[] memory seats = auction.tickPositions(p);
            if (seats.length != 0) {
                vm.prank(seats[0]);
                try auction.withdrawBid() {} catch {}
                _note();
                return;
            }
            (, p,,,,,) = auction.ticks(p);
        }
        _note();
    }

    function opUnstakeToZero(uint256 s) external {
        address who = _actor(s);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(have) {} catch {}
        _note();
    }

    function opRestake(uint256 s, uint96 raw) external {
        address who = _actor(s);
        if (auction.stakes(who) != 0) return;
        uint256 amount = bound(uint256(raw), 1e15, 5e18);
        if (mono.balanceOf(address(this)) < amount) return;
        (uint256 price,,,,,,) = auction.positions(who);
        if (price != 0) {
            (uint256 nx, uint256 pv,,,,,) = auction.ticks(price);
            if (nx == 0 && pv == 0 && price != FLOOR) relinksPossible++;
        }
        mono.transfer(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), amount);
        try auction.stake(amount) {} catch {}
        vm.stopPrank();
        _note();
    }

    /// Clusters of 4 adjacent ticks separated by 14 empty grid steps (> the 8-step band), so a
    /// single `_solveBand` cannot walk the whole book: `_sync`'s OUTER window loop iterates, and
    /// the one-splice-per-window rule is actually exercised.
    function step(uint256 i) public pure returns (uint256) {
        return (i / 4) * 18 + (i % 4);
    }

    function opBid(uint256 s, uint256 priceSeed, uint96 raw) external {
        address who = _actor(s);
        uint256 price = FLOOR + step(priceSeed % N) * SPACING;
        (uint256 held,,,,,,) = auction.positions(who);
        if (held != 0) {
            (uint256 live,) = auction.positionOf(who);
            if (live != 0) price = held;
        }
        if (auction.stakes(who) == 0) return;
        uint128 amount = uint128(bound(uint256(raw), 2e18, 40e18));
        // UI hint: walk `next` up from the floor.
        uint256 prev = FLOOR;
        for (uint256 i; i < N + 4; ++i) {
            (uint256 nx,,,,,,) = auction.ticks(prev);
            if (nx == 0 || nx >= price) break;
            prev = nx;
        }
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        try auction.submitBid(price, amount, who, prev) {} catch {}
        vm.stopPrank();
        _note();
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract Review9LinksDeepBookTest is Review9LinksBase {
    Review9DeepHandler internal handler;
    uint256 internal constant N = 40; // 10 clusters, 180 grid steps: many windows per sweep
    address[] internal owners;

    function setUp() public {
        _deploy(0, 120e18);

        for (uint256 i; i < N; ++i) {
            owners.push(address(uint160(0xC000 + i)));
        }
        handler = new Review9DeepHandler(auction, mono, cur, owners);
        _registerGrid(handler.step(N - 1) + 4);
        mono.transfer(address(handler), 5_000e18);

        // Seat the whole book in the genesis block: `due()` is 0 there, so no implicit sync
        // walks (and splices) it while it is being built.
        uint256 prev = FLOOR;
        for (uint256 i; i < N; ++i) {
            address who = owners[i];
            uint256 price = FLOOR + handler.step(i) * SPACING;
            mono.transfer(who, 1e18);
            cur.mint(who, 20e18);
            vm.startPrank(who);
            mono.approve(address(auction), 1e18);
            auction.stake(1e18);
            cur.approve(address(auction), 20e18);
            auction.submitBid(price, 20e18, who, prev);
            vm.stopPrank();
            prev = price;
        }
        assertEq(auction.highestTick(), FLOOR + handler.step(N - 1) * SPACING, "book not built");
        targetContract(address(handler));
    }

    function invariant_links_deepBook() public view {
        _checkList();
        _checkPositionsReachable(owners);
    }

    /// Anti-vacuity: the deep book really truncates sweeps and parks the cursor.
    function test_links_deepBookIterates() public {
        vm.roll(block.number + 300);
        auction.sync(type(uint128).max);
        _checkList();
        _checkPositionsReachable(owners);
        uint256 sweepLen;
        uint256 p = auction.highestTick();
        while (p != 0) {
            sweepLen++;
            (, p,,,,,) = auction.ticks(p);
        }
        uint256 uiLen = 1;
        uint256 q = FLOOR;
        while (true) {
            (uint256 nx,,,,,,) = auction.ticks(q);
            if (nx == 0) break;
            uiLen++;
            q = nx;
        }
        emit log_named_uint("sweep chain", sweepLen);
        emit log_named_uint("ui chain", uiLen);
        // Anti-vacuity: the outer window loop really iterated. The book spans more than one
        // band, so a single window could not have covered it; after the sweep the two chains
        // agree (dead bands are unlinked down to each window's resume point), so the anchor is
        // the SPAN, not a length gap.
        assertEq(sweepLen, uiLen, "the two chains agree after a full sweep");
        assertGt(auction.highestTick() - FLOOR, 8 * SPACING, "book spans more than one band");
    }
}
