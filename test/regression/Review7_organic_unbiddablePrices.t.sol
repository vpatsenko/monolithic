// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 7 / organic-UX lens: prices that used to be live become UNBIDDABLE.
///
/// `_initializeTick` (src/GenerousAuction.sol l.1228-1248) accepts `prevPrice` only when
/// `ticks[prevPrice].next == 0 || >= price`. After `_splice` has moved a node's `.next` past a
/// re-exposed trap, the exact list predecessor of a detached init price has `.next < price`
/// (BadPrevHint), and no other init tick below it has `.next > price`; the only candidates have
/// `.next == price`, which self-loops (see `Review7_organic_selfLoopBrick.t.sol`). The
/// documented recovery — "a stale hint reverts; the caller re-reads the book and retries" —
/// has nothing to retry with.
///
/// Minimal: FAILS (no non-looping hint exists for 1.12 after six honest steps).
/// Sim, fat book + keeper: 88 of 1593 honest bid attempts (5.5%) unbiddable — FAILS the 5% bar.
/// Sim, thin book + keeper: 2073 of 3744 (55%), 40/40 verified on-chain by trying every hint.
contract Review7OrganicUnbiddableMinimal is Test {
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

    address internal alice = address(0xA11CE);
    address internal b9 = address(0xB9);
    address internal b10 = address(0xB10);
    address internal b11 = address(0xB11);
    address internal b12 = address(0xB12);
    address internal carol = address(0xCA201);
    address internal dave = address(0xDA4E);

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

    /// FAILS on current code.
    function test_oldPriceHasNoUsableHint() public {
        _bid(alice, P7, 1000e18, FLOOR);
        _bid(b9, P9, 2e18, P7);
        _bid(b10, P10, 2e18, P9);
        _bid(b11, P11, 2e18, P10);
        _bid(b12, P12, 2e18, P11);
        vm.roll(block.number + K);
        auction.sync(64); // the four small positions exhaust
        vm.roll(block.number + K);
        auction.sync(64); // sweep splices 12-11-10-9 out: 12.prev = 7, 7.next = 12
        _bid(carol, P10, 2e18, P7); // an old price, accepted via the interior trap; highestTick = 10
        vm.roll(block.number + K);
        auction.sync(64); // carol exhausts
        vm.roll(block.number + K);
        auction.sync(64); // sweep from 10 splices again: 7.next = 10, 12.prev still 7

        // dave wants 1.12 (an old price). Try EVERY hint the grid offers, on-chain.
        uint256 accepted;
        uint256 acceptedNoLoop;
        for (uint256 d; d < 12; ++d) {
            uint256 x = FLOOR + d * SPACING;
            (,,,,,, bool init) = auction.ticks(x);
            if (!init) continue;
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _bid(dave, P12, 2e18, x);
            bool loop;
            if (ok) {
                (, uint256 pv,,,,,) = auction.ticks(P12);
                loop = pv == P12;
                ++accepted;
                if (!loop) ++acceptedNoLoop;
            }
            emit log_string(string.concat(
                    "hint d",
                    vm.toString(d),
                    ": ",
                    ok ? (loop ? "ACCEPTED -> SELF-LOOP" : "accepted") : "reverted",
                    ok ? "" : string.concat(" ", vm.toString(bytes32(bytes4(ret))))
                ));
            vm.revertToStateAndDelete(snap);
        }
        emit log_named_uint("hints accepted", accepted);
        emit log_named_uint("hints accepted without corrupting the list", acceptedNoLoop);
        assertGt(acceptedNoLoop, 0, "an honest bidder must be able to bid at an initialised price with SOME hint");
    }
}
