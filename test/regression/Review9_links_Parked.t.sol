// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {TestERC20} from "../TestERC20.sol";
import {Review9LinksBase} from "./Review9_links_Base.sol";

/// The PARKED-CURSOR driver. 170 single-tick windows, each 10 grid steps apart (wider than the
/// 8-step band), so one sweep needs ~170 window iterations against a `maxTicks` floored at
/// `SYNC_TICKS = 128`: every full sweep truncates, `settleCursor` parks, and the next one resumes
/// from it. That is the state the dense 32-tick driver can never reach, and the one where the
/// only list-mutating call NOT behind `SettleFirst` (`claim` -> `_reseat` -> `_relink` and the
/// `highestTick` bump) can act.
contract Review9ParkedHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 public immutable N;

    address[] public actors;
    uint256 public parkedCalls; // ghost: calls that ended with the cursor parked
    uint256 public totalCalls;

    constructor(GenerousAuction a, Mono m, TestERC20 c, address[] memory who) {
        auction = a;
        mono = m;
        cur = c;
        actors = who;
        N = who.length;
    }

    function step(uint256 i) public pure returns (uint256) {
        return i * 10;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % N];
    }

    function _note() internal {
        totalCalls++;
        if (auction.settleCursor() != 0) parkedCalls++;
    }

    function opSync(uint8 which) external {
        uint256[6] memory b = [uint256(1), 8, 64, 128, 300, type(uint128).max];
        try auction.sync(b[which % 6]) {} catch {}
        _note();
    }

    function opRoll(uint8 seed) external {
        vm.roll(block.number + (uint256(seed) % 7) * 100 + 1);
        _note();
    }

    /// The one list-mutating entry point with no `SettleFirst` guard.
    function opClaim(uint256 s) external {
        try auction.claim(_actor(s)) {} catch {}
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

    function opWithdrawTop(uint256) external {
        uint256 p = auction.highestTick();
        for (uint256 i; i < N + 4 && p != 0; ++i) {
            address[] memory seats = auction.tickPositions(p);
            if (seats.length != 0) {
                vm.prank(seats[0]);
                try auction.withdrawBid() {} catch {}
                break;
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
        mono.transfer(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), amount);
        try auction.stake(amount) {} catch {}
        vm.stopPrank();
        _note();
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
}

/// forge-config: default.invariant.runs = 40
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail-on-revert = false
contract Review9LinksParkedTest is Review9LinksBase {
    Review9ParkedHandler internal handler;
    uint256 internal constant N = 170;
    address[] internal owners;

    function setUp() public {
        _deploy(0, 300e18);
        for (uint256 i; i < N; ++i) {
            owners.push(address(uint160(0xC000 + i)));
        }
        handler = new Review9ParkedHandler(auction, mono, cur, owners);
        for (uint256 i; i < N + 4; ++i) {
            _registerPrice(FLOOR + handler.step(i) * SPACING);
        }
        mono.transfer(address(handler), 20_000e18);

        uint256 prev = FLOOR;
        for (uint256 i; i < N; ++i) {
            address who = owners[i];
            uint256 price = FLOOR + handler.step(i) * SPACING;
            mono.transfer(who, 1e18);
            cur.mint(who, 40e18);
            vm.startPrank(who);
            mono.approve(address(auction), 1e18);
            auction.stake(1e18);
            cur.approve(address(auction), 40e18);
            auction.submitBid(price, 40e18, who, prev);
            vm.stopPrank();
            prev = price;
        }
        targetContract(address(handler));
    }

    function invariant_links_parked() public view {
        _checkList();
        _checkPositionsReachable(owners);
    }

    /// Anti-vacuity: the sweep really truncates and the cursor really parks here.
    function test_links_parkedShapeIsReached() public {
        vm.roll(block.number + 400);
        emit log_named_uint("saleSupply", auction.saleSupply());
        emit log_named_uint("due", auction.due());
        auction.sync(1); // floored to SYNC_TICKS = 128 < 170 windows
        emit log_named_uint("tokensSold", auction.tokensSold());
        emit log_named_uint("due after", auction.due());
        emit log_named_uint("cursor", auction.settleCursor());
        assertTrue(auction.settleCursor() != 0, "cursor did not park on a 170-window book");
        _checkList();
        _checkPositionsReachable(owners);
        emit log_named_uint("settleCursor step", (auction.settleCursor() - FLOOR) / SPACING);
        emit log_named_uint("highestTick step", (auction.highestTick() - FLOOR) / SPACING);

        // resume, repeatedly, and check after each
        for (uint256 i; i < 6; ++i) {
            auction.sync(1);
            _checkList();
            _checkPositionsReachable(owners);
        }
    }
}
