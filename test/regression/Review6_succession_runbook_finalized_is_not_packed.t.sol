// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 6 / succession. The documented runbook (agent-docs/GenerousAuction.md "Succession",
/// step 3) says: revoke the predecessor's MINTER_ROLE "only once the predecessor is drained
/// (`due() == 0` / finalized)". Drained is NOT packed: `finalize` (src/GenerousAuction.sol:452)
/// syncs and sells the frozen tail but never calls `_mintPack`, and the successor's constructor
/// (src/GenerousAuction.sol:239) packs only what was SOLD at that instant. So a sale that is
/// finalized with `due() == 0` can still hold `tokensSold > tokensMinted`, and revoking then
/// bricks every claim on it (`_claim` -> `_mintPack` -> `Mono.mint` reverts, :1154 / :1099).
contract Review6_succession_runbook_finalized_is_not_packed is Test {
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;
    uint256 internal constant P0 = FLOOR;

    address internal aa = address(0xA1);
    address internal stranger = address(0x5717);

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _cfg(uint64 end, uint128 emission, address prev) internal view returns (IGenerousAuction.Config memory) {
        return IGenerousAuction.Config({
            token: address(mono),
            currency: address(cur),
            admin: address(0xF1),
            floorPrice: FLOOR,
            tickSpacing: SPACING,
            decayQ: HALF,
            windowTicks: 8,
            startBlock: uint64(block.number),
            endBlock: end,
            roundBlocks: K,
            emissionPerRound: emission,
            minPremiumBips: 1_500,
            previousAuction: prev
        });
    }

    function _stakeFor(GenerousAuction a, address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(a), amt);
        a.stake(amt);
        vm.stopPrank();
    }

    function _bid(GenerousAuction a, address who, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(a), amount);
        a.submitBid(price, amount, who, prev);
        vm.stopPrank();
    }

    /// Runs the documented runbook to the letter. Returns the predecessor.
    function _runbook() internal returns (GenerousAuction a, GenerousAuction b) {
        uint64 end = uint64(block.number) + 2 * K;
        a = new GenerousAuction(_cfg(end, 100e18, address(0)));
        mono.grantRole(mono.MINTER_ROLE(), address(a));

        _stakeFor(a, aa, 1e18);
        _bid(a, aa, P0, 1000e18, FLOOR); // absorbs both rounds

        // Round 1 settles inside the sale; round 2 accrues but is never synced before `endBlock`.
        vm.roll(block.number + K);
        a.sync(64);
        assertEq(a.tokensSold(), 100e18, "round 1 sold");
        vm.roll(end + 1);
        assertEq(a.due(), 100e18, "round 2 is a frozen, un-synced tail");

        // Step 1: deploy the successor. Its constructor packs the predecessor — what is SOLD.
        b = new GenerousAuction(_cfg(0, 100e18, address(a)));
        assertEq(a.tokensMinted(), 100e18, "the constructor packed round 1");
        // Step 2: grant to the successor.
        mono.grantRole(mono.MINTER_ROLE(), address(b));

        // "End it": drain and finalize the predecessor. Permissionless, so anyone does it.
        vm.prank(stranger);
        assertTrue(a.finalize(64), "tail drained in one call");
        assertTrue(a.finalized());
        assertEq(a.due(), 0, "the runbook's condition: drained");

        // Step 3, exactly as written: "only once the predecessor is drained (due()==0 / finalized)".
        mono.revokeRole(mono.MINTER_ROLE(), address(a));
    }

    /// `finalize` packs on completion, so the literal runbook leaves nothing unpacked and a
    /// finalized, revoked predecessor still pays.
    function test_runbookFollowedLiterally_claimPays() public {
        (GenerousAuction a,) = _runbook();

        assertEq(a.tokensSold(), 200e18);
        assertEq(a.tokensMinted(), 200e18, "finalize packed the tail it sold");
        assertEq(a.currencyMinted(), a.currencyRaised(), "nothing left to pack");

        uint256 paid = a.claim(aa);
        assertEq(paid, 200e18, "both rounds paid after the documented sequence");
    }

    /// The wrong order — role revoked BEFORE finalize — must not hold the stake lock hostage:
    /// finalize's pack is best-effort, the lock lifts, and the pack lands once the role is back.
    function test_roleRevokedBeforeFinalize_lockStillLifts() public {
        uint64 end = uint64(block.number) + 2 * K;
        GenerousAuction a = new GenerousAuction(_cfg(end, 100e18, address(0)));
        mono.grantRole(mono.MINTER_ROLE(), address(a));
        _stakeFor(a, aa, 1e18);
        _bid(a, aa, P0, 1000e18, FLOOR);
        vm.roll(end + 1);
        mono.revokeRole(mono.MINTER_ROLE(), address(a)); // the natural instinct, the wrong order

        vm.prank(stranger);
        assertTrue(a.finalize(64), "finalizes despite the missing role");
        assertTrue(a.finalized());
        assertEq(a.tokensMinted(), 0, "nothing could be packed without the role");
        vm.prank(aa);
        a.unstake(1e18); // the lock lifted

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(a), mono.MINTER_ROLE()
            )
        );
        a.claim(aa);
        mono.grantRole(mono.MINTER_ROLE(), address(a));
        assertEq(a.claim(aa), 200e18, "pays once the role is back");
    }
}
