// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 6 — AggLayer / POS (agglayer-contracts @ 110bda5a,
// HEAD tidak bergerak vs r5: main 110bda5a, develop cfdca3c2).
// Deep-dive area BARU (tugas r6): BridgeV2 exit-leaf accounting
// (leaf count vs GER, exit tidak terhitung / terhitung ganda) dan
// GlobalExitRoot update paths (urutan update, race antar rollup,
// GER yang bisa di-rollback).
// Yang TIDAK diulang: slash/auction (mati, r5), ValidatorShare dust 3 wei
// (Informational, r5), migrateLegacyToken 1:1 (r5), ClaimCompressor (r2 Low),
// updateQuorum (r2 Low), depositBulk (r2 Low), backwardLET stall (r2 D1,
// sudah fixed upstream 540299e6), addNewRollupType rollup-shell (r3 Info),
// gateway routes (r1 K7), double-claim (r1), bridge-to-own-network (r1).

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {IAgglayerBridge} from "../src/interfaces/IAgglayerBridge.sol";
import {AgglayerBridgeL2} from "../src/sovereignChains/AgglayerBridgeL2.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {AgglayerGateway} from "../src/AgglayerGateway.sol";
import {IAggchainSigners} from "../src/interfaces/IAggchainSigners.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {MerkleHelper} from "./AgglayerR1.t.sol";
import {FallbackSucceeds} from "./AgglayerR3.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Mock GER L2 untuk BridgeL2: GER apa pun dianggap ada, dan
/// globalExitRootRemover = test contract ini.
contract MockGERL2 {
    address public remover;

    constructor(address _remover) {
        remover = _remover;
    }

    function updateExitRoot(bytes32) external {}

    function globalExitRootMap(bytes32) external pure returns (uint256) {
        return 1;
    }

    function globalExitRootRemover() external view returns (address) {
        return remover;
    }
}

/// @notice Verifier tiruan yang selalu revert (kontrol: gateway benar-benar
/// mendelegasikan verifikasi ke route.verifier).
contract MockSP1VerifierRevert is ISP1Verifier {
    function verifyProof(
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure override {
        revert("mock verifier always reverts");
    }
}

/// @notice Memanggil ISP1Verifier lewat high-level call di frame sendiri,
/// untuk mengisolasi perilaku compiler (extcodesize check?) dari logika
/// gateway. Dipakai lewat low-level call agar hasil boolean tertangkap.
contract VerifierCaller {
    function callVerifier(
        address v,
        bytes32 vkey,
        bytes calldata pv,
        bytes calldata pr
    ) external view {
        ISP1Verifier(v).verifyProof(vkey, pv, pr);
    }
}

/// @notice Expose fungsi internal AgglayerBridge untuk menguji akuntansi
/// nullifier secara langsung (networkID default 0 = mainnet).
contract BridgeHarness is AgglayerBridge {
    function setClaimed(uint32 leafIndex, uint32 sourceBridgeNetwork) external {
        _setAndCheckClaimed(leafIndex, sourceBridgeNetwork);
    }
}

contract AgglayerR6Test is Test {
    address public user = address(0xBEEF);
    address public other = address(0xCAFE);

    // ---------- R6-A: gateway ----------
    AgglayerGateway public gateway;
    bytes4 public constant PP_SELECTOR = bytes4(0xAABBCCDD);
    bytes32 public constant PP_VKEY = bytes32(uint256(0x1234));

    // ---------- R6-B: nullifier ----------
    BridgeHarness public bridgeHarness;

    // ---------- R6-C: GER ----------
    AgglayerGER public ger;
    address public mockBridgeAddr = makeAddr("mockBridge");
    address public mockManagerAddr = makeAddr("mockManager");

    // ---------- R6-D: BridgeL2 ----------
    AgglayerBridgeL2 public bridgeL2;
    MockGERL2 public mockGerL2;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);
        vm.deal(user, 100 ether);

        // --- Gateway di belakang proxy, route awal menunjuk EOA ---
        AgglayerGateway gwImpl = new AgglayerGateway();
        gateway = AgglayerGateway(
            address(new ERC1967Proxy(address(gwImpl), ""))
        );
        IAggchainSigners.SignerInfo[] memory signers = new IAggchainSigners.SignerInfo[](0);
        address eoaVerifier = makeAddr("eoaVerifier");
        gateway.initialize(
            address(this), // defaultAdmin
            address(this), // aggchainDefaultVKeyRole
            address(this), // addRouteRole
            address(this), // freezeRouteRole
            PP_SELECTOR,
            eoaVerifier, // verifier TANPA CODE (EOA)
            PP_VKEY,
            address(this), // multisigRole
            signers,
            0
        );

        // --- Harness bridge mainnet (langsung, tanpa initialize) ---
        bridgeHarness = new BridgeHarness();

        // --- GER asli: bridge + manager adalah alamat mock ---
        AgglayerGER gerImpl = new AgglayerGER(mockManagerAddr, mockBridgeAddr);
        ger = AgglayerGER(address(new ERC1967Proxy(address(gerImpl), "")));
        ger.initialize();

        // --- BridgeL2 sovereign (network 2) + MockGERL2 ---
        mockGerL2 = new MockGERL2(address(this));
        AgglayerBridgeL2 bridgeImpl = new AgglayerBridgeL2();
        bridgeL2 = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(bridgeImpl), "")))
        );
        bridgeL2.initialize(
            2, // NETWORK_ID sovereign
            address(0), // gas token = ether
            0,
            IBaseLegacyAgglayerGER(address(mockGerL2)),
            address(0), // polygonRollupManager = 0 di L2
            "",
            address(this), // bridgeManager = test ini
            address(0), // sovereign WETH: tidak ada
            false,
            address(0), // emergency pauser: dimatikan
            address(0), // emergency unpauser: dimatikan
            address(this) // proxiedTokensManager
        );
        vm.deal(address(bridgeL2), 10 ether);
    }

    // ============ R6-A: Gateway route ke verifier tanpa code ============
    // _addPessimisticVKeyRoute hanya menolak address(0); EOA / kontrak
    // tanpa fungsi verifyProof BISA didaftarkan sebagai route. Hasil PoC:
    // EOA -> FAIL-CLOSED (extcodesize check solc 0.8.28 membuat high-level
    // call revert); kontrak DENGAN code + fallback kosong -> VAKUM
    // (verifyPessimisticProof sukses atas proof sampah). Lihat verdict di
    // audit note: yang kedua butuh AL_ADD_PP_ROUTE_ROLE (trusted) -> Info.

    function _gatewayCall(
        bytes memory proofBytes
    ) internal returns (bool ok) {
        bytes memory pv = abi.encodePacked(bytes32(uint256(0xBEEF)));
        (ok, ) = address(gateway).call(
            abi.encodeCall(
                AgglayerGateway.verifyPessimisticProof,
                (pv, proofBytes)
            )
        );
    }

    function test_R6A_gatewayEoaRouteVerifiesGarbageProof() public {
        // Route awal (dari setUp) menunjuk EOA.
        (address v, bytes32 vk, bool frozen) = gateway.pessimisticVKeyRoutes(
            PP_SELECTOR
        );
        assertTrue(v != address(0), "route tidak terdaftar");
        assertEq(vk, PP_VKEY, "vkey route salah");
        assertFalse(frozen, "route frozen");

        // Proof sampah: selector route + byte sampah.
        bytes memory garbage = abi.encodePacked(PP_SELECTOR, hex"deadbeef");
        bool ok = _gatewayCall(garbage);
        // EOA = tanpa code -> extcodesize check solc 0.8.28 membuat call
        // revert (fail-closed). Verdict R6-A/EOA: NEGATIF.
        emit log_named_string("R6-A gateway EOA route, garbage proof ok?", ok ? "true (VACUOUS)" : "false (revert, fail-closed)");
        assertFalse(ok, "R6-A: call ke EOA seharusnya revert (fail-closed)");
    }

    function test_R6A_gatewayFallbackContractRouteVerifiesGarbageProof() public {
        FallbackSucceeds fb = new FallbackSucceeds();
        bytes4 sel2 = bytes4(0x11223344);
        gateway.addPessimisticVKeyRoute(sel2, address(fb), bytes32(uint256(0x5678)));
        bytes memory garbage = abi.encodePacked(sel2, hex"deadbeef");
        bool ok = _gatewayCall(garbage);
        emit log_named_string("R6-A gateway fallback-contract route, garbage proof ok?", ok ? "true (VACUOUS)" : "false (revert, fail-closed)");
        assertTrue(ok, "R6-A: call ke fallback-contract revert (fail-closed)");
    }

    function test_R6A_gatewayRevertingVerifierStillReverts() public {
        MockSP1VerifierRevert rv = new MockSP1VerifierRevert();
        bytes4 sel3 = bytes4(0x55667788);
        gateway.addPessimisticVKeyRoute(sel3, address(rv), bytes32(uint256(0x9abc)));
        bytes memory garbage = abi.encodePacked(sel3, hex"deadbeef");
        bool ok = _gatewayCall(garbage);
        assertFalse(ok, "R6-A: verifier yang revert seharusnya membuat gateway revert");
    }

    function test_R6A_directHighLevelCallToEoa() public {
        VerifierCaller caller = new VerifierCaller();
        address eoa = makeAddr("eoaDirect");
        (bool ok, ) = address(caller).call(
            abi.encodeCall(
                VerifierCaller.callVerifier,
                (eoa, PP_VKEY, hex"00", hex"00")
            )
        );
        emit log_named_string("R6-A direct ISP1Verifier high-level call ke EOA ok?", ok ? "true (VACUOUS)" : "false (revert, fail-closed)");
        assertFalse(ok, "R6-A: direct call ke EOA seharusnya revert (fail-closed)");
    }

    function test_R6A_addRouteZeroAddressReverts() public {
        vm.expectRevert();
        gateway.addPessimisticVKeyRoute(
            bytes4(0x99aabbcc),
            address(0),
            bytes32(uint256(0x1))
        );
    }

    // ============ R6-B: aliasing nullifier mainnet vs rollup-1 ============
    // _setAndCheckClaimed / isClaimed di AgglayerBridge: bila networkID == 0
    // (mainnet) dan sourceBridgeNetwork == 1 (zkEVM / rollupID 1), slot
    // nullifier = leafIndex saja — SAMA dengan slot leaf mainnet
    // (sourceBridgeNetwork == 0 -> leafIndex + 0 * 2^32 = leafIndex).

    function test_R6B_nullifierAliasMainnetVsRollup1() public {
        assertEq(bridgeHarness.networkID(), 0, "harness harus mainnet (id 0)");

        bridgeHarness.setClaimed(7, 0); // klaim leaf mainnet #7
        assertTrue(bridgeHarness.isClaimed(7, 0), "slot (7,0) harus set");
        // ALIAS: slot (7,1) membaca bit yang SAMA.
        assertTrue(
            bridgeHarness.isClaimed(7, 1),
            "R6-B: (7,1) ikut set -> alias terbukti"
        );
        assertFalse(bridgeHarness.isClaimed(7, 2), "slot (7,2) harus kosong");
        assertFalse(bridgeHarness.isClaimed(8, 0), "slot (8,0) harus kosong");

        // Klaim kedua leaf (7,1) harus revert AlreadyClaimed karena bit sama.
        vm.expectRevert(IAgglayerBridge.AlreadyClaimed.selector);
        bridgeHarness.setClaimed(7, 1);

        // Kontrol: network lain tidak kena alias.
        bridgeHarness.setClaimed(7, 2);
        assertTrue(bridgeHarness.isClaimed(7, 2), "slot (7,2) harus bisa di-set");
    }

    function test_R6B_bridgeToOwnNetworkReverts() public {
        // Jalur reachability: leaf mainnet dengan destination == mainnet
        // tidak bisa dibuat (r1 sudah buktikan; ditegaskan ulang di sini).
        vm.expectRevert(IAgglayerBridge.DestinationNetworkInvalid.selector);
        bridgeHarness.bridgeAsset{value: 1 ether}(
            0, // destinationNetwork == networkID
            user,
            1 ether,
            address(0),
            false,
            ""
        );
        vm.expectRevert(IAgglayerBridge.DestinationNetworkInvalid.selector);
        bridgeHarness.bridgeMessage(0, user, false, "x");
    }

    // ============ R6-C: GER update paths ============
    // updateExitRoot: bila GER hasil sudah ada di globalExitRootMap, TIDAK
    // ada leaf L1Info baru dan TIDAK ada entri l1InfoRootMap baru — tapi
    // lastMainnetExitRoot / lastRollupExitRoot tetap di-update. Dan GER
    // itu sendiri tidak menegakkan monotonicity: caller yang menyerahkan
    // root lama akan me-rollback getLastGlobalExitRoot() ke GER lama.

    function _ger(bytes32 m, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(m, r));
    }

    function test_R6C_duplicateGerAddsNoL1InfoLeaf() public {
        bytes32 m1 = bytes32(uint256(0xA1));
        bytes32 r1 = bytes32(uint256(0xB1));

        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m1); // G1 = H(M1, 0)
        assertEq(ger.depositCount(), 1, "leaf L1Info #1 harus ada");
        bytes32 rootAfterG1 = ger.getRoot();

        vm.prank(mockManagerAddr);
        ger.updateExitRoot(r1); // G2 = H(M1, R1)
        assertEq(ger.depositCount(), 2, "leaf L1Info #2 harus ada");
        bytes32 l1InfoRoot2 = ger.l1InfoRootMap(2);
        assertTrue(l1InfoRoot2 != bytes32(0), "l1InfoRootMap[2] harus set");
        assertEq(ger.getLastGlobalExitRoot(), _ger(m1, r1), "GER terakhir = G2");

        // Update duplikat: bridge kirim M1 lagi -> GER yang sama (G2).
        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m1);
        assertEq(ger.depositCount(), 2, "R6-C: duplikat TIDAK boleh tambah leaf");
        assertEq(ger.l1InfoRootMap(2), l1InfoRoot2, "R6-C: l1InfoRootMap[2] tidak berubah");
        assertEq(ger.l1InfoRootMap(3), bytes32(0), "R6-C: tidak ada entri [3]");
        assertEq(ger.getLastGlobalExitRoot(), _ger(m1, r1), "GER terakhir tetap G2");
        assertTrue(ger.getRoot() != rootAfterG1, "root L1Info maju setelah G2");
    }

    function test_R6C_gerRollsBackIfCallerPassesOldRoot() public {
        bytes32 m1 = bytes32(uint256(0xA1));
        bytes32 r1 = bytes32(uint256(0xB1));

        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m1); // G1
        vm.prank(mockManagerAddr);
        ger.updateExitRoot(r1); // G2
        assertEq(ger.getLastGlobalExitRoot(), _ger(m1, r1), "GER = G2");

        // Manager menyerahkan root lama (0): GER kembali ke G1, tanpa leaf baru.
        vm.prank(mockManagerAddr);
        ger.updateExitRoot(bytes32(0));
        assertEq(ger.getLastGlobalExitRoot(), _ger(m1, bytes32(0)), "R6-C: GER rollback ke G1");
        assertEq(ger.depositCount(), 2, "R6-C: rollback tidak tambah leaf");
    }

    function test_R6C_onlyBridgeOrManagerCanUpdate() public {
        vm.expectRevert(IBaseLegacyAgglayerGER.OnlyAllowedContracts.selector);
        ger.updateExitRoot(bytes32(uint256(0x1)));
    }

    // ============ R6-D: BridgeL2 emergency claim management ============
    // setMultipleClaims: menandai klaim TANPA meng-update
    // claimedGlobalIndexHashChain (padahal jalur klaim normal meng-update-nya).
    // unsetMultipleClaims + re-claim: nullifier dihapus, klaim yang sama bisa
    // dibayar KEDUA kalinya dari saldo bridge, dan localBalanceTree terhitung
    // GANDA. Semua jalur ini hanyaGlobalExitRootRemover (trusted role).

    uint256 public constant MAINNET_FLAG = 2 ** 64;

    function _mainnetClaim(
        bytes32[32] memory proofLocal,
        bytes32 mainnetExitRoot,
        uint256 amount
    ) internal {
        bytes32[32] memory emptyProof;
        bridgeL2.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG, // globalIndex: mainnet flag, leafIndex 0
            mainnetExitRoot,
            bytes32(0), // rollupExitRoot (tidak dipakai jalur mainnet)
            0, // originNetwork = mainnet
            address(0), // originTokenAddress = ether
            2, // destinationNetwork = chain ini
            user,
            amount,
            ""
        );
    }

    function _buildMainnetLeaf(
        uint256 amount
    ) internal view returns (bytes32 mainnetExitRoot, bytes32[32] memory proofLocal) {
        bytes32 leaf = MerkleHelper.leafValue(
            0, // _LEAF_TYPE_ASSET
            0, // originNetwork mainnet
            address(0),
            2, // destinationNetwork
            user,
            amount,
            keccak256("")
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        mainnetExitRoot = MerkleHelper.treeRoot(leaves);
        proofLocal = MerkleHelper.treeProof(leaves, 0);
    }

    function test_R6D_unsetThenReclaimPaysTwiceAndDoubleCountsLBT() public {
        (bytes32 mainnetExitRoot, bytes32[32] memory proofLocal) = _buildMainnetLeaf(1 ether);
        bytes32 lbtKey = keccak256(abi.encodePacked(uint32(0), address(0)));

        bytes32 chainBefore = bridgeL2.claimedGlobalIndexHashChain();
        assertEq(chainBefore, bytes32(0), "rantai klaim awal 0");

        // Klaim #1: user dibayar 1 ether, LBT = 1 ether, rantai berubah.
        uint256 balBefore = user.balance;
        _mainnetClaim(proofLocal, mainnetExitRoot, 1 ether);
        assertEq(user.balance, balBefore + 1 ether, "klaim #1 harus bayar 1 ether");
        assertTrue(bridgeL2.isClaimed(0, 0), "nullifier (0,0) harus set");
        assertEq(bridgeL2.localBalanceTree(lbtKey), 1 ether, "LBT harus 1 ether");
        bytes32 chainAfterClaim = bridgeL2.claimedGlobalIndexHashChain();
        assertTrue(chainAfterClaim != chainBefore, "rantai klaim harus berubah");

        // Remover unset klaim: nullifier hilang, TAPI LBT tetap 1 ether.
        bytes32 unsetChainBefore = bridgeL2.unsetGlobalIndexHashChain();
        uint256[] memory gis = new uint256[](1);
        gis[0] = MAINNET_FLAG;
        bridgeL2.unsetMultipleClaims(gis);
        assertFalse(bridgeL2.isClaimed(0, 0), "nullifier harus terhapus");
        assertEq(bridgeL2.localBalanceTree(lbtKey), 1 ether, "R6-D: LBT TIDAK berkurang saat unset");
        assertTrue(
            bridgeL2.unsetGlobalIndexHashChain() != unsetChainBefore,
            "rantai unset harus berubah"
        );

        // Klaim #2 (proof sama): dibayar LAGI 1 ether dari saldo bridge.
        _mainnetClaim(proofLocal, mainnetExitRoot, 1 ether);
        assertEq(user.balance, balBefore + 2 ether, "R6-D: klaim ke-2 dibayar lagi (double payout)");
        assertEq(bridgeL2.localBalanceTree(lbtKey), 2 ether, "R6-D: LBT terhitung GANDA (2 ether)");
    }

    function test_R6D_setMultipleClaimsSkipsHashChain() public {
        bytes32 chainBefore = bridgeL2.claimedGlobalIndexHashChain();
        uint256[] memory gis = new uint256[](1);
        gis[0] = MAINNET_FLAG + 5; // leafIndex 5, mainnet flag
        bridgeL2.setMultipleClaims(gis);
        assertTrue(bridgeL2.isClaimed(5, 0), "R6-D: setMultipleClaims harus set nullifier");
        assertEq(
            bridgeL2.claimedGlobalIndexHashChain(),
            chainBefore,
            "R6-D: rantai klaim TIDAK berubah padahal nullifier di-set"
        );
    }

    function test_R6D_unsetOfNeverClaimedReverts() public {
        uint256[] memory gis = new uint256[](1);
        gis[0] = MAINNET_FLAG + 9;
        vm.expectRevert();
        bridgeL2.unsetMultipleClaims(gis);
    }

    function test_R6D_onlyRemoverCanManageClaims() public {
        uint256[] memory gis = new uint256[](1);
        gis[0] = MAINNET_FLAG + 3;
        vm.prank(other);
        vm.expectRevert();
        bridgeL2.setMultipleClaims(gis);
        vm.prank(other);
        vm.expectRevert();
        bridgeL2.unsetMultipleClaims(gis);
    }
}
