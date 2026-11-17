// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {AgglayerManager} from "../src/AgglayerManager.sol";
import {AgglayerGateway} from "../src/AgglayerGateway.sol";
import {PolygonZkEVMEtrog} from "../src/consensus/zkEVM/PolygonZkEVMEtrog.sol";
import {PolygonRollupBaseEtrog} from "../src/lib/PolygonRollupBaseEtrog.sol";
import {PolygonDataCommittee} from "../src/consensus/validium/PolygonDataCommittee.sol";
import {IAgglayerBridge} from "../src/interfaces/IAgglayerBridge.sol";
import {IPolygonZkEVMBridge} from "../src/interfaces/IPolygonZkEVMBridge.sol";
import {IAgglayerGateway, IAgglayerGatewayErrors} from "../src/interfaces/IAgglayerGateway.sol";
import {BridgeLib} from "../src/lib/BridgeLib.sol";
import {IAgglayerGER} from "../src/interfaces/IAgglayerGER.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IBridgeMessageReceiver} from "../src/interfaces/IBridgeMessageReceiver.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {IAggchainSigners} from "../src/interfaces/IAggchainSigners.sol";
import {IPolygonZkEVMErrors} from "../src/interfaces/IPolygonZkEVMErrors.sol";
import {IAgglayerManager} from "../src/interfaces/IAgglayerManager.sol";
import {IPolygonDataCommitteeErrors} from "../src/interfaces/IPolygonDataCommitteeErrors.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts5/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts5/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable4/token/ERC20/IERC20Upgradeable.sol";

// ---------- Mocks ----------
contract MockPOL is ERC20 {
    constructor() ERC20("POL", "POL") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPermitToken is ERC20, ERC20Permit {
    constructor() ERC20("Permit Token", "PTK") ERC20Permit("Permit Token") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSP1Verifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external view override {}
}

/// @notice Minimal stand-in for AgglayerManager: only the functions the
/// consensus/bridge/GER contracts call. Passed to constructors via an
/// explicit address->contract conversion.
contract MockRollupManager {
    uint64 public lastBatchSequenced;
    uint64 public batchFee = 0.01 ether;
    bool public emergencyState;
    uint64 public lastDeactivatedEmergencyStateTimestamp;
    IAgglayerGER public ger;

    function setGER(address _ger) external {
        ger = IAgglayerGER(_ger);
    }

    function onSequenceBatches(uint64 n, bytes32) external returns (uint64) {
        lastBatchSequenced += n;
        return lastBatchSequenced;
    }

    function isEmergencyState() external view returns (bool) {
        return emergencyState;
    }

    function getBatchFee() external view returns (uint256) {
        return batchFee;
    }

    function getForcedBatchFee() external view returns (uint256) {
        return batchFee * 100;
    }

    function updateRollupRoot(bytes32 rollupRoot) external {
        ger.updateExitRoot(rollupRoot);
    }

    function initRollup(
        address rollupProxy,
        address admin,
        address sequencer,
        uint32 networkID,
        string memory url,
        string memory name
    ) external {
        PolygonZkEVMEtrog(rollupProxy).initialize(
            admin,
            sequencer,
            networkID,
            address(0),
            url,
            name
        );
    }
}

/// @notice Receiver that tries to re-enter the bridge during claimMessage.
contract MaliciousReceiver is IBridgeMessageReceiver {
    IAgglayerBridge public bridge;
    bytes public replayCalldata;
    bool public replayReverted;
    bool public replayAttempted;

    function setBridge(address _bridge) external {
        bridge = IAgglayerBridge(_bridge);
    }

    function setReplay(bytes calldata cd) external {
        replayCalldata = cd;
    }

    function onMessageReceived(
        address,
        uint32,
        bytes memory
    ) external payable override {
        replayAttempted = true;
        (bool ok, ) = address(bridge).call(replayCalldata);
        replayReverted = !ok;
    }
}

// ---------- Merkle helpers (deposit-contract tree, depth 32) ----------
library MerkleHelper {
    function zeroHash(uint256 h) internal pure returns (bytes32 z) {
        z = bytes32(0);
        for (uint256 i; i < h; i++) {
            z = keccak256(abi.encodePacked(z, z));
        }
    }

    function treeRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory cur = new bytes32[](leaves.length == 0 ? 1 : leaves.length);
        for (uint256 i; i < leaves.length; i++) cur[i] = leaves[i];
        for (uint256 h; h < 32; h++) {
            uint256 nextLen = (cur.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLen);
            for (uint256 i; i < nextLen; i++) {
                bytes32 left = cur[2 * i];
                bytes32 right = (2 * i + 1 < cur.length) ? cur[2 * i + 1] : zeroHash(h);
                next[i] = keccak256(abi.encodePacked(left, right));
            }
            cur = next;
        }
        return cur[0];
    }

    function treeProof(
        bytes32[] memory leaves,
        uint32 index
    ) internal pure returns (bytes32[32] memory proof) {
        bytes32[][] memory levels = new bytes32[][](33);
        levels[0] = new bytes32[](leaves.length == 0 ? 1 : leaves.length);
        for (uint256 i; i < leaves.length; i++) levels[0][i] = leaves[i];
        for (uint256 h; h < 32; h++) {
            uint256 nextLen = (levels[h].length + 1) / 2;
            levels[h + 1] = new bytes32[](nextLen);
            for (uint256 i; i < nextLen; i++) {
                bytes32 left = levels[h][2 * i];
                bytes32 right = (2 * i + 1 < levels[h].length)
                    ? levels[h][2 * i + 1]
                    : zeroHash(h);
                levels[h + 1][i] = keccak256(abi.encodePacked(left, right));
            }
        }
        for (uint256 h; h < 32; h++) {
            uint256 idx = uint256(index) >> h;
            if (idx % 2 == 0) {
                proof[h] = (idx + 1 < levels[h].length)
                    ? levels[h][idx + 1]
                    : zeroHash(h);
            } else {
                proof[h] = levels[h][idx - 1];
            }
        }
    }

    function leafValue(
        uint8 leafType,
        uint32 originNetwork,
        address originAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes32 metadataHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    leafType,
                    originNetwork,
                    originAddress,
                    destinationNetwork,
                    destinationAddress,
                    amount,
                    metadataHash
                )
            );
    }
}

contract AgglayerR1Test is Test {
    MockPOL public pol;
    MockRollupManager public mockManager;
    MockSP1Verifier public mockVerifier;

    AgglayerBridge public bridgeL1; // proxy, networkID 0
    AgglayerGER public gerL1;
    AgglayerBridge public bridgeL2; // proxy, networkID 1
    AgglayerGER public gerL2;
    AgglayerGateway public gateway;
    AgglayerManager public manager;
    PolygonZkEVMEtrog public etrog;

    address public user = address(0xBEEF);
    address public sequencer = address(0x5EED);
    uint256 public victimPk = 0x1234;
    address public victim;

    bytes4 public constant PP_SELECTOR = 0x12345678;

    function setUp() public {
        vm.warp(1_700_000_000);
        victim = vm.addr(victimPk);
        vm.deal(address(this), 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(sequencer, 100 ether);

        pol = new MockPOL();
        mockManager = new MockRollupManager();
        mockVerifier = new MockSP1Verifier();

        // --- L1 bridge proxy (network 0) ---
        AgglayerBridge bridgeImpl = new AgglayerBridge();
        TransparentUpgradeableProxy bridgeProxy = new TransparentUpgradeableProxy(
            address(bridgeImpl),
            address(this),
            ""
        );
        bridgeL1 = AgglayerBridge(payable(address(bridgeProxy)));

        // --- L1 GER (rollupManager = mock, bridge = L1 proxy) ---
        AgglayerGER gerImpl = new AgglayerGER(
            address(mockManager),
            address(bridgeL1)
        );
        ERC1967Proxy gerProxy = new ERC1967Proxy(address(gerImpl), "");
        gerL1 = AgglayerGER(address(gerProxy));
        mockManager.setGER(address(gerL1));

        // --- L1 bridge initialize ---
        bridgeL1.initialize(
            0,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(gerL1)),
            address(mockManager),
            ""
        );
        gerL1.initialize();

        // --- L2 bridge proxy (network 1) + L2 GER ---
        TransparentUpgradeableProxy bridgeL2Proxy = new TransparentUpgradeableProxy(
            address(bridgeImpl),
            address(this),
            ""
        );
        bridgeL2 = AgglayerBridge(payable(address(bridgeL2Proxy)));
        AgglayerGER gerL2Impl = new AgglayerGER(
            address(mockManager),
            address(bridgeL2)
        );
        ERC1967Proxy gerL2Proxy = new ERC1967Proxy(address(gerL2Impl), "");
        gerL2 = AgglayerGER(address(gerL2Proxy));
        bridgeL2.initialize(
            1,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(gerL2)),
            address(0),
            ""
        );
        gerL2.initialize();

        // --- Gateway ---
        AgglayerGateway gatewayImpl = new AgglayerGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), "");
        gateway = AgglayerGateway(address(gatewayProxy));
        IAggchainSigners.SignerInfo[] memory signers = new IAggchainSigners.SignerInfo[](1);
        signers[0] = IAggchainSigners.SignerInfo({addr: address(0x51CE), url: "https://signer.example"});
        gateway.initialize(
            address(this), // defaultAdmin
            address(this), // aggchainDefaultVKeyRole
            address(this), // addRouteRole
            address(this), // freezeRouteRole
            PP_SELECTOR,
            address(mockVerifier),
            bytes32(uint256(0xABCD)),
            address(this), // multisigRole
            signers,
            1
        );

        // --- Real manager (proxy) ---
        AgglayerManager managerImpl = new AgglayerManager(
            IAgglayerGER(address(gerL1)),
            IERC20Upgradeable(address(pol)),
            IPolygonZkEVMBridge(address(bridgeL1)),
            IAgglayerGateway(address(gateway))
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), "");
        manager = AgglayerManager(address(managerProxy));
        manager.initialize();

        // --- Etrog consensus (proxy, admin = mock manager) ---
        PolygonZkEVMEtrog etrogImpl = new PolygonZkEVMEtrog(
            IAgglayerGER(address(gerL1)),
            IERC20Upgradeable(address(pol)),
            IAgglayerBridge(address(bridgeL1)),
            AgglayerManager(address(mockManager))
        );
        TransparentUpgradeableProxy etrogProxy = new TransparentUpgradeableProxy(
            address(etrogImpl),
            address(mockManager),
            ""
        );
        etrog = PolygonZkEVMEtrog(address(etrogProxy));
        mockManager.initRollup(
            address(etrog),
            address(this), // admin
            sequencer,
            1,
            "https://seq.example",
            "testnet"
        );
        // Open force batches to everyone
        etrog.setForceBatchAddress(address(0));

        vm.deal(address(bridgeL1), 100 ether);
    }

    // Helper: bridge 1 ether on L2 to L1, register rollup root on L1 GER.
    // Returns (leaf, l2Root, rollupRoot, proofLocal, proofRollup).
    function _bridgeL2ToL1Asset(
        address dest,
        uint256 amount
    )
        internal
        returns (
            bytes32 leaf,
            bytes32 rollupRoot,
            bytes32[32] memory proofLocal,
            bytes32[32] memory proofRollup
        )
    {
        vm.prank(user);
        bridgeL2.bridgeAsset{value: amount}(
            0,
            dest,
            amount,
            address(0),
            false,
            ""
        );
        leaf = MerkleHelper.leafValue(
            0,
            0,
            address(0),
            0,
            dest,
            amount,
            keccak256("")
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        bytes32 l2Root = MerkleHelper.treeRoot(leaves);
        assertEq(l2Root, bridgeL2.getRoot(), "l2 root mismatch");
        proofLocal = MerkleHelper.treeProof(leaves, 0);
        bytes32[] memory rollupLeaves = new bytes32[](1);
        rollupLeaves[0] = l2Root;
        rollupRoot = MerkleHelper.treeRoot(rollupLeaves);
        proofRollup = MerkleHelper.treeProof(rollupLeaves, 0);
        mockManager.updateRollupRoot(rollupRoot);
    }

    // ============ CANDIDATE 1: L1 nullifier collision (mainnet vs rollup-0) ============
    // A mainnet-origin leaf can never exist on the L1 bridge because bridging to
    // your own network reverts. The special-case nullifier slot is unreachable
    // for mainnet leaves, so the apparent collision cannot freeze funds.
    function test_BridgeAssetToOwnNetworkReverts() public {
        vm.expectRevert(IAgglayerBridge.DestinationNetworkInvalid.selector);
        bridgeL1.bridgeAsset{value: 1 ether}(
            0, // destinationNetwork == networkID
            user,
            1 ether,
            address(0),
            false,
            ""
        );
        vm.expectRevert(IAgglayerBridge.DestinationNetworkInvalid.selector);
        bridgeL1.bridgeMessage(0, user, false, "x");
    }

    // ============ CANDIDATE 2: double claim / replay ============
    function test_DoubleClaimReverts() public {
        (
            ,
            bytes32 rollupRoot,
            bytes32[32] memory proofLocal,
            bytes32[32] memory proofRollup
        ) = _bridgeL2ToL1Asset(user, 1 ether);

        uint256 balBefore = user.balance;
        bridgeL1.claimAsset(
            proofLocal,
            proofRollup,
            0, // globalIndex: mainnet flag 0, rollupIndex 0, leafIndex 0
            bytes32(0), // mainnetExitRoot (never updated on L1 GER)
            rollupRoot,
            0, // originNetwork
            address(0), // originTokenAddress (ether)
            0, // destinationNetwork
            user,
            1 ether,
            ""
        );
        assertEq(user.balance, balBefore + 1 ether, "claim payout wrong");
        assertTrue(bridgeL1.isClaimed(0, 1), "nullifier not set");

        // Second claim of the same leaf must revert
        vm.expectRevert(IAgglayerBridge.AlreadyClaimed.selector);
        bridgeL1.claimAsset(
            proofLocal,
            proofRollup,
            0,
            bytes32(0),
            rollupRoot,
            0,
            address(0),
            0,
            user,
            1 ether,
            ""
        );
    }

    // ============ CANDIDATE 3: claimMessage reentrancy ============
    function test_ClaimMessageReentrancyNoDoubleSpend() public {
        MaliciousReceiver receiver = new MaliciousReceiver();
        receiver.setBridge(address(bridgeL1));

        // Bridge a message on L2 to the malicious receiver
        bytes memory metadata = "hello";
        vm.prank(user);
        bridgeL2.bridgeMessage{value: 0.5 ether}(0, address(receiver), false, metadata);

        bytes32 leaf = MerkleHelper.leafValue(
            1, // leaf type message
            1, // originNetwork = L2 networkID
            user, // originAddress = msg.sender on L2
            0,
            address(receiver),
            0.5 ether,
            keccak256(metadata)
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        bytes32 l2Root = MerkleHelper.treeRoot(leaves);
        assertEq(l2Root, bridgeL2.getRoot(), "l2 root mismatch (msg)");
        bytes32[32] memory proofLocal = MerkleHelper.treeProof(leaves, 0);
        bytes32[] memory rollupLeaves = new bytes32[](1);
        rollupLeaves[0] = l2Root;
        bytes32 rollupRoot = MerkleHelper.treeRoot(rollupLeaves);
        bytes32[32] memory proofRollup = MerkleHelper.treeProof(rollupLeaves, 0);
        mockManager.updateRollupRoot(rollupRoot);

        // Build the exact replay calldata for the receiver to attempt
        bytes memory replay = abi.encodeCall(
            IAgglayerBridge.claimMessage,
            (
                proofLocal,
                proofRollup,
                0,
                bytes32(0),
                rollupRoot,
                1,
                user,
                0,
                address(receiver),
                0.5 ether,
                metadata
            )
        );
        receiver.setReplay(replay);

        uint256 bridgeBalBefore = address(bridgeL1).balance;
        bridgeL1.claimMessage(
            proofLocal,
            proofRollup,
            0,
            bytes32(0),
            rollupRoot,
            1,
            user,
            0,
            address(receiver),
            0.5 ether,
            metadata
        );

        assertTrue(receiver.replayAttempted(), "reentrancy not attempted");
        assertTrue(receiver.replayReverted(), "reentrant claim did NOT revert");
        assertEq(address(receiver).balance, 0.5 ether, "receiver got != 1 payout");
        assertEq(
            address(bridgeL1).balance,
            bridgeBalBefore - 0.5 ether,
            "bridge paid more than once"
        );

        // External replay also reverts
        vm.expectRevert(IAgglayerBridge.AlreadyClaimed.selector);
        bridgeL1.claimMessage(
            proofLocal,
            proofRollup,
            0,
            bytes32(0),
            rollupRoot,
            1,
            user,
            0,
            address(receiver),
            0.5 ether,
            metadata
        );
    }

    // ============ CANDIDATE 4: force-batch timeout gating ============
    function test_ForceBatchTimeoutEnforced() public {
        pol.mint(user, 100 ether);
        vm.startPrank(user);
        pol.approve(address(etrog), 100 ether);

        bytes memory txData = hex"1234";
        etrog.forceBatch(txData, 100 ether);
        uint64 forcedTs = uint64(block.timestamp);
        bytes32 forcedBlockHash = blockhash(block.number - 1);
        bytes32 forcedGER = gerL1.getLastGlobalExitRoot();
        vm.stopPrank();

        PolygonRollupBaseEtrog.BatchData[] memory batches = new PolygonRollupBaseEtrog.BatchData[](1);
        batches[0] = PolygonRollupBaseEtrog.BatchData({
            transactions: txData,
            forcedGlobalExitRoot: forcedGER,
            forcedTimestamp: forcedTs,
            forcedBlockHashL1: forcedBlockHash
        });

        // Before timeout: must revert
        vm.expectRevert(
            IPolygonZkEVMErrors.ForceBatchTimeoutNotExpired.selector
        );
        etrog.sequenceForceBatches(batches);

        // After timeout: succeeds
        vm.warp(block.timestamp + 5 days + 1);
        etrog.sequenceForceBatches(batches);
        assertEq(etrog.lastForceBatchSequenced(), 1, "force batch not sequenced");
    }

    function test_ForceBatchLastBatchGatesWholeArray() public {
        pol.mint(user, 100 ether);
        vm.startPrank(user);
        pol.approve(address(etrog), 100 ether);
        bytes memory txA = hex"aaaa";
        bytes memory txB = hex"bbbb";
        etrog.forceBatch(txA, 100 ether);
        // NOTE: read timestamp via cheatcode, not `uint64(block.timestamp)`:
        // with via_ir the optimizer reuses the first TIMESTAMP load across
        // the warp (CSE), so a second plain read returns the stale value.
        uint64 tsA = uint64(vm.getBlockTimestamp());
        bytes32 bhA = blockhash(block.number - 1);
        bytes32 gerA = gerL1.getLastGlobalExitRoot();
        vm.warp(block.timestamp + 1);
        etrog.forceBatch(txB, 100 ether);
        uint64 tsB = uint64(vm.getBlockTimestamp());
        bytes32 bhB = blockhash(block.number - 1);
        bytes32 gerB = gerL1.getLastGlobalExitRoot();
        vm.stopPrank();

        PolygonRollupBaseEtrog.BatchData[] memory both = new PolygonRollupBaseEtrog.BatchData[](2);
        both[0] = PolygonRollupBaseEtrog.BatchData(txA, gerA, tsA, bhA);
        both[1] = PolygonRollupBaseEtrog.BatchData(txB, gerB, tsB, bhB);

        // A expired, B not: whole array must revert (last-batch check gates it).
        // A expires at tsA+5d, B at tsB+5d = tsA+5d+1, so warp exactly to tsA+5d.
        vm.warp(tsA + 5 days);
        vm.expectRevert(
            IPolygonZkEVMErrors.ForceBatchTimeoutNotExpired.selector
        );
        etrog.sequenceForceBatches(both);

        // A alone succeeds
        PolygonRollupBaseEtrog.BatchData[] memory onlyA = new PolygonRollupBaseEtrog.BatchData[](1);
        onlyA[0] = both[0];
        etrog.sequenceForceBatches(onlyA);
        assertEq(etrog.lastForceBatchSequenced(), 1);

        // B after its own timeout succeeds
        vm.warp(tsB + 5 days + 1);
        PolygonRollupBaseEtrog.BatchData[] memory onlyB = new PolygonRollupBaseEtrog.BatchData[](1);
        onlyB[0] = both[1];
        etrog.sequenceForceBatches(onlyB);
        assertEq(etrog.lastForceBatchSequenced(), 2);
    }

    // ============ CANDIDATE 5: permit validation ============
    function test_PermitWrongOwnerReverts() public {
        MockPermitToken token = new MockPermitToken();
        token.mint(victim, 10 ether);
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        permitTypehash,
                        victim,
                        address(bridgeL1),
                        amount,
                        token.nonces(victim),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimPk, digest);
        // BridgeLib does abi.decode(permitData[4:], ...) so params must be
        // ABI-encoded (32-byte words), not packed.
        bytes memory permitData = abi.encodePacked(
            bytes4(0xd505accf),
            abi.encode(victim, address(bridgeL1), amount, deadline, v, r, s)
        );

        // Attacker tries to use victim's permit: owner != msg.sender
        vm.prank(user);
        vm.expectRevert(BridgeLib.NotValidOwner.selector);
        bridgeL1.bridgeAsset(1, victim, amount, address(token), false, permitData);

        // Victim's own call with the valid permit succeeds
        vm.prank(victim);
        bridgeL1.bridgeAsset(1, victim, amount, address(token), false, permitData);
        assertEq(token.balanceOf(address(bridgeL1)), amount, "bridge did not receive tokens");
    }

    // ============ CANDIDATE 6: permissionless emergency activation gated ============
    function test_EmergencyActivationBeforeTimeoutReverts() public {
        address randomCaller = address(0x9999);
        vm.prank(randomCaller);
        vm.expectRevert(IAgglayerManager.HaltTimeoutNotExpired.selector);
        manager.activateEmergencyState();
    }

    // ============ CANDIDATE 7: gateway frozen route ============
    function test_GatewayFrozenRouteReverts() public {
        bytes memory proof = abi.encodePacked(PP_SELECTOR, bytes4(0xdeadbeef), hex"112233");
        // Valid route verifies (mock verifier is a no-op)
        gateway.verifyPessimisticProof("", proof);

        gateway.freezePessimisticVKeyRoute(PP_SELECTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgglayerGatewayErrors.RouteIsFrozen.selector,
                PP_SELECTOR
            )
        );
        gateway.verifyPessimisticProof("", proof);
    }

    // ============ CANDIDATE 8: data committee duplicate signatures ============
    function test_DataCommitteeDuplicateSignatureReverts() public {
        PolygonDataCommittee committeeImpl = new PolygonDataCommittee();
        ERC1967Proxy committeeProxy = new ERC1967Proxy(address(committeeImpl), "");
        PolygonDataCommittee committee = PolygonDataCommittee(address(committeeProxy));
        committee.initialize();

        uint256[3] memory pks = [uint256(0x1111), uint256(0x2222), uint256(0x3333)];
        address[3] memory addrs;
        for (uint256 i; i < 3; i++) addrs[i] = vm.addr(pks[i]);
        // sort (pk, addr) pairs by address ascending
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (addrs[i] > addrs[j]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }
        string[] memory urls = new string[](3);
        urls[0] = "https://m1.example";
        urls[1] = "https://m2.example";
        urls[2] = "https://m3.example";
        bytes memory addrsBytes = abi.encodePacked(addrs[0], addrs[1], addrs[2]);
        committee.setupCommittee(2, urls, addrsBytes);

        bytes32 signedHash = keccak256("test-data");
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pks[0], signedHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pks[1], signedHash);
        bytes memory sig1 = abi.encodePacked(r1, s1, v1);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);

        // Valid: two distinct signatures
        committee.verifyMessage(signedHash, abi.encodePacked(sig1, sig2, addrsBytes));

        // Invalid: same signature twice (double-count attempt)
        vm.expectRevert(
            IPolygonDataCommitteeErrors.CommitteeAddressDoesNotExist.selector
        );
        committee.verifyMessage(signedHash, abi.encodePacked(sig1, sig1, addrsBytes));
    }
}
