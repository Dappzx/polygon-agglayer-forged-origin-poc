// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 5 — AggLayer (agglayer-contracts @ 110bda5a, HEAD tidak bergerak)
// Permukaan BARU yang belum tersentuh dalam (tugas r5c):
//   AgglayerBridgeL2.migrateLegacyToken — jalur PERMISSIONLESS yang memindahkan
//   pemegang token legacy (wrapped lama) ke token sovereign saat ini, 1:1,
//   dengan kombinasi mintable / non-mintable + fee-on-transfer.
//   Plus: perilaku bridgeAsset setelah removeLegacySovereignTokenAddress.
// Yang SUDAH jenuh dan TIDAK diulang: addNewRollupType, verifier (address 0),
// ClaimCompressor, updateQuorum, gateway routes, LET/LBT (r2 V5), permit (r1 K5).

import "forge-std/Test.sol";
import {AgglayerBridgeL2} from "../src/sovereignChains/AgglayerBridgeL2.sol";
import {TokenWrapped} from "../src/lib/TokenWrapped.sol";
import {IAgglayerBridgeL2} from "../src/interfaces/IAgglayerBridgeL2.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {MockGERFull} from "./AgglayerR3.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice ERC20 fee-on-transfer tiruan (10% fee hangus saat transfer) yang
/// mengimplementasikan antarmuka mint/burn yang dipakai bridge.
contract MockFoTToken {
    string public name = "Fee Token";
    string public symbol = "FOT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable bridgeAddress;

    constructor(address _bridge) {
        bridgeAddress = _bridge;
    }

    function mint(address to, uint256 value) external {
        require(msg.sender == bridgeAddress, "only bridge");
        balanceOf[to] += value;
        totalSupply += value;
    }

    function burn(address account, uint256 value) external {
        require(msg.sender == bridgeAddress, "only bridge");
        balanceOf[account] -= value;
        totalSupply -= value;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transferFrom(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - value;
        }
        return _transferFrom(from, to, value);
    }

    function _transferFrom(address from, address to, uint256 value) internal returns (bool) {
        balanceOf[from] -= value;
        // 10% fee hangus (tidak dikreditkan ke siapa pun)
        balanceOf[to] += (value * 90) / 100;
        return true;
    }
}

contract AgglayerR5Test is Test {
    AgglayerBridgeL2 public bridgeL2;
    MockGERFull public mockGer;

    address public user = address(0xBEEF);
    address public other = address(0xCAFE);
    address public proxiedTokensManager = makeAddr("proxiedTokensManager");

    uint32 public constant ORIGIN_NETWORK = 1;
    address public constant ORIGIN_TOKEN = address(0xBEEF01);
    uint32 public constant NETWORK_ID = 2;

    TokenWrapped public legacy;
    TokenWrapped public current;

    function setUp() public {
        mockGer = new MockGERFull();
        // BridgeL2 adalah implementation yang _disableInitializers di
        // constructor -> harus di-deploy di belakang proxy seperti produksi.
        AgglayerBridgeL2 bridgeImpl = new AgglayerBridgeL2();
        bridgeL2 = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(bridgeImpl), "")))
        );
        bridgeL2.initialize(
            NETWORK_ID,
            address(0), // gas token = ether
            0,
            IBaseLegacyAgglayerGER(address(mockGer)),
            address(0), // polygonRollupManager = 0 di L2
            "",
            address(this), // bridgeManager = test ini
            address(0), // sovereign WETH: tidak ada (gas = ether)
            false,
            address(0), // emergency pauser: dimatikan
            address(0), // emergency unpauser: dimatikan
            proxiedTokensManager
        );

        // Token legacy + token saat ini, keduanya TokenWrapped asli dengan
        // bridge = bridgeL2 (mint/burn onlyBridge).
        vm.prank(address(bridgeL2));
        legacy = new TokenWrapped("Legacy Token", "LEG", 18);
        vm.prank(address(bridgeL2));
        current = new TokenWrapped("Current Token", "CUR", 18);
    }

    function _mapOriginTo(address sovereign, bool isNotMintable) internal {
        uint32[] memory networks = new uint32[](1);
        address[] memory origins = new address[](1);
        address[] memory sovereigns = new address[](1);
        bool[] memory flags = new bool[](1);
        networks[0] = ORIGIN_NETWORK;
        origins[0] = ORIGIN_TOKEN;
        sovereigns[0] = sovereign;
        flags[0] = isNotMintable;
        bridgeL2.setMultipleSovereignTokenAddress(networks, origins, sovereigns, flags);
    }

    /// @dev Daftarkan `legacy` sebagai token pertama, lalu remap ke `current`.
    /// Setelah ini `legacy` berstatus legacy dan `current` adalah mapping aktif.
    function _setupLegacyAndCurrent(bool legacyNotMintable, bool currentNotMintable) internal {
        _mapOriginTo(address(legacy), legacyNotMintable);
        _mapOriginTo(address(current), currentNotMintable);
    }

    function _mintLegacy(address to, uint256 amount) internal {
        vm.prank(address(bridgeL2));
        legacy.mint(to, amount);
    }

    function _migrate(address token, uint256 amount) internal {
        vm.prank(user);
        bridgeL2.migrateLegacyToken(token, amount, "");
    }

    // ---- C1: happy path mintable -> mintable, konservasi 1:1 eksak --------
    function test_R5_migrateLegacy_mintableToMintable() public {
        _setupLegacyAndCurrent(false, false);
        _mintLegacy(user, 1000e18);

        _migrate(address(legacy), 400e18);
        assertEq(legacy.balanceOf(user), 600e18, "legacy left after partial migrate");
        assertEq(current.balanceOf(user), 400e18, "current minted 1:1");
        assertEq(legacy.totalSupply(), 600e18, "legacy supply shrinks by burned amount");
        assertEq(current.totalSupply(), 400e18, "current supply equals migrated amount");

        _migrate(address(legacy), 600e18);
        assertEq(legacy.balanceOf(user), 0, "legacy fully migrated");
        assertEq(current.balanceOf(user), 1000e18, "current equals original legacy balance");
        assertEq(legacy.totalSupply(), 0, "legacy supply zero");
        assertEq(current.totalSupply(), 1000e18, "current supply equals original");
    }

    // ---- C2: legacy non-mintable (transfer ke bridge) -> current mintable --
    function test_R5_migrateLegacy_nonMintableLegacy() public {
        _setupLegacyAndCurrent(true, false);
        _mintLegacy(user, 500e18);

        vm.prank(user);
        legacy.approve(address(bridgeL2), 500e18);

        _migrate(address(legacy), 500e18);
        assertEq(legacy.balanceOf(user), 0, "legacy moved out of user");
        assertEq(legacy.balanceOf(address(bridgeL2)), 500e18, "bridge holds transferred legacy");
        assertEq(current.balanceOf(user), 500e18, "current minted 1:1");
    }

    // ---- C3: current non-mintable dibayar dari saldo bridge ----------------
    function test_R5_migrateLegacy_nonMintableCurrent() public {
        _setupLegacyAndCurrent(false, true);
        _mintLegacy(user, 200e18);

        // Saldo bridge atas current kurang -> migrate revert.
        vm.prank(address(bridgeL2));
        current.mint(address(bridgeL2), 100e18);
        vm.expectRevert();
        _migrate(address(legacy), 200e18);

        // Setelah bridge didanai penuh -> migrate sukses, bridge terkuras pas.
        vm.prank(address(bridgeL2));
        current.mint(address(bridgeL2), 100e18);
        _migrate(address(legacy), 200e18);
        assertEq(current.balanceOf(user), 200e18, "user paid from bridge balance");
        assertEq(current.balanceOf(address(bridgeL2)), 0, "bridge current balance drained exactly");
        assertEq(legacy.balanceOf(user), 0, "legacy burned");
    }

    // ---- C4: semua percobaan curang harus revert tanpa perubahan state -----
    function test_R5_migrateLegacy_attackAttemptsRevert() public {
        _setupLegacyAndCurrent(false, false);
        _mintLegacy(user, 100e18);

        // (a) migrate melebihi saldo
        vm.expectRevert();
        _migrate(address(legacy), 101e18);
        assertEq(legacy.balanceOf(user), 100e18, "balance unchanged after failed migrate");

        // (b) token yang tidak pernah di-mapping
        vm.prank(address(bridgeL2));
        TokenWrapped unmapped = new TokenWrapped("Unmapped", "UNM", 18);
        vm.prank(user);
        vm.expectRevert(IAgglayerBridgeL2.TokenNotMapped.selector);
        bridgeL2.migrateLegacyToken(address(unmapped), 1e18, "");

        // (c) token yang SUDAH menjadi mapping aktif (bukan legacy)
        vm.prank(user);
        vm.expectRevert(IAgglayerBridgeL2.TokenAlreadyUpdated.selector);
        bridgeL2.migrateLegacyToken(address(current), 1e18, "");

        // (d) double-migrate: setelah saldo habis, migrate lagi revert
        _migrate(address(legacy), 100e18);
        assertEq(current.balanceOf(user), 100e18, "first migrate ok");
        vm.expectRevert();
        _migrate(address(legacy), 1);

        // (e) orang lain tidak bisa memigrasikan token user
        _mintLegacy(user, 50e18);
        vm.prank(other);
        vm.expectRevert();
        bridgeL2.migrateLegacyToken(address(legacy), 50e18, "");
        assertEq(legacy.balanceOf(user), 50e18, "victim balance untouched");
        assertEq(current.balanceOf(other), 0, "attacker got nothing");
    }

    // ---- C5: legacy fee-on-transfer non-mintable: yang diklaim = yang DITERIMA
    function test_R5_migrateLegacy_feeOnTransferLegacy() public {
        MockFoTToken fot = new MockFoTToken(address(bridgeL2));
        _mapOriginTo(address(fot), true); // legacy, non-mintable
        _mapOriginTo(address(current), false); // current, mintable

        vm.prank(address(bridgeL2));
        fot.mint(user, 1000e18);
        vm.prank(user);
        fot.approve(address(bridgeL2), 1000e18);

        _migrate(address(fot), 1000e18);
        // Bridge hanya menerima 900 (fee 10%), jadi yang di-mint juga 900 —
        // bukan 1000 yang diminta. Konservasi pada jumlah yang diterima.
        assertEq(fot.balanceOf(address(bridgeL2)), 900e18, "bridge received 900 after fee");
        assertEq(current.balanceOf(user), 900e18, "user minted exactly what bridge received");
        assertEq(fot.balanceOf(user), 0, "user fot fully spent");
    }

    // ---- C6: setelah removeLegacy, migrate tertutup tapi bridge-out tetap 1:1
    function test_R5_removeLegacyThenBridgeOutStillConserves() public {
        _setupLegacyAndCurrent(false, false);
        _mintLegacy(user, 300e18);

        // BridgeManager menghapus mapping legacy.
        bridgeL2.removeLegacySovereignTokenAddress(address(legacy));
        (uint32 oNet, address oTok) = bridgeL2.wrappedTokenToTokenInfo(address(legacy));
        assertEq(oNet, 0, "legacy originNetwork cleared");
        assertEq(oTok, address(0), "legacy originToken cleared");
        // Mapping aktif (1, ORIGIN_TOKEN) -> current tidak tersentuh.
        bytes32 h = keccak256(abi.encodePacked(ORIGIN_NETWORK, ORIGIN_TOKEN));
        assertEq(bridgeL2.tokenInfoToWrappedToken(h), address(current), "current mapping intact");

        // Migrate legacy sekarang tertutup.
        vm.prank(user);
        vm.expectRevert(IAgglayerBridgeL2.TokenNotMapped.selector);
        bridgeL2.migrateLegacyToken(address(legacy), 1e18, "");

        // Tapi user tetap bisa bridge-out token legacy-nya: karena mapping
        // terhapus, bridgeAsset memperlakukannya sebagai token native chain ini
        // (originNetwork = 2, originTokenAddress = legacy) dan MENGUNCI-nya,
        // bukan membakar. Tidak ada dana hilang / tercetak ganda.
        uint256 depositsBefore = bridgeL2.depositCount();
        vm.prank(user);
        legacy.approve(address(bridgeL2), 300e18);
        vm.prank(user);
        bridgeL2.bridgeAsset(1, user, 300e18, address(legacy), false, "");
        assertEq(legacy.balanceOf(user), 0, "user legacy spent");
        assertEq(legacy.balanceOf(address(bridgeL2)), 300e18, "bridge locks legacy 1:1");
        assertEq(bridgeL2.depositCount(), depositsBefore + 1, "one leaf added");
        assertEq(legacy.totalSupply(), 300e18, "no burn, no mint: supply unchanged");
    }
}
