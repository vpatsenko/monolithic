// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {TestERC20} from "../TestERC20.sol";
import {Review9LinksBase} from "./Review9_links_Base.sol";

/// Randomised driver over a grid FOUR TIMES wider than the window band, with the operations that
/// historically broke the tick list: fresh bids, re-bids at an old price, top-ups, withdrawal of
/// the CURRENT top bidder, unstake-to-zero, re-stake after a sweep unlinked the tick, syncs at
/// budgets 1 / 8 / 64 / huge, rolls of varying length, claims (which now re-seat, and do so
/// WITHOUT the `SettleFirst` guard), and deliberately wrong bid hints.
contract Review9LinksHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant GRID = 32;
    uint64 internal constant K = 100;

    address[8] public actors;
    uint256 public staleHint; // a hint remembered from an earlier block, as a UI would

    uint256 public bids;
    uint256 public withdrawals;
    uint256 public zeroUnstakes;
    uint256 public restakes;
    uint256 public claims;

    constructor(GenerousAuction a, Mono m, TestERC20 c) {
        auction = a;
        mono = m;
        cur = c;
        for (uint256 i; i < 8; ++i) {
            actors[i] = address(uint160(0xB000 + i));
        }
        staleHint = FLOOR;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 8];
    }

    function _price(uint256 s) internal pure returns (uint256) {
        return FLOOR + (s % GRID) * SPACING;
    }

    /// The exact predecessor a UI would read: walk `next` up from the floor.
    function _uiHint(uint256 price) internal view returns (uint256 prev) {
        prev = FLOOR;
        for (uint256 i; i < GRID + 8; ++i) {
            (uint256 nx,,,,,,) = auction.ticks(prev);
            if (nx == 0 || nx >= price) break;
            prev = nx;
        }
    }

    function _hint(uint256 price, uint256 mode) internal view returns (uint256) {
        if (mode == 0) return _uiHint(price);
        if (mode == 1) return 0;
        if (mode == 2) return staleHint;
        if (mode == 3) return price; // self-hint: must be rejected by `_validHint`
        if (mode == 4) return auction.highestTick();
        return auction.settleCursor();
    }

    function _stakeUp(address who, uint256 amount) internal {
        if (mono.balanceOf(address(this)) < amount) return;
        mono.transfer(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), amount);
        try auction.stake(amount) {} catch {}
        vm.stopPrank();
    }

    function opBid(uint256 actorSeed, uint256 priceSeed, uint96 rawAmt, uint8 hintMode) external {
        address who = _actor(actorSeed);
        if (auction.stakes(who) == 0) _stakeUp(who, 5e18);
        if (auction.stakes(who) == 0) return;
        uint256 price = _price(priceSeed);
        (uint256 held,,,,,,) = auction.positions(who);
        if (held != 0 && held != price) {
            (uint256 live,) = auction.positionOf(who);
            if (live != 0) price = held; // one bid per owner: top up
        }
        uint128 amount = uint128(bound(uint256(rawAmt), 2e18, 300e18));
        uint256 prev = _hint(price, uint256(hintMode) % 6);

        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        try auction.submitBid(price, amount, who, prev) {
            bids++;
            staleHint = _uiHint(price);
        } catch {}
        vm.stopPrank();
    }

    /// Withdraw whoever is standing at (or nearest below) the CURRENT top of book — the shape
    /// that leaves `highestTick` on a dead ex-top.
    function opWithdrawTop(uint256) external {
        uint256 p = auction.highestTick();
        for (uint256 i; i < GRID + 8 && p != 0; ++i) {
            address[] memory seats = auction.tickPositions(p);
            if (seats.length != 0) {
                vm.prank(seats[0]);
                try auction.withdrawBid() {
                    withdrawals++;
                } catch {}
                return;
            }
            (, p,,,,,) = auction.ticks(p);
        }
    }

    function opWithdraw(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        (uint256 live,) = auction.positionOf(who);
        if (live == 0) return;
        vm.prank(who);
        try auction.withdrawBid() {
            withdrawals++;
        } catch {}
    }

    /// Unstake to ZERO: the position keeps its escrow but the tick reads dead, so a sweep can
    /// splice it out from under a live bid.
    function opUnstakeToZero(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(have) {
            zeroUnstakes++;
        } catch {}
    }

    function opUnstake(uint256 actorSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(bound(uint256(rawAmt), 1, have)) {} catch {}
    }

    /// Re-stake into a position whose tick a sweep may have unlinked: the `_reseat` -> `_relink`
    /// path, the one place a tick is put back into the list with no hint.
    function opRestake(uint256 actorSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        if (auction.stakes(who) != 0) return;
        uint256 amount = bound(uint256(rawAmt), 1e15, 20e18);
        if (mono.balanceOf(address(this)) < amount) return;
        mono.transfer(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), amount);
        try auction.stake(amount) {
            restakes++;
        } catch {}
        vm.stopPrank();
    }

    function opStake(uint256 actorSeed, uint96 rawAmt) external {
        _stakeUp(_actor(actorSeed), bound(uint256(rawAmt), 1e15, 30e18));
    }

    function opClaim(uint256 actorSeed) external {
        try auction.claim(_actor(actorSeed)) {
            claims++;
        } catch {}
    }

    function opClaimAndStake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try auction.claimAndStake() {} catch {}
    }

    /// Budgets 1 / 8 / 64 / huge — the parking, single-window and whole-book cases.
    function opSync(uint8 which) external {
        uint256[4] memory budgets = [uint256(1), 8, 64, type(uint128).max];
        try auction.sync(budgets[which % 4]) {} catch {}
    }

    function opRoll(uint8 seed) external {
        vm.roll(block.number + (uint256(seed) % 5) * K + 1);
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = false
contract Review9LinksListInvariantTest is Review9LinksBase {
    Review9LinksHandler internal handler;

    function setUp() public {
        _deploy(0, 40e18);
        _registerGrid(32);
        handler = new Review9LinksHandler(auction, mono, cur);
        mono.transfer(address(handler), 20_000e18);
        targetContract(address(handler));
    }

    function invariant_links_twoChainsAgree() public view {
        _checkList();
        address[] memory owners = new address[](8);
        for (uint256 i; i < 8; ++i) {
            owners[i] = handler.actorAt(i);
        }
        _checkPositionsReachable(owners);
    }

    /// Anti-vacuity: the driver must really reach the shapes this lens is about.
    function test_links_handlerReachesTheShapes() public {
        handler.opStake(0, 10e18);
        handler.opStake(1, 10e18);
        handler.opBid(0, 20, 100e18, 0);
        handler.opBid(1, 4, 100e18, 0);
        handler.opRoll(3);
        handler.opSync(3);
        handler.opWithdrawTop(0);
        handler.opRoll(2);
        handler.opSync(0);
        handler.opUnstakeToZero(1);
        handler.opSync(3);
        handler.opRestake(1, 5e18);
        _checkList();
        address[] memory owners = new address[](8);
        for (uint256 i; i < 8; ++i) {
            owners[i] = handler.actorAt(i);
        }
        _checkPositionsReachable(owners);
        assertGt(handler.bids(), 0, "bids landed");
        assertGt(handler.withdrawals(), 0, "a top withdrawal landed");
        assertGt(handler.zeroUnstakes(), 0, "an unstake-to-zero landed");
    }
}
