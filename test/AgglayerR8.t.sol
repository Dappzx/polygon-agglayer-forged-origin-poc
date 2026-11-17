// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 8 — BridgeV2 lanjutan (agglayer-contracts @ 110bda5a,
// HEAD tidak bergerak vs r7: main 110bda5a, develop cfdca3c2).
// Fokus BARU (tugas r8): claim accounting, WETH handling, emergency claim
// paths, token mapping edge cases, amount-0 / zero-address / metadata,
// interaksi BridgeV2 dengan rollup obsolete/dihapus.
// Yang TIDAK diulang: nullifier collision, double-claim, reentrancy
// claimMessage, sequenceForceBatches timeout, permit bridge, emergency
// activation (r1), ClaimCompressor, BridgeL2 LET/LBT, backwardLET,
// migrateLegacyToken, exit-leaf accounting, GER update paths, gateway
// routing, R6-D unsetMultipleClaims + re-claim (r6, Informational).

import "forge-std/Test.sol";
import {AgglayerR2Test, MerkleHelper, MockPOL} from "./AgglayerR2.t.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {AgglayerBridgeL2} from "../src/sovereignChains/AgglayerBridgeL2.sol";
import {IAgglayerBridge} from "../src/interfaces/IAgglayerBridge.sol";
import {IAgglayerBridgeL2} from "../src/interfaces/IAgglayerBridgeL2.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IEmergencyManager} from "../src/interfaces/IEmergencyManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts5/token/ERC20/IERC20.sol";

/// @notice Pembaca saldo lewat kontrak terpisah: test contract ini adalah
/// proxiedTokensManager (= admin TokenWrappedTransparentProxy), jadi
/// pemanggilan balanceOf LANGSUNG ke wrapped token dari test akan revert
/// "admin cannot fallback". Lewat BalReader, msg.sender != admin.
contract BalReader {
    function bal(address token, address who) external view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }
}

/// @notice Mock GER L2 untuk BridgeL2 r8: GER apa pun dianggap ada,
/// globalExitRootRemover = test contract ini.
contract MockGERL2R8 {
    address public remover;
    constructor(address _remover) { remover = _remover; }
    function updateExitRoot(bytes32) external {}
    function globalExitRootMap(bytes32) external pure returns (uint256) { return 1; }
    function globalExitRootRemover() external view returns (address) { return remover; }
}

contract AgglayerR8Test is AgglayerR2Test {
    AgglayerBridge public bridgeL1e; // L1 bridge dgn manager = test ini
    AgglayerGER public gerL1e;
    AgglayerBridgeL2 public bridgeL2Sov; // sovereign net 2, ether-native
    AgglayerBridgeL2 public bridgeL2Gas; // sovereign net 3, gas token
    MockGERL2R8 public mockGerL2R8;
    MockPOL public gasToken;
    MockPOL public sovTokenS;
    BalReader public balReader;

    function _wbal(address token, address who) internal view returns (uint256) {
        return balReader.bal(token, who);
    }

    address public tokenA = address(0xA77A);
    bytes32 public constant LBT_ETH_KEY = keccak256(abi.encodePacked(uint32(0), address(0)));

    bool private r8Init;

    function _initR8() internal {
        if (r8Init) return;
        r8Init = true;

        // --- L1 bridge dgn polygonRollupManager = test ini (bisa emergency) ---
        AgglayerBridge implE = new AgglayerBridge();
        bridgeL1e = AgglayerBridge(
            payable(
                address(
                    new TransparentUpgradeableProxy(address(implE), address(this), "")
                )
            )
        );
        AgglayerGER gerImplE = new AgglayerGER(address(mockManager), address(bridgeL1e));
        gerL1e = AgglayerGER(address(new ERC1967Proxy(address(gerImplE), "")));
        bridgeL1e.initialize(
            0, address(0), 0,
            IBaseLegacyAgglayerGER(address(gerL1e)),
            address(this), ""
        );
        gerL1e.initialize();
        vm.deal(address(bridgeL1e), 100 ether);

        // --- GER L2 mock + BridgeL2 sovereign ether-native (net 2) ---
        mockGerL2R8 = new MockGERL2R8(address(this));
        AgglayerBridgeL2 sovImpl = new AgglayerBridgeL2();
        bridgeL2Sov = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(sovImpl), "")))
        );
        bridgeL2Sov.initialize(
            2, address(0), 0,
            IBaseLegacyAgglayerGER(address(mockGerL2R8)),
            address(0), "",
            address(this), // bridgeManager
            address(0), false, // sovereign WETH: tidak ada
            address(this), // emergency pauser
            address(this), // emergency unpauser
            address(this) // proxiedTokensManager
        );
        vm.deal(address(bridgeL2Sov), 10 ether);
        vm.deal(address(bridgeL2Gas), 10 ether);

        // --- BridgeL2 gas-token (net 3): gas token MockPOL, WETH auto-deploy ---
        gasToken = new MockPOL();
        AgglayerBridgeL2 gasImpl = new AgglayerBridgeL2();
        bridgeL2Gas = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(gasImpl), "")))
        );
        bridgeL2Gas.initialize(
            3, address(gasToken), 0,
            IBaseLegacyAgglayerGER(address(mockGerL2R8)),
            address(0),
            abi.encode("POL", "POL", 18),
            address(this),
            address(0), false,
            address(this),
            address(this),
            address(this)
        );

        sovTokenS = new MockPOL();
        sovTokenS.mint(address(bridgeL2Sov), 1000 ether);
        balReader = new BalReader();
    }

    // Helper: klaim leaf asal-mainnet di BridgeL2 (sovereign) via MockGERL2.
    // Leaf dibuat dengan bridgeAsset di bridgeL1 (net 0) ke destNet.
    function _claimMainnetLeafOnSov(
        AgglayerBridgeL2 sov,
        uint32 destNet,
        address dest,
        uint256 amount
    ) internal {
        vm.prank(user);
        bridgeL1.bridgeAsset{value: amount}(destNet, dest, amount, address(0), false, "");
        bytes32 leaf = MerkleHelper.leafValue(
            0, 0, address(0), destNet, dest, amount, keccak256("")
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        bytes32 l1Root = bridgeL1.getRoot();
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(leaves, 0);
        bytes32[32] memory proofRollup;
        sov.claimAsset(
            proofLocal, proofRollup,
            uint256(2) ** 64, // mainnet flag, leafIndex 0
            l1Root, bytes32(0),
            0, address(0), destNet, dest, amount, ""
        );
    }

    // Helper: klaim leaf asal-rollup-5 (originNetwork 5, token tokenA) di sov.
    // Membangun pohon lokal + pohon rollup (indexRollup 4) secara sintetis;
    // MockGERL2 menerima GER apa pun.
    function _claimRollup5LeafOnSov(
        AgglayerBridgeL2 sov,
        bytes32[] memory localLeaves,
        uint32 leafIndex,
        address dest,
        uint256 amount,
        bytes memory metadata
    ) internal returns (address wrapped) {
        bytes32 localRoot = MerkleHelper.treeRoot(localLeaves);
        bytes32[] memory rollupLeaves = new bytes32[](5);
        rollupLeaves[4] = localRoot;
        bytes32 rollupRoot = MerkleHelper.treeRoot(rollupLeaves);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(localLeaves, leafIndex);
        bytes32[32] memory proofRollup = MerkleHelper.treeProof(rollupLeaves, 4);
        uint256 globalIndex = (uint256(4) << 32) | uint256(leafIndex);
        sov.claimAsset(
            proofLocal, proofRollup, globalIndex,
            bytes32(0), rollupRoot,
            5, tokenA, sov.networkID(), dest, amount, metadata
        );
        return sov.getTokenWrappedAddress(5, tokenA);
    }

    function _leaf5(
        uint32 destNet,
        address dest,
        uint256 amount,
        bytes memory metadata
    ) internal pure returns (bytes32) {
        return MerkleHelper.leafValue(
            0, 5, address(0xA77A), destNet, dest, amount, keccak256(metadata)
        );
    }

    // ============ R8-C1: emergency memblokir SEMUA jalur klaim/bridge L1 ============
    // bridgeAsset, bridgeMessage, bridgeMessageWETH, claimAsset, claimMessage
    // semua revert OnlyNotEmergencyState; updateGlobalExitRoot tetap jalan
    // (tidak memindahkan dana); setelah deactivate, klaim sukses.
    function test_R8C1_EmergencyBlocksAllClaimAndBridgePaths() public {
        _initR8();
        mockManager.setGER(address(gerL1e));
        (
            ,
            bytes32 rollupRoot,
            bytes32[32] memory proofLocal,
            bytes32[32] memory proofRollup
        ) = _bridgeL2ToL1Asset(user, 1 ether);

        bridgeL1e.activateEmergencyState();
        assertTrue(bridgeL1e.isEmergencyState(), "emergency tidak aktif");

        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1e.bridgeAsset{value: 1 ether}(1, user, 1 ether, address(0), false, "");
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1e.bridgeMessage(1, user, false, "x");
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1e.bridgeMessageWETH(1, user, 1 ether, false, "x");
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1e.claimAsset(
            proofLocal, proofRollup, 0, bytes32(0), rollupRoot,
            0, address(0), 0, user, 1 ether, ""
        );
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1e.claimMessage(
            proofLocal, proofRollup, 0, bytes32(0), rollupRoot,
            1, user, 0, user, 1 ether, "x"
        );

        // updateGlobalExitRoot bukan jalur dana: tetap bisa dipanggil saat darurat.
        bridgeL1e.updateGlobalExitRoot();

        // Kontrol: setelah deactivate, klaim yang sama sukses.
        bridgeL1e.deactivateEmergencyState();
        assertFalse(bridgeL1e.isEmergencyState(), "emergency masih aktif");
        uint256 balBefore = user.balance;
        bridgeL1e.claimAsset(
            proofLocal, proofRollup, 0, bytes32(0), rollupRoot,
            0, address(0), 0, user, 1 ether, ""
        );
        assertEq(user.balance, balBefore + 1 ether, "klaim pasca-emergency gagal");
        assertTrue(bridgeL1e.isClaimed(0, 1), "nullifier tidak ter-set");
    }

    // ============ R8-C2: LBT gate — pesan ETH tanpa backing revert ============
    // BridgeL2 ether-native: bridgeMessage dgn ETH revert LocalBalanceTreeUnderflow
    // saat LBT[(0,0)] = 0; setelah klaim ETH 5 masuk, LBT = 5 dan pengiriman
    // 3 + 2 sukses, 3 berikutnya revert. Invarian pessimistic bertahan.
    function test_R8C2_LBTGateBlocksUnbackedEthMessage() public {
        _initR8();
        assertEq(bridgeL2Sov.localBalanceTree(LBT_ETH_KEY), 0, "LBT awal bukan 0");

        // expectRevert(selector) diganti low-level call + cek selector manual
        // (lebih deterministik untuk custom error 4-arg).
        vm.prank(user);
        (bool ok0, bytes memory ret0) = address(bridgeL2Sov).call{value: 1 ether}(
            abi.encodeCall(AgglayerBridge.bridgeMessage, (uint32(0), user, false, bytes("hi")))
        );
        assertFalse(ok0, "bridgeMessage tanpa LBT seharusnya revert");
        assertEq(
            bytes4(ret0),
            IAgglayerBridgeL2.LocalBalanceTreeUnderflow.selector,
            "revert bukan LocalBalanceTreeUnderflow"
        );

        // Danai LBT via klaim leaf mainnet (0,0) 5 ether.
        _claimMainnetLeafOnSov(bridgeL2Sov, 2, user, 5 ether);
        assertEq(bridgeL2Sov.localBalanceTree(LBT_ETH_KEY), 5 ether, "LBT pasca-klaim salah");

        vm.prank(user);
        bridgeL2Sov.bridgeMessage{value: 3 ether}(0, user, false, "hi");
        assertEq(bridgeL2Sov.localBalanceTree(LBT_ETH_KEY), 2 ether, "LBT pasca-kirim-3 salah");

        vm.prank(user);
        (bool ok1, bytes memory ret1) = address(bridgeL2Sov).call{value: 3 ether}(
            abi.encodeCall(AgglayerBridge.bridgeMessage, (uint32(0), user, false, bytes("hi")))
        );
        assertFalse(ok1, "bridgeMessage 3 ether dgn LBT 2 seharusnya revert");
        assertEq(
            bytes4(ret1),
            IAgglayerBridgeL2.LocalBalanceTreeUnderflow.selector,
            "revert bukan LocalBalanceTreeUnderflow"
        );

        vm.prank(user);
        bridgeL2Sov.bridgeMessage{value: 2 ether}(0, user, false, "hi");
        assertEq(bridgeL2Sov.localBalanceTree(LBT_ETH_KEY), 0, "LBT akhir bukan 0");
    }

    // ============ R8-C3: WETH bisa di-remap jadi sovereign token (Info) ============
    // _setSovereignTokenAddress hanya menolak bila wrappedTokenToTokenInfo[addr]
    // .originTokenAddress != 0. WETHToken tidak pernah didaftarkan di mapping itu
    // (deploy di initialize tanpa set mapping), jadi cek lolos dan WETH bisa
    // dipetakan sebagai sovereign token untuk (5, tokenA). Akibatnya klaim
    // (5,tokenA) mencetak WETH, dan WETH itu keluar lagi sebagai leaf (0,0)
    // alias klaim ETH di mainnet — kebingungan ledger WETH/ETH.
    function test_R8C3_WETHRemappedAsSovereignToken() public {
        _initR8();
        address weth3 = address(bridgeL2Gas.WETHToken());
        assertTrue(weth3 != address(0), "WETH gas chain tidak ada");
        // Pra-kondisi: WETH tidak ada di wrappedTokenToTokenInfo.
        (uint32 oNet, address oAddr) = bridgeL2Gas.wrappedTokenToTokenInfo(weth3);
        assertEq(oAddr, address(0), "WETH sudah terdaftar, cek tidak bisa diuji");
        assertEq(oNet, uint32(0), "WETH sudah terdaftar, cek tidak bisa diuji");

        // bridgeManager (test ini) memetakan (5, tokenA) -> WETH. HARUSNYA
        // ditolak (WETH adalah token sistem), tapi lolos.
        uint32[] memory nets = new uint32[](1);
        nets[0] = 5;
        address[] memory origins = new address[](1);
        origins[0] = tokenA;
        address[] memory sovs = new address[](1);
        sovs[0] = weth3;
        bool[] memory notMint = new bool[](1);
        notMint[0] = false;
        bridgeL2Gas.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);

        assertEq(
            bridgeL2Gas.tokenInfoToWrappedToken(keccak256(abi.encodePacked(uint32(5), tokenA))),
            weth3, "mapping (5,tokenA) bukan WETH"
        );
        (oNet, oAddr) = bridgeL2Gas.wrappedTokenToTokenInfo(weth3);
        assertEq(oNet, uint32(5), "info WETH bukan (5,tokenA)");
        assertEq(oAddr, tokenA, "info WETH bukan (5,tokenA)");

        // Klaim leaf (5,tokenA) 10 -> mencetak WETH, bukan wrapped token baru.
        bytes memory metadata = abi.encode("Token A", "TKA", 18);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf5(3, user, 10 ether, metadata);
        _claimRollup5LeafOnSov(bridgeL2Gas, leaves, 0, user, 10 ether, metadata);
        assertEq(
            bridgeL2Gas.getTokenWrappedAddress(5, tokenA), weth3,
            "klaim (5,tokenA) tidak mencetak WETH"
        );
        // Saldo WETH user = 10 (dicetak dari klaim TokenA, tanpa ETH masuk).
        assertEq(
            _wbal(weth3, user), 10 ether,
            "WETH dari klaim TokenA bukan 10"
        );

        // WETH itu di-bridge keluar: cabang token == WETHToken di bridgeAsset
        // selalu membuat leaf origin (0,0) -> klaim ETH di mainnet.
        // TAPI _addLeafBridge (override L2) mengurangi LBT[(0,0)]: tanpa
        // backing ETH, exit ini REVERT LocalBalanceTreeUnderflow. Jadi
        // kebingungan mint TIDAK menciptakan exit ETH tanpa backing.
        vm.prank(user);
        (bool okA, bytes memory retA) = address(bridgeL2Gas).call(
            abi.encodeCall(
                AgglayerBridge.bridgeAsset,
                (uint32(0), user, uint256(10 ether), weth3, false, bytes(""))
            )
        );
        assertFalse(okA, "bridge WETH tanpa LBT[(0,0)] seharusnya revert");
        assertEq(
            bytes4(retA),
            IAgglayerBridgeL2.LocalBalanceTreeUnderflow.selector,
            "revert bukan LocalBalanceTreeUnderflow"
        );

        // Bila ada kapasitas ETH riil (klaim mainnet 5 ETH -> LBT[(0,0)]=5),
        // WETH dari TokenA BISA memakan kapasitas itu: bridge 5 keluar
        // sebagai leaf (0,0) dan sukses; 5 sisanya revert lagi.
        // Artinya: pemegang WETH legit (dari ETH) bisa kehilangan kapasitas
        // exit ke pemegang WETH dari TokenA — kerusakan INTERNAL rantai,
        // bukan drain bridge mainnet (total ETH keluar <= ETH masuk).
        _claimMainnetLeafOnSov(bridgeL2Gas, 3, user, 5 ether);
        assertEq(bridgeL2Gas.localBalanceTree(LBT_ETH_KEY), 5 ether, "LBT[(0,0)] bukan 5");
        vm.prank(user);
        bridgeL2Gas.bridgeAsset(0, user, 5 ether, weth3, false, "");
        bytes32 expectLeaf = MerkleHelper.leafValue(
            0, 0, address(0), 0, user, 5 ether, keccak256("")
        );
        bytes32[] memory oneLeaf = new bytes32[](1);
        oneLeaf[0] = expectLeaf;
        assertEq(
            bridgeL2Gas.getRoot(), MerkleHelper.treeRoot(oneLeaf),
            "leaf keluar WETH bukan (0,0)"
        );
        assertEq(bridgeL2Gas.localBalanceTree(LBT_ETH_KEY), 0, "LBT[(0,0)] akhir bukan 0");
        vm.prank(user);
        (bool okB, bytes memory retB) = address(bridgeL2Gas).call(
            abi.encodeCall(
                AgglayerBridge.bridgeAsset,
                (uint32(0), user, uint256(5 ether), weth3, false, bytes(""))
            )
        );
        assertFalse(okB, "bridge sisa WETH tanpa kapasitas seharusnya revert");
        assertEq(
            bytes4(retB),
            IAgglayerBridgeL2.LocalBalanceTreeUnderflow.selector,
            "revert bukan LocalBalanceTreeUnderflow"
        );
    }

    // ============ R8-C4: amount 0 + destination zero-address ============
    // - bridgeAsset 0 ETH + klaim 0 sukses, bayar 0, nullifier ter-set,
    //   klaim kedua revert AlreadyClaimed (tidak ada inflasi/drain).
    // - bridge ERC20 ke address(0) lalu klaim ke 0 REVERT total (mint ke 0
    //   dilarang OZ) dan nullifier TIDAK ter-set: dana macet karena pilihan
    //   user sendiri, bukan pencurian.
    // - bridgeMessage ke address(0) + klaim ke 0 SUKSES, ETH hangus ke 0.
    function test_R8C4_ZeroAmountAndZeroDestination() public {
        _initR8();
        mockManager.setGER(address(gerL1e));

        // --- amount 0 ETH L2 -> L1, klaim 0 ---
        vm.prank(user);
        bridgeL2.bridgeAsset{value: 0}(0, user, 0, address(0), false, "");
        bytes32 leaf0 = MerkleHelper.leafValue(0, 0, address(0), 0, user, 0, keccak256(""));
        bytes32[] memory leaves0 = new bytes32[](1);
        leaves0[0] = leaf0;
        bytes32 l2Root0 = MerkleHelper.treeRoot(leaves0);
        assertEq(l2Root0, bridgeL2.getRoot(), "root L2 amount-0 salah");
        bytes32[32] memory proofLocal0 = MerkleHelper.treeProof(leaves0, 0);
        bytes32[] memory rollupLeaves0 = new bytes32[](1);
        rollupLeaves0[0] = l2Root0;
        bytes32 rollupRoot0 = MerkleHelper.treeRoot(rollupLeaves0);
        bytes32[32] memory proofRollup0 = MerkleHelper.treeProof(rollupLeaves0, 0);
        mockManager.updateRollupRoot(rollupRoot0);
        uint256 balBefore = user.balance;
        bridgeL1e.claimAsset(
            proofLocal0, proofRollup0, 0, bytes32(0), rollupRoot0,
            0, address(0), 0, user, 0, ""
        );
        assertEq(user.balance, balBefore, "klaim 0 mengubah saldo");
        assertTrue(bridgeL1e.isClaimed(0, 1), "nullifier klaim 0 tidak ter-set");
        vm.expectRevert(IAgglayerBridge.AlreadyClaimed.selector);
        bridgeL1e.claimAsset(
            proofLocal0, proofRollup0, 0, bytes32(0), rollupRoot0,
            0, address(0), 0, user, 0, ""
        );

        // --- ERC20 ke address(0): klaim revert, nullifier TIDAK ter-set ---
        MockPOL tkn = new MockPOL();
        tkn.mint(user, 100 ether);
        vm.prank(user);
        tkn.approve(address(bridgeL2), type(uint256).max);
        vm.prank(user);
        bridgeL2.bridgeAsset(0, address(0), 1 ether, address(tkn), false, "");
        bytes memory meta = bridgeL2.getTokenMetadata(address(tkn));
        bytes32 leafZ = MerkleHelper.leafValue(
            0, 1, address(tkn), 0, address(0), 1 ether, keccak256(meta)
        );
        bytes32[] memory leavesZ = new bytes32[](2);
        leavesZ[0] = leaf0;
        leavesZ[1] = leafZ;
        bytes32 l2RootZ = MerkleHelper.treeRoot(leavesZ);
        assertEq(l2RootZ, bridgeL2.getRoot(), "root L2 zero-dest salah");
        bytes32[32] memory proofLocalZ = MerkleHelper.treeProof(leavesZ, 1);
        bytes32[] memory rollupLeavesZ = new bytes32[](1);
        rollupLeavesZ[0] = l2RootZ;
        bytes32 rollupRootZ = MerkleHelper.treeRoot(rollupLeavesZ);
        bytes32[32] memory proofRollupZ = MerkleHelper.treeProof(rollupLeavesZ, 0);
        mockManager.updateRollupRoot(rollupRootZ);
        (bool ok, ) = address(bridgeL1e).call(
            abi.encodeCall(
                AgglayerBridge.claimAsset,
                (
                    proofLocalZ, proofRollupZ,
                    uint256(1), // globalIndex: rollupIndex 0, leafIndex 1
                    bytes32(0), rollupRootZ,
                    uint32(1), address(tkn), uint32(0), address(0),
                    uint256(1 ether), meta
                )
            )
        );
        assertFalse(ok, "klaim ERC20 ke address(0) seharusnya revert");
        assertFalse(bridgeL1e.isClaimed(1, 1), "nullifier klaim gagal ikut ter-set");

        // --- message ke address(0): klaim sukses, ETH hangus ke 0 ---
        vm.prank(user);
        bridgeL2.bridgeMessage{value: 1 ether}(0, address(0), false, "x");
        bytes32 leafM = MerkleHelper.leafValue(
            1, 1, user, 0, address(0), 1 ether, keccak256("x")
        );
        bytes32[] memory leavesM = new bytes32[](3);
        leavesM[0] = leaf0;
        leavesM[1] = leafZ;
        leavesM[2] = leafM;
        bytes32 l2RootM = MerkleHelper.treeRoot(leavesM);
        assertEq(l2RootM, bridgeL2.getRoot(), "root L2 message-0 salah");
        bytes32[32] memory proofLocalM = MerkleHelper.treeProof(leavesM, 2);
        bytes32[] memory rollupLeavesM = new bytes32[](1);
        rollupLeavesM[0] = l2RootM;
        bytes32 rollupRootM = MerkleHelper.treeRoot(rollupLeavesM);
        bytes32[32] memory proofRollupM = MerkleHelper.treeProof(rollupLeavesM, 0);
        mockManager.updateRollupRoot(rollupRootM);
        uint256 zeroBefore = address(0).balance;
        bridgeL1e.claimMessage(
            proofLocalM, proofRollupM, 2, bytes32(0), rollupRootM,
            1, user, 0, address(0), 1 ether, "x"
        );
        assertEq(address(0).balance, zeroBefore + 1 ether, "ETH tidak hangus ke 0");
        assertTrue(bridgeL1e.isClaimed(2, 1), "nullifier klaim message-0 tidak ter-set");
    }

    // ============ R8-C5: konservasi lintas remap (wrapped lama + sovereign baru) ============
    // Klaim (5,tokenA) 10 -> W1; remap (5,tokenA) -> S (non-mintable, didanai
    // bridge); klaim (5,tokenA) 5 -> S; bridge balik W1 10 + S 5, keduanya
    // ber-leaf origin (5,tokenA); total keluar 15 == total masuk 15,
    // LBT kembali 0. Tidak ada inflasi dari representasi ganda.
    function test_R8C5_RemapConservation() public {
        _initR8();
        bytes memory metadata = abi.encode("Token A", "TKA", 18);

        bytes32 leaf1 = _leaf5(2, user, 10 ether, metadata);
        bytes32[] memory leaves1 = new bytes32[](1);
        leaves1[0] = leaf1;
        address w1 = _claimRollup5LeafOnSov(bridgeL2Sov, leaves1, 0, user, 10 ether, metadata);
        assertTrue(w1 != address(0), "W1 tidak ter-deploy");
        assertEq(_wbal(w1, user), 10 ether, "W1 user bukan 10");

        uint32[] memory nets = new uint32[](1);
        nets[0] = 5;
        address[] memory origins = new address[](1);
        origins[0] = tokenA;
        address[] memory sovs = new address[](1);
        sovs[0] = address(sovTokenS);
        bool[] memory notMint = new bool[](1);
        notMint[0] = true;
        bridgeL2Sov.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);

        bytes32 leaf2 = _leaf5(2, user, 5 ether, metadata);
        bytes32[] memory leaves2 = new bytes32[](2);
        leaves2[0] = leaf1;
        leaves2[1] = leaf2;
        _claimRollup5LeafOnSov(bridgeL2Sov, leaves2, 1, user, 5 ether, metadata);
        assertEq(sovTokenS.balanceOf(user), 5 ether, "S user bukan 5");
        assertEq(_wbal(w1, user), 10 ether, "W1 berubah pasca-remap");
        assertEq(
            bridgeL2Sov.localBalanceTree(keccak256(abi.encodePacked(uint32(5), tokenA))),
            15 ether, "LBT (5,tokenA) bukan 15"
        );

        // Bridge balik keduanya: keduanya harus ber-leaf origin (5,tokenA).
        // S non-mintable -> _bridgeWrappedAsset pakai safeTransferFrom, butuh approval.
        vm.prank(user);
        sovTokenS.approve(address(bridgeL2Sov), type(uint256).max);
        vm.prank(user);
        bridgeL2Sov.bridgeAsset(0, user, 10 ether, w1, false, "");
        vm.prank(user);
        bridgeL2Sov.bridgeAsset(0, user, 5 ether, address(sovTokenS), false, "");
        assertEq(_wbal(w1, user), 0, "W1 tidak habis terbakar");
        assertEq(sovTokenS.balanceOf(user), 0, "S tidak habis ter-bridge");
        assertEq(sovTokenS.balanceOf(address(bridgeL2Sov)), 1000 ether, "S bridge tidak kembali 1000");
        assertEq(
            bridgeL2Sov.localBalanceTree(keccak256(abi.encodePacked(uint32(5), tokenA))),
            0, "LBT (5,tokenA) akhir bukan 0"
        );
        // Root akhir = tree dari 2 leaf bridge-balik, keduanya origin (5,tokenA).
        bytes32 backLeaf1 = MerkleHelper.leafValue(
            0, 5, tokenA, 0, user, 10 ether, keccak256(abi.encode("Token A", "TKA", 18))
        );
        bytes32 backLeaf2 = MerkleHelper.leafValue(
            0, 5, tokenA, 0, user, 5 ether, keccak256(abi.encode("POL", "POL", 18))
        );
        bytes32[] memory backLeaves = new bytes32[](2);
        backLeaves[0] = backLeaf1;
        backLeaves[1] = backLeaf2;
        assertEq(
            bridgeL2Sov.getRoot(), MerkleHelper.treeRoot(backLeaves),
            "leaf bridge-balik bukan origin (5,tokenA)"
        );
    }
}
